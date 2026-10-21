// Password reset codes.
//
// A code is 8 characters from a 32-letter alphabet with no 0/O or 1/I, so it
// can be read from an email and typed: 40 bits. It lasts 15 minutes, five
// wrong guesses use it up, and requesting a new one ends the old one, so
// online guessing is hopeless. Only HMAC(server secret, account, code) is
// stored.

const { createHmac, randomInt, timingSafeEqual } = require('node:crypto');

const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const LENGTH = 8;
const TTL_MS = 15 * 60 * 1000;
const MAX_ATTEMPTS = 5;

/** A new code, shown to people as ABCD-EFGH. */
function newCode() {
  let code = '';
  for (let i = 0; i < LENGTH; i++) code += ALPHABET[randomInt(ALPHABET.length)];
  return code;
}

const display = (code) => `${code.slice(0, 4)}-${code.slice(4)}`;

/** The code as typed, upper-cased without spaces or dashes; null if it can't be one. */
function normalize(value) {
  if (typeof value !== 'string' || value.length > 32) return null;
  const code = value.replace(/[\s-]/g, '').toUpperCase();
  if (code.length !== LENGTH || [...code].some((c) => !ALPHABET.includes(c))) return null;
  return code;
}

function digest(accountID, code) {
  const { resolveSecret } = require('./auth');
  return createHmac('sha256', resolveSecret())
    .update(`password-reset:${accountID}:${code}`)
    .digest('hex');
}

function matches(stored, accountID, code) {
  const expected = Buffer.from(digest(accountID, code));
  const actual = Buffer.from(String(stored));
  return expected.length === actual.length && timingSafeEqual(expected, actual);
}

/** Addresses that can receive mail; Sign in with Apple placeholders can't. */
const deliverable = (email) => !email.endsWith('.invalid');

// Anything that depends on whether an address has an account runs after the
// response has gone, so how long the response takes says nothing about it.
const pending = new Set();
// The person was told a code was sent, so a failure is counted and the count
// logged. Never public: a failure only happens when the address has an
// account, so a public count would tell anyone who asked for a reset.
const metrics = { deliveryFailures: 0 };

/** Runs `work` for `email` after the current response. Failures are logged without the address. */
function afterResponse(email, work) {
  const job = new Promise((resolve) => setImmediate(resolve))
    .then(work)
    .catch((error) => {
      metrics.deliveryFailures += 1;
      console.error(
        `Password reset not sent (failures since start: ${metrics.deliveryFailures}):`,
        String(error?.message ?? error).replaceAll(email, '<address>')
      );
    })
    .finally(() => pending.delete(job));
  pending.add(job);
}

/** Resolves once every queued request has finished. For tests and shutdown. */
async function settle() {
  while (pending.size) await Promise.all(pending);
}

module.exports = {
  newCode,
  display,
  normalize,
  digest,
  matches,
  deliverable,
  afterResponse,
  settle,
  metrics,
  TTL_MS,
  MAX_ATTEMPTS,
};
