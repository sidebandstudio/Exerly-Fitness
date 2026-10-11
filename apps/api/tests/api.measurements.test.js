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

test('measurements preserve units, revisions and deletion across duplicate replay', async () => {
  const user = await signUp(api);
  const token = user.token;
  const client_id = randomUUID();
  const body = { client_id, type: 'waist', value: 32.5, unit: 'in' };
  const headers = { 'Idempotency-Key': randomUUID() };
  const created = await api.post('/api/measurements', body, { token, headers });
  assert.equal(created.status, 201);
  assert.equal(created.body.value, 82.55);
  assert.equal(created.body.unit, 'cm');
  assert.equal(created.body.entered_value, 32.5);
  assert.equal(created.body.entered_unit, 'in');
  const path = `/api/measurements/${created.body.id}`;
  const changed = await api.put(
    path,
    { type: 'waist', value: 81.25, unit: 'cm', base_revision: 1 },
    { token }
  );
  assert.equal(changed.status, 200);
  assert.equal(changed.body.revision, 2);
  const stale = await api.put(path, { ...body, base_revision: 1 }, { token });
  assert.equal(stale.status, 409);
  assert.equal(stale.body.details.current.value, 81.25);
  assert.equal((await api.del(path, { token, headers: { 'If-Match': '2' } })).status, 200);
  assert.equal((await api.get('/api/measurements', { token })).body.total, 0);
  const replay = await api.post('/api/measurements', body, { token, headers });
  assert.equal(replay.body.id, created.body.id);
  assert.equal((await api.get('/api/measurements', { token })).body.total, 0);
  assert.equal((await api.post('/api/measurements', body, { token })).status, 409);
  const restored = await api.post(`${path}/restore`, { base_revision: 3 }, { token });
  assert.equal(restored.body.value, 81.25);
  assert.equal(restored.body.revision, 4);
  const exported = await api.get('/api/export', { token });
  assert.equal(exported.body.measurements.length, 1);
  assert.equal(exported.body.measurements[0].value, 81.25);
  const page = await api.get('/api/measurements?limit=1&offset=1', { token });
  assert.equal(page.body.entries.length, 0);
  assert.equal(page.body.total, 1);
  const feed = await api.get('/api/sync', { token });
  assert.deepEqual(
    feed.body.changes.map((row) => row.revision),
    [1, 2, 3, 4]
  );
  assert.ok(feed.body.changes.every((row) => row.kind === 'measurement'));
  const other = await signUp(api);
  assert.equal((await api.get(path, { token: other.token })).status, 404);
  assert.equal(
    (await api.put(path, { ...body, base_revision: 4 }, { token: other.token })).status,
    404
  );
  assert.equal((await api.get('/api/measurements', { token: other.token })).body.total, 0);
});

test('measurement validation rejects incompatible units, invalid values and unchecked updates', async () => {
  const { token } = await signUp(api);
  for (const body of [
    { type: 'weight', value: 80, unit: 'kg' },
    { type: 'body_fat', value: 18, unit: 'cm' },
    { type: 'body_fat', value: 101, unit: '%' },
    { type: 'waist', value: -1, unit: 'cm' },
    { type: 'waist', value: 'NaN', unit: 'cm' },
    { type: 'waist', value: 80, unit: 'cm', entry_date: '2099-01-01' },
  ])
    assert.equal((await api.post('/api/measurements', body, { token })).status, 400);
  assert.equal((await api.get('/api/measurements', { token })).body.total, 0);
  const created = await api.post(
    '/api/measurements',
    { type: 'body_fat', value: 18.5, unit: '%' },
    { token }
  );
  assert.equal(created.status, 201);
  assert.equal(created.body.value, 18.5);
  assert.equal(
    (
      await api.put(
        `/api/measurements/${created.body.id}`,
        { type: 'body_fat', value: 18, unit: '%' },
        { token }
      )
    ).status,
    400
  );
  assert.equal((await api.del(`/api/measurements/${created.body.id}`, { token })).status, 400);
});

test('measurements accept every body site, both sides of each limb, and filter by site', async () => {
  const { token } = await signUp(api);
  const sites = ['bust', 'chest', 'hips', 'neck', 'shoulders', 'waist'];
  for (const limb of ['ankle', 'bicep', 'calf', 'forearm', 'thigh', 'wrist'])
    sites.push(`left_${limb}`, `right_${limb}`);
  for (const [index, type] of sites.entries()) {
    const created = await api.post(
      '/api/measurements',
      { client_id: randomUUID(), type, value: 10 + index, unit: 'in', entry_date: '2026-10-01' },
      { token }
    );
    assert.equal(created.status, 201, type);
    assert.equal(created.body.type, type);
    assert.equal(created.body.value, Number(((10 + index) * 2.54).toFixed(4)));
  }
  // Older sides-unknown sites stay writable, so their history can be edited.
  const older = await api.post(
    '/api/measurements',
    { client_id: randomUUID(), type: 'arms', value: 33, unit: 'cm' },
    { token }
  );
  assert.equal(older.status, 201);
  for (const type of ['left_arm', 'bicep', 'left_waist'])
    assert.equal(
      (await api.post('/api/measurements', { type, value: 30, unit: 'cm' }, { token })).status,
      400,
      type
    );
  const all = await api.get('/api/measurements?from=2026-01-01', { token });
  assert.equal(all.body.total, sites.length + 1);
  const left = await api.get('/api/measurements?type=left_bicep&from=2026-01-01', { token });
  assert.equal(left.body.total, 1);
  assert.equal(left.body.entries[0].type, 'left_bicep');
  assert.equal(
    (await api.get('/api/measurements?type=left_arm&from=2026-01-01', { token })).status,
    400
  );
});
