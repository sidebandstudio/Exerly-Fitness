// Account lifecycle: Sign in with Apple, linking it to an existing account,
// the full data export, and account deletion.

const express = require('express');
const bcrypt = require('bcrypt');
const { createHash } = require('node:crypto');

const store = require('../data');
const apple = require('../lib/apple');
const sessions = require('../lib/sessions');
const { asyncHandler, badRequest, conflict, ApiError } = require('../lib/errors');
const { authenticate, adminEmails } = require('../lib/auth');
const { rateLimit } = require('../lib/ratelimit');
const { normalizeTimeZone } = require('../lib/dates');
const dates = require('../lib/dates');
const v = require('../lib/validate');
const { newUserFields, serializeUser } = require('../lib/users');
const { OWNERSHIP, ownerFilters } = require('../lib/ownership');

const router = express.Router();
const NONCE_RETENTION_MS = 24 * 3600 * 1000;

// Apple may hide the address entirely. The legacy tables are keyed by email,
// so such accounts get a stable address that can never receive mail.
function placeholderEmail(subject) {
  const digest = createHash('sha256').update(`apple:${subject}`).digest('hex').slice(0, 24);
  return `apple-${digest}@users.exerly.invalid`;
}

/** Records a token's nonce; a second use of the same nonce is a replay. */
async function consumeNonce(nonceHash) {
  if (await store.findOne('auth_nonces', { nonce_hash: nonceHash })) {
    throw new ApiError(401, 'This sign-in was already used. Try again.');
  }
  await store.insert('auth_nonces', { nonce_hash: nonceHash, created_at: new Date() });
}

/**
 * Housekeeping that must not run inside a sign-in's serializable
 * transaction: concurrent sign-ins would conflict on it and fail after
 * their retries. Failures are harmless and retried next time.
 */
function afterSignIn(identityID) {
  const cutoff = new Date(Date.now() - NONCE_RETENTION_MS);
  store.remove('auth_nonces', { created_at: { lt: cutoff } }).catch(() => {});
  if (identityID) {
    store
      .update('account_identities', { id: identityID }, { last_used_at: new Date() })
      .catch(() => {});
  }
}

router.post(
  '/auth/apple',
  rateLimit({ name: 'apple', max: 20, windowMs: 10 * 60 * 1000 }),
  asyncHandler(async (req, res) => {
    const verified = await apple.verifyIdentityToken(req.body.identityToken, req.body.nonce);
    const name =
      req.body.name == null || req.body.name === ''
        ? null
        : v.str(req.body.name, 'name', { max: 80 });
    const outcome = await store.transaction(async () => {
      await consumeNonce(verified.nonceHash);
      const identity = await store.findOne('account_identities', {
        provider: 'apple',
        subject: verified.subject,
      });
      if (identity) {
        return {
          user: await store.findById('users', identity.account_id),
          created: false,
          identityID: identity.id,
        };
      }
      const email = verified.email ?? placeholderEmail(verified.subject);
      const existing = await store.findOne('users', { email });
      let user = existing;
      if (existing && !existing.email_verified_at) {
        throw conflict(
          'An Exerly account already uses this email. Sign in with your password, then connect Apple in Settings.',
          { code: 'link_required' }
        );
      }
      if (!existing) {
        user = await store.insert('users', {
          ...newUserFields({
            name: name ?? 'Exerly member',
            email,
            isAdmin: adminEmails().includes(email),
            timezone: normalizeTimeZone(req.body.timezone || req.get('X-Timezone')),
            unitSystem: req.body.unitSystem,
          }),
          email_verified_at: verified.email ? new Date() : null,
        });
      }
      await store.insert('account_identities', {
        account_id: user.id,
        provider: 'apple',
        subject: verified.subject,
        email: verified.email,
        created_at: new Date(),
        last_used_at: new Date(),
      });
      return { user, created: !existing };
    });
    afterSignIn(outcome.identityID);
    const session = await sessions.createSession(outcome.user, req, { modern: true });
    res.status(outcome.created ? 201 : 200).json({ created: outcome.created, ...session });
  })
);

router.post(
  '/api/account/identities/apple',
  authenticate,
  asyncHandler(async (req, res) => {
    const verified = await apple.verifyIdentityToken(req.body.identityToken, req.body.nonce);
    await consumeNonce(verified.nonceHash);
    const identity = await store.findOne('account_identities', {
      provider: 'apple',
      subject: verified.subject,
    });
    if (identity && identity.account_id !== req.account.id) {
      throw conflict('This Apple ID is connected to another Exerly account');
    }
    if (!identity) {
      await store.insert('account_identities', {
        account_id: req.account.id,
        provider: 'apple',
        subject: verified.subject,
        email: verified.email,
        created_at: new Date(),
      });
    }
    res.status(identity ? 200 : 201).json({ provider: 'apple', connected: true });
  })
);

router.delete(
  '/api/account/identities/apple',
  authenticate,
  asyncHandler(async (req, res) => {
    if (!req.account.hash) {
      throw badRequest('Set a password before disconnecting Apple, or you could not sign in again');
    }
    await store.remove('account_identities', { account_id: req.account.id, provider: 'apple' });
    res.json({ provider: 'apple', connected: false });
  })
);

// Everything the account holds, as one JSON document, so nobody is locked
// into Exerly by the cost of leaving it.
router.get(
  '/api/export',
  authenticate,
  asyncHandler(async (req, res) => {
    const user = req.account;
    const tables = {};
    for (const [collection, rule] of Object.entries(OWNERSHIP)) {
      if (rule.export === false || rule.keys.length === 0) continue;
      const rows = new Map();
      for (const filter of ownerFilters(collection, user)) {
        for (const row of await store.find(collection, filter)) rows.set(row.id, row);
      }
      const exported = [...rows.values()].map((row) => {
        // Rows keep `_id`, which the native and legacy clients read.
        const copy = { ...row };
        for (const field of rule.omit ?? []) delete copy[field];
        return copy;
      });
      if (rule.single) tables[rule.single] = exported[0] ?? null;
      else tables[collection] = exported;
    }
    res.set(
      'Content-Disposition',
      `attachment; filename="exerly-export-${dates.today('UTC')}.json"`
    );
    res.json({
      exported_at: new Date().toISOString(),
      version: 3,
      // The password digest and session credentials are never exported.
      account: {
        ...serializeUser(user),
        created_at: user.created_at,
        profile: user.profile ?? {},
        preferences_revision: user.preferences_revision ?? 0,
      },
      ...tables,
    });
  })
);

const APPLE_CONFIRMATION_MAX_AGE_S = 10 * 60;

// Refusals use 403, not 401: the session is fine, and a 401 would make the app
// refresh it or sign out.
const notConfirmed = (message, code) => new ApiError(403, message, { code });

/**
 * Deleting can't be undone, so a session alone isn't enough: a phone left
 * unlocked or a copied access token must not be able to do it. A password
 * account sends its password; an account connected to Apple can instead send
 * a Sign in with Apple identity token from the last ten minutes, for the same
 * Apple ID, with its nonce, which is then used up.
 */
async function confirmIdentity(body, user, linked) {
  if (typeof body.password === 'string' && body.password) {
    if (!user.hash) {
      throw badRequest('This account has no password. Confirm with Apple.', {
        code: 'apple_reauthorization_required',
      });
    }
    const ok = body.password.length <= 200 && (await bcrypt.compare(body.password, user.hash));
    if (!ok) throw notConfirmed('That password is incorrect.', 'wrong_password');
    return;
  }
  if (body.identityToken !== undefined) {
    if (!linked) {
      throw badRequest('This account isn’t connected to Apple. Enter your password.', {
        code: 'password_required',
      });
    }
    let verified;
    try {
      verified = await apple.verifyIdentityToken(body.identityToken, body.nonce);
    } catch (error) {
      if (error.status !== 401) throw error;
      throw notConfirmed('Apple couldn’t confirm it’s you. Try again.', 'apple_not_confirmed');
    }
    const age = Date.now() / 1000 - verified.issuedAt;
    if (verified.subject !== linked.subject || !(age <= APPLE_CONFIRMATION_MAX_AGE_S)) {
      throw notConfirmed('Apple couldn’t confirm it’s you. Try again.', 'apple_not_confirmed');
    }
    try {
      await consumeNonce(verified.nonceHash);
    } catch {
      throw notConfirmed(
        'That Apple confirmation was already used. Try again.',
        'apple_not_confirmed'
      );
    }
    return;
  }
  if (linked && !user.hash) {
    throw badRequest('Confirm with Apple to delete your account.', {
      code: 'apple_reauthorization_required',
    });
  }
  throw badRequest('Enter your password to delete your account.', { code: 'password_required' });
}

// App Store Review Guideline 5.1.1(v): accounts can be deleted in the app.
// The person confirms who they are first (confirmIdentity). Every row the
// account owns goes in one transaction, which also ends every session and
// token. Apple's authorization is revoked first when the account uses Sign in
// with Apple and revocation is configured; if that fails, nothing is deleted.
router.delete(
  '/api/account',
  authenticate,
  // Per account, so a copied session can't keep guessing the password.
  rateLimit({
    name: 'delete-account',
    max: 5,
    windowMs: 60 * 60 * 1000,
    key: (req) => req.account.id,
    message: 'Too many attempts to delete this account. Try again in an hour.',
  }),
  asyncHandler(
    async (req, res) => {
      if (req.body?.confirm !== true) {
        throw badRequest('Send {"confirm": true} to delete the account and all of its data');
      }
      const user = req.account;
      const linked = await store.findOne('account_identities', {
        account_id: user.id,
        provider: 'apple',
      });
      await confirmIdentity(req.body, user, linked);
      let appleRevoked = false;
      if (linked && apple.revocationConfigured()) {
        const code = req.body.appleAuthorizationCode;
        if (typeof code !== 'string' || !code) {
          throw badRequest('Sign in with Apple again to confirm deletion', {
            code: 'apple_reauthorization_required',
          });
        }
        try {
          await apple.revokeAuthorizationCode(code);
          appleRevoked = true;
        } catch {
          throw new ApiError(
            502,
            'Apple could not revoke the sign-in. Nothing was deleted; try again.'
          );
        }
      }
      const removed = await store.transaction(async () => {
        const counts = {};
        for (const collection of Object.keys(OWNERSHIP)) {
          if (collection === 'users') continue;
          let total = 0;
          for (const filter of ownerFilters(collection, user)) {
            total += await store.remove(collection, filter);
          }
          if (total) counts[collection] = total;
        }
        await store.remove('users', { id: user.id });
        return counts;
      });
      res.json({ deleted: true, apple_revoked: appleRevoked, removed });
    },
    { transactional: false }
  )
);

module.exports = router;
