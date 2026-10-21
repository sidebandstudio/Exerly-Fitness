const express = require('express');

const store = require('../data');
const { asyncHandler, notFound, badRequest } = require('../lib/errors');
const { authenticate } = require('../lib/auth');
const v = require('../lib/validate');

const router = express.Router();
router.use(authenticate);

const NUTRIENTS = [
  ['calories', { min: 0, max: 30000 }],
  ['protein', { min: 0, max: 2000 }],
  ['carbs', { min: 0, max: 2000 }],
  ['fat', { min: 0, max: 2000 }],
  ['fiber', { min: 0, max: 500 }],
  ['sugar', { min: 0, max: 2000 }],
  ['sodium', { min: 0, max: 100000 }],
  ['saturated_fat', { min: 0, max: 1000 }],
];

function readFood(body) {
  const out = {
    name: v.str(body.name, 'name', { max: 200 }),
    brand: v.str(body.brand, 'brand', { required: false, max: 120 }),
    barcode: v.str(body.barcode, 'barcode', { required: false, max: 32 }),
    serving_size: v.str(body.servingSize ?? body.serving_size, 'servingSize', {
      required: false,
      max: 80,
    }),
    serving_unit: v.str(body.servingUnit ?? body.serving_unit, 'servingUnit', {
      required: false,
      max: 32,
    }),
    serving_grams: v.num(body.servingGrams ?? body.serving_grams, 'servingGrams', {
      required: false,
      min: 0,
      max: 10000,
    }),
  };
  for (const [field, bounds] of NUTRIENTS) {
    const camel = field.replace(/_(.)/g, (_, c) => c.toUpperCase());
    const raw = body[field] ?? body[camel];
    out[field] = v.num(raw, field, { required: field === 'calories', ...bounds });
  }
  return out;
}

// ---------- personal food library ----------

router.get(
  '/foods',
  asyncHandler(async (req, res) => {
    const filter = { email: req.user.email };
    if (req.query.favorites === 'true') filter.is_favorite = true;
    if (req.query.q) filter.name = { like: v.str(req.query.q, 'q', { max: 100 }) };

    // "recent" is the default because that's what a food picker should open to.
    const sort =
      req.query.sort === 'name'
        ? { name: 1 }
        : req.query.sort === 'used'
          ? { use_count: -1 }
          : { last_used: -1 };

    const limit = Math.min(200, Math.max(1, parseInt(req.query.limit, 10) || 50));
    res.json(await store.find('library_foods', filter, { sort, limit }));
  })
);

router.post(
  '/foods',
  asyncHandler(async (req, res) => {
    const created = await store.insert('library_foods', {
      email: req.user.email,
      ...readFood(req.body || {}),
      source: 'custom',
      is_favorite: !!req.body.isFavorite,
      use_count: 0,
      last_used: new Date(),
      created_at: new Date(),
    });
    res.status(201).json(created);
  })
);

router.put(
  '/foods/:id',
  asyncHandler(async (req, res) => {
    const patch = readFood(req.body || {});
    if (req.body.isFavorite != null) patch.is_favorite = !!req.body.isFavorite;

    const updated = await store.update(
      'library_foods',
      { id: String(req.params.id), email: req.user.email },
      patch
    );
    if (!updated) throw notFound('Food not found in your library');
    res.json(updated);
  })
);

router.post(
  '/foods/:id/favorite',
  asyncHandler(async (req, res) => {
    const existing = await store.findOne('library_foods', {
      id: String(req.params.id),
      email: req.user.email,
    });
    if (!existing) throw notFound('Food not found in your library');

    const updated = await store.update(
      'library_foods',
      { id: existing.id },
      { is_favorite: req.body?.favorite != null ? !!req.body.favorite : !existing.is_favorite }
    );
    res.json(updated);
  })
);

router.delete(
  '/foods/:id',
  asyncHandler(async (req, res) => {
    const deleted = await store.removeOne('library_foods', {
      id: String(req.params.id),
      email: req.user.email,
    });
    if (!deleted) throw notFound('Food not found in your library');
    res.json({ message: 'Removed from library', food: deleted });
  })
);

// ---------- recipes ----------

function readIngredients(value) {
  if (!Array.isArray(value)) throw badRequest('ingredients must be an array');
  if (value.length === 0) throw badRequest('A recipe needs at least one ingredient');
  if (value.length > 60) throw badRequest('A recipe can hold at most 60 ingredients');

  return value.map((raw, i) => {
    const item = raw || {};
    const servings =
      v.num(item.servings, `ingredients[${i}].servings`, {
        required: false,
        min: 0.01,
        max: 100,
      }) ?? 1;
    const scale = (value) => (value == null ? 0 : Number((value * servings).toFixed(2)));
    return {
      name: v.str(item.name, `ingredients[${i}].name`, { max: 200 }),
      servings,
      serving_size: v.str(item.servingSize ?? item.serving_size, `ingredients[${i}].servingSize`, {
        required: false,
        max: 80,
      }),
      calories: Math.round(
        v.num(item.calories, `ingredients[${i}].calories`, { min: 0, max: 30000 }) * servings
      ),
      protein: scale(v.num(item.protein, `ingredients[${i}].protein`, { required: false, min: 0 })),
      carbs: scale(v.num(item.carbs, `ingredients[${i}].carbs`, { required: false, min: 0 })),
      fat: scale(v.num(item.fat, `ingredients[${i}].fat`, { required: false, min: 0 })),
      fiber: scale(v.num(item.fiber, `ingredients[${i}].fiber`, { required: false, min: 0 })),
      sugar: scale(v.num(item.sugar, `ingredients[${i}].sugar`, { required: false, min: 0 })),
    };
  });
}

// Per-serving totals, which is what a recipe is actually for: cook once, log a
// portion, and have the macros divided correctly.
function recipeTotals(recipe) {
  const servings = recipe.servings || 1;
  const sum = (field) =>
    (recipe.ingredients || []).reduce((total, i) => total + (Number(i[field]) || 0), 0);

  return {
    total: {
      calories: Math.round(sum('calories')),
      protein: Number(sum('protein').toFixed(1)),
      carbs: Number(sum('carbs').toFixed(1)),
      fat: Number(sum('fat').toFixed(1)),
      fiber: Number(sum('fiber').toFixed(1)),
      sugar: Number(sum('sugar').toFixed(1)),
    },
    per_serving: {
      calories: Math.round(sum('calories') / servings),
      protein: Number((sum('protein') / servings).toFixed(1)),
      carbs: Number((sum('carbs') / servings).toFixed(1)),
      fat: Number((sum('fat') / servings).toFixed(1)),
      fiber: Number((sum('fiber') / servings).toFixed(1)),
      sugar: Number((sum('sugar') / servings).toFixed(1)),
    },
  };
}

router.get(
  '/recipes',
  asyncHandler(async (req, res) => {
    const recipes = await store.find('recipes', { email: req.user.email }, { sort: { name: 1 } });
    res.json(recipes.map((r) => ({ ...r, ...recipeTotals(r) })));
  })
);

router.post(
  '/recipes',
  asyncHandler(async (req, res) => {
    const created = await store.insert('recipes', {
      email: req.user.email,
      name: v.str(req.body.name, 'name', { max: 200 }),
      ingredients: readIngredients(req.body.ingredients),
      servings: v.num(req.body.servings, 'servings', { required: false, min: 0.5, max: 100 }) ?? 1,
      note: v.str(req.body.note, 'note', { required: false, max: 1000 }),
      created_at: new Date(),
      updated_at: new Date(),
    });
    res.status(201).json({ ...created, ...recipeTotals(created) });
  })
);

router.put(
  '/recipes/:id',
  asyncHandler(async (req, res) => {
    const updated = await store.update(
      'recipes',
      { id: String(req.params.id), email: req.user.email },
      {
        name: v.str(req.body.name, 'name', { max: 200 }),
        ingredients: readIngredients(req.body.ingredients),
        servings:
          v.num(req.body.servings, 'servings', { required: false, min: 0.5, max: 100 }) ?? 1,
        note: v.str(req.body.note, 'note', { required: false, max: 1000 }),
        updated_at: new Date(),
      }
    );
    if (!updated) throw notFound('Recipe not found');
    res.json({ ...updated, ...recipeTotals(updated) });
  })
);

router.delete(
  '/recipes/:id',
  asyncHandler(async (req, res) => {
    const deleted = await store.removeOne('recipes', {
      id: String(req.params.id),
      email: req.user.email,
    });
    if (!deleted) throw notFound('Recipe not found');
    res.json({ message: 'Recipe deleted', recipe: deleted });
  })
);

module.exports = router;
module.exports.recipeTotals = recipeTotals;
module.exports.readFood = readFood;
module.exports.readIngredients = readIngredients;
