// Entry point.
//
// DATABASE_URL -> PostgreSQL. Pending migrations run before the server listens.

require('dotenv').config();

const store = require('./data');
const { createApp } = require('./app');
const webhooks = require('./lib/webhooks');
const { shutdown: stop, deadlineMs } = require('./lib/shutdown');

const PORT = Number(process.env.PORT) || 3001;
// Binding to all interfaces so a phone on the same network, or another machine
// on the tailnet, can reach a development server.
const HOST = process.env.HOST || '0.0.0.0';

function fail(message, hints = []) {
  console.error(`ERROR: ${message}`);
  hints.forEach((h) => console.error(`   ${h}`));
  process.exit(1);
}

async function main() {
  if (process.env.NODE_ENV === 'production' && !process.env.JWT_SECRET) {
    fail('JWT_SECRET is required in production', [
      'Without it the server would sign tokens with a value that is in the public repo.',
    ]);
  }
  if (!process.env.DATABASE_URL) {
    fail('DATABASE_URL is required', [
      'Point it at PostgreSQL 16 or later, for example the docker-compose database.',
    ]);
  }

  let info;
  try {
    info = await store.connect();
  } catch (err) {
    fail(`Could not connect to the database: ${err.message}`, [
      'Check the connection string and that this IP is allowed.',
    ]);
  }

  const app = createApp();

  // listen() only after the database is up. The old entry point called it
  // immediately, so every request during the connect window failed with a
  // buffering timeout rather than a clean 503.
  const server = app.listen(PORT, HOST, () => {
    console.log('');
    console.log('  Exerly API');
    console.log(`  Listening   http://localhost:${PORT}`);
    console.log(`  Storage     ${info.driver} (${info.target})`);
    console.log(
      `  AI          ${process.env.GEMINI_API_KEY || process.env.AI_API_KEY ? 'Gemini' : 'mock responses'}`
    );
    console.log('');
  });

  // Finish in-flight requests before exiting so a deploy doesn't drop the
  // request that was mid-write when the signal arrived.
  const shutdown = (signal) => async () => {
    console.log(`\n${signal} received, shutting down.`);
    setTimeout(() => process.exit(1), deadlineMs()).unref();
    await stop({ server, store });
    process.exit(0);
  };

  // Tells the person's webhooks when their change feed moves on.
  webhooks.start();

  process.on('SIGTERM', shutdown('SIGTERM'));
  process.on('SIGINT', shutdown('SIGINT'));
}

main().catch((err) => {
  console.error('Fatal startup error:', err);
  process.exit(1);
});
