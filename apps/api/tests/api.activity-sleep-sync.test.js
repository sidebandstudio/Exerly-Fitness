const test = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const { startServer, signUp } = require('./helpers/server');
const dates = require('../lib/dates');
let api;
test.before(async () => {
  api = await startServer();
});
test.after(async () => {
  await api.close();
});

const types = [
  {
    path: '/api/activities',
    collection: 'activities',
    kind: 'activity',
    body: { activity: 'Walk', duration_min: 30, calories: 110 },
    field: 'duration_min',
    values: [35, 40],
  },
  {
    path: '/api/sleep',
    collection: 'sleep',
    kind: 'sleep',
    body: { hours: 7.5, quality: 'good', bedtime: '23:00', wake_time: '06:30' },
    field: 'hours',
    values: [7.75, 8],
  },
];

test('manual logs preserve fractional durations, unknown values, naps and the selected date', async () => {
  const user = await signUp(api);
  const token = user.token;
  const day = dates.addDays(dates.today(user.timezone), -3);
  const activity = await api.post(
    '/api/activities',
    {
      activity: 'Walk',
      duration_min: 30.25,
      entry_date: day,
      client_id: randomUUID(),
    },
    { token }
  );
  assert.equal(activity.status, 201);
  assert.equal(activity.body.calories, null);
  assert.equal(activity.body.intensity, null);
  assert.equal(activity.body.duration_min, 30.25);
  const sleep = await api.post(
    '/api/sleep',
    {
      hours: 7.25,
      bedtime: '23:00',
      wake_time: '06:15',
      entry_date: day,
      client_id: randomUUID(),
    },
    { token }
  );
  assert.equal(sleep.status, 201);
  assert.equal(sleep.body.quality, null);
  const nap = await api.post(
    '/api/sleep',
    {
      hours: 0.5,
      quality: 'good',
      entry_date: day,
      client_id: randomUUID(),
    },
    { token }
  );
  assert.equal(nap.status, 201);
  const summary = (await api.get(`/api/summary?entry_date=${day}`, { token })).body;
  assert.equal(summary.sleep_entries.length, 2);
  assert.equal(summary.sleep_hours, 7.75);
  assert.equal(summary.sleep.id, nap.body.id, 'Legacy clients still receive the latest entry');
  assert.equal(summary.activities[0].calories, null);
  assert.equal(summary.entry_count, 3);
  assert.equal((await api.get('/api/summary', { token })).body.entry_count, 0);
  const edited = await api.put(
    `/api/activities/${activity.body.id}`,
    {
      activity: 'Walk',
      duration_min: 45.5,
      calories: 0,
      base_revision: 1,
    },
    { token }
  );
  assert.equal(edited.status, 200);
  assert.equal(edited.body.calories, 0, 'Explicit zero is retained separately from unknown');
  assert.equal(edited.body.entry_date, day);
  const exported = (await api.get('/api/export', { token })).body;
  assert.equal(exported.activities[0].duration_min, 45.5);
  assert.equal(exported.sleep.length, 2);
  assert.equal(exported.sleep.find((row) => row.id === sleep.body.id).quality, null);
});

for (const { path, collection, kind, body, field, values } of types) {
  test(`${kind} additions merge, repeated operations do not duplicate and competing edits require review`, async () => {
    const user = await signUp(api);
    const token = user.token;
    const payload = { ...body, client_id: randomUUID() };
    const headers = { 'Idempotency-Key': randomUUID() };
    const attempts = await Promise.all(
      Array.from({ length: 4 }, () => api.post(path, payload, { token, headers }))
    );
    assert.ok(attempts.every((row) => row.status === 201));
    assert.equal(new Set(attempts.map((row) => row.body.id)).size, 1);
    const row = attempts[0].body;
    assert.equal(row.revision, 1);
    assert.equal((await api.post(path, payload, { token })).status, 409);
    const independent = await api.post(path, { ...body, client_id: randomUUID() }, { token });
    assert.equal(independent.status, 201);
    assert.equal((await api.get(path, { token })).body.length, 2);
    const edits = await Promise.all(
      values.map((value) =>
        api.put(`${path}/${row.id}`, { ...body, [field]: value, base_revision: 1 }, { token })
      )
    );
    assert.deepEqual(edits.map((result) => result.status).sort(), [200, 409]);
    const current = (await api.get(`${path}/${row.id}`, { token })).body;
    assert.equal(current.revision, 2);
    assert.equal((await api.put(`${path}/${row.id}`, body, { token })).status, 409);
    assert.equal((await api.post(path, payload, { token, headers })).body.revision, 1);
    assert.equal((await api.get(`${path}/${row.id}`, { token })).body[field], current[field]);
    const other = await signUp(api);
    assert.equal((await api.get(`${path}/${row.id}`, { token: other.token })).status, 404);
    assert.equal((await api.post(path, payload, { token: other.token, headers })).status, 201);
    const changes = (await api.get('/api/sync', { token })).body.changes.filter(
      (item) => item.kind === kind && item.entity_id === payload.client_id
    );
    assert.deepEqual(
      changes.map((item) => item.revision),
      [1, 2]
    );
    assert.equal((await api.get('/api/export', { token })).body[collection].length, 2);
  });

  test(`${kind} deletion cannot be resurrected by a stale edit or replay after restoration`, async () => {
    const user = await signUp(api);
    const token = user.token;
    const row = (await api.post(path, { ...body, client_id: randomUUID() }, { token })).body;
    const headers = { 'If-Match': '1', 'Idempotency-Key': randomUUID() };
    const removed = await api.del(`${path}/${row.id}`, { token, headers });
    assert.equal(removed.status, 200);
    assert.equal(removed.body[kind].revision, 2);
    assert.equal((await api.get(path, { token })).body.length, 0);
    assert.equal((await api.get(`${path}/${row.id}`, { token })).status, 404);
    assert.equal(
      (await api.put(`${path}/${row.id}`, { ...body, base_revision: 2 }, { token })).status,
      409
    );
    assert.equal(
      (await api.post(path, { ...body, client_id: row.client_id }, { token })).status,
      409
    );
    const summary = (await api.get('/api/summary', { token })).body;
    if (kind === 'activity') assert.equal(summary.activities.length, 0);
    else assert.equal(summary.sleep, null);
    assert.equal((await api.get('/api/export', { token })).body[collection].length, 0);
    assert.equal((await api.get(`${path}?include_deleted=true`, { token })).body[0].id, row.id);
    assert.equal(
      (await api.post(`${path}/${row.id}/restore`, { base_revision: 1 }, { token })).status,
      409
    );
    const restored = await api.post(`${path}/${row.id}/restore`, { base_revision: 2 }, { token });
    assert.equal(restored.status, 200);
    assert.equal(restored.body.id, row.id);
    assert.equal(restored.body.revision, 3);
    assert.equal((await api.del(`${path}/${row.id}`, { token, headers })).body[kind].revision, 2);
    assert.equal((await api.get(`${path}/${row.id}`, { token })).body.revision, 3);
    const changes = (await api.get('/api/sync', { token })).body.changes.filter(
      (item) => item.kind === kind
    );
    assert.deepEqual(
      changes.map((item) => item.deleted),
      [false, true, false]
    );
  });

  test(`legacy ${kind} records retain stable identities while adopting revision checks`, async () => {
    const user = await signUp(api);
    const token = user.token;
    const entry_date = dates.today(user.timezone);
    const original = await api.store.insert(collection, {
      ...body,
      email: user.email,
      account_id: user.user._id,
      entry_date,
      created_at: new Date(),
    });
    await api.store.insert(collection, {
      ...body,
      email: user.email,
      account_id: user.user._id,
      entry_date,
      created_at: new Date(),
    });
    const first = (await api.get(`${path}/${original.id}`, { token })).body;
    assert.equal(first.client_id, `legacy-${original.id}`);
    assert.equal(
      (await api.get(`${path}/${original.id}`, { token })).body.client_id,
      first.client_id
    );
    assert.equal(
      (await api.put(`${path}/${original.id}`, { ...body, base_revision: 1 }, { token })).status,
      200
    );
    const adopted = (await api.get(`${path}/${original.id}`, { token })).body;
    assert.equal(adopted.client_id, first.client_id);
    assert.equal(adopted.id, original.id);
    assert.equal(adopted.revision, 2);
    assert.equal((await api.put(`${path}/${original.id}`, body, { token })).status, 409);
    assert.equal(
      (await api.post(path, { ...body, client_id: first.client_id }, { token })).status,
      400
    );
    assert.equal((await api.get(path, { token })).body.length, 2);
  });
}

test('resetting a day emits activity and sleep deletion markers and preserves other dates', async () => {
  const user = await signUp(api);
  const token = user.token;
  const today = dates.today(user.timezone);
  const yesterday = dates.addDays(today, -1);
  for (const { path, body } of types) {
    await api.post(path, { ...body, client_id: randomUUID(), entry_date: today }, { token });
    await api.post(path, { ...body, client_id: randomUUID(), entry_date: yesterday }, { token });
  }
  const reset = await api.post('/api/reset-today', { entry_date: today }, { token });
  assert.equal(reset.status, 200);
  assert.equal(reset.body.counts.activities, 1);
  assert.equal(reset.body.counts.sleep, 1);
  for (const { path, kind } of types) {
    assert.equal((await api.get(`${path}?date=${today}`, { token })).body.length, 0);
    assert.equal((await api.get(`${path}?date=${yesterday}`, { token })).body.length, 1);
    const feed = (await api.get('/api/sync', { token })).body.changes.filter(
      (item) => item.kind === kind && item.deleted
    );
    assert.equal(feed.length, 1);
    assert.equal(feed[0].payload.entry_date, today);
  }
});

test('an administrator reset sends tombstones to the target account and replays without another deletion', async () => {
  const user = await signUp(api);
  const admin = await signUp(api, { email: 'admin@exerly.test' });
  const kinds = [
    ...types,
    { path: '/api/food', collection: 'food', kind: 'food', body: { name: 'Rice', calories: 200 } },
  ];
  for (const { path, body } of kinds) {
    assert.equal(
      (await api.post(path, { ...body, client_id: randomUUID() }, { token: user.token })).status,
      201
    );
  }
  const path = `/api/admin/user/${encodeURIComponent(user.email)}/reset-today`;
  assert.equal((await api.post(path, {}, { token: user.token })).status, 403);
  const options = { token: admin.token, headers: { 'Idempotency-Key': randomUUID() } };
  const reset = await api.post(path, {}, options);
  assert.equal(reset.status, 200);
  assert.deepEqual(reset.body.counts, { activities: 1, food: 1, sleep: 1 });
  assert.deepEqual((await api.post(path, {}, options)).body, reset.body);
  const changes = (await api.get('/api/sync', { token: user.token })).body.changes;
  for (const { collection, kind } of kinds) {
    assert.equal(changes.filter((item) => item.kind === kind && item.deleted).length, 1);
    const stored = await api.store.find(
      collection,
      { email: user.email },
      { includeDeleted: true }
    );
    assert.equal(stored.length, 1);
    assert.ok(stored[0].deleted_at);
    assert.equal(stored[0].revision, 2);
  }
  assert.equal((await api.get('/api/sync', { token: admin.token })).body.changes.length, 0);
});

// The iPhone recognises an activity imported from Apple Health as unchanged by
// these fields (HealthImport.fingerprint(activity:)), so the server must hand
// each back as the app sent it, in the list a sync reads and after a write.
test('an imported activity comes back with the fields its fingerprint covers unchanged', async () => {
  const user = await signUp(api);
  const token = user.token;
  const day = dates.addDays(dates.today(user.timezone), -2);
  const sent = {
    activity: 'Running',
    duration_min: 30,
    calories: 320,
    type: 'health',
    entry_date: day,
  };
  const saved = await api.post('/api/activities', { ...sent, client_id: randomUUID() }, { token });
  assert.equal(saved.status, 201, JSON.stringify(saved.body));
  const listed = await api.get(
    `/api/activities?from=${day}&to=${day}&include_deleted=true&limit=500&page=1`,
    { token }
  );
  assert.equal(listed.status, 200);
  for (const row of [saved.body, listed.body[0]]) {
    for (const [field, value] of Object.entries(sent)) assert.equal(row[field], value, field);
    assert.equal(row.intensity, null);
  }
});
