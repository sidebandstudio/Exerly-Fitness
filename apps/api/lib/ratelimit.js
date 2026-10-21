// Fixed-window rate limiter.
//
// Hand-rolled rather than pulling in express-rate-limit: the whole thing is 40
// lines, and a single-instance API doesn't need a shared store. If this ever
// runs on more than one instance the counters become per-instance, which is
// worth remembering before scaling out.

const net = require('node:net');

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
 * Counts failures rather than requests, for limits on guessing.
 * `reserve(key)` is synchronous: it throws a 429 once recorded failures plus
 * attempts still being checked reach `max`, and otherwise holds a place, so a
 * burst of requests can't all pass the check while slow verification
 * (bcrypt, Apple) runs. The caller settles the reservation with `fail()` or
 * `release()`; a second call does nothing, so `release()` can sit in a
 * `finally`. `failures(key)` is the recorded count. Shares the sweeper and
 * `reset()`.
 */
function failureLimit({ max, windowMs, name, message }) {
  const id = (key) => `${name}:${key}`;
  const live = (key) => {
    const entry = buckets.get(id(key));
    return entry && Date.now() <= entry.resetAt ? entry : null;
  };
  const fresh = (key) => {
    const entry = { count: 0, pending: 0, resetAt: Date.now() + windowMs };
    buckets.set(id(key), entry);
    return entry;
  };
  const unlimited = { fail() {}, release() {} };
  return {
    reserve(key) {
      if (limitsOff()) return unlimited;
      const entry = live(key) ?? fresh(key);
      if (entry.count + entry.pending >= max) {
        const { ApiError } = require('./errors');
        const minutes = Math.ceil((entry.resetAt - Date.now()) / 60000);
        throw new ApiError(429, message || `Too many attempts. Try again in ${minutes} minutes.`, {
          code: 'too_many_attempts',
          retry_after_minutes: minutes,
        });
      }
      entry.pending += 1;
      let settled = false;
      const settle = (failed) => {
        if (settled) return;
        settled = true;
        entry.pending -= 1;
        if (failed) (live(key) ?? fresh(key)).count += 1;
      };
      return { fail: () => settle(true), release: () => settle(false) };
    },
    failures(key) {
      return live(key)?.count ?? 0;
    },
    clear(key) {
      buckets.delete(id(key));
    },
    /** Forgets every key that starts with `prefix`. */
    clearPrefix(prefix) {
      for (const key of buckets.keys()) if (key.startsWith(id(prefix))) buckets.delete(key);
    },
  };
}

/** Forgets one key of a `rateLimit` middleware, as `name` and `key` gave it. */
function forget(name, key) {
  buckets.delete(`${name}:${key}`);
}

/**
 * The network an address belongs to, for limits a single home or office
 * shares: the /24 of an IPv4 address and the /56 of an IPv6 one (a typical
 * household delegation). Anything else is returned as it is.
 */
function networkPrefix(address = '') {
  const ip = String(address).split('%')[0];
  const v4 = /^(?:::ffff:)?(\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}$/i.exec(ip);
  if (v4) return `${v4[1]}.0/24`;
  if (!net.isIPv6(ip)) return ip;
  const [head, tail] = ip.toLowerCase().split('::');
  const left = head ? head.split(':') : [];
  const right = tail ? tail.split(':') : [];
  const groups =
    tail === undefined
      ? left
      : [...left, ...Array(8 - left.length - right.length).fill('0'), ...right];
  if (groups.length !== 8) return ip;
  const full = groups.map((g) => g.padStart(4, '0'));
  return `${full.slice(0, 3).join(':')}:${full[3].slice(0, 2)}00::/56`;
}

function reset() {
  buckets.clear();
}

module.exports = { rateLimit, failureLimit, forget, networkPrefix, reset, clientKey };
