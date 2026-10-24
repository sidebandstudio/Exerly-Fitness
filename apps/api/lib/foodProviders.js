const budget = require('./providerBudget');
const CACHE_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const NUTRIENTS = [
  'calories',
  'protein',
  'carbs',
  'fat',
  'fiber',
  'sugar',
  'sodium',
  'saturated_fat',
];
const OFF_FIELDS =
  'code,product_name,product_name_en,brands,categories_tags,nutriments,nutrition_data_per,product_quantity,product_quantity_unit,quantity,serving_size,serving_quantity,serving_quantity_unit';

function num(value) {
  if (value == null || value === '') return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
}
function metadata(food) {
  return {
    ...food,
    missing_nutrients: NUTRIENTS.filter((key) => food[key] == null),
    fetched_at: new Date().toISOString(),
    region: process.env.FOOD_REGION || 'US',
  };
}

function mapOpenFoodFactsProduct(product, barcode = null) {
  const name = product.product_name || product.product_name_en;
  if (!name) return null;
  const nutrients = product.nutriments || {};
  const volumeLabel = /^\s*\d+(?:[.,]\d+)?\s*(?:ml|cl|dl|l|millilit(?:er|re)s?|lit(?:er|re)s?)\b/i;
  const liquid =
    ['ml', 'l', 'cl', 'dl'].includes(product.product_quantity_unit) ||
    product.nutrition_data_per === '100ml' ||
    product.serving_quantity_unit === 'ml' ||
    volumeLabel.test(product.serving_size || '');
  const unit = liquid ? 'ml' : 'g';
  const nutrient = (name) => num(nutrients[`${name}_100g`]);
  const energy = nutrient('energy-kcal');
  const sodium = nutrient('sodium');
  const portions = [{ id: '100', label: `100 ${unit}`, amount: 100, unit, multiplier: 1 }];
  const serving = num(product.serving_quantity);
  const servingUnit = product.serving_quantity_unit;
  if (serving > 0 && servingUnit === unit) {
    portions.push({
      id: 'serving',
      label: product.serving_size || `${serving} ${unit}`,
      amount: serving,
      unit,
      multiplier: serving / 100,
    });
  }
  return metadata({
    barcode: barcode || product.code || null,
    name,
    brand: product.brands || null,
    calories: energy == null ? null : Math.round(energy),
    protein: nutrient('proteins'),
    carbs: nutrient('carbohydrates'),
    fat: nutrient('fat'),
    fiber: nutrient('fiber'),
    sugar: nutrient('sugars'),
    sodium: sodium == null ? null : sodium * 1000,
    saturated_fat: nutrient('saturated-fat'),
    serving_size: `100 ${unit}`,
    nutrition_basis: {
      amount: 100,
      unit,
      nutrient_units: { energy: 'kcal', sodium: 'mg', other: 'g' },
    },
    portions,
    source: 'openfoodfacts',
    cacheable: true,
  });
}

function mapFatSecretFood(food, barcode = null) {
  if (!food?.food_name) return null;
  const raw = food.servings?.serving;
  const servings = Array.isArray(raw) ? raw : raw ? [raw] : [];
  const serving = servings.find((s) => String(s.is_default) === '1') || servings[0];
  if (!serving) return null;
  const calories = num(serving.calories);
  return metadata({
    barcode,
    name: food.food_name,
    brand: food.brand_name || null,
    food_id: String(food.food_id),
    serving_id: String(serving.serving_id),
    calories: calories == null ? null : Math.round(calories),
    protein: num(serving.protein),
    carbs: num(serving.carbohydrate),
    fat: num(serving.fat),
    fiber: num(serving.fiber),
    sugar: num(serving.sugar),
    sodium: num(serving.sodium),
    saturated_fat: num(serving.saturated_fat),
    serving_size: serving.serving_description || '1 serving',
    nutrition_basis: {
      amount: num(serving.metric_serving_amount) ?? 1,
      unit: serving.metric_serving_unit || 'serving',
      nutrient_units: { energy: 'kcal', sodium: 'mg', other: 'g' },
    },
    portions: servings.map((s) => ({
      id: String(s.serving_id),
      label: s.serving_description,
      amount: num(s.metric_serving_amount),
      unit: s.metric_serving_unit,
      nutrients: {
        calories: num(s.calories),
        protein: num(s.protein),
        carbs: num(s.carbohydrate),
        fat: num(s.fat),
        fiber: num(s.fiber),
        sugar: num(s.sugar),
        sodium: num(s.sodium),
        saturated_fat: num(s.saturated_fat),
      },
    })),
    source: 'fatsecret',
    cacheable: false,
  });
}

async function fetchJSON(
  url,
  { fetchImpl = fetch, deadline = Date.now() + 6500, headers = {}, ...options } = {}
) {
  const controller = new AbortController();
  const timer = setTimeout(
    () => controller.abort(),
    Math.max(1, Math.min(3500, deadline - Date.now()))
  );
  try {
    const response = await fetchImpl(url, { ...options, headers, signal: controller.signal });
    if (Number(response.headers.get('content-length')) > 2_000_000)
      throw new Error('Provider response too large');
    const text = await response.text();
    if (text.length > 2_000_000) throw new Error('Provider response too large');
    const data = text ? JSON.parse(text) : {};
    return { response, data };
  } finally {
    clearTimeout(timer);
  }
}

// Kept for callers that need a Response; timeout also covers reading its body
// in all food-provider calls, which use fetchJSON directly.
async function fetchWithTimeout(url, options = {}, timeoutMs = 6000) {
  return fetch(url, { ...options, signal: AbortSignal.timeout(timeoutMs) });
}

let tokenCache;
async function fatSecretToken(options) {
  if (tokenCache?.expires > Date.now()) return tokenCache.value;
  const credentials = Buffer.from(
    `${process.env.FATSECRET_CLIENT_ID}:${process.env.FATSECRET_CLIENT_SECRET}`
  ).toString('base64');
  const { response, data } = await fetchJSON('https://oauth.fatsecret.com/connect/token', {
    ...options,
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      Authorization: `Basic ${credentials}`,
    },
    body: 'grant_type=client_credentials&scope=basic%20barcode',
  });
  if (!response.ok || !data.access_token)
    throw new Error('Food provider authentication unavailable');
  tokenCache = {
    value: data.access_token,
    expires: Date.now() + Math.max(0, Number(data.expires_in) - 60) * 1000,
  };
  return tokenCache.value;
}

async function fatSecretBarcode(identity, options) {
  // Enable only after the account's entitlement and diary storage rights have
  // been verified. Provider response caching stays disabled.
  if (process.env.FATSECRET_ENABLED !== 'true')
    return { status: 'disabled', provider: 'fatsecret' };
  if (
    !process.env.FATSECRET_CLIENT_ID ||
    !process.env.FATSECRET_CLIENT_SECRET ||
    process.env.FATSECRET_DIARY_STORAGE_ALLOWED !== 'true'
  ) {
    return { status: 'temporarily_unavailable', provider: 'fatsecret', reason: 'configuration' };
  }
  if (!identity.gtin13) return { status: 'unsupported_format', provider: 'fatsecret' };
  try {
    const token = await fatSecretToken(options);
    const url = new URL('https://platform.fatsecret.com/rest/food/barcode/find-by-id/v2');
    url.search = new URLSearchParams({
      barcode: identity.gtin13,
      format: 'json',
      flag_default_serving: 'true',
      region: process.env.FOOD_REGION || 'US',
    });
    const { response, data } = await fetchJSON(url, {
      ...options,
      headers: { Authorization: `Bearer ${token}` },
    });
    if (response.status === 429) return { status: 'rate_limited', provider: 'fatsecret' };
    if (Number(data.error?.code) === 211) return { status: 'not_found', provider: 'fatsecret' };
    if (!response.ok || data.error)
      return { status: 'temporarily_unavailable', provider: 'fatsecret' };
    const food = mapFatSecretFood(data.food, identity.identity);
    return food
      ? { status: 'found', food }
      : { status: 'temporarily_unavailable', provider: 'fatsecret' };
  } catch {
    return { status: 'temporarily_unavailable', provider: 'fatsecret' };
  }
}

async function openFoodFactsBarcode(identity, options) {
  const reserve = options.reserve ?? budget.reserve;
  const backoff = options.backoff ?? budget.backoff;
  if (!(await reserve('off-product', 15)))
    return { status: 'rate_limited', provider: 'openfoodfacts', retry_after: 60 };
  try {
    const base = process.env.OFF_API_BASE_URL || 'https://world.openfoodfacts.org';
    const url = new URL(`/api/v3.6/product/${identity.openFoodFacts}.json`, base);
    url.searchParams.set('fields', OFF_FIELDS);
    const headers = {
      'User-Agent':
        process.env.OFF_USER_AGENT || 'Exerly/1.0 (https://sideband.studio; hello@sideband.studio)',
    };
    if (base === 'https://world.openfoodfacts.net')
      headers.Authorization = `Basic ${Buffer.from('off:off').toString('base64')}`;
    const { response, data } = await fetchJSON(url, { ...options, headers });
    if (response.status === 429) {
      const retry = Number(response.headers.get('retry-after')) || 60;
      await backoff('off-product', retry);
      return { status: 'rate_limited', provider: 'openfoodfacts', retry_after: retry };
    }
    if (response.status === 404 || data.status === 0 || data.result?.id === 'product_not_found')
      return { status: 'not_found', provider: 'openfoodfacts' };
    if (!response.ok || !data.product)
      return { status: 'temporarily_unavailable', provider: 'openfoodfacts' };
    const food = mapOpenFoodFactsProduct(data.product, identity.identity);
    return food
      ? { status: 'found', food, product: data.product }
      : {
          status: 'temporarily_unavailable',
          provider: 'openfoodfacts',
          reason: 'incomplete_product',
        };
  } catch {
    return { status: 'temporarily_unavailable', provider: 'openfoodfacts' };
  }
}

async function lookupBarcode(identity, options = {}) {
  const opts = { ...options, deadline: Date.now() + 6500 };
  const [fs, off] = await Promise.all([
    fatSecretBarcode(identity, opts),
    openFoodFactsBarcode(identity, opts),
  ]);
  const outcomes = [fs, off];
  const found = outcomes.find((result) => result.status === 'found');
  if (found) return found;
  const unavailable = outcomes.find((result) =>
    ['temporarily_unavailable', 'rate_limited'].includes(result.status)
  );
  return unavailable ?? { status: 'not_found' };
}

const searchCache = new Map();
/** Open Food Facts products matching a search, unmapped. */
async function searchOpenFoodFactsProducts(query, limit = 20) {
  const key = `${query.trim().toLowerCase()}:${limit}`;
  const cached = searchCache.get(key);
  if (cached?.expires > Date.now()) return cached.products;
  // Plain-text OFF search is a legacy endpoint with a strict shared budget.
  // It is deliberately invoked on submit, never as remote autocomplete.
  if (!(await budget.reserve('off-search', 10))) return [];
  const url = new URL(
    '/cgi/search.pl',
    process.env.OFF_API_BASE_URL || 'https://world.openfoodfacts.org'
  );
  url.search = new URLSearchParams({
    search_terms: query,
    search_simple: '1',
    action: 'process',
    json: '1',
    page_size: String(limit),
    fields: OFF_FIELDS,
  });
  const headers = {
    'User-Agent':
      process.env.OFF_USER_AGENT || 'Exerly/1.0 (https://sideband.studio; hello@sideband.studio)',
  };
  if (url.hostname === 'world.openfoodfacts.net')
    headers.Authorization = `Basic ${Buffer.from('off:off').toString('base64')}`;
  try {
    const { response, data } = await fetchJSON(url, { headers });
    if (response.status === 429) {
      await budget.backoff('off-search', Number(response.headers.get('retry-after')));
      return [];
    }
    if (!response.ok || !Array.isArray(data.products)) return [];
    if (searchCache.size >= 200) searchCache.delete(searchCache.keys().next().value);
    searchCache.set(key, { products: data.products, expires: Date.now() + 300000 });
    return data.products;
  } catch {
    return [];
  }
}

async function searchFoods(query, limit = 20) {
  const products = await module.exports.searchOpenFoodFactsProducts(query, limit);
  return products.map((product) => mapOpenFoodFactsProduct(product)).filter(Boolean);
}

module.exports = {
  CACHE_TTL_MS,
  lookupBarcode,
  openFoodFactsBarcode,
  searchFoods,
  searchOpenFoodFactsProducts,
  fetchWithTimeout,
  mapOpenFoodFactsProduct,
  mapFatSecretFood,
};
