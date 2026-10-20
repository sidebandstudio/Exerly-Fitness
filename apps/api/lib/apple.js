// Sign in with Apple: identity-token verification and token revocation.
//
// The app requests Apple's credential with nonce = SHA-256(rawNonce) and sends
// the identity token plus the raw nonce. The token must be RS256-signed by a
// current Apple key, issued by Apple, for one of our bundle IDs, unexpired, and
// carry that nonce. The nonce is recorded by the caller so a token can't be
// replayed.
//
// Revocation (App Store Review Guideline 5.1.1(v)) needs a Sign in with Apple
// key: APPLE_TEAM_ID, APPLE_KEY_ID and APPLE_PRIVATE_KEY. Without them,
// revocationConfigured() is false and account deletion skips it.

const { createHash, createPublicKey, timingSafeEqual } = require('node:crypto');
const jwt = require('jsonwebtoken');
const { unauthorized, badRequest } = require('./errors');

const ISSUER = 'https://appleid.apple.com';
const KEYS_URL = 'https://appleid.apple.com/auth/keys';
const KEY_TTL_MS = 24 * 3600 * 1000;
const REFETCH_AFTER_MS = 60 * 1000;

let keyCache = { keys: new Map(), fetchedAt: 0 };

function audiences() {
  return (process.env.APPLE_BUNDLE_IDS || 'com.exerly.fitness')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}

async function fetchKeys() {
  const response = await fetch(KEYS_URL, { signal: AbortSignal.timeout(5000) });
  if (!response.ok) throw new Error(`Apple keys request failed with ${response.status}`);
  const { keys } = await response.json();
  keyCache = {
    keys: new Map(keys.map((jwk) => [jwk.kid, createPublicKey({ key: jwk, format: 'jwk' })])),
    fetchedAt: Date.now(),
  };
}

const sha256 = (value) => createHash('sha256').update(value).digest('hex');

function sameString(a, b) {
  return (
    typeof a === 'string' &&
    typeof b === 'string' &&
    a.length === b.length &&
    timingSafeEqual(Buffer.from(a), Buffer.from(b))
  );
}

const apple = {
  audiences,
  sha256,

  /** The public key for `kid`, refetching Apple's key set when it is stale or lacks the key. */
  async publicKey(kid) {
    const age = Date.now() - keyCache.fetchedAt;
    if (age > KEY_TTL_MS || (!keyCache.keys.has(kid) && age > REFETCH_AFTER_MS)) {
      await fetchKeys();
    }
    return keyCache.keys.get(kid) ?? null;
  },

  /**
   * Verifies an identity token against the raw nonce the app generated.
   * Returns { subject, email, emailVerified, nonceHash, issuedAt } (issuedAt in seconds).
   */
  async verifyIdentityToken(identityToken, rawNonce) {
    if (typeof identityToken !== 'string' || identityToken.length > 8192) {
      throw badRequest('identityToken is required');
    }
    if (typeof rawNonce !== 'string' || rawNonce.length < 16 || rawNonce.length > 256) {
      throw badRequest('nonce must be 16 to 256 characters');
    }
    const decoded = jwt.decode(identityToken, { complete: true });
    if (!decoded || decoded.header.alg !== 'RS256' || typeof decoded.header.kid !== 'string') {
      throw unauthorized('Invalid Apple identity token');
    }
    const key = await apple.publicKey(decoded.header.kid);
    if (!key) throw unauthorized('Invalid Apple identity token');
    let claims;
    try {
      claims = jwt.verify(identityToken, key, {
        algorithms: ['RS256'],
        issuer: ISSUER,
        audience: apple.audiences(),
        clockTolerance: 60,
      });
    } catch {
      throw unauthorized('Invalid Apple identity token');
    }
    const nonceHash = sha256(rawNonce);
    if (!sameString(claims.nonce, nonceHash) || typeof claims.sub !== 'string' || !claims.sub) {
      throw unauthorized('Invalid Apple identity token');
    }
    const emailVerified = claims.email_verified === true || claims.email_verified === 'true';
    const email =
      typeof claims.email === 'string' && emailVerified ? claims.email.trim().toLowerCase() : null;
    return { subject: claims.sub, email, emailVerified, nonceHash, issuedAt: claims.iat };
  },

  revocationConfigured() {
    return !!(
      process.env.APPLE_TEAM_ID &&
      process.env.APPLE_KEY_ID &&
      process.env.APPLE_PRIVATE_KEY
    );
  },

  clientSecret(clientID) {
    return jwt.sign({}, process.env.APPLE_PRIVATE_KEY.replace(/\\n/g, '\n'), {
      algorithm: 'ES256',
      keyid: process.env.APPLE_KEY_ID,
      issuer: process.env.APPLE_TEAM_ID,
      audience: ISSUER,
      subject: clientID,
      expiresIn: '5m',
    });
  },

  /**
   * Exchanges a fresh authorization code for a refresh token and revokes it,
   * which ends the app's Sign in with Apple authorization for this user.
   */
  async revokeAuthorizationCode(code) {
    const clientID = apple.audiences()[0];
    const form = (fields) =>
      new URLSearchParams({
        client_id: clientID,
        client_secret: apple.clientSecret(clientID),
        ...fields,
      });
    const exchanged = await fetch(`${ISSUER}/auth/token`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: form({ grant_type: 'authorization_code', code }),
      signal: AbortSignal.timeout(10_000),
    });
    if (!exchanged.ok) throw new Error(`Apple token exchange failed with ${exchanged.status}`);
    const { refresh_token: refreshToken } = await exchanged.json();
    const revoked = await fetch(`${ISSUER}/auth/revoke`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: form({ token: refreshToken, token_type_hint: 'refresh_token' }),
      signal: AbortSignal.timeout(10_000),
    });
    if (!revoked.ok) throw new Error(`Apple token revocation failed with ${revoked.status}`);
  },
};

module.exports = apple;
