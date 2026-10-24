// Express app assembly.
//
// Deliberately does not connect to a database or call listen(). The entry point
// does both, which is what lets the test suite boot the same app against an
// in-memory SQLite file.

const express = require('express');
const cors = require('cors');

const store = require('./data');
const { securityHeaders, corsOrigin } = require('./lib/security');
const { rateLimit } = require('./lib/ratelimit');
const { notFoundHandler, errorHandler } = require('./lib/errors');

function createApp({ logger = console } = {}) {
  const app = express();

  // Behind one reverse proxy (docker-compose, self-hosting), req.ip is the
  // proxy's address unless Express reads X-Forwarded-For. On App Platform that
  // header names DigitalOcean's ingress instead, so limits use clientIP()
  // (lib/ratelimit.js), which reads do-connecting-ip there.
  app.set('trust proxy', 1);
  app.disable('x-powered-by');

  app.use(securityHeaders);
  app.use(
    cors({
      origin: corsOrigin(
        (process.env.EXTRA_CORS_ORIGINS || '')
          .split(',')
          .map((s) => s.trim())
          .filter(Boolean)
      ),
      credentials: true,
      optionsSuccessStatus: 204,
    })
  );

  // A body cap. Without one, a single large POST can exhaust the 512MB
  // instance the API runs on. An import carries a whole export, so its route
  // reads the body itself, with a larger cap, once the app has signed in
  // (routes/portability.js).
  const body = express.json({ limit: '256kb' });
  app.use((req, res, next) => (req.path === '/v1/import' ? next() : body(req, res, next)));

  app.use(
    ['/api', '/v1'],
    rateLimit({
      name: 'global',
      max: 600,
      windowMs: 60 * 1000,
      message: 'Too many requests. Slow down.',
    })
  );

  app.get('/ping', (_req, res) => res.send('pong'));

  app.get('/api/health', (_req, res) => {
    const ready = store.isReady();
    res.status(ready ? 200 : 503).json({
      status: ready ? 'healthy' : 'unhealthy',
      timestamp: new Date().toISOString(),
      uptime: process.uptime(),
      database: { driver: store.name, status: ready ? 'connected' : 'disconnected' },
      memory: {
        used: `${Math.round(process.memoryUsage().heapUsed / 1048576)} MB`,
        total: `${Math.round(process.memoryUsage().heapTotal / 1048576)} MB`,
      },
      version: '2.0.0',
    });
  });

  // Before the path-less routers below, some of which authenticate everything they see.
  app.use(require('./routes/mcp'));
  app.use(require('./routes/auth'));
  app.use(require('./routes/account'));
  app.use(require('./routes/onboarding'));
  app.use(require('./routes/profile'));
  app.use(require('./routes/dashboard'));

  app.use('/api/activities', require('./routes/activities'));
  app.use('/api/food', require('./routes/food'));
  app.use('/api/diary', require('./routes/diary'));
  app.use('/api/sync', require('./routes/sync'));
  app.use('/api/sleep', require('./routes/sleep'));
  app.use('/api/weight', require('./routes/weight'));
  app.use('/api/measurements', require('./routes/measurements'));
  app.use('/api/goals', require('./routes/goals'));
  app.use('/api/water', require('./routes/water'));
  app.use('/api/workouts', require('./routes/workouts'));
  app.use('/api/program', require('./routes/program'));
  app.use('/api/library', require('./routes/library'));
  app.use('/api/ai', require('./routes/ai'));
  app.use('/api/admin', require('./routes/admin'));
  app.use('/v1/tokens', require('./routes/tokens'));
  app.use('/v1/webhooks', require('./routes/webhooks'));
  app.use('/v1/nutrition', require('./routes/nutritionPlans'));
  app.use('/v1', require('./routes/portability'));
  app.use('/v1/foods', require('./routes/foods'));
  app.use('/v1/recipes', require('./routes/recipes'));
  app.use('/v1', require('./routes/documents'));

  app.use(notFoundHandler);
  app.use(errorHandler(logger));

  return app;
}

module.exports = { createApp };
