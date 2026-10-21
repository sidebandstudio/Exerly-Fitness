// Fixed-window rate limiter.
//
// Hand-rolled rather than pulling in express-rate-limit: the whole thing is 40
// lines, and a single-instance API doesn't need a shared store. If this ever
// runs on more than one instance the counters become per-instance, which is
// worth remembering before scaling out.

const buckets = new Map();

// One sweep for all limiters. Without it, every unique IP that ever hits the
// API stays in memory forever.
const SWEEP_MS = 5 * 60 * 1000;
const sweeper = setInterval(() => {
  const now = Date.now();
  for (const [key, entry] of buckets) {
    if (now > entry.resetAt) buckets.delete(key);
  }
}, SWEEP_MS);
sweeper.unref?.();

function clientKey(req) {
  // trust proxy is set on the app, so req.ip already reflects X-Forwarded-For
  // when running behind DigitalOcean's load balancer.
  return req.ip || req.socket?.remoteAddress || 'unknown';
}

/**
 * @param {object} options
 * @param {number} options.max requests allowed per window
 * @param {number} options.windowMs window length
 * @param {string} options.name namespace, so two limiters don't share counters
 * @param {(req) => string} [options.key] defaults to client IP
 */
// ExerlyCore's live tests sign in many synthetic accounts from one address in
// seconds. scripts/live-sync.sh runs the API with NODE_ENV=test and
// EXERLY_RATE_LIMITS=off; production and staging never set NODE_ENV=test.
const limitsOff = () => process.env.NODE_ENV === 'test' && process.env.EXERLY_RATE_LIMITS === 'off';

function rateLimit({ max, windowMs, name, key = clientKey, message }) {
  return (req, res, next) => {
    if (limitsOff()) return next();
    const id = `${name}:${key(req)}`;
    const now = Date.now();
    let entry = buckets.get(id);

    if (!entry || now > entry.resetAt) {
      entry = { count: 0, resetAt: now + windowMs };
      buckets.set(id, entry);
    }

    entry.count += 1;
    const remaining = Math.max(0, max - entry.count);
    res.set('RateLimit-Limit', String(max));
    res.set('RateLimit-Remaining', String(remaining));
    res.set('RateLimit-Reset', String(Math.ceil((entry.resetAt - now) / 1000)));

    if (entry.count > max) {
      res.set('Retry-After', String(Math.ceil((entry.resetAt - now) / 1000)));
      return res.status(429).json({
        message: message || 'Too many requests. Try again shortly.',
      });
    }
    next();
  };
}

/**
 * Counts failures rather than requests, for limits on guessing: `check(key)`
 * throws a 429 once `max` failures have been recorded for `key` in the
 * window, and `fail(key)` records one. Shares the sweeper and `reset()`.
 */
function failureLimit({ max, windowMs, name, message }) {
  const live = (key) => {
    const entry = buckets.get(`${name}:${key}`);
    return entry && Date.now() <= entry.resetAt ? entry : null;
  };
  return {
    check(key) {
      if (limitsOff()) return;
      const entry = live(key);
      if (entry && entry.count >= max) {
        const { ApiError } = require('./errors');
        const minutes = Math.ceil((entry.resetAt - Date.now()) / 60000);
        throw new ApiError(429, message || `Too many attempts. Try again in ${minutes} minutes.`, {
          code: 'too_many_attempts',
          retry_after_minutes: minutes,
        });
      }
    },
    fail(key) {
      if (limitsOff()) return;
      const entry = live(key) ?? { count: 0, resetAt: Date.now() + windowMs };
      entry.count += 1;
      buckets.set(`${name}:${key}`, entry);
    },
  };
}

function reset() {
  buckets.clear();
}

module.exports = { rateLimit, failureLimit, reset, clientKey };
