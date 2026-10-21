// /v1/webhooks: signed notices that an account's change feed moved on. The
// receiver is a local server, so private addresses are allowed in this file
// only; the URL checks are tested with them off.

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { randomUUID } = require('node:crypto');
const { startServer, signUp } = require('./helpers/server');
const webhooks = require('../lib/webhooks');

let api;
let receiver;
let reply = 200;
const received = [];

test.before(async () => {
  process.env.EXERLY_WEBHOOKS_ALLOW_PRIVATE = '1';
  api = await startServer();
  receiver = await new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      let body = '';
      req.on('data', (chunk) => (body += chunk));
      req.on('end', () => {
        received.push({ headers: req.headers, body });
        res.statusCode = reply;
        res.end();
      });
    });
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
});
test.after(async () => {
  delete process.env.EXERLY_WEBHOOKS_ALLOW_PRIVATE;
  receiver.close();
  await api.close();
});

const key = () => ({ 'Idempotency-Key': randomUUID() });
const url = () => `http://127.0.0.1:${receiver.address().port}/exerly`;

async function writeDocument(user) {
  const id = randomUUID().toUpperCase();
  const res = await api.put(
    `/v1/documents/custom_metric/${id}`,
    { base_revision: 0, payload: { id, name: 'Synthetic mood', kind: 'scale' } },
    { token: user.token, headers: key() }
  );
  assert.equal(res.status, 201, JSON.stringify(res.body));
}

async function latestSequence(user) {
  const changes = (await api.get('/v1/changes?after=0', { token: user.token })).body.changes;
  return changes.at(-1).sequence;
}

test('a change sends one signed notice with the new sequence, and nothing more', async () => {
  const user = await signUp(api);
  await writeDocument(user);
  const created = await api.post('/v1/webhooks', { url: url() }, { token: user.token });
  assert.equal(created.status, 201, JSON.stringify(created.body));
  const { secret, id } = created.body;
  assert.match(secret, /^whsec_/);
  assert.equal(
    created.body.delivered_sequence,
    await latestSequence(user),
    'Only changes from now on'
  );
  const listed = (await api.get('/v1/webhooks', { token: user.token })).body;
  assert.deepEqual(
    listed.map((w) => w.id),
    [id]
  );
  assert.equal(listed[0].secret, undefined, 'The secret is shown once');

  received.length = 0;
  await webhooks.deliverDue();
  assert.equal(received.length, 0, 'Nothing new yet');

  await writeDocument(user);
  await writeDocument(user);
  await webhooks.deliverDue();
  assert.equal(received.length, 1, 'Two changes, one notice');
  const [notice] = received;
  const body = JSON.parse(notice.body);
  assert.equal(body.type, 'changes');
  assert.equal(body.webhook_id, id);
  assert.equal(body.sequence, await latestSequence(user));
  assert.deepEqual(
    Object.keys(body).sort(),
    ['sent_at', 'sequence', 'type', 'webhook_id'],
    'No data, only the sequence'
  );
  assert.equal(notice.headers['exerly-webhook'], id);
  const [, timestamp, signature] = notice.headers['exerly-signature'].match(
    /^t=(\d+),v1=([0-9a-f]{64})$/
  );
  assert.equal(signature, webhooks.signature(secret, timestamp, notice.body));

  await webhooks.deliverDue();
  assert.equal(received.length, 1, 'Delivered once');
});

test('a failing endpoint is retried with backoff, then disabled, and can be enabled again', async () => {
  const user = await signUp(api);
  const { id } = (await api.post('/v1/webhooks', { url: url() }, { token: user.token })).body;
  received.length = 0;
  reply = 500;
  await writeDocument(user);
  const start = new Date();
  await webhooks.deliverDue({ now: start });
  let [state] = (await api.get('/v1/webhooks', { token: user.token })).body;
  assert.equal(state.failures, 1);
  assert.equal(state.last_error, 'HTTP 500');
  await webhooks.deliverDue({ now: new Date(start.getTime() + 10_000) });
  assert.equal(received.length, 1, 'Not before the retry time');
  await webhooks.deliverDue({ now: new Date(start.getTime() + 31_000) });
  assert.equal(received.length, 2, 'Retried after 30 s');

  // Every later failure doubles the wait, up to 6 hours, until it is disabled.
  let now = start.getTime() + 31_000;
  for (let failures = 2; failures < webhooks.MAX_FAILURES; failures++) {
    now += webhooks.retryDelay(failures) + 1;
    await webhooks.deliverDue({ now: new Date(now) });
  }
  [state] = (await api.get('/v1/webhooks', { token: user.token })).body;
  assert.equal(state.failures, webhooks.MAX_FAILURES);
  assert.notEqual(state.disabled_at, null);
  assert.equal(webhooks.retryDelay(14), 6 * 60 * 60 * 1000);

  reply = 200;
  const enabled = await api.post(`/v1/webhooks/${id}/enable`, {}, { token: user.token });
  assert.equal(enabled.status, 200);
  await webhooks.deliverDue({ now: new Date(now + 1) });
  [state] = (await api.get('/v1/webhooks', { token: user.token })).body;
  assert.equal(state.failures, 0);
  assert.equal(state.delivered_sequence, await latestSequence(user));
});

test("a token's webhooks are its own and stop when it is revoked; accounts don't mix", async () => {
  const user = await signUp(api);
  const other = await signUp(api);
  const minted = await api.post(
    '/v1/tokens',
    { name: 'Synthetic dashboard', scopes: ['read'], password: user.password },
    { token: user.token, headers: key() }
  );
  const agent = minted.body.token;
  const mine = await api.post('/v1/webhooks', { url: url() }, { token: user.token });
  const theirs = await api.post('/v1/webhooks', { url: url() }, { token: agent });
  assert.equal(theirs.status, 201, JSON.stringify(theirs.body));
  assert.deepEqual(
    (await api.get('/v1/webhooks', { token: agent })).body.map((w) => w.id),
    [theirs.body.id]
  );
  assert.equal((await api.del(`/v1/webhooks/${mine.body.id}`, { token: agent })).status, 404);
  assert.equal((await api.get('/v1/webhooks', { token: user.token })).body.length, 2);
  assert.equal((await api.get('/v1/webhooks', { token: other.token })).body.length, 0);

  await api.del(`/v1/tokens/${minted.body.id}`, { token: user.token });
  received.length = 0;
  await writeDocument(other);
  await writeDocument(user);
  await webhooks.deliverDue();
  assert.deepEqual(
    received.map((r) => r.headers['exerly-webhook']),
    [mine.body.id],
    "The revoked token's webhook stays quiet, and the other account has none"
  );
  const states = (await api.get('/v1/webhooks', { token: user.token })).body;
  const stopped = states.find((w) => w.id === theirs.body.id);
  assert.match(stopped.last_error, /revoked/);

  assert.equal((await api.del(`/v1/webhooks/${mine.body.id}`, { token: user.token })).status, 204);
  assert.equal((await api.del('/v1/webhooks/not-an-id', { token: user.token })).status, 404);
});

test('only public https URLs, at most five an account', async () => {
  const user = await signUp(api);
  for (let i = 0; i < 4; i++) {
    assert.equal(
      (await api.post('/v1/webhooks', { url: url() }, { token: user.token })).status,
      201
    );
  }
  assert.equal((await api.post('/v1/webhooks', { url: url() }, { token: user.token })).status, 201);
  assert.equal((await api.post('/v1/webhooks', { url: url() }, { token: user.token })).status, 409);

  delete process.env.EXERLY_WEBHOOKS_ALLOW_PRIVATE;
  try {
    for (const bad of [
      'http://example.com/hook',
      'https://127.0.0.1/hook',
      'https://10.1.2.3/hook',
      'https://[::1]/hook',
      'https://user:pass@example.com/hook',
      'not a url',
    ]) {
      assert.throws(() => webhooks.checkURL(bad), /https|public|credentials/, bad);
    }
    assert.equal(webhooks.checkURL('https://example.com/hook#x'), 'https://example.com/hook');
    for (const address of [
      '127.0.0.1',
      '10.0.0.5',
      '172.20.1.1',
      '192.168.1.1',
      '100.80.149.7',
      '169.254.169.254',
      '::1',
      'fd12::1',
      'fe80::1',
      '::ffff:10.0.0.1',
    ]) {
      assert.equal(webhooks.privateAddress(address), true, address);
    }
    for (const address of ['93.184.216.34', '2606:2800:220:1:248:1893:25c8:1946']) {
      assert.equal(webhooks.privateAddress(address), false, address);
    }
    await assert.rejects(webhooks.post('https://127.0.0.1/hook', '{}', {}), /private/);
  } finally {
    process.env.EXERLY_WEBHOOKS_ALLOW_PRIVATE = '1';
  }
});

test('a new password revokes agent tokens and pauses webhooks made from a session', async () => {
  const user = await signUp(api);
  const minted = await api.post(
    '/v1/tokens',
    { name: 'Synthetic agent', scopes: ['read', 'write'], password: user.password },
    { token: user.token, headers: key() }
  );
  const agent = minted.body.token;
  const fromSession = await api.post('/v1/webhooks', { url: url() }, { token: user.token });
  const fromAgent = await api.post('/v1/webhooks', { url: url() }, { token: agent });
  assert.equal(fromSession.status, 201);
  assert.equal(fromAgent.status, 201);

  const changed = await api.post(
    '/api/change-password',
    { currentPassword: user.password, newPassword: 'a-brand-new-passphrase' },
    { token: user.token }
  );
  assert.equal(changed.status, 200);
  assert.match(changed.body.message, /agent tokens are revoked/);
  assert.equal((await api.get('/v1/changes', { token: agent })).status, 401);
  assert.equal((await api.post('/mcp', {}, { token: agent })).status, 401);
  const paused = await api.store.findOne('webhooks', { id: fromSession.body.id });
  assert.ok(paused.disabled_at, 'the webhook a session made is paused');
  assert.match(paused.last_error, /password changed/);

  // The token's own webhook stops with the token at its next delivery.
  const login = await api.post('/login', { email: user.email, password: 'a-brand-new-passphrase' });
  await writeDocument({ token: login.body.token });
  await webhooks.deliverDue({ send: async () => 200 });
  assert.ok((await api.store.findOne('webhooks', { id: fromAgent.body.id })).disabled_at);
});

test('a delivery that fails while the password changes leaves the webhook paused', async () => {
  const user = await signUp(api);
  const hook = await api.post('/v1/webhooks', { url: url() }, { token: user.token });
  assert.equal(hook.status, 201);
  await writeDocument(user);
  let changed;
  const delivered = await webhooks.deliverDue({
    send: async () => {
      // The owner changes the password while this delivery is in flight.
      changed = await api.post(
        '/api/change-password',
        { currentPassword: user.password, newPassword: 'a-brand-new-passphrase' },
        { token: user.token }
      );
      return 503;
    },
  });
  assert.ok(delivered >= 1);
  assert.equal(changed.status, 200);
  const row = await api.store.findOne('webhooks', { id: hook.body.id });
  assert.ok(row.disabled_at, 'still paused');
  assert.match(row.last_error, /password changed/);
});
