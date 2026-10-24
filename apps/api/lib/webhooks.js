// Webhooks: when an account's change feed moves on, a signed POST to the
// person's own HTTPS endpoint says so. The body carries the feed's sequence
// number and nothing else; the receiver reads /v1/changes with its own token,
// so a webhook can't leak data to a URL that later changes hands.
//
//   POST <url>
//   Exerly-Webhook: <webhook id>
//   Exerly-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256 of "t.body" with the secret>
//   {"type":"changes","webhook_id":"…","sequence":42,"sent_at":"…"}
//
// Deliveries coalesce: one POST carries the latest sequence. A failure retries
// after 30 s, doubling up to 6 h, and 15 failures in a row disable the
// webhook. URLs must be https and may not resolve to a private address, which
// is checked again when connecting, so DNS can't be pointed inward later.

const { createHmac, randomBytes } = require('node:crypto');
const dns = require('node:dns');
const http = require('node:http');
const https = require('node:https');
const net = require('node:net');

const store = require('../data');
const { badRequest } = require('./errors');

const MAX_FAILURES = 15;
const TIMEOUT_MS = 5000;
const FIRST_RETRY_MS = 30 * 1000;
const LONGEST_RETRY_MS = 6 * 60 * 60 * 1000;

// Private networks are allowed only where every address is the operator's own,
// such as a staging server on a tailnet, or tests. Never on a public server.
const allowPrivate = () => process.env.EXERLY_WEBHOOKS_ALLOW_PRIVATE === '1';

function ipv4Private(address) {
  const [a, b] = address.split('.').map(Number);
  return (
    a === 0 ||
    a === 10 ||
    a === 127 ||
    (a === 100 && b >= 64 && b <= 127) ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) ||
    (a === 192 && b === 0) ||
    (a === 198 && (b === 18 || b === 19)) ||
    a >= 224
  );
}

/** Loopback, private, link-local, shared, multicast and reserved addresses. */
function privateAddress(address) {
  if (net.isIPv4(address)) return ipv4Private(address);
  if (!net.isIPv6(address)) return true;
  const lower = address.toLowerCase();
  const mapped =
    lower.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/) ?? lower.match(/^64:ff9b::(\d+\.\d+\.\d+\.\d+)$/);
  if (mapped) return ipv4Private(mapped[1]);
  return (
    lower === '::' ||
    lower === '::1' ||
    /^f[cd]/.test(lower) ||
    /^fe[89ab]/.test(lower) ||
    lower.startsWith('ff') ||
    lower.startsWith('::ffff:')
  );
}

/** The URL as stored, or a 400 saying what's wrong with it. */
function checkURL(raw) {
  let url;
  try {
    url = new URL(String(raw ?? ''));
  } catch {
    throw badRequest('url must be an absolute https URL');
  }
  if (String(raw).length > 2000) throw badRequest('url must be at most 2000 characters');
  if (url.protocol !== 'https:' && !(allowPrivate() && url.protocol === 'http:')) {
    throw badRequest('Webhook URLs must use https.');
  }
  if (url.username || url.password) {
    throw badRequest('Put no credentials in the URL. Check the signature instead.');
  }
  const host = url.hostname.replace(/^\[|\]$/g, '');
  if (net.isIP(host) && privateAddress(host) && !allowPrivate()) {
    throw badRequest('Webhook URLs must reach a public address.');
  }
  url.hash = '';
  return url.toString();
}

/** Refuses a host that resolves only to private addresses. */
async function checkResolves(url) {
  const host = new URL(url).hostname.replace(/^\[|\]$/g, '');
  if (net.isIP(host) || allowPrivate()) return;
  let addresses;
  try {
    addresses = await dns.promises.lookup(host, { all: true });
  } catch {
    throw badRequest(`${host} doesn't resolve.`);
  }
  if (addresses.every((a) => privateAddress(a.address))) {
    throw badRequest('Webhook URLs must reach a public address.');
  }
}

// Connecting only to public addresses, whatever DNS says by then.
function publicLookup(hostname, options, callback) {
  dns.lookup(hostname, { ...options, all: true }, (error, addresses) => {
    if (error) return callback(error);
    const usable = addresses.filter((a) => allowPrivate() || !privateAddress(a.address));
    if (usable.length === 0)
      return callback(new Error(`${hostname} resolves only to private addresses`));
    if (options.all) return callback(null, usable);
    return callback(null, usable[0].address, usable[0].family);
  });
}

/** POSTs a body; resolves with the status. Redirects are not followed. */
function post(url, body, headers) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const host = target.hostname.replace(/^\[|\]$/g, '');
    if (net.isIP(host) && privateAddress(host) && !allowPrivate()) {
      return reject(new Error('The URL reaches a private address'));
    }
    const client = target.protocol === 'https:' ? https : http;
    const request = client.request(
      target,
      {
        method: 'POST',
        headers: { ...headers, 'Content-Length': Buffer.byteLength(body) },
        lookup: publicLookup,
        timeout: TIMEOUT_MS,
      },
      (response) => {
        response.resume();
        response.on('end', () => resolve(response.statusCode));
      }
    );
    request.on('timeout', () => request.destroy(new Error(`No answer in ${TIMEOUT_MS / 1000} s`)));
    request.on('error', reject);
    request.end(body);
  });
}

const newSecret = () => `whsec_${randomBytes(32).toString('base64url')}`;

function signature(secret, timestamp, body) {
  return createHmac('sha256', secret).update(`${timestamp}.${body}`).digest('hex');
}

function retryDelay(failures) {
  return Math.min(FIRST_RETRY_MS * 2 ** (failures - 1), LONGEST_RETRY_MS);
}

/**
 * Sends every webhook that is due: enabled, with its retry time reached, and
 * with its account's feed past the sequence it last delivered. Each is claimed
 * for two minutes first, so two servers never send the same one at once.
 * `send` replaces the HTTP POST in tests.
 */
async function deliverDue({ now = new Date(), send = post } = {}) {
  const { rows } = await store.query(
    `UPDATE webhooks w SET next_attempt_at = $1::timestamptz + interval '2 minutes'
       FROM sync_cursors c
      WHERE c.account_id = w.account_id::text AND c.sequence > w.delivered_sequence
        AND w.disabled_at IS NULL AND w.next_attempt_at <= $1
      RETURNING w.id, w.url, w.secret, w.token_id, w.failures, c.sequence AS sequence`,
    [now]
  );
  for (const row of rows) {
    if (row.token_id) {
      const token = await store.findOne('personal_access_tokens', { id: row.token_id });
      if (!token || token.revoked_at || (token.expires_at && token.expires_at <= now)) {
        await store.update(
          'webhooks',
          { id: row.id },
          {
            disabled_at: now,
            last_error: 'The token that created it was revoked or has expired.',
          }
        );
        continue;
      }
    }
    const sequence = Number(row.sequence);
    const body = JSON.stringify({
      type: 'changes',
      webhook_id: row.id,
      sequence,
      sent_at: now.toISOString(),
    });
    const timestamp = Math.floor(now.getTime() / 1000);
    let error = null;
    try {
      const status = await send(row.url, body, {
        'Content-Type': 'application/json',
        'User-Agent': 'Exerly-Webhooks/1',
        'Exerly-Webhook': row.id,
        'Exerly-Signature': `t=${timestamp},v1=${signature(row.secret, timestamp, body)}`,
      });
      if (status < 200 || status >= 300) error = `HTTP ${status}`;
    } catch (failure) {
      error = String(failure?.message ?? failure).slice(0, 200);
    }
    // Results are written only while the webhook is still on. If it was
    // paused while this delivery was in flight (a new password pauses
    // webhooks made from a session), a stale result must not undo that.
    const stillOn = { id: row.id, disabled_at: null };
    if (error) {
      const failures = row.failures + 1;
      await store.update('webhooks', stillOn, {
        failures,
        last_error: error,
        next_attempt_at: new Date(now.getTime() + retryDelay(failures)),
        ...(failures >= MAX_FAILURES ? { disabled_at: now } : {}),
      });
    } else {
      await store.update('webhooks', stillOn, {
        delivered_sequence: sequence,
        failures: 0,
        last_error: null,
        last_delivery_at: now,
        next_attempt_at: now,
      });
    }
  }
  return rows.length;
}

/** Delivers every few seconds until the process exits. */
function start({ intervalMs = 10000, logger = console } = {}) {
  let running = false;
  const timer = setInterval(async () => {
    if (running) return;
    running = true;
    try {
      await deliverDue();
    } catch (error) {
      logger.error('Webhook delivery failed:', error.message);
    } finally {
      running = false;
    }
  }, intervalMs);
  timer.unref();
  return () => clearInterval(timer);
}

module.exports = {
  MAX_FAILURES,
  privateAddress,
  checkURL,
  checkResolves,
  newSecret,
  signature,
  retryDelay,
  deliverDue,
  start,
  post,
};
