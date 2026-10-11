// Isolated simulator fixture: the real application and PostgreSQL adapter with a
// deterministic external food provider. Never reads development/production env.
process.env.NODE_ENV = 'test';
process.env.JWT_SECRET = 'isolated-ios-fixture-secret';
process.env.ADMIN_EMAILS = '';
// Lets recipe import read the synthetic pages below from this fixture's own address.
process.env.EXERLY_TEST_FIXTURE = 'isolated-simulator';
const express = require('express');
const jwt = require('jsonwebtoken');
const store = require('../apps/api/data');
const providers = require('../apps/api/lib/foodProviders');
const foodDatabaseGolden = require('../docs/api/golden/foods-v1.json');
const { ApiError } = require('../apps/api/lib/errors');
const { createApp } = require('../apps/api/app');
const { reset: resetRateLimits } = require('../apps/api/lib/ratelimit');
const { start: startCluster } = require('../apps/api/tests/helpers/cluster');
const recipePages = require('../apps/api/lib/recipePages');
// Synthetic recipe pages for import, since the simulator can't reach real sites.
// One line names a food the generic table doesn't have, so it's left to resolve.
const syntheticRecipePages = {
  'black-bean-bowl': {
    '@context': 'https://schema.org',
    '@graph': [
      { '@type': 'WebPage', name: 'Synthetic kitchen' },
      {
        '@type': 'Recipe',
        name: 'Synthetic black bean bowl',
        recipeYield: ['2', '2 bowls'],
        recipeIngredient: [
          '1 (15 oz) can black beans, drained and rinsed',
          '1 cup cooked rice',
          '2 tbsp olive oil',
          '1 lime, juiced',
          '3 oz Synthetic smoky tempeh',
        ],
        recipeInstructions: [
          { '@type': 'HowToStep', text: 'Warm the beans in the oil with the lime juice.' },
          { '@type': 'HowToStep', text: 'Crumble the tempeh over the rice and beans.' },
        ],
      },
    ],
  },
};
let cluster;
const stopCluster = () => {
  if (!cluster) return;
  const owned = cluster;
  cluster = undefined;
  owned.stop();
};
process.once('exit', stopCluster);
let offline = false;
let disconnect = false;
let dropSetupAcknowledgement = false;
let dropPreferencesAcknowledgement = false;
let dropSessionUpgradeAcknowledgement = false;
let dropAccountDeleteAcknowledgement = false;
const sessionUpgradeAttempts = [];
let measurementRoundTrip = null;
let weightRoundTrip = null;
let dailyLogsRoundTrip = null;
let setupRoundTrip = null;
let preferencesRoundTrip = null;
const foodDatabaseRequests = [];
providers.searchOpenFoodFactsProducts = async (query, limit) => {
  foodDatabaseRequests.push({ type: 'search', query, limit });
  if (query === 'provider unavailable')
    throw new ApiError(503, 'The food database is unavailable right now.');
  return foodDatabaseGolden.products
    .filter((product) => product.product_name?.toLowerCase().includes(query.toLowerCase()))
    .slice(0, limit);
};
providers.openFoodFactsBarcode = async (identity) => {
  foodDatabaseRequests.push({ type: 'barcode', code: identity.openFoodFacts });
  const product = foodDatabaseGolden.products.find((item) => identity.aliases.includes(item.code));
  return product ? { status: 'found', product } : { status: 'not_found' };
};
providers.lookupBarcode = async (identity) => ({
  status: 'found',
  food: providers.mapOpenFoodFactsProduct(
    {
      code: '0036000291452',
      product_name: 'Simulator oat drink',
      brands: 'Test fixture',
      quantity: '1 l',
      serving_size: '100 ml',
      nutriments: {
        'energy-kcal_100g': 60,
        proteins_100g: 2,
        carbohydrates_100g: 8,
        fat_100g: 2,
        fiber_100g: 1,
        sugars_100g: 4,
        sodium_100g: 0.04,
        'saturated-fat_100g': 0.2,
      },
    },
    identity.identity
  ),
});
(async () => {
  cluster = startCluster();
  await store.connect({ connectionString: cluster.url });
  const app = express();
  app.use('/__test', express.json());
  app.get('/__test/food-database-requests', (req, res) => {
    if (req.get('X-Test-Fixture') !== 'isolated-simulator') return res.sendStatus(403);
    res.json({ requests: foodDatabaseRequests });
  });
  app.post('/__test/control', async (req, res, next) => {
    if (req.get('X-Test-Fixture') !== 'isolated-simulator') return res.sendStatus(403);
    try {
      if (req.body.resetFoodDatabaseRequests) foodDatabaseRequests.length = 0;
      if (req.body.designAdminEmail) {
        const email = String(req.body.designAdminEmail);
        if (!email.startsWith('design-admin-') || !email.endsWith('@exerly.test'))
          return res.sendStatus(400);
        const user = await store.findOne('users', { email });
        if (!user) return res.sendStatus(404);
        await store.update('users', { id: user.id }, { is_admin: true });
      }
      if (req.body.repairLegacyEmail) {
        const email = String(req.body.repairLegacyEmail);
        if (!email.endsWith('@exerly.test')) return res.sendStatus(400);
        const user = await store.findOne('users', { email });
        if (!user) return res.sendStatus(404);
        await store.transaction(async () => {
          await store.update(
            'users',
            { id: user.id },
            {
              onboardingCompleted: true,
              age: 34,
              gender: 'female',
              height: 167.5,
              weight: 72.25,
              goal: 'maintain',
              unitSystem: 'metric',
              profile: { sex: 'female', allergies: ['nuts'] },
            }
          );
          await store.remove('programs', { email });
          await store.remove('goals', { email });
        });
      }
      offline = req.body.offline === true;
      disconnect = req.body.disconnect === true;
      dropSetupAcknowledgement = req.body.dropSetupAcknowledgement === true;
      dropPreferencesAcknowledgement = req.body.dropPreferencesAcknowledgement === true;
      dropSessionUpgradeAcknowledgement = req.body.dropSessionUpgradeAcknowledgement === true;
      dropAccountDeleteAcknowledgement = req.body.dropAccountDeleteAcknowledgement === true;
      resetRateLimits();
      res.json({ offline, dropSetupAcknowledgement, dropPreferencesAcknowledgement });
    } catch (error) {
      next(error);
    }
  });
  app.get('/__test/ready', (_req, res) => res.json({ isolated: true }));
  // Read by the API's own fetcher, which sends no fixture header; "plain" has no recipe data.
  app.get('/__test/recipe-pages/:slug', (req, res) => {
    const recipe = syntheticRecipePages[req.params.slug];
    if (!recipe && req.params.slug !== 'plain') return res.sendStatus(404);
    res
      .type('html')
      .send(
        `<!doctype html><html><head><title>Synthetic kitchen</title>${
          recipe ? `<script type="application/ld+json">${JSON.stringify(recipe)}</script>` : ''
        }</head><body><h1>Synthetic kitchen</h1></body></html>`
      );
  });
  app.post('/__test/legacy-session', async (req, res, next) => {
    if (req.get('X-Test-Fixture') !== 'isolated-simulator') return res.sendStatus(403);
    try {
      if (typeof req.body.email !== 'string' || !req.body.email.endsWith('@exerly.test'))
        return res.sendStatus(400);
      const user = await store.findOne('users', { email: req.body.email });
      if (!user) return res.sendStatus(404);
      res.json({
        token: jwt.sign({ email: user.email, is_admin: false }, process.env.JWT_SECRET, {
          expiresIn: '1h',
        }),
      });
    } catch (error) {
      next(error);
    }
  });
  app.get('/__test/session-upgrades', async (req, res, next) => {
    if (req.get('X-Test-Fixture') !== 'isolated-simulator') return res.sendStatus(403);
    try {
      if (typeof req.query.email !== 'string' || !req.query.email.endsWith('@exerly.test'))
        return res.sendStatus(400);
      const user = await store.findOne('users', { email: req.query.email });
      if (!user) return res.sendStatus(404);
      const sessions = await store.find('sessions', { account_id: user.id });
      res.json({
        count: sessions.length,
        attempts: sessionUpgradeAttempts.filter((attempt) => attempt.email === user.email),
      });
    } catch (error) {
      next(error);
    }
  });
  app.get('/__test/preferences-roundtrip', (req, res) => {
    if (req.get('X-Test-Fixture') !== 'isolated-simulator') return res.sendStatus(403);
    res.json(preferencesRoundTrip || { ready: false });
  });
  app.post('/__test/preferences-roundtrip', async (req, res, next) => {
    if (req.get('X-Test-Fixture') !== 'isolated-simulator') return res.sendStatus(403);
    try {
      const user = await store.findOne('users', { email: req.body.email });
      if (
        !user ||
        !user.email.startsWith('preferences-cross-') ||
        !user.email.endsWith('@exerly.test')
      )
        return res.sendStatus(400);
      if (!user.onboardingCompleted || user.preferences_revision < 2) return res.sendStatus(409);
      if (!['native-saved', 'browser-saved'].includes(req.body.phase)) return res.sendStatus(400);
      preferencesRoundTrip = {
        ready: true,
        email: user.email,
        account_id: user.id,
        phase: req.body.phase,
      };
      res.json(preferencesRoundTrip);
    } catch (error) {
      next(error);
    }
  });
  app.get('/__test/setup-roundtrip', (req, res) => {
    if (req.get('X-Test-Fixture') !== 'isolated-simulator') return res.sendStatus(403);
    res.json(setupRoundTrip || { ready: false });
  });
  app.post('/__test/setup-roundtrip', async (req, res, next) => {
    if (req.get('X-Test-Fixture') !== 'isolated-simulator') return res.sendStatus(403);
    try {
      const user = await store.findOne('users', { email: req.body.email });
      if (!user || !user.email.startsWith('setup-cross-') || !user.email.endsWith('@exerly.test'))
        return res.sendStatus(400);
      if (!['browser-draft', 'native-draft', 'browser-complete'].includes(req.body.phase))
        return res.sendStatus(400);
      const draft = await store.findOne('onboarding_drafts', { account_id: user.id });
      if (req.body.phase === 'browser-complete' ? !user.onboardingCompleted : !draft)
        return res.sendStatus(409);
      setupRoundTrip = {
        ready: true,
        email: user.email,
        account_id: user.id,
        phase: req.body.phase,
      };
      res.json(setupRoundTrip);
    } catch (error) {
      next(error);
    }
  });
  app.get('/__test/measurement-roundtrip', (req, res) => {
    if (req.get('X-Test-Fixture') !== 'isolated-simulator') return res.sendStatus(403);
    res.json(measurementRoundTrip || { ready: false });
  });
  app.post('/__test/measurement-roundtrip', async (req, res, next) => {
    if (req.get('X-Test-Fixture') !== 'isolated-simulator') return res.sendStatus(403);
    try {
      const user = await store.findOne('users', { email: req.body.email });
      if (!user || !user.email.startsWith('measurement-') || !user.email.endsWith('@exerly.test')) {
        return res.sendStatus(400);
      }
      const row = await store.findOne('measurements', { id: req.body.id, account_id: user.id });
      if (!row || row.type !== 'waist' || row.value !== 80.5) return res.sendStatus(409);
      measurementRoundTrip = { ready: true, email: user.email, id: row.id };
      res.json(measurementRoundTrip);
    } catch (error) {
      next(error);
    }
  });
  app.get('/__test/measurement-account', async (req, res, next) => {
    if (req.get('X-Test-Fixture') !== 'isolated-simulator') return res.sendStatus(403);
    try {
      const users = await store.find('users', {}, { sort: { created_at: -1 } });
      const user = users.find(
        (row) => row.email.startsWith('measurement-') && row.email.endsWith('@exerly.test')
      );
      if (!user) return res.sendStatus(404);
      res.json({ email: user.email });
    } catch (error) {
      next(error);
    }
  });
  app.get('/__test/weight-account', async (req, res, next) => {
    if (req.get('X-Test-Fixture') !== 'isolated-simulator') return res.sendStatus(403);
    try {
      const users = await store.find('users', {}, { sort: { created_at: -1 } });
      const user = users.find(
        (row) => row.email.startsWith('weight-') && row.email.endsWith('@exerly.test')
      );
      if (!user) return res.sendStatus(404);
      res.json({ email: user.email });
    } catch (error) {
      next(error);
    }
  });
  app.get('/__test/weight-roundtrip', (req, res) => {
    if (req.get('X-Test-Fixture') !== 'isolated-simulator') return res.sendStatus(403);
    res.json(weightRoundTrip || { ready: false });
  });
  app.post('/__test/weight-roundtrip', async (req, res, next) => {
    if (req.get('X-Test-Fixture') !== 'isolated-simulator') return res.sendStatus(403);
    try {
      const user = await store.findOne('users', { email: req.body.email });
      if (!user || !user.email.startsWith('weight-') || !user.email.endsWith('@exerly.test'))
        return res.sendStatus(400);
      const row = await store.findOne('weights', { id: req.body.id, account_id: user.id });
      if (!row || row.weight_kg !== 72.8 || row.revision !== 11) return res.sendStatus(409);
      weightRoundTrip = { ready: true, email: user.email, id: row.id, day: row.entry_date };
      res.json(weightRoundTrip);
    } catch (error) {
      next(error);
    }
  });
  app.get('/__test/daily-logs-account', async (req, res, next) => {
    if (req.get('X-Test-Fixture') !== 'isolated-simulator') return res.sendStatus(403);
    try {
      const users = await store.find('users', {}, { sort: { created_at: -1 } });
      const user = users.find(
        (row) => row.email.startsWith('daily-logs-') && row.email.endsWith('@exerly.test')
      );
      if (!user) return res.sendStatus(404);
      res.json({ email: user.email });
    } catch (error) {
      next(error);
    }
  });
  app.get('/__test/daily-logs-roundtrip', (req, res) => {
    if (req.get('X-Test-Fixture') !== 'isolated-simulator') return res.sendStatus(403);
    res.json(dailyLogsRoundTrip || { ready: false });
  });
  app.post('/__test/daily-logs-roundtrip', async (req, res, next) => {
    if (req.get('X-Test-Fixture') !== 'isolated-simulator') return res.sendStatus(403);
    try {
      const user = await store.findOne('users', { email: req.body.email });
      if (!user || !user.email.startsWith('daily-logs-') || !user.email.endsWith('@exerly.test'))
        return res.sendStatus(400);
      const activity = await store.findOne('activities', {
        id: req.body.activityID,
        account_id: user.id,
      });
      const sleep = await store.findOne('sleep', { id: req.body.sleepID, account_id: user.id });
      if (
        !activity ||
        !sleep ||
        activity.duration_min !== 63.25 ||
        activity.calories !== null ||
        activity.revision !== 6 ||
        sleep.hours !== 8.75 ||
        sleep.quality !== 'good' ||
        sleep.revision !== 5
      )
        return res.sendStatus(409);
      dailyLogsRoundTrip = {
        ready: true,
        email: user.email,
        activityID: activity.id,
        sleepID: sleep.id,
        day: activity.entry_date,
      };
      res.json(dailyLogsRoundTrip);
    } catch (error) {
      next(error);
    }
  });
  app.use((req, res, next) => {
    if (
      offline &&
      (req.path.startsWith('/api/') || req.path.startsWith('/v1/') || req.path.startsWith('/auth/'))
    ) {
      if (disconnect) return req.socket.destroy();
      return res.status(503).json({ message: 'Simulator connection interruption' });
    }
    if (req.path === '/auth/refresh' && req.method === 'POST') {
      try {
        const claims = jwt.verify(
          String(req.get('Authorization') || '').replace(/^Bearer /, ''),
          process.env.JWT_SECRET
        );
        sessionUpgradeAttempts.push({
          email: claims.email,
          operation: req.get('Idempotency-Key') || null,
        });
      } catch {
        /* The real API below rejects invalid credentials. */
      }
      if (dropSessionUpgradeAcknowledgement) {
        const json = res.json.bind(res);
        res.json = (body) => {
          if (res.statusCode < 400) {
            dropSessionUpgradeAcknowledgement = false;
            req.socket.destroy();
            return res;
          }
          return json(body);
        };
      }
    }
    if (dropSetupAcknowledgement && req.path === '/api/onboarding/complete') {
      const json = res.json.bind(res);
      res.json = (body) => {
        if (res.statusCode < 400) {
          dropSetupAcknowledgement = false;
          req.socket.destroy();
          return res;
        }
        return json(body);
      };
    }
    if (
      dropAccountDeleteAcknowledgement &&
      req.path === '/api/account' &&
      req.method === 'DELETE'
    ) {
      const json = res.json.bind(res);
      res.json = (body) => {
        if (res.statusCode < 400) {
          dropAccountDeleteAcknowledgement = false;
          req.socket.destroy();
          return res;
        }
        return json(body);
      };
    }
    if (
      dropPreferencesAcknowledgement &&
      req.path === '/api/preferences' &&
      req.method === 'PATCH'
    ) {
      const json = res.json.bind(res);
      res.json = (body) => {
        if (res.statusCode < 400) {
          dropPreferencesAcknowledgement = false;
          req.socket.destroy();
          return res;
        }
        return json(body);
      };
    }
    next();
  });
  app.use(createApp());
  const port = Number(process.env.EXERLY_FIXTURE_PORT || 39001);
  recipePages.allowFixtureOrigin(`http://127.0.0.1:${port}`);
  const server = app.listen(port, '0.0.0.0', () => {
    console.log(`Isolated simulator API listening on ${server.address().port}`);
  });
  const shutdown = () => {
    server.close(async () => {
      try {
        await store.disconnect();
      } finally {
        stopCluster();
        process.exit(0);
      }
    });
    server.closeAllConnections();
  };
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
