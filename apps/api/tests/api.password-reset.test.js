// Password recovery: a mailed code that works once, briefly, for its own
// account, without saying whether an address has an account. Mail stays in
// the memory transport's outbox.

const test = require('node:test');
const assert = require('node:assert/strict');
const mail = require('../lib/mail');
const passwordReset = require('../lib/passwordReset');
const { startServer, signUp } = require('./helpers/server');
const { reset: resetRateLimits } = require('../lib/ratelimit');
const accounts = require('./helpers/accounts');

const { appleAccount, loginModern, refresh, personalToken, mailedCode, forgot, resetPassword } =
  accounts;

let api;
test.before(async () => {
  accounts.trustLocalAppleKey();
  api = await startServer();
});
test.after(async () => api.close());
test.beforeEach(() => resetRateLimits());

test('a reset request says the same thing whether or not the account exists', async () => {
  mail.clear();
  const user = await signUp(api);
  const apple = await appleAccount(api);
  const placeholder = (await api.store.findById('users', apple.id)).email;
  const answers = [];
  for (const email of [user.email, 'nobody-here@exerly.test', placeholder]) {
    const res = await forgot(api, email);
    assert.equal(res.status, 202, email);
    answers.push(res.body);
  }
  await passwordReset.settle();
  assert.deepEqual(answers[1], answers[0]);
  assert.deepEqual(answers[2], answers[0]);
  assert.deepEqual(
    mail.sent().map((m) => m.to),
    [user.email],
    'mail goes only to a real account with a deliverable address'
  );
  assert.equal(mail.sent()[0].from, 'Exerly <hello@sideband.studio>');

  // An unknown address fails the reset exactly as a wrong code does.
  const unknown = await resetPassword(api, 'nobody-here@exerly.test', 'ABCD-EFGH');
  const wrong = await resetPassword(api, user.email, 'ABCD-EFGH');
  assert.equal(unknown.status, 400);
  assert.deepEqual(unknown.body, wrong.body);
});

test('a reset code is stored hashed, works once, and ends every session and token', async () => {
  const user = await signUp(api);
  const phone = await loginModern(api, user.email, user.password);
  const agent = await personalToken(api, user);
  await forgot(api, user.email);
  const code = await mailedCode(user.email);

  const rows = await api.store.find('password_resets', { account_id: user.user._id });
  assert.equal(rows.length, 1);
  const stored = JSON.stringify(rows);
  for (const form of [code, code.replace('-', '')]) assert.ok(!stored.includes(form));

  const weak = await resetPassword(api, user.email, code, 'short');
  assert.equal(weak.status, 400);
  const changed = await resetPassword(api, user.email, code.toLowerCase().replace('-', ' '));
  assert.equal(changed.status, 200, JSON.stringify(changed.body));

  assert.equal((await api.get('/api/me', { token: user.token })).status, 401);
  assert.equal((await api.get('/api/me', { token: phone.token })).status, 401);
  assert.equal((await refresh(api, phone.refreshToken, 'after-reset-refresh')).status, 401);
  assert.equal((await api.get('/v1/changes', { token: agent })).status, 401);

  assert.equal(
    (await api.post('/login', { email: user.email, password: user.password })).status,
    401
  );
  const login = await api.post('/login', { email: user.email, password: 'a-brand-new-passphrase' });
  assert.equal(login.status, 200);

  const reused = await resetPassword(api, user.email, code, 'yet-another-passphrase');
  assert.equal(reused.status, 400);
  assert.equal(reused.body.details.code, 'reset_code_invalid');
});

test('five wrong guesses, a newer code or expiry end a code', async () => {
  const user = await signUp(api);
  await forgot(api, user.email);
  const guessed = await mailedCode(user.email);
  for (let i = 0; i < 5; i++) {
    const wrong = passwordReset.newCode();
    if (wrong === guessed.replace('-', '')) continue;
    assert.equal((await resetPassword(api, user.email, wrong)).status, 400);
  }
  assert.equal((await resetPassword(api, user.email, guessed)).status, 400, 'used up by guesses');

  resetRateLimits();
  await forgot(api, user.email);
  const first = await mailedCode(user.email);
  await forgot(api, user.email);
  const second = await mailedCode(user.email);
  assert.notEqual(first, second);
  assert.equal(
    (await resetPassword(api, user.email, first)).status,
    400,
    'replaced by a newer code'
  );

  resetRateLimits();
  await forgot(api, user.email);
  const late = await mailedCode(user.email);
  await api.store.updateMany(
    'password_resets',
    { account_id: user.user._id, used_at: null },
    { expires_at: new Date(Date.now() - 1000) }
  );
  assert.equal((await resetPassword(api, user.email, late)).status, 400, 'expired');
  assert.equal((await resetPassword(api, user.email, second)).status, 400);
  assert.equal(
    (await api.post('/login', { email: user.email, password: user.password })).status,
    200
  );
});

test('reset requests and attempts are rate limited', async () => {
  const user = await signUp(api);
  for (let i = 0; i < 3; i++) assert.equal((await forgot(api, user.email)).status, 202);
  assert.equal((await forgot(api, user.email)).status, 429, 'per email');
  assert.equal((await forgot(api, 'someone-else@exerly.test')).status, 202);
  assert.equal((await forgot(api, 'a-third-person@exerly.test')).status, 429, 'per address');

  resetRateLimits();
  for (let i = 0; i < 10; i++) {
    assert.equal((await resetPassword(api, 'nobody-here@exerly.test', 'ABCD-EFGH')).status, 400);
  }
  assert.equal((await resetPassword(api, 'nobody-here@exerly.test', 'ABCD-EFGH')).status, 429);
});

// ---------- Timing and concurrency ----------

test('a reset request is answered before the account is looked up', async () => {
  const user = await signUp(api);
  const original = api.store.findOne;
  let release;
  const gate = new Promise((resolve) => (release = resolve));
  let lookedUp = false;
  api.store.findOne = async (collection, filter, ...rest) => {
    if (collection === 'users' && filter?.email === user.email) {
      lookedUp = true;
      await gate;
    }
    return original(collection, filter, ...rest);
  };
  try {
    const answered = await Promise.race([
      forgot(api, user.email),
      new Promise((resolve) => setTimeout(() => resolve('timed out'), 3000)),
    ]);
    assert.notEqual(answered, 'timed out', 'the response waited for the account lookup');
    assert.equal(answered.status, 202);
    assert.equal(mail.sent(user.email).length, 0, 'nothing account-dependent ran first');
    release();
    await passwordReset.settle();
    assert.ok(lookedUp);
    assert.equal(mail.sent(user.email).length, 1);
  } finally {
    release();
    api.store.findOne = original;
  }
});

test('one reset code used by several requests at once changes the password once', async () => {
  const user = await signUp(api);
  await forgot(api, user.email);
  const code = await mailedCode(user.email);
  const passwords = Array.from({ length: 5 }, (_, i) => `concurrent-passphrase-${i}`);
  const results = await Promise.all(passwords.map((p) => resetPassword(api, user.email, code, p)));
  assert.deepEqual(
    results.map((r) => r.status).sort(),
    [200, 400, 400, 400, 400],
    JSON.stringify(results.map((r) => r.body))
  );
  const winner = passwords[results.findIndex((r) => r.status === 200)];
  resetRateLimits();
  for (const p of passwords) {
    const login = await api.post('/login', { email: user.email, password: p });
    assert.equal(login.status, p === winner ? 200 : 401, p);
  }
});

test('wrong guesses made at once cannot add up to more than five', async () => {
  const user = await signUp(api);
  await forgot(api, user.email);
  const code = await mailedCode(user.email);
  const guesses = [];
  while (guesses.length < 10) {
    const guess = passwordReset.newCode();
    if (guess !== code.replace('-', '')) guesses.push(guess);
  }
  const results = await Promise.all(guesses.map((g) => resetPassword(api, user.email, g)));
  assert.ok(
    results.every((r) => r.status === 400),
    JSON.stringify(results.map((r) => r.status))
  );
  const [row] = await api.store.find('password_resets', { account_id: user.user._id });
  assert.equal(row.attempts, 5, 'exactly five guesses counted');
  assert.ok(row.used_at, 'the code is used up');
  resetRateLimits();
  assert.equal((await resetPassword(api, user.email, code)).status, 400);
});

test('shutting down finishes queued reset mail before closing the database', async () => {
  const { shutdown } = require('../lib/shutdown');
  const order = [];
  let release;
  passwordReset.afterResponse('synthetic@exerly.test', async () => {
    await new Promise((resolve) => (release = resolve));
    order.push('mail sent');
  });
  const stopping = shutdown({
    server: { close: (done) => (order.push('server closed'), done()) },
    store: { disconnect: async () => order.push('database closed') },
  });
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.deepEqual(order, ['server closed'], 'the database waits for queued mail');
  release();
  await stopping;
  assert.deepEqual(order, ['server closed', 'mail sent', 'database closed']);
});

test('a reset email that fails to send is logged and counted, but public health says nothing', async () => {
  const before = passwordReset.metrics.deliveryFailures;
  const logged = [];
  const original = console.error;
  console.error = (...args) => logged.push(args.join(' '));
  try {
    passwordReset.afterResponse('synthetic@exerly.test', async () => {
      throw new Error('No mail transport for synthetic@exerly.test');
    });
    await passwordReset.settle();
  } finally {
    console.error = original;
  }
  assert.equal(passwordReset.metrics.deliveryFailures, before + 1);
  assert.equal(logged.length, 1);
  assert.match(logged[0], new RegExp(`failures since start: ${before + 1}`));
  assert.ok(!logged[0].includes('synthetic@exerly.test'));
  // A public counter would tell anyone whether a reset found an account.
  const health = await api.get('/api/health');
  assert.ok(!JSON.stringify(health.body).includes('delivery_failures'));
  assert.equal(health.body.password_reset, undefined);
});

test('the forced exit at shutdown waits less than App Platform allows, and can be set', () => {
  const { deadlineMs } = require('../lib/shutdown');
  assert.equal(deadlineMs({}), 100_000);
  assert.ok(deadlineMs({}) < 120_000, 'under the default grace period');
  assert.equal(deadlineMs({ SHUTDOWN_DEADLINE_SECONDS: '45' }), 45_000);
  assert.equal(deadlineMs({ SHUTDOWN_DEADLINE_SECONDS: 'soon' }), 100_000);
  assert.equal(deadlineMs({ SHUTDOWN_DEADLINE_SECONDS: '0' }), 100_000);
});
