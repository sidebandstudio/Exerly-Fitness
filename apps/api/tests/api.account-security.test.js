// Account security: confirming identity before deletion, refresh-credential
// reuse, and that one account's credentials, codes and sessions never reach
// another's. Apple identity tokens are signed by a local test key.

const test = require('node:test');
const assert = require('node:assert/strict');
const { randomBytes } = require('node:crypto');
const { startServer, signUp } = require('./helpers/server');
const { reset: resetRateLimits } = require('../lib/ratelimit');
const accounts = require('./helpers/accounts');

const {
  appleCredential,
  appleSubject,
  appleAccount,
  loginModern,
  refresh,
  personalToken,
  mailedCode,
  forgot,
  resetPassword,
} = accounts;

let api;
test.before(async () => {
  accounts.trustLocalAppleKey();
  api = await startServer();
});
test.after(async () => api.close());
test.beforeEach(() => resetRateLimits());

const deleteAccount = (token, body) =>
  api.del('/api/account', { token, body: { confirm: true, ...body } });

// ---------- Deleting an account ----------

test('a password account is deleted only with its password', async () => {
  const user = await signUp(api);
  const missing = await deleteAccount(user.token, {});
  assert.equal(missing.status, 400);
  assert.equal(missing.body.details.code, 'password_required');

  const wrong = await deleteAccount(user.token, { password: 'not-the-password' });
  assert.equal(wrong.status, 403, 'a refusal, not a 401 that would end the session');
  assert.equal(wrong.body.details.code, 'wrong_password');
  assert.equal(await api.store.count('users', { email: user.email }), 1);
  assert.equal((await api.get('/api/me', { token: user.token })).status, 200);

  const appleProof = await deleteAccount(user.token, appleCredential(appleSubject()));
  assert.equal(appleProof.status, 400, 'Apple cannot stand in for an account without Apple');
  assert.equal(appleProof.body.details.code, 'password_required');

  const done = await deleteAccount(user.token, { password: user.password });
  assert.equal(done.status, 200);
  assert.equal(await api.store.count('users', { email: user.email }), 0);
});

test('deletion attempts are limited per account', async () => {
  const user = await signUp(api);
  const bystander = await signUp(api);
  for (let i = 0; i < 5; i++) {
    assert.equal((await deleteAccount(user.token, { password: `guess-${i}-wrong` })).status, 403);
  }
  const limited = await deleteAccount(user.token, { password: user.password });
  assert.equal(limited.status, 429);
  assert.equal(await api.store.count('users', { email: user.email }), 1);
  // Another account on the same address is not held back.
  const other = await deleteAccount(bystander.token, { password: 'wrong-for-bystander' });
  assert.equal(other.status, 403);
});

test('an Apple account is deleted only with a fresh authorization for the same Apple ID', async () => {
  const account = await appleAccount(api);
  const remove = (body) => deleteAccount(account.token, body);

  const missing = await remove({});
  assert.equal(missing.status, 400);
  assert.equal(missing.body.details.code, 'apple_reauthorization_required');
  const password = await remove({ password: 'anything-at-all' });
  assert.equal(password.body.details.code, 'apple_reauthorization_required');

  for (const [why, body] of [
    ['another Apple ID', appleCredential(appleSubject())],
    [
      'issued 11 minutes ago',
      appleCredential(account.sub, { issuedSecondsAgo: 660, lifetime: 900 }),
    ],
    ['expired', appleCredential(account.sub, { issuedSecondsAgo: 700 })],
    [
      'the wrong nonce',
      { ...appleCredential(account.sub), nonce: randomBytes(16).toString('hex') },
    ],
  ]) {
    const refused = await remove(body);
    assert.equal(refused.status, 403, why);
    assert.equal(refused.body.details.code, 'apple_not_confirmed', why);
    resetRateLimits();
  }

  const confirmation = appleCredential(account.sub);
  const done = await remove(confirmation);
  assert.equal(done.status, 200, JSON.stringify(done.body));
  assert.equal(await api.store.count('users', { id: account.id }), 0);

  // The same confirmation can't be replayed, even by a new account for that Apple ID.
  const again = await api.post('/auth/apple', appleCredential(account.sub));
  assert.equal(again.status, 201);
  const replayed = await deleteAccount(again.body.token, confirmation);
  assert.equal(replayed.status, 403);
  assert.match(replayed.body.message, /already used/);
});

test('after deletion every session, refresh credential, token and reset code is gone', async () => {
  const user = await signUp(api);
  const phone = await loginModern(api, user.email, user.password);
  const tablet = await loginModern(api, user.email, user.password);
  const agent = await personalToken(api, user);
  assert.equal((await forgot(api, user.email)).status, 202);

  assert.equal((await deleteAccount(phone.token, { password: user.password })).status, 200);

  for (const token of [user.token, phone.token, tablet.token]) {
    const res = await api.get('/api/me', { token });
    assert.equal(res.status, 401);
    assert.equal(res.body.details?.code, 'account_deleted');
  }
  assert.equal((await refresh(api, tablet.refreshToken, 'after-deletion-refresh')).status, 401);
  assert.equal((await api.get('/v1/changes', { token: agent })).status, 401);
  for (const table of ['sessions', 'personal_access_tokens', 'password_resets']) {
    assert.equal(await api.store.count(table, { account_id: user.user._id }), 0, table);
  }
});

// ---------- Sessions ----------

test('a refresh credential used again after rotation ends the session', async () => {
  const user = await signUp(api);
  const session = await loginModern(api, user.email, user.password);
  const second = await refresh(api, session.refreshToken, 'rotation-operation-1');
  assert.equal(second.status, 200);
  const third = await refresh(api, second.body.refreshToken, 'rotation-operation-2');
  assert.equal(third.status, 200);

  // A lost acknowledgement retried with its own key is not reuse.
  const retried = await refresh(api, second.body.refreshToken, 'rotation-operation-2');
  assert.equal(retried.status, 200);
  assert.equal(retried.body.refreshToken, third.body.refreshToken);

  const stolen = await refresh(api, session.refreshToken, 'attacker-operation');
  assert.equal(stolen.status, 401);
  assert.match(stolen.body.message, /used from two places/);
  assert.equal((await refresh(api, third.body.refreshToken, 'rotation-operation-3')).status, 401);
  assert.equal((await api.get('/api/me', { token: third.body.token })).status, 401);

  // A forged credential for a known session id proves nothing and ends nothing.
  const other = await loginModern(api, user.email, user.password);
  const forged = `${other.sessionId}.${randomBytes(32).toString('base64url')}`;
  assert.equal((await refresh(api, forged, 'forged-operation')).status, 401);
  assert.equal((await refresh(api, other.refreshToken, 'other-operation')).status, 200);
});

// ---------- Isolation ----------

test('one account cannot reach another through the account and auth routes', async () => {
  const a = await signUp(api);
  const b = await signUp(api, { password: 'only-b-knows-this' });
  const bPhone = await loginModern(api, b.email, b.password);
  const bApple = appleSubject();
  assert.equal(
    (await api.post('/api/account/identities/apple', appleCredential(bApple), { token: b.token }))
      .status,
    201
  );

  // Sessions: A sees and revokes only its own.
  const listed = await api.get('/api/sessions', { token: a.token });
  assert.ok(listed.body.every((s) => s.id !== bPhone.sessionId));
  await api.del(`/api/sessions/${bPhone.sessionId}`, { token: a.token });
  assert.equal((await api.get('/api/me', { token: bPhone.token })).status, 200);

  // Apple: A can't take B's Apple ID, and disconnecting touches only A.
  const taken = await api.post('/api/account/identities/apple', appleCredential(bApple), {
    token: a.token,
  });
  assert.equal(taken.status, 409);
  await api.del('/api/account/identities/apple', { token: a.token });
  assert.equal(await api.store.count('account_identities', { subject: bApple }), 1);

  // Reset codes are bound to their account.
  await forgot(api, a.email);
  const aCode = mailedCode(a.email);
  assert.equal((await resetPassword(api, b.email, aCode)).status, 400);
  assert.equal((await api.post('/login', { email: b.email, password: b.password })).status, 200);
  resetRateLimits();

  // Deletion: B's password or Apple ID can't confirm A's deletion, and A's
  // deletion leaves B whole.
  const bSessions = { account_id: b.user._id, revoked_at: null };
  const bSessionsBefore = await api.store.count('sessions', bSessions);
  assert.equal((await deleteAccount(a.token, { password: b.password })).status, 403);
  assert.equal((await deleteAccount(a.token, appleCredential(bApple))).status, 400);
  assert.equal((await deleteAccount(a.token, { password: a.password })).status, 200);
  assert.equal(await api.store.count('users', { email: b.email }), 1);
  assert.equal(await api.store.count('sessions', bSessions), bSessionsBefore);
  assert.equal((await api.get('/api/me', { token: bPhone.token })).status, 200);
  const exported = await api.get('/api/export', { token: b.token });
  assert.ok(!JSON.stringify(exported.body).includes(a.email));
});
