// Stopping the server without losing work it already acknowledged.

const passwordReset = require('./passwordReset');

// DigitalOcean App Platform sends SIGTERM, waits `grace_period_seconds`, then
// kills the container: "Default: 120, Minimum 1, Maximum 600"
// (https://docs.digitalocean.com/products/app-platform/reference/app-spec/,
// services.termination). .do/app.yaml doesn't change it. Forcing our own
// exit at 100 s leaves queued reset mail as long as possible to drain, and
// still exits cleanly before the kill. SHUTDOWN_DEADLINE_SECONDS overrides it;
// keep it below the grace period if that is ever lowered.
const DEFAULT_DEADLINE_SECONDS = 100;

/** How long shutdown may take before the process exits anyway, in ms. */
function deadlineMs(env = process.env) {
  const seconds = Number(env.SHUTDOWN_DEADLINE_SECONDS);
  return (Number.isFinite(seconds) && seconds > 0 ? seconds : DEFAULT_DEADLINE_SECONDS) * 1000;
}

/**
 * Stops accepting requests and lets in-flight ones finish, then finishes
 * queued password-reset work (whose requests were answered "we sent a code"
 * before it ran), and only then closes the database.
 */
async function shutdown({ server, store, settle = passwordReset.settle }) {
  await new Promise((resolve) => server.close(() => resolve()));
  await settle().catch(() => {});
  await store.disconnect().catch(() => {});
}

module.exports = { shutdown, deadlineMs };
