const express = require('express');

const store = require('../data');
const { asyncHandler, notFound, badRequest, conflict } = require('../lib/errors');
const { authenticate } = require('../lib/auth');
const { rateLimit } = require('../lib/ratelimit');
const v = require('../lib/validate');
const { requireUser, entryDateFor, rangeFor, paginationFor } = require('../lib/users');
const providers = require('../lib/foodProviders');
const sync = require('../lib/sync');

const router = express.Router();
router.use(authenticate);

const MEAL_TYPES = ['breakfast', 'lunch', 'dinner', 'snack'];

// Macro fields are stored as the totals actually eaten, so a daily summary is
// a plain SUM with no multiplication at read time.
function scaleMacros(body, servings, round = true) {
  const per = (key, field, opts = {}) =>
    v.num(body[key], field, { required: false, min: 0, max: 100000, ...opts });

  const calories = v.num(body.calories, 'calories', { min: 0, max: 30000 });
  const scale = (value) =>
    value == null ? null : round ? Math.round(value * servings * 100) / 100 : value;

  return {
    calories: round ? Math.round(calories * servings) : calories,
    protein: scale(per('protein', 'protein')),
    carbs: scale(per('carbs', 'carbs')),
    fat: scale(per('fat', 'fat')),
    fiber: scale(per('fiber', 'fiber')),
    sugar: scale(per('sugar', 'sugar')),
    sodium: scale(per('sodium', 'sodium')),
    saturated_fat: scale(
      per('saturatedFat', 'saturatedFat') ?? per('saturated_fat', 'saturated_fat')
    ),
  };
}

function readEntry(body) {
  // Default of 1 keeps every existing client working: it sends absolute macros
  // with no `servings`, which multiplies through unchanged.
  const servings =
    v.num(body.servings, 'servings', {
      required: false,
      min: 0.01,
      max: 100,
    }) ?? 1;

  let basis = null;
  if (body.nutrition_basis != null) {
    basis = {
      amount: v.num(body.nutrition_basis.amount, 'nutrition_basis.amount', {
        min: 0.01,
        max: 100000,
      }),
      unit: v.oneOf(body.nutrition_basis.unit, 'nutrition_basis.unit', [
        'g',
        'ml',
        'serving',
        'oz',
        'fl_oz',
      ]),
    };
  }
  const enteredQuantity =
    body.entered_quantity == null
      ? { amount: servings, unit: 'serving' }
      : {
          amount: v.num(body.entered_quantity.amount, 'entered_quantity.amount', {
            min: 0.000001,
            max: 100000,
          }),
          unit: v.oneOf(body.entered_quantity.unit, 'entered_quantity.unit', [
            'serving',
            'g',
            'oz',
            'ml',
            'fl_oz',
          ]),
        };
  let normalized = enteredQuantity.amount;
  if (enteredQuantity.unit !== 'serving') {
    const mass = { g: 1, oz: 28.349523125 };
    const volume = { ml: 1, fl_oz: 29.5735295625 };
    const factors = mass[enteredQuantity.unit] ? mass : volume;
    if (!basis || !factors[basis.unit])
      throw badRequest('The entered quantity needs a matching weight or volume basis.');
    normalized =
      (enteredQuantity.amount * factors[enteredQuantity.unit]) /
      (basis.amount * factors[basis.unit]);
  }
  if (Math.abs(normalized - servings) > Math.max(1, servings) * 1e-9)
    throw badRequest('The entered quantity does not match the normalized serving count.');
  return {
    name: v.str(body.name, 'name', { max: 200 }),
    ...scaleMacros(body, servings),
    servings,
    entered_quantity: enteredQuantity,
    nutrition_basis: basis,
    nutrition_snapshot: {
      ...scaleMacros(body, 1, false),
      basis,
      nutrient_units: { calories: 'kcal', sodium: 'mg', other: 'g' },
    },
    source: v.str(body.source, 'source', { required: false, max: 64 }),
    serving_size: v.str(body.servingSize ?? body.serving_size, 'servingSize', {
      required: false,
      max: 80,
    }),
    serving_unit: v.str(body.servingUnit ?? body.serving_unit, 'servingUnit', {
      required: false,
      max: 32,
    }),
    meal_type: v.oneOf(body.mealType ?? body.meal_type, 'mealType', MEAL_TYPES, {
      required: false,
    }),
    barcode: v.str(body.barcode, 'barcode', { required: false, max: 32 }),
    brand: v.str(body.brand, 'brand', { required: false, max: 120 }),
    food_id: v.str(body.foodId ?? body.food_id, 'foodId', { required: false, max: 64 }),
  };
}

function checkedRevision(req, row) {
  if (row.revision_locked && req.body?.base_revision == null && req.get('If-Match') == null)
    throw conflict('Read this food entry and include its base_revision before changing it.', {
      current: row,
    });
  sync.checkRevision(req, row);
}
function revisionLocked(req, row = {}) {
  return !!row.revision_locked || req.body?.base_revision != null || req.get('If-Match') != null;
}

// ---------- search ----------
// Registered before /:id so "search" isn't parsed as a document id.

router.get(
  '/search',
  rateLimit({ name: 'food-search', max: 120, windowMs: 60 * 60 * 1000 }),
  asyncHandler(async (req, res) => {
    const user = await requireUser(req.user.email);
    const query = v.str(req.query.q, 'q', { max: 100 });
    const limit = Math.min(50, Math.max(1, parseInt(req.query.limit, 10) || 20));

    // The user's own library is searched first and returned first. Things you
    // have eaten before are almost always what you are looking for.
    const library = await store.find(
      'library_foods',
      { email: user.email, name: { like: query } },
      { sort: { use_count: -1 }, limit: 10 }
    );

    const remote = req.query.local === 'true' ? [] : await providers.searchFoods(query, limit);

    res.json({
      query,
      library: library.map((f) => ({ ...f, source: f.source || 'custom', in_library: true })),
      results: remote,
    });
  })
);

async function barcodeLookup(req, res) {
  const identity = require('../lib/barcodes').normalizeBarcode(
    req.params.barcode ?? req.body.barcode,
    req.query.symbology ?? req.body?.symbology
  );
  if (identity.status !== 'valid') return res.json({ ...identity, found: false });
  const personal = await store.findOne('library_foods', {
    email: req.user.email,
    barcode: { in: identity.aliases },
  });
  if (personal)
    return res.json({
      status: 'found',
      found: true,
      food: { ...personal, cached: true, personal: true },
    });
  const cached = await store.findOne('barcode_cache', { barcode: identity.identity });
  const usableCache = cached?.nutrition_basis && cached.source === 'openfoodfacts';
  if (usableCache && cached.expires_at > new Date()) {
    return res.json({ status: 'found', found: true, food: { ...cached, cached: true } });
  }
  const result = await providers.lookupBarcode(identity);
  if (result.status !== 'found') {
    if (usableCache && cached.fetched_at > new Date(Date.now() - 30 * 86400000)) {
      return res.json({
        status: 'found',
        found: true,
        warning: result.status,
        food: { ...cached, cached: true, stale: true },
      });
    }
    return res.json({ ...result, found: false, barcode: identity.raw });
  }
  if (result.food.cacheable) {
    await store.upsert(
      'barcode_cache',
      { barcode: identity.identity },
      {
        ...result.food,
        barcode: identity.identity,
        fetched_at: new Date(),
        expires_at: new Date(Date.now() + providers.CACHE_TTL_MS),
      }
    );
  }
  res.json({ status: 'found', found: true, food: { ...result.food, cached: false } });
}

router.get(
  '/barcode/:barcode',
  rateLimit({ name: 'barcode', max: 120, windowMs: 3600000 }),
  asyncHandler(barcodeLookup)
);
router.post(
  '/barcode-lookup',
  rateLimit({ name: 'barcode', max: 120, windowMs: 3600000 }),
  asyncHandler(barcodeLookup, { transactional: false })
);

// ---------- diary CRUD ----------

router.get(
  '/:id',
  asyncHandler(async (req, res) => {
    const food = await store.findOne(
      'food',
      { id: String(req.params.id), email: req.user.email },
      { includeDeleted: req.query.include_deleted === 'true' }
    );
    if (!food) throw notFound('Food entry not found');
    res.json(food);
  })
);

router.get(
  '/',
  asyncHandler(async (req, res) => {
    const user = await requireUser(req.user.email);

    // A single ?date= is the common case (the diary showing one day) and gets
    // an exact match rather than a range scan.
    if (req.query.date) {
      const date = v.dateStr(req.query.date, 'date');
      const { limit, skip } = paginationFor(req, { defaultLimit: 500 });
      return res.json(
        await store.find(
          'food',
          { email: user.email, entry_date: date },
          {
            sort: { logged_at: 1, id: 1 },
            includeDeleted: req.query.include_deleted === 'true',
            ...(req.query.limit || req.query.page ? { limit, skip } : {}),
          }
        )
      );
    }

    const { from, to } = rangeFor(req, user, { defaultDays: 90 });
    const { limit, skip } = paginationFor(req, { defaultLimit: 500 });
    res.json(
      await store.find(
        'food',
        { email: user.email, entry_date: { gte: from, lte: to } },
        {
          sort: { entry_date: -1, id: -1 },
          limit,
          skip,
          includeDeleted: req.query.include_deleted === 'true',
        }
      )
    );
  })
);

router.post(
  '/',
  asyncHandler(async (req, res) => {
    const user = await requireUser(req.user.email);
    const entry = readEntry(req.body || {});
    const entryDate = entryDateFor(req, user);

    const created = await createEntry(
      user,
      { ...entry, revision_locked: revisionLocked(req) },
      entryDate,
      req.body.client_id
    );

    // Remember anything logged with real nutrition data so it shows up in
    // recents and search next time without another round trip to a provider.
    if (req.body.saveToLibrary !== false) {
      await rememberInLibrary(user.email, req.body, entry);
    }

    res.status(201).json(created);
  })
);

router.put(
  '/:id',
  asyncHandler(async (req, res) => {
    const user = await requireUser(req.user.email);
    const current = await store.findOne('food', { id: String(req.params.id), email: user.email });
    if (!current) throw notFound('Food entry not found');
    checkedRevision(req, current);
    const entry = readEntry(req.body || {});
    const patch = {
      ...entry,
      account_id: user.id,
      client_id: current.client_id || sync.entityID(),
      revision: (current.revision ?? 1) + 1,
      revision_locked: revisionLocked(req, current),
      updated_at: new Date(),
    };

    // Moving an entry to another day is an edit, not a delete-and-relog.
    if (req.body.entry_date != null) patch.entry_date = entryDateFor(req, user);

    const updated = await store.update(
      'food',
      { id: String(req.params.id), email: user.email },
      patch
    );
    if (!updated) throw notFound('Food entry not found');
    await sync.change(user, 'food', updated);
    res.json(updated);
  })
);

router.delete(
  '/:id',
  asyncHandler(async (req, res) => {
    const user = await requireUser(req.user.email);
    const current = await store.findOne('food', {
      id: String(req.params.id),
      email: req.user.email,
    });
    if (!current) throw notFound('Food entry not found');
    checkedRevision(req, current);
    const deleted = await store.update(
      'food',
      { id: current.id, email: user.email },
      {
        account_id: user.id,
        client_id: current.client_id || sync.entityID(),
        revision: (current.revision ?? 1) + 1,
        revision_locked: revisionLocked(req, current),
        deleted_at: new Date(),
        updated_at: new Date(),
      }
    );
    await sync.change(user, 'food', deleted);
    res.json({ message: 'Food entry deleted', food: deleted });
  })
);

router.post(
  '/:id/restore',
  asyncHandler(async (req, res) => {
    const user = await requireUser(req.user.email);
    const current = await store.findOne(
      'food',
      { id: String(req.params.id), email: user.email },
      { includeDeleted: true }
    );
    if (!current || !current.deleted_at) throw notFound('Deleted food entry not found');
    checkedRevision(req, current);
    const restored = await store.update(
      'food',
      { id: current.id, email: user.email },
      {
        deleted_at: null,
        revision: (current.revision ?? 1) + 1,
        revision_locked: revisionLocked(req, current),
        updated_at: new Date(),
      }
    );
    await sync.change(user, 'food', restored);
    res.json(restored);
  })
);

// Log several items at once. The diary's "repeat yesterday's breakfast" and the
// recipe expansion both go through here instead of firing N requests.
router.post(
  '/batch',
  asyncHandler(async (req, res) => {
    const user = await requireUser(req.user.email);
    const items = req.body?.items;
    if (!Array.isArray(items) || items.length === 0)
      throw badRequest('items must be a non-empty array');
    if (items.length > 50) throw badRequest('Cannot log more than 50 items at once');

    const entryDate = entryDateFor(req, user);
    const fallbackMeal = v.oneOf(req.body.mealType, 'mealType', MEAL_TYPES, { required: false });
    const remember = req.body.saveToLibrary !== false;

    const created = [];
    for (const item of items) {
      const entry = readEntry(item);
      created.push(
        await createEntry(
          user,
          {
            ...entry,
            meal_type: entry.meal_type ?? fallbackMeal,
            revision_locked: revisionLocked(req),
          },
          entryDate,
          item.client_id
        )
      );
      // Same as the single-entry path. Without this, a diary filled entirely by
      // batch never builds up recents to log from next time.
      if (remember) await rememberInLibrary(user.email, item, entry);
    }
    res.status(201).json({ created, count: created.length });
  })
);

async function createEntry(user, entry, entryDate, rawID) {
  const clientID = sync.entityID(rawID);
  if (
    await store.findOne(
      'food',
      { account_id: user.id, client_id: clientID },
      { includeDeleted: true }
    )
  ) {
    throw conflict('This entry already exists or was deleted. Refresh to reconcile it.');
  }
  const created = await store.insert('food', {
    email: user.email,
    account_id: user.id,
    client_id: clientID,
    revision: 1,
    ...entry,
    entry_date: entryDate,
    logged_at: new Date(),
    created_at: new Date(),
    updated_at: new Date(),
  });
  await sync.change(user, 'food', created);
  return created;
}

async function rememberInLibrary(email, body, entry) {
  const hasNutrition = entry.calories > 0;
  if (!hasNutrition) return;

  const match = entry.barcode
    ? { email, barcode: entry.barcode }
    : { email, name: entry.name, brand: entry.brand ?? null };

  const existing = await store.findOne('library_foods', match);
  if (existing) {
    await store.update(
      'library_foods',
      { id: existing.id },
      { use_count: (existing.use_count || 0) + 1, last_used: new Date() }
    );
    return;
  }

  // Store per-serving values in the library so logging it again with a
  // different serving count scales correctly.
  const per = (key) => entry.nutrition_snapshot[key];
  await store.insert('library_foods', {
    email,
    name: entry.name,
    brand: entry.brand,
    barcode: entry.barcode,
    calories: per('calories'),
    protein: per('protein'),
    carbs: per('carbs'),
    fat: per('fat'),
    fiber: per('fiber'),
    sugar: per('sugar'),
    sodium: per('sodium'),
    saturated_fat: per('saturated_fat'),
    serving_size: entry.serving_size,
    serving_unit: entry.serving_unit,
    nutrition_basis: entry.nutrition_basis,
    source: body.source || (entry.barcode ? 'barcode' : 'custom'),
    is_favorite: false,
    use_count: 1,
    last_used: new Date(),
    created_at: new Date(),
  });
}

module.exports = router;
module.exports.readEntry = readEntry;
