// Account security: confirming identity before deletion, refresh-credential
// reuse, and that one account's credentials, codes and sessions never reach
// another's. Apple identity tokens are signed by a local test key.

const test = require('node:test');
const assert = require('node:assert/strict');
const { createHash, createHmac, randomBytes } = require('node:crypto');
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

test('a copied session gets ten wrong confirmations an hour across every route that asks', async () => {
  const user = await signUp(api);
  const bystander = await signUp(api);
  const wrong = 'not-the-password';
  const key = () => ({ 'Idempotency-Key': `guess-${randomBytes(6).toString('hex')}` });
  const guesses = [
    () => deleteAccount(user.token, { password: wrong }),
    () => deleteAccount(user.token, { password: wrong }),
    () =>
      api.post(
        '/api/account/identities/apple',
        { ...appleCredential(appleSubject()), password: wrong },
        { token: user.token }
      ),
    () =>
      api.post(
        '/api/account/identities/apple',
        { ...appleCredential(appleSubject()), password: wrong },
        { token: user.token }
      ),
    () =>
      api.del('/api/account/identities/apple', { token: user.token, body: { password: wrong } }),
    () =>
      api.post(
        '/v1/tokens',
        { name: 'Synthetic agent', scopes: ['read'], password: wrong },
        { token: user.token, headers: key() }
      ),
    () =>
      api.post(
        '/v1/tokens',
        { name: 'Synthetic agent', scopes: ['read'], password: wrong },
        { token: user.token, headers: key() }
      ),
    () =>
      api.post(
        '/api/change-password',
        { currentPassword: wrong, newPassword: 'a-brand-new-passphrase' },
        { token: user.token }
      ),
    () =>
      api.post(
        '/api/change-password',
        { currentPassword: wrong, newPassword: 'a-brand-new-passphrase' },
        { token: user.token }
      ),
    () => deleteAccount(user.token, { password: wrong }),
  ];
  for (const [i, guess] of guesses.entries()) {
    const res = await guess();
    assert.ok([401, 403].includes(res.status), `guess ${i}: ${res.status}`);
  }
  // The eleventh try is refused even with the right password, on any route.
  const limited = await deleteAccount(user.token, { password: user.password });
  assert.equal(limited.status, 429);
  assert.equal(limited.body.details.code, 'too_many_attempts');
  const changing = await api.post(
    '/api/change-password',
    { currentPassword: user.password, newPassword: 'a-brand-new-passphrase' },
    { token: user.token }
  );
  assert.equal(changing.status, 429);
  assert.equal(await api.store.count('users', { email: user.email }), 1);
  assert.equal((await api.get('/api/me', { token: user.token })).status, 200);
  // Missing proof isn't a guess, and another account isn't held back.
  assert.equal((await deleteAccount(bystander.token, {})).status, 400);
  assert.equal((await deleteAccount(bystander.token, { password: wrong })).status, 403);
  assert.equal(
    (await deleteAccount(bystander.token, { password: bystander.password })).status,
    200
  );
});

test('change-password is limited per account, not per address', async () => {
  const one = await signUp(api);
  const two = await signUp(api);
  const change = (user, i) =>
    api.post(
      '/api/change-password',
      { currentPassword: 'short', newPassword: `x${i}` },
      { token: user.token }
    );
  for (let i = 0; i < 10; i++) assert.equal((await change(one, i)).status, 400);
  assert.equal((await change(one, 10)).status, 429);
  assert.equal((await change(two, 0)).status, 400, 'a second account on the same address');
});

test('wrong passwords sent at once cannot get past the ten-guess budget', async () => {
  const user = await signUp(api);
  const burst = await Promise.all(
    Array.from({ length: 30 }, (_, i) => deleteAccount(user.token, { password: `guess-${i}` }))
  );
  const statuses = burst.map((r) => r.status);
  assert.ok(statuses.filter((s) => s === 403).length <= 10, JSON.stringify(statuses));
  assert.equal(statuses.filter((s) => s === 403 || s === 429).length, 30, JSON.stringify(statuses));
  assert.equal((await deleteAccount(user.token, { password: user.password })).status, 429);
  assert.equal(await api.store.count('users', { email: user.email }), 1);
});

const loginFrom = (email, password, ip) =>
  api.post('/login', { email, password }, { headers: { 'X-Forwarded-For': ip } });

test('wrong sign-ins sent at once from one network stop at ten', async () => {
  const user = await signUp(api);
  const burst = await Promise.all(
    Array.from({ length: 30 }, (_, i) => loginFrom(user.email, `guess-${i}`, `198.51.100.${i + 1}`))
  );
  const statuses = burst.map((r) => r.status);
  assert.ok(statuses.filter((s) => s === 401).length <= 10, JSON.stringify(statuses));
  assert.equal(statuses.filter((s) => s === 401 || s === 429).length, 30, JSON.stringify(statuses));
});

test('guesses from one network limit that network, and only slow sign-in from others', async () => {
  const user = await signUp(api);
  for (let i = 0; i < 10; i++) {
    assert.equal((await loginFrom(user.email, `guess-${i}`, `198.51.100.${i + 1}`)).status, 401);
  }
  // The same /24 is held back, even with the right password.
  const limited = await loginFrom(user.email, user.password, '198.51.100.200');
  assert.equal(limited.status, 429);
  assert.match(limited.body.message, /from this network/);
  // The owner on another network still gets in, after a capped wait.
  const started = Date.now();
  const owner = await loginFrom(user.email, user.password, '203.0.113.7');
  const waited = Date.now() - started;
  assert.equal(owner.status, 200);
  assert.ok(waited >= 1900, `waited ${waited} ms`);
  assert.ok(waited < 15000, `waited ${waited} ms`);
});

test('IPv6 sign-in limits cover a /56', async () => {
  const user = await signUp(api);
  for (let i = 0; i < 10; i++) {
    assert.equal(
      (await loginFrom(user.email, `guess-${i}`, `2001:db8:abcd:12${i}f::1`)).status,
      401
    );
  }
  assert.equal((await loginFrom(user.email, user.password, '2001:db8:abcd:1234::9')).status, 429);
  assert.equal((await loginFrom(user.email, user.password, '2001:db8:abcd:1300::1')).status, 200);
});

test('a password reset clears the guess budget, the change-password limit and the sign-in limit', async () => {
  const user = await signUp(api);
  const network = '198.51.100.';
  for (let i = 0; i < 10; i++) {
    await api.post(
      '/api/change-password',
      { currentPassword: `guess-${i}`, newPassword: 'a-brand-new-passphrase' },
      { token: user.token }
    );
    await loginFrom(user.email, `guess-${i}`, `${network}${i + 1}`);
  }
  assert.equal((await deleteAccount(user.token, { password: user.password })).status, 429);
  assert.equal((await loginFrom(user.email, user.password, `${network}99`)).status, 429);

  await forgot(api, user.email);
  const code = await mailedCode(user.email);
  assert.equal((await resetPassword(api, user.email, code, 'reset-passphrase-1')).status, 200);

  const started = Date.now();
  const signedIn = await loginFrom(user.email, 'reset-passphrase-1', `${network}99`);
  assert.equal(signedIn.status, 200, JSON.stringify(signedIn.body));
  assert.ok(Date.now() - started < 1500, 'no leftover backoff');
  const changed = await api.post(
    '/api/change-password',
    { currentPassword: 'reset-passphrase-1', newPassword: 'reset-passphrase-2' },
    { token: signedIn.body.token }
  );
  assert.equal(changed.status, 200, JSON.stringify(changed.body));
});

test('signup is limited per email as well as per address', async () => {
  const email = `limited-${randomBytes(4).toString('hex')}@exerly.test`;
  const attempt = (i) =>
    api.post(
      '/signup',
      { name: 'Synthetic', email, password: 'correct-horse-battery' },
      { headers: { 'X-Forwarded-For': `192.0.2.${i + 1}` } }
    );
  assert.equal((await attempt(0)).status, 201);
  for (let i = 1; i < 5; i++) assert.equal((await attempt(i)).status, 409);
  assert.equal((await attempt(5)).status, 429);
});

test('with Apple revocation on, a password account connected to Apple deletes with both', async () => {
  const apple = require('../lib/apple');
  const saved = {
    env: ['APPLE_TEAM_ID', 'APPLE_KEY_ID', 'APPLE_PRIVATE_KEY'].map((k) => [k, process.env[k]]),
    revoke: apple.revokeAuthorizationCode,
  };
  const revoked = [];
  process.env.APPLE_TEAM_ID = 'SYNTHETIC';
  process.env.APPLE_KEY_ID = 'SYNTHETIC';
  process.env.APPLE_PRIVATE_KEY = 'synthetic';
  apple.revokeAuthorizationCode = async (code) => revoked.push(code);
  try {
    const person = await signUp(api);
    const sub = appleSubject();
    const linked = await api.post(
      '/api/account/identities/apple',
      { ...appleCredential(sub), password: person.password },
      { token: person.token }
    );
    assert.equal(linked.status, 201);

    const passwordOnly = await deleteAccount(person.token, { password: person.password });
    assert.equal(passwordOnly.status, 400);
    assert.equal(passwordOnly.body.details.code, 'apple_reauthorization_required');
    const appleOnly = await deleteAccount(person.token, {
      ...appleCredential(sub),
      appleAuthorizationCode: 'synthetic-code',
    });
    assert.equal(appleOnly.status, 400);
    assert.equal(appleOnly.body.details.code, 'password_required');
    assert.deepEqual(revoked, []);
    assert.equal(await api.store.count('users', { email: person.email }), 1);

    // Asking again any number of times doesn't use up the guess budget.
    for (let i = 0; i < 10; i++) {
      assert.equal((await deleteAccount(person.token, { password: person.password })).status, 400);
    }
    const both = await deleteAccount(person.token, {
      password: person.password,
      appleAuthorizationCode: 'synthetic-code',
    });
    assert.equal(both.status, 200, JSON.stringify(both.body));
    assert.equal(both.body.apple_revoked, true);
    assert.deepEqual(revoked, ['synthetic-code']);
    assert.equal(await api.store.count('users', { email: person.email }), 0);
  } finally {
    for (const [k, value] of saved.env) {
      if (value === undefined) delete process.env[k];
      else process.env[k] = value;
    }
    apple.revokeAuthorizationCode = saved.revoke;
  }
});

test('an Apple sign-in used again to connect Apple is refused with 403, not 401', async () => {
  const person = await signUp(api);
  const credential = { ...appleCredential(appleSubject()), password: person.password };
  const link = (body) => api.post('/api/account/identities/apple', body, { token: person.token });
  assert.equal((await link(credential)).status, 201);
  const replayed = await link(credential);
  assert.equal(replayed.status, 403);
  assert.equal(replayed.body.details.code, 'apple_not_confirmed');
  const forged = await link({ ...credential, identityToken: 'not-a-jwt' });
  assert.equal(forged.status, 403);
  assert.equal(forged.body.details.code, 'apple_not_confirmed');
  assert.equal((await api.get('/api/me', { token: person.token })).status, 200);
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
  await mailedCode(user.email);

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
    (
      await api.post(
        '/api/account/identities/apple',
        { ...appleCredential(bApple), password: b.password },
        { token: b.token }
      )
    ).status,
    201
  );

  // Sessions: A sees and revokes only its own.
  const listed = await api.get('/api/sessions', { token: a.token });
  assert.ok(listed.body.every((s) => s.id !== bPhone.sessionId));
  await api.del(`/api/sessions/${bPhone.sessionId}`, { token: a.token });
  assert.equal((await api.get('/api/me', { token: bPhone.token })).status, 200);

  // Apple: A can't take B's Apple ID, and disconnecting touches only A.
  const taken = await api.post(
    '/api/account/identities/apple',
    { ...appleCredential(bApple), password: a.password },
    { token: a.token }
  );
  assert.equal(taken.status, 409);
  await api.del('/api/account/identities/apple', {
    token: a.token,
    body: { password: a.password },
  });
  assert.equal(await api.store.count('account_identities', { subject: bApple }), 1);

  // Reset codes are bound to their account.
  await forgot(api, a.email);
  const aCode = await mailedCode(a.email);
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

// ---------- What a session alone can't do ----------

test('a stolen session cannot link its own Apple ID and then delete a password account', async () => {
  const victim = await signUp(api);
  const attackerApple = appleSubject();
  const linked = await api.post('/api/account/identities/apple', appleCredential(attackerApple), {
    token: victim.token,
  });
  assert.notEqual(linked.status, 201, 'linking needs more than a session');
  assert.notEqual(linked.status, 200);
  assert.equal(await api.store.count('account_identities', { subject: attackerApple }), 0);

  const deleted = await deleteAccount(victim.token, appleCredential(attackerApple));
  assert.notEqual(deleted.status, 200);
  assert.equal(await api.store.count('users', { email: victim.email }), 1);
});

test('a password account connected to Apple still needs its password to delete', async () => {
  const person = await signUp(api);
  const sub = appleSubject();
  const linked = await api.post(
    '/api/account/identities/apple',
    { ...appleCredential(sub), password: person.password },
    { token: person.token }
  );
  assert.equal(linked.status, 201, JSON.stringify(linked.body));

  const withApple = await deleteAccount(person.token, appleCredential(sub));
  assert.equal(withApple.status, 400);
  assert.equal(withApple.body.details.code, 'password_required');
  assert.equal(await api.store.count('users', { email: person.email }), 1);
  assert.equal((await deleteAccount(person.token, { password: person.password })).status, 200);
});

test('connecting or disconnecting Apple needs the password', async () => {
  const person = await signUp(api);
  const link = (body) => api.post('/api/account/identities/apple', body, { token: person.token });
  const missing = await link(appleCredential(appleSubject()));
  assert.equal(missing.status, 400);
  assert.equal(missing.body.details.code, 'password_required');
  const wrong = await link({ ...appleCredential(appleSubject()), password: 'not-the-password' });
  assert.equal(wrong.status, 403);
  assert.equal(wrong.body.details.code, 'wrong_password');
  assert.equal(await api.store.count('account_identities', { account_id: person.user._id }), 0);
  assert.equal(
    (await link({ ...appleCredential(appleSubject()), password: person.password })).status,
    201
  );

  const unlink = (body) => api.del('/api/account/identities/apple', { token: person.token, body });
  assert.equal((await unlink({})).status, 400);
  assert.equal((await unlink({ password: 'not-the-password' })).status, 403);
  assert.equal(await api.store.count('account_identities', { account_id: person.user._id }), 1);
  assert.equal((await unlink({ password: person.password })).status, 200);
  assert.equal(await api.store.count('account_identities', { account_id: person.user._id }), 0);
});

test('an Apple-only account adds another Apple ID only with a fresh token for the linked one', async () => {
  const account = await appleAccount(api);
  const link = (body) => api.post('/api/account/identities/apple', body, { token: account.token });
  const second = appleSubject();
  const missing = await link(appleCredential(second));
  assert.equal(missing.status, 400);
  assert.equal(missing.body.details.code, 'apple_reauthorization_required');

  const other = appleCredential(appleSubject());
  const foreign = await link({
    ...appleCredential(second),
    currentIdentityToken: other.identityToken,
    currentNonce: other.nonce,
  });
  assert.equal(foreign.status, 403);
  assert.equal(await api.store.count('account_identities', { subject: second }), 0);

  const current = appleCredential(account.sub);
  const done = await link({
    ...appleCredential(second),
    currentIdentityToken: current.identityToken,
    currentNonce: current.nonce,
  });
  assert.equal(done.status, 201, JSON.stringify(done.body));
});

test('an agent token needs the password, or a fresh Sign in with Apple without one', async () => {
  const person = await signUp(api);
  const create = (token, extra) =>
    api.post(
      '/v1/tokens',
      { name: 'Synthetic agent', scopes: ['read', 'write'], ...extra },
      { token, headers: { 'Idempotency-Key': `token-${randomBytes(6).toString('hex')}` } }
    );
  const missing = await create(person.token, {});
  assert.equal(missing.status, 400);
  assert.equal(missing.body.details.code, 'password_required');
  const wrong = await create(person.token, { password: 'not-the-password' });
  assert.equal(wrong.status, 403);
  assert.equal(wrong.body.details.code, 'wrong_password');
  assert.equal(await api.store.count('personal_access_tokens', { account_id: person.user._id }), 0);
  assert.equal((await create(person.token, { password: person.password })).status, 201);

  const account = await appleAccount(api);
  const unconfirmed = await create(account.token, {});
  assert.equal(unconfirmed.status, 400);
  assert.equal(unconfirmed.body.details.code, 'apple_reauthorization_required');
  const foreign = await create(account.token, appleCredential(appleSubject()));
  assert.equal(foreign.status, 403);
  assert.equal(await api.store.count('personal_access_tokens', { account_id: account.id }), 0);
  const confirmed = await create(account.token, appleCredential(account.sub));
  assert.equal(confirmed.status, 201, JSON.stringify(confirmed.body));
});

test('an Apple token without an issue time does not confirm a deletion', async () => {
  const account = await appleAccount(api);
  const undated = await deleteAccount(
    account.token,
    appleCredential(account.sub, { withoutIssuedAt: true })
  );
  assert.equal(undated.status, 403);
  assert.equal(undated.body.details.code, 'apple_not_confirmed');
  assert.equal(await api.store.count('users', { id: account.id }), 1);
});

test('rejecting a forged refresh credential costs the same however often the session rotated', async () => {
  const user = await signUp(api);
  const session = await loginModern(api, user.email, user.password);
  // As if the session had rotated three million times.
  await api.store.update('sessions', { session_id: session.sessionId }, { generation: 3_000_000 });
  const forged = [];
  for (let i = 0; i < 10; i++) {
    forged.push(`${session.sessionId}.${randomBytes(32).toString('base64url')}`);
    forged.push(`${session.sessionId}.2999999.${randomBytes(32).toString('base64url')}`);
  }
  const started = Date.now();
  for (const [i, credential] of forged.entries()) {
    assert.equal((await refresh(api, credential, `forged-operation-${i}`)).status, 401);
  }
  const elapsed = Date.now() - started;
  // Recomputing every earlier credential took minutes here.
  assert.ok(elapsed < 15000, `20 forged credentials took ${elapsed} ms`);
  const stored = await api.store.findOne('sessions', { session_id: session.sessionId });
  assert.equal(stored.revoked_at, null, 'a forgery proves nothing and ends nothing');
});

test('a refresh credential issued before it carried its generation still rotates once', async () => {
  const user = await signUp(api);
  const session = await loginModern(api, user.email, user.password);
  const [id, generation] = session.refreshToken.split('.');
  assert.equal(generation, '0');
  const legacy = (n) =>
    `${id}.${createHmac('sha256', process.env.JWT_SECRET).update(`refresh:${id}:${n}`).digest('base64url')}`;
  await api.store.update(
    'sessions',
    { session_id: id },
    { refresh_hash: createHash('sha256').update(legacy(0)).digest('hex') }
  );
  const upgraded = await refresh(api, legacy(0), 'legacy-operation-1');
  assert.equal(upgraded.status, 200, JSON.stringify(upgraded.body));
  assert.equal(upgraded.body.refreshToken.split('.').length, 3);
  const forged = `${id}.${randomBytes(32).toString('base64url')}`;
  assert.equal((await refresh(api, forged, 'legacy-forged')).status, 401);
  assert.equal((await api.store.findOne('sessions', { session_id: id })).revoked_at, null);
  const reused = await refresh(api, legacy(0), 'legacy-operation-2');
  assert.equal(reused.status, 401);
  assert.match(reused.body.message, /used from two places/);
});
