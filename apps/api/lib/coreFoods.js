// Food-database products as ExerlyCore Foods: the `saved_food` document shape,
// with nutrients per 100 g keyed by ExerlyCore's Nutrient names in its units.
// docs/api/golden/foods-v1.json holds products and the Foods they map to;
// ExerlyCore's tests decode those Foods, so the two sides can't drift.

const ATTRIBUTION = {
  openFoodFacts:
    'Data from Open Food Facts (https://world.openfoodfacts.org), available under the Open Database License.',
};

// Open Food Facts gives every `<name>_100g` amount in grams (energy in kcal).
// Each entry is the ExerlyCore nutrient and the factor to its unit.
const OFF_NUTRIENTS = {
  'energy-kcal': ['energy', 1],
  proteins: ['protein', 1],
  carbohydrates: ['carbohydrate', 1],
  fat: ['fat', 1],
  fiber: ['fiber', 1],
  sugars: ['sugars', 1],
  'added-sugars': ['addedSugars', 1],
  starch: ['starch', 1],
  'saturated-fat': ['saturatedFat', 1],
  'monounsaturated-fat': ['monounsaturatedFat', 1],
  'polyunsaturated-fat': ['polyunsaturatedFat', 1],
  'trans-fat': ['transFat', 1],
  'omega-3-fat': ['omega3', 1],
  'alpha-linolenic-acid': ['omega3ALA', 1],
  'eicosapentaenoic-acid': ['omega3EPA', 1],
  'docosahexaenoic-acid': ['omega3DHA', 1],
  'omega-6-fat': ['omega6', 1],
  cholesterol: ['cholesterol', 1e3],
  sodium: ['sodium', 1e3],
  potassium: ['potassium', 1e3],
  calcium: ['calcium', 1e3],
  iron: ['iron', 1e3],
  magnesium: ['magnesium', 1e3],
  phosphorus: ['phosphorus', 1e3],
  zinc: ['zinc', 1e3],
  copper: ['copper', 1e3],
  manganese: ['manganese', 1e3],
  selenium: ['selenium', 1e6],
  'vitamin-a': ['vitaminA', 1e6],
  'vitamin-c': ['vitaminC', 1e3],
  'vitamin-d': ['vitaminD', 1e6],
  'vitamin-e': ['vitaminE', 1e3],
  'vitamin-k': ['vitaminK', 1e6],
  'vitamin-b1': ['thiamin', 1e3],
  'vitamin-b2': ['riboflavin', 1e3],
  'vitamin-pp': ['niacin', 1e3],
  'pantothenic-acid': ['pantothenicAcid', 1e3],
  'vitamin-b6': ['vitaminB6', 1e3],
  'vitamin-b12': ['vitaminB12', 1e6],
  'vitamin-b9': ['folate', 1e6],
  choline: ['choline', 1e3],
  caffeine: ['caffeine', 1e3],
};

const KJ_PER_KCAL = 4.184;

// Typical densities in g/ml, for labels and servings given by volume. Open
// Food Facts rarely records a product's density, so its categories pick one;
// the first match wins, and anything else is taken as water and says so.
const DENSITIES = [
  [/oil/, 0.92, 'Typical for oils'],
  [/syrup|honey|molasses/, 1.36, 'Typical for syrups and honey'],
  [/milk|kefir|yogurt-drink|drinkable-yogurt/, 1.03, 'Typical for milk'],
  [/cream/, 1.0, 'Typical for cream'],
  [/juice|nectar|smoothie/, 1.04, 'Typical for juices'],
  [/soda|soft-drink|carbonated|cola|lemonade|energy-drink/, 1.04, 'Typical for soft drinks'],
  [/spirit|liqueur|vodka|whisk|rum|gin/, 0.95, 'Typical for spirits'],
  [/beer/, 1.01, 'Typical for beer'],
  [/wine/, 0.99, 'Typical for wine'],
  [/soup|broth/, 1.03, 'Typical for soups'],
];

function density(product) {
  const categories = (product.categories_tags ?? []).join(' ');
  for (const [pattern, value, note] of DENSITIES) {
    if (pattern.test(categories)) return { density: value, assumed: true, note };
  }
  return {
    density: 1,
    assumed: true,
    note: "Water's density, assumed: not known for this product",
  };
}

function amount(value) {
  if (value == null || value === '') return null;
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : null;
}

/** Six significant digits, so unit conversions don't leave float noise. */
const tidy = (value) => Number(value.toPrecision(6));

/**
 * An Open Food Facts product as an ExerlyCore Food, or null without a name or
 * a barcode. Amounts per 100 ml and servings or packages in millilitres are
 * converted with a typical density for the product's category, recorded as
 * `volume`. The package's size is a serving too: "1 can" for canned food,
 * else "1 package", so a person can log "1 can of beans". A multipack
 * ("6 x 330 ml") has no one package. Alcohol is left out, because Open Food
 * Facts gives it as % by volume.
 */
function fromOpenFoodFacts(product, { now = new Date() } = {}) {
  const name = String(product?.product_name || product?.product_name_en || '').trim();
  const code = String(product?.code ?? '').trim();
  if (!name || !/^\d{8,14}$/.test(code)) return null;
  const nutriments = product.nutriments ?? {};
  // A label per 100 ml, or servings in millilitres, need a density to become
  // grams. It is recorded as the food's volume basis, so the label can be
  // recovered and the approximation shown.
  const perVolume = product.nutrition_data_per === '100ml';
  const servingUnit = product.serving_quantity_unit ?? 'g';
  const packageUnit = product.product_quantity_unit ?? 'g';
  const packageSize = /\d\s*[x×*]\s*\d/i.test(String(product.quantity ?? ''))
    ? null
    : amount(product.product_quantity);
  const volume =
    perVolume || servingUnit === 'ml' || (packageSize && packageUnit === 'ml')
      ? density(product)
      : null;
  const toGrams = perVolume ? 1 / volume.density : 1;
  const per100g = {};
  for (const [key, [nutrient, factor]] of Object.entries(OFF_NUTRIENTS)) {
    const value = amount(nutriments[`${key}_100g`]);
    if (value != null) per100g[nutrient] = tidy(value * factor * toGrams);
  }
  if (per100g.energy == null) {
    const kilojoules = amount(nutriments.energy_100g ?? nutriments['energy-kj_100g']);
    if (kilojoules != null) per100g.energy = tidy((kilojoules / KJ_PER_KCAL) * toGrams);
  }
  const servings = [];
  const serving = amount(product.serving_quantity);
  if (serving > 0 && ['g', 'ml'].includes(servingUnit)) {
    const label = String(product.serving_size ?? '').trim();
    servings.push({
      name: label || `${serving} ${servingUnit}`,
      grams: tidy(servingUnit === 'ml' ? serving * volume.density : serving),
    });
  }
  if (packageSize > 0 && ['g', 'ml'].includes(packageUnit)) {
    const grams = tidy(packageUnit === 'ml' ? packageSize * volume.density : packageSize);
    const canned = (product.categories_tags ?? []).some((tag) => /canned|tinned/.test(tag));
    // A single-serve package is already its serving.
    if (!servings.some((s) => s.grams === grams))
      servings.push({ name: canned ? '1 can' : '1 package', grams });
  }
  const brand = String(product.brands ?? '')
    .split(',')[0]
    .trim();
  return {
    id: `off:${code}`,
    name,
    ...(brand ? { brand } : {}),
    source: 'openFoodFacts',
    per100g,
    servings,
    barcode: code,
    favorite: false,
    createdAt: now.toISOString(),
    ...(volume ? { volume } : {}),
  };
}

module.exports = { ATTRIBUTION, OFF_NUTRIENTS, fromOpenFoodFacts };
