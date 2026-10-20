// Proving it's the account's owner, not just someone holding its session.

const bcrypt = require('bcrypt');

const store = require('../data');
const apple = require('./apple');
const { badRequest, ApiError } = require('./errors');

const APPLE_CONFIRMATION_MAX_AGE_S = 10 * 60;

/** Records a token's nonce; a second use of the same nonce is a replay. */
async function consumeNonce(nonceHash) {
  if (await store.findOne('auth_nonces', { nonce_hash: nonceHash })) {
    throw new ApiError(401, 'This sign-in was already used. Try again.');
  }
  await store.insert('auth_nonces', { nonce_hash: nonceHash, created_at: new Date() });
}

// Refusals use 403, not 401: the session is fine, and a 401 would make the app
// refresh it or sign out.
const notConfirmed = (message, code) => new ApiError(403, message, { code });

/**
 * A session alone can't delete the account, connect or disconnect a way to
 * sign in, or create an agent token: a phone left unlocked or a copied access
 * token must not be able to. A password account always sends its password,
 * whatever else is connected, because anyone holding the session can connect
 * their own Apple ID. An account without a password sends a Sign in with
 * Apple identity token from the last ten minutes, for an Apple ID already
 * connected to it, with its nonce, which is then used up.
 *
 * `purpose` finishes "Enter your password to …".
 */
async function confirmIdentity({ password, identityToken, nonce }, user, purpose) {
  if (user.hash) {
    if (typeof password !== 'string' || !password) {
      throw badRequest(`Enter your password to ${purpose}.`, { code: 'password_required' });
    }
    const ok = password.length <= 200 && (await bcrypt.compare(password, user.hash));
    if (!ok) throw notConfirmed('That password is incorrect.', 'wrong_password');
    return;
  }
  if (identityToken === undefined) {
    throw badRequest(`Confirm with Apple to ${purpose}.`, {
      code: 'apple_reauthorization_required',
    });
  }
  let verified;
  try {
    verified = await apple.verifyIdentityToken(identityToken, nonce);
  } catch (error) {
    if (error.status !== 401) throw error;
    throw notConfirmed('Apple couldn’t confirm it’s you. Try again.', 'apple_not_confirmed');
  }
  const connected = await store.findOne('account_identities', {
    account_id: user.id,
    provider: 'apple',
    subject: verified.subject,
  });
  // A token without an issue time has no age, so it fails this check too.
  const age = Date.now() / 1000 - verified.issuedAt;
  if (!connected || !(age <= APPLE_CONFIRMATION_MAX_AGE_S)) {
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
}

module.exports = { confirmIdentity, consumeNonce };
