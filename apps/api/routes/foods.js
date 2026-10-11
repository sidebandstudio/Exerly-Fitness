// Food search, ingredient matching and barcode lookup for ExerlyCore. Results
// are Foods in the `saved_food` document shape, ready to save or log: generic
// foods from the bundled USDA table first, then packaged foods from Open Food Facts.
// Personal tokens can use these too: searching reads no account data.

const express = require('express');
const { authenticate } = require('../lib/auth');
const { ApiError, asyncHandler, badRequest, notFound, tooMany } = require('../lib/errors');
const v = require('../lib/validate');
const providers = require('../lib/foodProviders');
const { normalizeBarcode } = require('../lib/barcodes');
const coreFoods = require('../lib/coreFoods');
const genericFoods = require('../lib/genericFoods');

const router = express.Router();
router.use(authenticate);

const unavailable = () =>
  new ApiError(503, 'The food database is unavailable right now. Try again shortly.');

router.get(
  '/search',
  asyncHandler(
    async (req, res) => {
      const query = v.str(req.query.q, 'q', { max: 100 });
      if (query.length < 2) throw badRequest('q needs at least two characters');
      const limit = v.int(req.query.limit ?? 20, 'limit', { min: 1, max: 50 });
      // A quarter of the results at most (three at least) are generic foods,
      // so packaged ones stay near the top.
      const generic = genericFoods.search(query, Math.max(3, Math.ceil(limit / 4)));
      const products = await providers.searchOpenFoodFactsProducts(query, limit);
      const packaged = products
        .map((product) => coreFoods.fromOpenFoodFacts(product))
        .filter(Boolean);
      const attribution = [
        generic.length ? genericFoods.ATTRIBUTION : null,
        packaged.length || !generic.length ? coreFoods.ATTRIBUTION.openFoodFacts : null,
      ];
      res.json({
        foods: [...generic, ...packaged].slice(0, limit),
        attribution: attribution.filter(Boolean).join(' '),
      });
    },
    { transactional: false }
  )
);

// The generic food each of a recipe's ingredient names (see
// genericFoods.ingredient), or null: one request for a whole imported recipe,
// from the bundled USDA table only, so it spends none of the shared Open Food
// Facts budget.
router.post(
  '/match',
  asyncHandler(
    async (req, res) => {
      const queries = req.body?.queries;
      if (!Array.isArray(queries) || queries.length > 100)
        throw badRequest('queries must be a list of up to 100 food names');
      const foods = queries.map((query, i) => {
        const name = v.str(query, `queries[${i}]`, { required: false, max: 100 });
        return name ? genericFoods.ingredient(name) : null;
      });
      res.json({ foods, attribution: genericFoods.ATTRIBUTION });
    },
    { transactional: false }
  )
);

router.get(
  '/barcode/:code',
  asyncHandler(
    async (req, res) => {
      const identity = normalizeBarcode(req.params.code, req.query.symbology);
      if (identity.status !== 'valid') throw badRequest(identity.message);
      const result = await providers.openFoodFactsBarcode(identity, {});
      if (result.status === 'not_found') throw notFound('No food has that barcode');
      if (result.status === 'rate_limited') {
        res.set('Retry-After', String(result.retry_after ?? 60));
        throw tooMany('Food lookups are busy. Try again shortly.');
      }
      const food =
        result.status === 'found'
          ? coreFoods.fromOpenFoodFacts({
              ...result.product,
              code: result.product.code || identity.openFoodFacts,
            })
          : null;
      if (!food) throw unavailable();
      res.json({ food, attribution: coreFoods.ATTRIBUTION.openFoodFacts });
    },
    { transactional: false }
  )
);

module.exports = router;
