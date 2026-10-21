// v1 document sync: revisions, conflicts, idempotency, tombstones, the change
// feed and isolation.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { startServer, signUp } = require('./helpers/server');
const docs = require('../lib/documents');
const { foodEntryProblems, foodProblems } = require('../lib/nutrition/validate');

let api;
test.before(async () => {
  api = await startServer();
});
test.after(async () => {
  await api.close();
});

const sessionID = () => randomUUID().toUpperCase();
const session = (id, notes = '') => ({
  id,
  name: 'Synthetic push day',
  startedAt: '2026-10-06T18:00:00.000Z',
  timeZoneID: 'America/New_York',
  notes,
  exercises: [],
});
const key = () => ({ 'Idempotency-Key': randomUUID() });
const put = (token, id, payload, base_revision, headers = key()) =>
  api.put(`/v1/documents/workout_session/${id}`, { payload, base_revision }, { token, headers });

test('documents get server revisions and stale writes conflict with the current version', async () => {
  const { token } = await signUp(api);
  const id = sessionID();
  const created = await put(token, id, session(id), 0);
  assert.equal(created.status, 201, JSON.stringify(created.body));
  assert.equal(created.body.revision, 1);
  assert.equal(created.body.kind, 'workout_session');
  assert.equal(created.body.id, id);

  const updated = await put(token, id, session(id, 'second'), 1);
  assert.equal(updated.status, 200);
  assert.equal(updated.body.revision, 2);

  const stale = await put(token, id, session(id, 'stale'), 1);
  assert.equal(stale.status, 409);
  assert.equal(stale.body.details.document.revision, 2);
  assert.equal(stale.body.details.document.payload.notes, 'second');

  const read = await api.get(`/v1/documents/workout_session/${id}`, { token });
  assert.equal(read.status, 200);
  assert.deepEqual(read.body.payload, session(id, 'second'));
  assert.equal(read.body.deleted, false);

  const recreate = await put(token, id, session(id), 0);
  assert.equal(recreate.status, 409, 'creating over an existing document conflicts');
});

test('a retried push with the same key applies once', async () => {
  const { token } = await signUp(api);
  const id = sessionID();
  const headers = key();
  const results = await Promise.all(
    Array.from({ length: 5 }, () => put(token, id, session(id), 0, headers))
  );
  assert.ok(
    results.every((r) => r.status === 201),
    JSON.stringify(results.map((r) => r.status))
  );
  for (const r of results) assert.deepEqual(r.body, results[0].body);
  const read = await api.get(`/v1/documents/workout_session/${id}`, { token });
  assert.equal(read.body.revision, 1);
});

test('deletion leaves a tombstone that reaches other devices and can be restored', async () => {
  const { token } = await signUp(api);
  const id = sessionID();
  await put(token, id, session(id), 0);
  const stale = await api.del(`/v1/documents/workout_session/${id}?base_revision=0`, {
    token,
    headers: key(),
  });
  assert.equal(stale.status, 409);
  const deleted = await api.del(`/v1/documents/workout_session/${id}?base_revision=1`, {
    token,
    headers: key(),
  });
  assert.equal(deleted.status, 200);
  assert.equal(deleted.body.revision, 2);
  assert.equal(deleted.body.deleted, true);

  const read = await api.get(`/v1/documents/workout_session/${id}`, { token });
  assert.equal(read.body.deleted, true);
  assert.equal(read.body.payload, null);

  const restored = await put(token, id, session(id, 'restored'), 2);
  assert.equal(restored.status, 200);
  assert.equal(restored.body.revision, 3);
  assert.equal(
    (
      await api.del(`/v1/documents/workout_session/${sessionID()}?base_revision=0`, {
        token,
        headers: key(),
      })
    ).status,
    404
  );
});

test('the change feed lists document changes in order and pages past legacy kinds', async () => {
  const { token } = await signUp(api);
  const a = sessionID();
  const b = sessionID();
  await put(token, a, session(a), 0);
  await api.post('/api/water', { deltaMl: 250 }, { token, headers: key() });
  await put(token, b, session(b), 0);
  await api.post('/api/water', { deltaMl: 250 }, { token, headers: key() });
  await put(token, a, session(a, 'edited'), 1);
  await api.del(`/v1/documents/workout_session/${b}?base_revision=1`, { token, headers: key() });
  await api.post('/api/water', { deltaMl: 250 }, { token, headers: key() });

  const all = (await api.get('/v1/changes?after=0', { token })).body;
  assert.deepEqual(
    all.changes.map((c) => [c.id, c.revision, c.deleted]),
    [
      [a, 1, false],
      [b, 1, false],
      [a, 2, false],
      [b, 2, true],
    ]
  );
  assert.equal(all.changes[2].payload.notes, 'edited');
  assert.equal(all.changes[3].payload, null);
  assert.equal(all.cursor, 7, 'the cursor passes the trailing legacy change');
  assert.equal(all.has_more, false);

  const pages = [];
  let cursor = 0;
  for (let i = 0; i < 10; i++) {
    const page = (await api.get(`/v1/changes?after=${cursor}&limit=2`, { token })).body;
    pages.push(...page.changes.map((c) => `${c.id}:${c.revision}`));
    cursor = page.cursor;
    if (!page.has_more) break;
  }
  assert.deepEqual(
    pages,
    all.changes.map((c) => `${c.id}:${c.revision}`)
  );
  assert.equal(cursor, 7);
});

test('documents are private to their account', async () => {
  const owner = await signUp(api);
  const intruder = await signUp(api);
  const id = sessionID();
  await put(owner.token, id, session(id, 'private'), 0);
  assert.equal(
    (await api.get(`/v1/documents/workout_session/${id}`, { token: intruder.token })).status,
    404
  );
  assert.equal(
    (
      await api.del(`/v1/documents/workout_session/${id}?base_revision=1`, {
        token: intruder.token,
        headers: key(),
      })
    ).status,
    404
  );
  // The same ID in another account is a separate document.
  const own = await put(intruder.token, id, session(id, 'mine'), 0);
  assert.equal(own.status, 201);
  assert.equal(
    (await api.get('/v1/changes?after=0', { token: intruder.token })).body.changes.length,
    1
  );
  const ownerCopy = await api.get(`/v1/documents/workout_session/${id}`, { token: owner.token });
  assert.equal(ownerCopy.body.payload.notes, 'private');
});

test('rejects unknown kinds, bad ids, mismatched payloads and missing base revisions', async () => {
  const { token } = await signUp(api);
  const id = sessionID();
  const cases = [
    ['/v1/documents/food_photo/' + id, { payload: { id }, base_revision: 0 }],
    [
      '/v1/documents/workout_session/has%20space',
      { payload: { id: 'has space' }, base_revision: 0 },
    ],
    [`/v1/documents/workout_session/${id}`, { payload: { id: sessionID() }, base_revision: 0 }],
    [`/v1/documents/workout_session/${id}`, { payload: [id], base_revision: 0 }],
    [`/v1/documents/workout_session/${id}`, { payload: session(id) }],
    [`/v1/documents/workout_session/${id}`, { payload: session(id), base_revision: -1 }],
  ];
  for (const [path, body] of cases) {
    const res = await api.put(path, body, { token, headers: key() });
    assert.equal(res.status, 400, `${path} ${JSON.stringify(body).slice(0, 60)} -> ${res.status}`);
  }
  assert.equal((await api.get('/v1/changes?after=0', { token })).body.changes.length, 0);
});

test('custom exercises sync as documents and appear in the export and deletion', async () => {
  const user = await signUp(api);
  const id = `custom-${randomUUID().toLowerCase()}`;
  const exercise = { id, name: 'Zercher Squat', metric: 'weightReps' };
  const res = await api.put(
    `/v1/documents/custom_exercise/${id}`,
    { payload: exercise, base_revision: 0 },
    { token: user.token, headers: key() }
  );
  assert.equal(res.status, 201);
  const exported = (await api.get('/api/export', { token: user.token })).body;
  assert.equal(exported.documents.length, 1);
  assert.deepEqual(exported.documents[0].payload, exercise);
  await api.del('/api/account', {
    token: user.token,
    body: { confirm: true, password: user.password },
  });
  assert.equal(await api.store.count('documents', { account_id: user.user._id }), 0);
});

test('proposals and audit events sync, and audit events never change', async () => {
  const { token } = await signUp(api);
  const proposalID = randomUUID().toUpperCase();
  const proposal = {
    id: proposalID,
    title: 'Did you mean 150 kg?',
    summary: 'Ten times your history.',
    falsifier: 'You lifted 1500 kg.',
    status: 'pending',
    confidence: 'high',
    author: { kind: 'mcp', name: 'Synthetic agent' },
    changes: [{ kind: 'workout_session', id: 'X', after: { id: 'X', notes: 'Fixed' } }],
    evidence: [],
    createdAt: '2026-10-06T18:00:00.000Z',
  };
  const filed = await api.put(
    `/v1/documents/proposal/${proposalID}`,
    { payload: proposal, base_revision: 0 },
    { token, headers: key() }
  );
  assert.equal(filed.status, 201, JSON.stringify(filed.body));
  const decided = await api.put(
    `/v1/documents/proposal/${proposalID}`,
    { payload: { ...proposal, status: 'accepted' }, base_revision: 1 },
    { token, headers: key() }
  );
  assert.equal(decided.status, 200);

  const missingFalsifier = await api.put(
    `/v1/documents/proposal/${randomUUID().toUpperCase()}`,
    { payload: { ...proposal, id: undefined, falsifier: ' ' }, base_revision: 0 },
    { token, headers: key() }
  );
  assert.equal(missingFalsifier.status, 400);

  const eventID = randomUUID().toUpperCase();
  const event = {
    id: eventID,
    action: 'proposalAccepted',
    at: '2026-10-06T18:05:00.000Z',
    actor: { kind: 'builtIn', name: 'You' },
    targets: [{ kind: 'workout_session', id: 'X' }],
  };
  const path = `/v1/documents/audit_event/${eventID}`;
  assert.equal(
    (await api.put(path, { payload: event, base_revision: 0 }, { token, headers: key() })).status,
    201
  );
  // Re-sending the same event is harmless; changing or deleting it is refused.
  assert.equal(
    (await api.put(path, { payload: event, base_revision: 1 }, { token, headers: key() })).status,
    200
  );
  assert.equal(
    (
      await api.put(
        path,
        { payload: { ...event, action: 'proposalRejected' }, base_revision: 1 },
        { token, headers: key() }
      )
    ).status,
    400
  );
  assert.equal((await api.del(`${path}?base_revision=1`, { token, headers: key() })).status, 400);
  const changes = (await api.get('/v1/changes?after=0', { token })).body.changes;
  assert.deepEqual(
    changes.map((c) => `${c.kind}:${c.revision}`),
    ['proposal:1', 'proposal:2', 'audit_event:1']
  );
});

test('a UUID document ID is one document whatever its letter case', async () => {
  const { token, user } = await signUp(api);
  const upper = randomUUID().toUpperCase();
  const lower = upper.toLowerCase();
  const session = (id, notes) => ({
    id,
    name: '',
    notes,
    startedAt: '2026-10-06T18:00:00.000Z',
    timeZoneID: 'UTC',
    exercises: [],
  });
  const first = await api.put(
    `/v1/documents/workout_session/${lower}`,
    { payload: session(lower, 'first'), base_revision: 0 },
    { token, headers: key() }
  );
  assert.equal(first.status, 201, JSON.stringify(first.body));
  assert.equal(first.body.id, upper);
  const second = await api.put(
    `/v1/documents/workout_session/${upper}`,
    { payload: session(upper, 'second'), base_revision: 1 },
    { token, headers: key() }
  );
  assert.equal(second.status, 200);
  assert.equal(second.body.revision, 2);
  const read = await api.get(`/v1/documents/workout_session/${lower}`, { token });
  assert.equal(read.body.payload.id, upper);
  assert.equal(read.body.payload.notes, 'second');
  assert.equal(
    await api.store.count('documents', { account_id: user._id, kind: 'workout_session' }),
    1
  );
  const feed = (await api.get('/v1/changes?after=0', { token })).body.changes;
  assert.ok(feed.every((c) => c.id === upper && c.payload.id === upper));

  const proposalID = randomUUID();
  const filed = await api.put(
    `/v1/documents/proposal/${proposalID}`,
    {
      payload: {
        id: proposalID,
        createdAt: '2026-10-06T18:30:00.000Z',
        author: { kind: 'builtIn', name: 'Exerly' },
        title: 'Fix',
        summary: '',
        changes: [{ kind: 'workout_session', id: lower, after: session(lower, 'x') }],
        evidence: [
          {
            claim: 'c',
            level: 'anecdote',
            caveats: [],
            dataRefs: [{ kind: 'workout_session', id: lower }],
          },
        ],
        confidence: 'low',
        falsifier: 'f',
        status: 'pending',
      },
      base_revision: 0,
    },
    { token, headers: key() }
  );
  assert.equal(filed.status, 201, JSON.stringify(filed.body));
  const stored = (await api.get(`/v1/documents/proposal/${proposalID}`, { token })).body.payload;
  assert.equal(stored.id, proposalID.toUpperCase());
  assert.equal(stored.changes[0].id, upper);
  assert.equal(stored.evidence[0].dataRefs[0].id, upper);
});

const migration = (name) =>
  fs.readFileSync(path.join(__dirname, '../db/migrations', `${name}.up.sql`), 'utf8');
const LOWERCASE_UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/;

test('the migration uppercases UUID document IDs and refuses to merge twins', async () => {
  const { user } = await signUp(api);
  const sql = migration('0005_canonical_document_ids');
  const now = new Date();
  const insertDocument = (id) =>
    api.store.insert('documents', {
      account_id: user._id,
      kind: 'workout_session',
      document_id: id,
      revision: 1,
      payload: { id },
      deleted_at: null,
      created_at: now,
      updated_at: now,
    });
  const insertChange = (kind, id, sequence) =>
    api.store.insert('sync_changes', {
      account_id: user._id,
      sequence,
      kind,
      entity_id: id,
      server_id: id,
      revision: 1,
      deleted: false,
      payload: { payload: { id } },
      created_at: now,
    });
  const lower = randomUUID();
  const legacy = randomUUID();
  await insertDocument(lower);
  await insertChange('workout_session', lower, 1001);
  await insertChange('water', legacy, 1002);

  await api.store.query(sql);
  const rows = await api.store.find('documents', { account_id: user._id });
  assert.deepEqual(
    rows.map((r) => r.document_id),
    [lower.toUpperCase()]
  );
  const changes = await api.store.find('sync_changes', { account_id: user._id });
  assert.deepEqual(changes.map((c) => c.entity_id).sort(), [lower.toUpperCase(), legacy].sort());

  const twin = randomUUID();
  await insertDocument(twin);
  await insertDocument(twin.toUpperCase());
  await assert.rejects(api.store.query(sql), /duplicate key|unique/i);
  await api.store.query('DELETE FROM documents WHERE account_id = $1', [user._id]);
});

test('migration 0006 makes stored and feed payloads canonical, as the API writes them', async () => {
  const { token, user } = await signUp(api);
  const [workout, proposal, audit] = [randomUUID(), randomUUID(), randomUUID()];
  const before = session(workout, 'before');
  const legacy = [
    ['workout_session', workout, before],
    [
      'proposal',
      proposal,
      {
        id: proposal,
        createdAt: '2026-10-06T18:30:00.000Z',
        author: { kind: 'builtIn', name: 'Exerly' },
        title: 'Fix',
        summary: '',
        changes: [
          { kind: 'workout_session', id: workout, before, after: session(workout, 'after') },
        ],
        evidence: [
          {
            claim: 'c',
            level: 'anecdote',
            caveats: [],
            dataRefs: [{ kind: 'workout_session', id: workout }],
          },
        ],
        confidence: 'low',
        falsifier: 'f',
        status: 'pending',
      },
    ],
    [
      'audit_event',
      audit,
      {
        id: audit,
        at: '2026-10-06T18:30:00.000Z',
        action: 'proposalFiled',
        actor: { kind: 'builtIn', name: 'Exerly' },
        proposalID: proposal,
        targets: [{ kind: 'workout_session', id: workout }],
      },
    ],
  ];
  const now = new Date();
  for (const [i, [kind, id, payload]] of legacy.entries()) {
    await api.store.insert('documents', {
      account_id: user._id,
      kind,
      document_id: id,
      revision: 1,
      payload,
      deleted_at: null,
      created_at: now,
      updated_at: now,
    });
    await api.store.insert('sync_changes', {
      account_id: user._id,
      sequence: 2001 + i,
      kind,
      entity_id: id,
      server_id: id,
      revision: 1,
      deleted: false,
      payload: { id, client_id: id, revision: 1, payload, updated_at: now.toISOString() },
      created_at: now,
    });
  }

  await api.store.query(migration('0005_canonical_document_ids'));
  await api.store.query(migration('0006_canonical_payload_ids'));
  for (const [kind, id, payload] of legacy) {
    const row = await api.store.findOne('documents', { account_id: user._id, kind });
    assert.equal(row.document_id, id.toUpperCase());
    assert.deepEqual(row.payload, docs.canonicalPayload(kind, payload), kind);
    assert.doesNotMatch(JSON.stringify(row.payload), LOWERCASE_UUID, kind);
  }
  const feed = (await api.get('/v1/changes?after=2000', { token })).body.changes;
  assert.equal(feed.length, 3);
  assert.doesNotMatch(JSON.stringify(feed), LOWERCASE_UUID);
  const read = await api.get(`/v1/documents/proposal/${proposal}`, { token });
  assert.equal(read.body.payload.changes[0].after.id, workout.toUpperCase());

  // A device re-sending the audit event in its canonical form is not a change.
  const resent = await api.put(
    `/v1/documents/audit_event/${audit}`,
    { payload: docs.canonicalPayload('audit_event', legacy[2][2]), base_revision: 1 },
    { token, headers: key() }
  );
  assert.equal(resent.status, 200, JSON.stringify(resent.body));
});

test('nutrition documents sync like training ones', async () => {
  const { token } = await signUp(api);
  const entryID = randomUUID().toUpperCase();
  const documents = [
    [
      'saved_food',
      'F1',
      { id: 'F1', name: 'Oats', source: 'custom', per100g: { energy: 380 }, servings: [] },
    ],
    [
      'food_entry',
      entryID,
      {
        id: entryID,
        date: '2026-10-05',
        meal: 'Breakfast',
        loggedAt: '2026-10-05T08:00:00.000Z',
        grams: 40,
        food: { foodID: 'F1', name: 'Oats', source: 'custom', per100g: { energy: 380 } },
      },
    ],
    [
      'nutrition_day',
      '2026-10-05',
      { id: '2026-10-05', date: '2026-10-05', status: 'complete', notes: '' },
    ],
    [
      'weight_entry',
      entryID,
      {
        id: entryID,
        at: '2026-10-05T07:00:00.000Z',
        date: '2026-10-05',
        weight: { unit: 'kg', value: 80 },
      },
    ],
  ];
  for (const [kind, id, payload] of documents) {
    const res = await api.put(
      `/v1/documents/${kind}/${id}`,
      { payload, base_revision: 0 },
      { token, headers: key() }
    );
    assert.equal(res.status, 201, `${kind}: ${JSON.stringify(res.body)}`);
  }
  const planID = randomUUID().toUpperCase();
  const day = { energy: 2060, protein: 144, fat: 69, carbohydrate: 215 };
  const plan = await api.put(
    `/v1/documents/nutrition_plan/${planID}`,
    {
      payload: {
        id: planID,
        startDate: '2026-10-05',
        createdAt: '2026-10-05T08:00:00.000Z',
        goal: { direction: 'lose', weeklyRate: 0.005 },
        mode: 'coached',
        diet: 'balanced',
        protein: 'moderate',
        weekdayWeights: [1, 1, 1, 1, 1, 1, 1],
        checkInDay: 2,
        allowBelowFloor: false,
        targets: Array(7).fill(day),
      },
      base_revision: 0,
    },
    { token, headers: key() }
  );
  assert.equal(plan.status, 201, JSON.stringify(plan.body));
  const noTargets = await api.put(
    `/v1/documents/nutrition_plan/${randomUUID()}`,
    {
      payload: { startDate: '2026-10-05', goal: { direction: 'lose' }, targets: [] },
      base_revision: 0,
    },
    { token, headers: key() }
  );
  assert.equal(noTargets.status, 400);
  const wrongDay = await api.put(
    '/v1/documents/nutrition_day/2026-10-06',
    { payload: { id: '2026-10-06', date: '2026-10-05', status: 'complete' }, base_revision: 0 },
    { token, headers: key() }
  );
  assert.equal(wrongDay.status, 400);
  const changes = (await api.get('/v1/changes?after=0', { token })).body.changes;
  assert.deepEqual(
    changes.map((c) => c.kind),
    ['saved_food', 'food_entry', 'nutrition_day', 'weight_entry', 'nutrition_plan']
  );
});

test("a session's program and an entry's food are stored in canonical form", async () => {
  const { token } = await signUp(api);
  const program = randomUUID();
  const food = randomUUID();
  const workout = sessionID();
  const entry = sessionID();
  await put(
    token,
    workout,
    { ...session(workout), program: { programID: program, cycle: 0, dayID: 'A' } },
    0
  );
  const logged = await api.put(
    `/v1/documents/food_entry/${entry}`,
    {
      payload: {
        id: entry,
        date: '2026-10-05',
        meal: 'Breakfast',
        loggedAt: '2026-10-05T08:00:00.000Z',
        grams: 40,
        food: { foodID: food, name: 'Oats', source: 'custom', per100g: { energy: 380 } },
      },
      base_revision: 0,
    },
    { token, headers: key() }
  );
  assert.equal(logged.status, 201, JSON.stringify(logged.body));
  const read = async (kind, id) =>
    (await api.get(`/v1/documents/${kind}/${id}`, { token })).body.payload;
  assert.equal((await read('workout_session', workout)).program.programID, program.toUpperCase());
  assert.equal((await read('food_entry', entry)).food.foodID, food.toUpperCase());
});

test('gym profiles sync as documents', async () => {
  const { token } = await signUp(api);
  const id = randomUUID().toUpperCase();
  const gym = {
    id,
    name: 'Synthetic gym',
    equipment: ['dumbbell', 'flatBench'],
    bars: [{ value: 20, unit: 'kg' }],
    plates: [],
    loads: { dumbbell: [{ value: 22.5, unit: 'kg' }] },
    excluded: [],
    createdAt: '2026-10-06T12:00:00.000Z',
  };
  const saved = await api.put(
    `/v1/documents/gym_profile/${id}`,
    { payload: gym, base_revision: 0 },
    { token, headers: key() }
  );
  assert.equal(saved.status, 201, JSON.stringify(saved.body));
  const flat = await api.put(
    `/v1/documents/gym_profile/${randomUUID()}`,
    { payload: { ...gym, loads: [] }, base_revision: 0 },
    { token, headers: key() }
  );
  assert.equal(flat.status, 400);
});

test('hidden suggestions sync as documents named by their food', async () => {
  const { token } = await signUp(api);
  const hidden = { id: 'usda:2709224', name: 'Banana, raw', hiddenAt: '2026-10-10T12:00:00.000Z' };
  const saved = await api.put(
    '/v1/documents/hidden_suggestion/usda:2709224',
    { payload: hidden, base_revision: 0 },
    { token, headers: key() }
  );
  assert.equal(saved.status, 201, JSON.stringify(saved.body));
  const read = await api.get('/v1/documents/hidden_suggestion/usda:2709224', { token });
  assert.deepEqual(read.body.payload, hidden);
  const unnamed = await api.put(
    '/v1/documents/hidden_suggestion/usda:1',
    { payload: { id: 'usda:1', hiddenAt: hidden.hiddenAt }, base_revision: 0 },
    { token, headers: key() }
  );
  assert.equal(unnamed.status, 400);
});

test('import provenance syncs as documents named by import and part', async () => {
  const { token } = await signUp(api);
  const id = `${randomUUID().toUpperCase()}.0`;
  const provenance = {
    id,
    importID: id.slice(0, 36),
    part: 0,
    parts: 1,
    source: 'strong',
    files: ['strong.csv'],
    importedAt: '2026-10-20T12:00:00.000Z',
    timeZoneID: 'America/New_York',
    lines: [{ key: 'workouts', title: 'Workouts', new: 2, existing: 0, updated: 0 }],
    documents: [`workout_session/${randomUUID().toUpperCase()}`],
  };
  const saved = await api.put(
    `/v1/documents/import_provenance/${id}`,
    { payload: provenance, base_revision: 0 },
    { token, headers: key() }
  );
  assert.equal(saved.status, 201, JSON.stringify(saved.body));
  const read = await api.get(`/v1/documents/import_provenance/${id}`, { token });
  assert.deepEqual(read.body.payload, provenance);
  const otherID = `${randomUUID().toUpperCase()}.0`;
  const partless = await api.put(
    `/v1/documents/import_provenance/${otherID}`,
    { payload: { ...provenance, id: otherID, part: undefined }, base_revision: 0 },
    { token, headers: key() }
  );
  assert.equal(partless.status, 400);
});

test('legacy food logs and saved foods stay in their own feeds', async () => {
  const { token } = await signUp(api);
  await api.post('/api/food', { name: 'Logged oats', calories: 300 }, { token });
  const food = { id: 'F1', name: 'Oats', source: 'custom', per100g: { energy: 380 }, servings: [] };
  const saved = await api.put(
    '/v1/documents/saved_food/F1',
    { payload: food, base_revision: 0 },
    { token, headers: key() }
  );
  assert.equal(saved.status, 201, JSON.stringify(saved.body));
  const documents = (await api.get('/v1/changes?after=0', { token })).body.changes;
  assert.deepEqual(
    documents.map((c) => c.kind),
    ['saved_food']
  );
  const legacy = (await api.get('/api/sync?after=0', { token })).body.changes;
  assert.deepEqual(
    legacy.filter((c) => c.kind === 'food').map((c) => c.payload.name),
    ['Logged oats']
  );
});

test('custom metrics, their values and experiments sync, with metric references canonical', async () => {
  const { token } = await signUp(api);
  const metric = randomUUID();
  const write = (kind, id, payload) =>
    api.put(
      `/v1/documents/${kind}/${id}`,
      { payload, base_revision: 0 },
      { token, headers: key() }
    );
  const saved = await write('custom_metric', metric, {
    id: metric,
    name: 'Sleep quality',
    kind: 'scale',
    createdAt: '2026-10-06T08:00:00.000Z',
  });
  assert.equal(saved.status, 201, JSON.stringify(saved.body));
  const entry = randomUUID().toUpperCase();
  const value = await write('metric_entry', entry, {
    id: entry,
    metricID: metric,
    date: '2026-10-06',
    value: 4,
  });
  assert.equal(value.status, 201, JSON.stringify(value.body));
  const read = await api.get(`/v1/documents/metric_entry/${entry}`, { token });
  assert.equal(read.body.payload.metricID, metric.toUpperCase());
  const experiment = randomUUID().toUpperCase();
  const planned = await write('experiment', experiment, {
    id: experiment,
    name: 'Creatine and sleep',
    change: '5 g creatine',
    metric: `metric:${metric.toUpperCase()}`,
    baselineStart: '2026-10-01',
    baselineEnd: '2026-10-14',
    interventionStart: '2026-10-15',
    interventionEnd: '2026-10-28',
    createdAt: '2026-10-01T08:00:00.000Z',
  });
  assert.equal(planned.status, 201, JSON.stringify(planned.body));
  assert.equal((await write('custom_metric', randomUUID(), { name: 'No kind' })).status, 400);
});

test('a recipe round-trips whole; an agent cannot write a bad count or ingredient serving', async () => {
  const { token } = await signUp(api);
  const recipe = {
    id: 'R1',
    name: 'Porridge',
    source: 'recipe',
    per100g: { energy: 127.4 },
    servings: [],
    favorite: false,
    createdAt: '2026-10-07T08:00:00.000Z',
    ingredients: [
      {
        food: { foodID: 'F1', name: 'Oats', source: 'custom', per100g: { energy: 380 } },
        grams: 80,
        serving: { name: '1/2 cup', grams: 40 },
        quantity: 2,
      },
    ],
    yieldGrams: 160,
    servingCount: 2,
    preparation: 'Simmer 5 minutes, stirring.',
  };
  const saved = await api.put(
    '/v1/documents/saved_food/R1',
    { payload: recipe, base_revision: 0 },
    { token, headers: key() }
  );
  assert.equal(saved.status, 201, JSON.stringify(saved.body));
  const [change] = (await api.get('/v1/changes?after=0', { token })).body.changes;
  assert.deepEqual(change.payload, recipe, 'a recipe round-trips whole');

  assert.deepEqual(foodProblems(recipe, 'R1'), []);
  assert.deepEqual(foodProblems({ ...recipe, servingCount: 0, preparation: 3 }, 'R1'), [
    'the serving count must be positive',
    'preparation must be text',
  ]);
  const [oats] = recipe.ingredients;
  const counted = { ...oats, serving: { name: '', grams: 40 }, quantity: 0 };
  assert.deepEqual(foodProblems({ ...recipe, ingredients: [counted] }, 'R1'), [
    'ingredients[0].serving needs a name and a positive weight in grams',
    'ingredients[0].quantity must be positive',
  ]);
});

test('an unweighed quick add is a valid entry; its flag must be true or false', () => {
  const id = randomUUID().toUpperCase();
  const entry = {
    id,
    date: '2026-10-07',
    meal: 'Lunch',
    loggedAt: '2026-10-07T16:30:00.000Z',
    grams: 100,
    food: {
      foodID: `quick:${id}`,
      name: 'Quick add',
      source: 'custom',
      per100g: { energy: 450 },
      unweighed: true,
    },
  };
  assert.deepEqual(foodEntryProblems(entry, id), []);
  assert.deepEqual(foodEntryProblems({ ...entry, food: { ...entry.food, unweighed: 'yes' } }, id), [
    'food.unweighed must be true or false',
  ]);
});
