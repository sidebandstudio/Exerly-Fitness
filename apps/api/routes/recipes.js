// Recipe import from a web page: the server fetches the page, under the rules
// in lib/recipePages.js, and returns the recipe its structured data
// describes. The app matches the ingredient lines to foods and opens the
// recipe for review; nothing is saved here.

const express = require('express');
const { authenticate } = require('../lib/auth');
const { asyncHandler, forbidden } = require('../lib/errors');
const { rateLimit } = require('../lib/ratelimit');
const v = require('../lib/validate');
const recipePages = require('../lib/recipePages');

const router = express.Router();
router.use(authenticate);

router.post(
  '/import',
  // The app's sessions only: a personal token would let an agent point the server at URLs.
  (req, _res, next) =>
    next(req.pat ? forbidden('Recipe import is only available in the Exerly app.') : undefined),
  rateLimit({
    name: 'recipe-import',
    max: 30,
    windowMs: 60 * 60 * 1000,
    key: (req) => String(req.account.id),
    message: 'That is a lot of recipes in an hour. Try again later.',
  }),
  asyncHandler(
    async (req, res) => {
      const url = v.str(req.body?.url, 'url', { max: 2048 });
      const page = await recipePages.fetchPage(url);
      res.json({ recipe: recipePages.readRecipe(page.html, page.url) });
    },
    { transactional: false }
  )
);

module.exports = router;
