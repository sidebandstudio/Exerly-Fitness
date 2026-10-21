// Stopping the server without losing work it already acknowledged.

const passwordReset = require('./passwordReset');

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

module.exports = { shutdown };
