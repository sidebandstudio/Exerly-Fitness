// Personal access tokens: scopes, the paths they can reach, server-side
// audit events, revocation and expiry.

const test = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const { startServer, signUp } = require('./helpers/server');

let api;
test.before(async () => {
  api = await startServer();
});
test.after(async () => {
  await api.close();
});

const key = () => ({ 'Idempotency-Key': randomUUID() });

async function token(user, scopes, extra = {}) {
  const res = await api.post(
    '/v1/tokens',
    { name: `Synthetic ${scopes.join('+')}`, scopes, ...extra },
    {
      token: user.token,
      headers: key(),
    }
  );
  assert.equal(res.status, 201, JSON.stringify(res.body));
  return res.body;
}

const session = (id) => ({
  id,
  startedAt: '2026-10-06T18:00:00.000Z',
  timeZoneID: 'UTC',
  exercises: [],
  name: '',
  notes: '',
});
const SESSION_ID = '0B2C4E6F-0000-4000-8000-000000000001';
const proposal = (id, extra = {}) => ({
  id,
  title: 'Did you mean 150 kg?',
  summary: 'Synthetic',
  falsifier: 'You lifted 1500 kg.',
  status: 'pending',
  confidence: 'high',
  author: { kind: 'builtIn', name: 'You' },
  changes: [{ kind: 'workout_session', id: SESSION_ID, before: null, after: session(SESSION_ID) }],
  evidence: [],
  createdAt: '2026-10-06T18:00:00.000Z',
  ...extra,
});

async function auditEvents(user) {
  const changes = (await api.get('/v1/changes?after=0', { token: user.token })).body.changes;
  return changes.filter((c) => c.kind === 'audit_event').map((c) => c.payload);
}

test('a token is shown once, stored hashed, and listed without its secret', async () => {
  const user = await signUp(api);
  const created = await token(user, ['read']);
  assert.match(created.token, /^exr_[A-Za-z0-9_-]{43}$/);
  assert.deepEqual(created.scopes, ['read']);
  const listed = (await api.get('/v1/tokens', { token: user.token })).body;
  assert.equal(listed.length, 1);
  assert.equal(listed[0].id, created.id);
  assert.ok(!JSON.stringify(listed).includes(created.token));
  assert.equal(listed[0].prefix, created.token.slice(0, 12));
  const stored = await api.store.findOne('personal_access_tokens', { id: created.id });
  assert.notEqual(stored.token_hash, created.token);
  assert.equal(stored.token_hash.length, 64);
  const events = await auditEvents(user);
  assert.deepEqual(
    events.map((e) => e.action),
    ['tokenCreated']
  );
});

test('tokens reach only /v1 and /mcp, never token management or the account', async () => {
  const user = await signUp(api);
  const { token: pat } = await token(user, ['read', 'write']);
  assert.equal((await api.get('/v1/changes?after=0', { token: pat })).status, 200);
  // Express matches paths regardless of case, so the refusal must too.
  for (const [method, path] of [
    ['get', '/api/export'],
    ['get', '/api/me'],
    ['get', '/API/me'],
    ['get', '/v1/tokens'],
    ['get', '/v1/Tokens'],
    ['get', '/V1/TOKENS/'],
    ['del', '/api/account'],
  ]) {
    const res = await api[method](path, { token: pat });
    assert.equal(res.status, 403, `${method} ${path} -> ${res.status}`);
  }
  for (const path of ['/v1/tokens', '/v1/Tokens', '/v1/TOKENS']) {
    const minted = await api.post(path, { name: 'x', scopes: ['read', 'write'] }, { token: pat });
    assert.equal(minted.status, 403, `post ${path} -> ${minted.status}`);
  }
  const listed = await api.get('/v1/tokens', { token: user.token });
  assert.equal(listed.body.length, 1, 'a token minted nothing');
});

test('a propose-only token files pending proposals under its own name and nothing else', async () => {
  const user = await signUp(api);
  const created = await token(user, ['propose']);
  const pat = created.token;
  const id = randomUUID().toUpperCase();
  const filed = await api.put(
    `/v1/documents/proposal/${id}`,
    { payload: proposal(id), base_revision: 0 },
    { token: pat, headers: key() }
  );
  assert.equal(filed.status, 201, JSON.stringify(filed.body));
  const stored = (await api.get(`/v1/documents/proposal/${id}`, { token: user.token })).body
    .payload;
  assert.deepEqual(stored.author, { kind: 'api', name: created.name, tokenID: created.id });

  const forbidden = [
    [
      'put',
      `/v1/documents/proposal/${randomUUID().toUpperCase()}`,
      (i) => ({ payload: proposal(i, { status: 'accepted' }), base_revision: 0 }),
    ],
    [
      'put',
      `/v1/documents/proposal/${id}`,
      () => ({ payload: proposal(id, { status: 'accepted' }), base_revision: 1 }),
    ],
    [
      'put',
      `/v1/documents/workout_session/${randomUUID().toUpperCase()}`,
      (i) => ({ payload: session(i), base_revision: 0 }),
    ],
    [
      'put',
      `/v1/documents/audit_event/${randomUUID().toUpperCase()}`,
      (i) => ({
        payload: { id: i, action: 'tokenRevoked', at: '2026-10-06T18:00:00.000Z', actor: {} },
        base_revision: 0,
      }),
    ],
  ];
  for (const [method, path, body] of forbidden) {
    const docID = path.split('/').at(-1);
    const res = await api[method](path, body(docID), { token: pat, headers: key() });
    assert.equal(res.status, 403, `${path} -> ${res.status} ${JSON.stringify(res.body)}`);
  }
  const events = await auditEvents(user);
  assert.deepEqual(
    events.map((e) => e.action),
    ['tokenCreated', 'proposalFiled']
  );
  assert.equal(events[1].proposalID, id);
  assert.equal(events[1].actor.tokenID, created.id);

  // The person decides with their session.
  const decided = await api.put(
    `/v1/documents/proposal/${id}`,
    { payload: proposal(id, { status: 'accepted' }), base_revision: 1 },
    { token: user.token, headers: key() }
  );
  assert.equal(decided.status, 200);
});

test('a write token may change data, and every write is audited', async () => {
  const user = await signUp(api);
  const created = await token(user, ['write']);
  assert.deepEqual(created.scopes, ['read', 'write']);
  const id = randomUUID().toUpperCase();
  const path = `/v1/documents/workout_session/${id}`;
  assert.equal(
    (
      await api.put(
        path,
        { payload: session(id), base_revision: 0 },
        { token: created.token, headers: key() }
      )
    ).status,
    201
  );
  assert.equal(
    (await api.del(`${path}?base_revision=1`, { token: created.token, headers: key() })).status,
    200
  );
  const events = await auditEvents(user);
  assert.deepEqual(
    events.map((e) => e.action),
    ['tokenCreated', 'directWrite', 'directWrite']
  );
  assert.deepEqual(events[1].targets, [{ kind: 'workout_session', id }]);
  assert.equal(events[2].note, 'deleted');
});

test('a read token writes nothing', async () => {
  const user = await signUp(api);
  const { token: pat } = await token(user, ['read']);
  const id = randomUUID().toUpperCase();
  assert.equal(
    (
      await api.put(
        `/v1/documents/proposal/${id}`,
        { payload: proposal(id), base_revision: 0 },
        { token: pat, headers: key() }
      )
    ).status,
    403
  );
  assert.equal(
    (
      await api.put(
        `/v1/documents/workout_session/${id}`,
        { payload: session(id), base_revision: 0 },
        { token: pat, headers: key() }
      )
    ).status,
    403
  );
});

test('revoked, expired and unknown tokens are refused; use is recorded', async () => {
  const user = await signUp(api);
  const created = await token(user, ['read']);
  assert.equal((await api.get('/v1/changes', { token: created.token })).status, 200);
  const stored = await api.store.findOne('personal_access_tokens', { id: created.id });
  assert.ok(stored.last_used_at);

  assert.equal(
    (await api.del(`/v1/tokens/${created.id}`, { token: user.token, headers: key() })).status,
    200
  );
  assert.equal((await api.get('/v1/changes', { token: created.token })).status, 401);
  assert.deepEqual((await api.get('/v1/tokens', { token: user.token })).body, []);
  assert.deepEqual(
    (await auditEvents(user)).map((e) => e.action),
    ['tokenCreated', 'tokenRevoked']
  );

  const expiring = await token(user, ['read'], { expires_in_days: 1 });
  await api.store.update(
    'personal_access_tokens',
    { id: expiring.id },
    { expires_at: new Date(Date.now() - 1000) }
  );
  assert.equal((await api.get('/v1/changes', { token: expiring.token })).status, 401);
  assert.equal((await api.get('/v1/changes', { token: `exr_${'A'.repeat(43)}` })).status, 401);
});

test('another account cannot see or revoke a token', async () => {
  const owner = await signUp(api);
  const other = await signUp(api);
  const created = await token(owner, ['read']);
  assert.deepEqual((await api.get('/v1/tokens', { token: other.token })).body, []);
  assert.equal(
    (await api.del(`/v1/tokens/${created.id}`, { token: other.token, headers: key() })).status,
    404
  );
  assert.equal((await api.get('/v1/changes', { token: created.token })).status, 200);
});

test('scopes and names are validated, and accounts hold at most 20 tokens', async () => {
  const user = await signUp(api);
  for (const body of [
    { name: '', scopes: ['read'] },
    { name: 'x', scopes: [] },
    { name: 'x', scopes: ['admin'] },
    { name: 'x', scopes: ['read'], expires_in_days: 0 },
  ]) {
    const res = await api.post('/v1/tokens', body, { token: user.token, headers: key() });
    assert.equal(res.status, 400, JSON.stringify(body));
  }
  for (let i = 0; i < 20; i++) await token(user, ['read']);
  assert.equal(
    (
      await api.post(
        '/v1/tokens',
        { name: 'one more', scopes: ['read'] },
        { token: user.token, headers: key() }
      )
    ).status,
    409
  );
});

test('deleting the account removes its tokens', async () => {
  const user = await signUp(api);
  const created = await token(user, ['read']);
  assert.equal(
    (
      await api.del('/api/account', {
        token: user.token,
        body: { confirm: true, password: user.password },
      })
    ).status,
    200
  );
  assert.equal(await api.store.count('personal_access_tokens', { id: created.id }), 0);
  assert.equal((await api.get('/v1/changes', { token: created.token })).status, 401);
});

test('a token secret is never kept in an idempotency receipt; a replay says it was shown once', async () => {
  const user = await signUp(api);
  const headers = { 'Idempotency-Key': `create-${randomUUID()}` };
  const body = { name: 'Synthetic agent', scopes: ['read'] };
  const created = await api.post('/v1/tokens', body, { token: user.token, headers });
  assert.equal(created.status, 201);
  assert.match(created.body.token, /^exr_/);
  const receipts = await api.store.find('operations', { account_id: user.user._id });
  assert.ok(receipts.length >= 1);
  assert.ok(!JSON.stringify(receipts).includes(created.body.token), 'the secret is not at rest');
  const replay = await api.post('/v1/tokens', body, { token: user.token, headers });
  assert.equal(replay.status, 201);
  assert.equal(replay.body.id, created.body.id);
  assert.equal(replay.body.token, null);
  assert.equal(replay.body.token_shown_once, true);
});
