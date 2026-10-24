const { randomUUID, createHash, createHmac, timingSafeEqual } = require('node:crypto');
const store = require('../data');
const { unauthorized, badRequest, conflict } = require('./errors');
const { serializeUser } = require('./users');

const hash = (value) => createHash('sha256').update(value).digest('hex');
function equal(a, b) {
  return (
    typeof a === 'string' &&
    typeof b === 'string' &&
    a.length === b.length &&
    timingSafeEqual(Buffer.from(a), Buffer.from(b))
  );
}
function refreshMAC(sessionID, generation) {
  const { resolveSecret } = require('./auth');
  return createHmac('sha256', resolveSecret())
    .update(`refresh:${sessionID}:${generation}`)
    .digest('base64url');
}
// `session.generation.mac`. The generation is covered by the MAC, so a
// presented credential says which rotation it came from and checking it is
// one HMAC however many rotations the session has had.
function credential(sessionID, generation) {
  return `${sessionID}.${generation}.${refreshMAC(sessionID, generation)}`;
}
// Credentials issued before the generation was included were
// `session.mac`. They stay valid until their next rotation.
const legacyCredential = (sessionID, generation) =>
  `${sessionID}.${refreshMAC(sessionID, generation)}`;
const LEGACY_REUSE_WINDOW = 16;

/** The session's current credential, in the form it was issued in. */
function currentCredential(session) {
  const legacy = legacyCredential(session.session_id, session.generation);
  return equal(session.refresh_hash, hash(legacy))
    ? legacy
    : credential(session.session_id, session.generation);
}

function isActive(session, user) {
  return (
    !!session &&
    !session.revoked_at &&
    session.expires_at > new Date() &&
    (session.credentials_version ?? 0) === (user.credentials_version ?? 0)
  );
}

function response(user, session, { modern = true } = {}) {
  const { signToken } = require('./auth');
  return {
    token: signToken(user, modern ? '15m' : '30d', {
      sid: session.session_id,
      version: session.credentials_version ?? 0,
    }),
    refreshToken: modern ? currentCredential(session) : undefined,
    expiresIn: modern ? 900 : 2592000,
    sessionId: session.session_id,
    user: serializeUser(user),
  };
}

// `modern` issues a short access token plus a rotating refresh credential.
// Installed legacy clients opt in with X-Session-Protocol: 2.
async function createSession(user, req, { modern } = {}) {
  return insertSession(user, req, randomUUID(), { modern });
}

async function insertSession(user, req, id, { modern } = {}) {
  const now = new Date();
  const session = await store.insert('sessions', {
    account_id: user.id,
    session_id: id,
    refresh_hash: hash(credential(id, 0)),
    generation: 0,
    credentials_version: user.credentials_version ?? 0,
    device_name: String(req.get('X-Device-Name') || 'Exerly device').slice(0, 100),
    created_at: now,
    updated_at: now,
    expires_at: new Date(now.getTime() + 90 * 86400000),
  });
  return response(user, session, { modern: modern ?? req.get('X-Session-Protocol') === '2' });
}

async function upgradeSession(user, req) {
  const operation = req.get('Idempotency-Key');
  // Installed clients without replay support keep their compatibility path.
  if (!operation)
    return store.transaction(async () => createSession(await upgradeAccount(user, req), req));
  if (!/^[a-zA-Z0-9._:-]{8,128}$/.test(operation))
    throw badRequest('Invalid session operation key');
  const { resolveSecret } = require('./auth');
  // The account, original credential and operation identify one upgrade. Only
  // this one-way identity and the refresh hash are stored, never a reusable
  // bearer/refresh credential inside a generic mutation acknowledgement.
  const identity = createHmac('sha256', resolveSecret())
    .update(
      JSON.stringify([
        'session-upgrade',
        String(user.id),
        req.token,
        operation,
        req.get('X-Session-Protocol') || '1',
      ])
    )
    .digest('hex');
  const id = `${identity.slice(0, 8)}-${identity.slice(8, 12)}-${identity.slice(12, 16)}-${identity.slice(16, 20)}-${identity.slice(20, 32)}`;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      return await store.transaction(async () => {
        const current = await upgradeAccount(user, req);
        const previous = await store.findOne('operations', { account_id: user.id, key: operation });
        let sessionID = id;
        if (previous) {
          const { canonicalJSON } = require('./mutations');
          const fingerprint = hash(
            canonicalJSON({
              method: req.method,
              path: req.originalUrl,
              body: req.body ?? null,
              revision: req.get('If-Match') ?? null,
            })
          );
          if (
            previous.fingerprint !== fingerprint ||
            typeof previous.response?.sessionId !== 'string'
          )
            throw conflict('This operation key was already used with different content');
          // A response lost before this server upgrade must recover its original
          // session. Replace the old credential-bearing acknowledgement with
          // its session reference once that reference has been validated.
          sessionID = previous.response.sessionId;
        }
        const existing = await store.findOne('sessions', {
          session_id: sessionID,
          account_id: user.id,
        });
        if (previous && !existing) throw unauthorized('Session no longer exists. Sign in again.');
        if (!existing) return insertSession(current, req, id);
        if (!isActive(existing, current)) throw unauthorized('Session expired. Sign in again.');
        if (previous)
          await store.update(
            'operations',
            { id: previous.id },
            { response: { sessionId: existing.session_id, session_upgrade: true } }
          );
        return response(current, existing, { modern: req.get('X-Session-Protocol') === '2' });
      });
    } catch (error) {
      if (!store.isRetryable(error) || attempt === 2) throw error;
    }
  }
}

async function upgradeAccount(user, req) {
  const current = await store.findById('users', user.id);
  if (!current || (req.user.version ?? 0) !== (current.credentials_version ?? 0))
    throw unauthorized('Session has been revoked');
  if (req.user.sid) {
    const source = await store.findOne('sessions', {
      account_id: current.id,
      session_id: req.user.sid,
    });
    if (!isActive(source, current)) throw unauthorized('Session has been revoked');
    // Serialize an upgrade with revocation of its original session. MongoDB
    // retries a conflicting transaction and rechecks the revoked source row.
    await store.update('sessions', { id: source.id }, { updated_at: new Date() });
  }
  return current;
}

async function rotate(refreshToken, operation) {
  if (typeof refreshToken !== 'string' || refreshToken.length > 256 || !refreshToken.includes('.'))
    throw unauthorized('Invalid refresh credential');
  if (typeof operation !== 'string' || !/^[a-zA-Z0-9._:-]{8,128}$/.test(operation))
    throw badRequest('An operation key is required to refresh the session');
  const result = await store.transaction(async () => {
    const id = refreshToken.split('.')[0];
    const session = await store.findOne('sessions', { session_id: id });
    if (!session || session.revoked_at || session.expires_at <= new Date())
      throw unauthorized('Session expired. Sign in again.');
    const user = await store.findById('users', session.account_id);
    if (!user) throw unauthorized('Session no longer exists');
    if (!isActive(session, user)) throw unauthorized('Session has been revoked');
    const presented = hash(refreshToken);
    // The client keeps the operation key until the rotated credential is in
    // Keychain. Retrying a lost acknowledgement returns the same credential.
    if (equal(session.previous_refresh_hash, presented) && session.previous_operation === operation)
      return response(user, session);
    if (!equal(session.refresh_hash, presented)) {
      // A genuine credential this session already rotated past means two
      // holders: the app and whoever copied it. Nobody can tell which is
      // which, so the session ends for both. The revocation must commit, so
      // the refusal is thrown after the transaction.
      if (rotatedEarlier(refreshToken, id, session.generation)) {
        await store.update('sessions', { id: session.id }, { revoked_at: new Date() });
        return REUSED;
      }
      throw unauthorized('Refresh credential has already been rotated');
    }
    const generation = session.generation + 1;
    const updated = await store.update(
      'sessions',
      { id: session.id, refresh_hash: presented },
      {
        generation,
        previous_refresh_hash: presented,
        previous_operation: operation,
        refresh_hash: hash(credential(id, generation)),
        updated_at: new Date(),
      }
    );
    if (!updated) throw unauthorized('Session changed. Retry with the saved credential.');
    return response(user, updated);
  });
  if (result === REUSED)
    throw unauthorized('This sign-in was used from two places, so it was ended. Sign in again.');
  return result;
}

const REUSED = Symbol('reused refresh credential');

/**
 * Whether `presented` is this session's credential from an earlier
 * generation. A forged credential costs at most LEGACY_REUSE_WINDOW HMACs to
 * refuse, never one per rotation.
 */
function rotatedEarlier(presented, sessionID, generation) {
  const parts = presented.split('.');
  if (parts.length === 3) {
    if (!/^\d{1,15}$/.test(parts[1])) return false;
    const earlier = Number(parts[1]);
    return earlier < generation && equal(refreshMAC(sessionID, earlier), parts[2]);
  }
  if (parts.length !== 2) return false;
  const oldest = Math.max(0, generation - LEGACY_REUSE_WINDOW);
  for (let earlier = generation - 1; earlier >= oldest; earlier--) {
    if (equal(legacyCredential(sessionID, earlier), presented)) return true;
  }
  return false;
}

async function revokeAll(accountID) {
  await store.updateMany('sessions', { account_id: accountID }, { revoked_at: new Date() });
}

module.exports = { createSession, upgradeSession, rotate, revokeAll, response, isActive };
