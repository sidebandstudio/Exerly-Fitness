// CSV exports and importing an Exerly JSON export. Synthetic data only.

const test = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const { startServer, signUp } = require('./helpers/server');
const { cell } = require('../lib/portability');

let api;
test.before(async () => {
  api = await startServer();
});
test.after(async () => api.close());

const key = () => ({ 'Idempotency-Key': randomUUID() });
const uuid = () => randomUUID().toUpperCase();

async function put(user, kind, payload) {
  const res = await api.put(
    `/v1/documents/${kind}/${payload.id}`,
    { base_revision: 0, payload },
    { token: user.token, headers: key() }
  );
  assert.equal(res.status, 201, `${kind}: ${JSON.stringify(res.body)}`);
}

/** One of everything the CSV files cover. */
async function seed(user) {
  const food = {
    foodID: 'off:3000000000013',
    name: 'Synthetic "olive", oil',
    source: 'openFoodFacts',
    per100g: { energy: 900, fat: 100 },
    volume: { density: 0.92, assumed: true, note: 'Typical for oils' },
  };
  await put(user, 'saved_food', {
    id: 'F1',
    name: '=SUM(A1:A2)',
    source: 'custom',
    per100g: { energy: 52, carbohydrate: 14 },
    servings: [{ name: '1 apple', grams: 180 }],
    favorite: true,
    createdAt: '2026-10-06T12:00:00.000Z',
  });
  await put(user, 'food_entry', {
    id: uuid(),
    date: '2026-10-06',
    meal: 'Dinner',
    loggedAt: '2026-10-06T23:30:00.000Z',
    grams: 13.8,
    serving: { name: '1 tbsp (15 ml)', grams: 13.8 },
    quantity: 1,
    food,
  });
  await put(user, 'food_entry', {
    id: uuid(),
    date: '2026-10-06',
    meal: 'Lunch',
    loggedAt: '2026-10-06T16:30:00.000Z',
    grams: 100,
    food: {
      foodID: 'quick:synthetic',
      name: 'Quick add',
      source: 'custom',
      per100g: { energy: 450, protein: 30 },
      unweighed: true,
    },
  });
  await put(user, 'weight_entry', {
    id: uuid(),
    at: '2026-10-06T11:00:00.000Z',
    date: '2026-10-06',
    weight: { value: 180.4, unit: 'lb' },
    source: 'manual',
  });
  await put(user, 'nutrition_day', {
    id: '2026-10-06',
    date: '2026-10-06',
    status: 'complete',
    notes: 'Line one\nline two',
    tags: ['travel'],
  });
  await put(user, 'workout_session', {
    id: uuid(),
    name: 'Push',
    notes: '',
    startedAt: '2026-10-06T18:00:00.000Z',
    endedAt: '2026-10-06T19:00:00.000Z',
    timeZoneID: 'America/New_York',
    bodyweight: { unit: 'kg', value: 80 },
    exercises: [
      {
        id: uuid(),
        exerciseID: 'barbell-bench-press',
        notes: '',
        sets: [
          {
            id: uuid(),
            kind: 'drop',
            efforts: [
              { reps: 6, load: { unit: 'kg', value: 100 } },
              { reps: 4, load: { unit: 'kg', value: 80 } },
            ],
            rir: 1,
            completedAt: '2026-10-06T18:10:00.000Z',
          },
        ],
      },
    ],
  });
  const metric = uuid();
  await put(user, 'custom_metric', {
    id: metric,
    name: 'Mood',
    unit: '',
    kind: 'scale',
    archived: false,
  });
  await put(user, 'metric_entry', { id: uuid(), metricID: metric, date: '2026-10-06', value: 4 });
}

const parse = (text) => text.trimEnd().split('\r\n');

/** The cells of one CSV line, unquoted. */
function cells(line) {
  const out = [];
  let field = '';
  let quoted = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (quoted) {
      if (c === '"' && line[i + 1] === '"') {
        field += '"';
        i++;
      } else if (c === '"') quoted = false;
      else field += c;
    } else if (c === '"') quoted = true;
    else if (c === ',') {
      out.push(field);
      field = '';
    } else field += c;
  }
  out.push(field);
  return out;
}

test('CSV files label units, leave unknowns empty, and are safe in a spreadsheet', async () => {
  const user = await signUp(api);
  await seed(user);
  const entries = await api.get('/v1/export/food_entries.csv', { token: user.token });
  assert.equal(entries.status, 200);
  assert.match(entries.headers.get('content-type'), /text\/csv/);
  const [header, quick, row] = parse(entries.body);
  const columns = header.split(',');
  const quickCells = cells(quick);
  assert.equal(quickCells[columns.indexOf('food_name')], 'Quick add');
  assert.equal(
    quickCells[columns.indexOf('grams')],
    '',
    "an unweighed portion's weight is unknown"
  );
  assert.equal(quickCells[columns.indexOf('energy_kcal')], '450');
  assert.ok(
    columns.includes('energy_kcal') &&
      columns.includes('sodium_mg') &&
      columns.includes('vitaminD_mcg')
  );
  assert.match(row, /"Synthetic ""olive"", oil"/);
  const values = cells(row);
  const energy = values[columns.indexOf('energy_kcal')];
  assert.equal(Number(energy), 124.2, '900 kcal per 100 g, 13.8 g');
  assert.equal(values[columns.indexOf('protein_g')], '', 'not reported, so empty, not zero');
  assert.equal(values[columns.indexOf('density_g_per_ml')], '0.92');

  const foods = await api.get('/v1/export/saved_foods.csv', { token: user.token });
  assert.match(foods.body, /'=SUM\(A1:A2\)/, 'a formula is neutralised');
  const sets = parse((await api.get('/v1/export/sets.csv', { token: user.token })).body);
  assert.equal(sets.length, 3, 'one row per effort of the drop set');
  const days = (await api.get('/v1/export/days.csv', { token: user.token })).body;
  assert.match(days, /"Line one\nline two"/);

  const missing = await api.get('/v1/export/everything.csv', { token: user.token });
  assert.equal(missing.status, 404);
  assert.match(missing.body.error ?? missing.body.message, /food_entries\.csv/);
  assert.equal(cell('-5 kg'), "'-5 kg");
  assert.equal(cell(-5), '-5');
});

test('a recipe exports its ingredients, cooked weight, servings and preparation', async () => {
  const user = await signUp(api);
  const oats = { foodID: 'F1', name: 'Oats', source: 'custom', per100g: { energy: 380 } };
  const milk = { foodID: 'F2', name: 'Milk', source: 'custom', per100g: { energy: 60 } };
  await put(user, 'saved_food', {
    id: 'R1',
    name: 'Porridge',
    source: 'recipe',
    per100g: { energy: 121 },
    servings: [],
    favorite: false,
    createdAt: '2026-10-10T08:00:00.000Z',
    yieldGrams: 400,
    servingCount: 2,
    preparation: 'Simmer, stirring.',
    ingredients: [
      { food: oats, grams: 80, serving: { name: '1/2 cup', grams: 40 }, quantity: 2 },
      { food: milk, grams: 300 },
    ],
  });
  const [header, row] = parse(
    (await api.get('/v1/export/saved_foods.csv', { token: user.token })).body
  );
  const columns = header.split(',');
  const values = cells(row);
  const value = (column) => values[columns.indexOf(column)];
  assert.deepEqual(['yield_grams', 'serving_count', 'ingredients', 'preparation'].map(value), [
    '400',
    '2',
    'Oats = 80 g; Milk = 300 g',
    'Simmer, stirring.',
  ]);
  assert.equal(value('energy_kcal_per_100g'), '121');
});

test('an export imports into another account whole, and twice changes nothing', async () => {
  const from = await signUp(api);
  await seed(from);
  await api.post('/api/food', { name: 'Legacy oats', calories: 300 }, { token: from.token });
  const exported = (await api.get('/api/export', { token: from.token })).body;

  const to = await signUp(api);
  const first = await api.post('/v1/import', exported, { token: to.token });
  assert.equal(first.status, 200, JSON.stringify(first.body));
  assert.equal(first.body.imported, 8);
  assert.deepEqual(first.body.skipped, []);
  assert.equal(first.body.tables.food?.restored, 1, 'the older food log is restored too');

  const documents = async (user) =>
    (await api.get('/v1/changes?after=0', { token: user.token })).body.changes
      .filter((c) => c.kind !== 'audit_event')
      .map((c) => ({ kind: c.kind, id: c.id, revision: c.revision, payload: c.payload }))
      .sort((a, b) => `${a.kind}/${a.id}`.localeCompare(`${b.kind}/${b.id}`));
  assert.deepEqual(await documents(to), await documents(from));

  const again = await api.post('/v1/import', exported, { token: to.token });
  assert.deepEqual([again.body.imported, again.body.kept], [0, 8]);

  assert.equal((await api.post('/v1/import', { hello: 1 }, { token: to.token })).status, 400);
  const minted = await api.post(
    '/v1/tokens',
    { name: 'Synthetic agent', scopes: ['read', 'write'], password: to.password },
    { token: to.token, headers: key() }
  );
  assert.equal((await api.post('/v1/import', exported, { token: minted.body.token })).status, 403);
  assert.equal((await api.get('/v1/export/sets.csv', { token: minted.body.token })).status, 200);
});

test("an export restores the server's older tables too, compares field for field, and undoes", async () => {
  const from = await signUp(api);
  const auth = { token: from.token };
  await api.post(
    '/api/food',
    { name: 'Legacy oats', calories: 300, client_id: randomUUID() },
    auth
  );
  await api.post(
    '/api/measurements',
    { client_id: randomUUID(), type: 'waist', value: 81.5, unit: 'cm' },
    { ...auth, headers: key() }
  );
  await api.post('/api/weight', { weight: 80.4 }, auth);
  await api.post('/api/water', { ml: 750 }, { ...auth, headers: key() });
  await api.put(
    '/api/diary/day',
    { status: 'complete', note: 'Synthetic day', base_revision: 0 },
    { ...auth, headers: key() }
  );
  await api.post('/api/goals', { dailyCalories: 2200, proteinG: 150 }, auth);
  await api.post(
    '/api/activities',
    { client_id: randomUUID(), activity: 'Synthetic ride', duration_min: 45, calories: 400 },
    auth
  );
  await api.post('/api/sleep', { client_id: randomUUID(), hours: 7, quality: 'good' }, auth);
  const exported = (await api.get('/api/export', auth)).body;
  const tables = ['food', 'measurements', 'weights', 'water', 'diary_days', 'activities', 'sleep'];
  for (const table of tables) assert.ok(exported[table]?.length, `${table} has a row to restore`);

  const to = await signUp(api);
  const first = await api.post('/v1/import', exported, { token: to.token });
  assert.equal(first.status, 200, JSON.stringify(first.body));
  for (const table of tables)
    assert.equal(first.body.tables[table]?.restored, exported[table].length, table);
  assert.equal(first.body.tables.goals?.restored, 1);
  assert.deepEqual(first.body.ignored_tables, []);

  // Field for field the same, apart from what belongs to the account restored
  // into (id, _id, account_id, email, identity_key) and when the row was last
  // written (updated_at).
  const differ = ['id', '_id', 'account_id', 'email', 'userId', 'identity_key', 'updated_at'];
  const comparable = (rows) =>
    (Array.isArray(rows) ? rows : rows ? [rows] : [])
      .filter((row) => !row.deleted_at)
      .map((row) =>
        Object.fromEntries(Object.entries(row).filter(([field]) => !differ.includes(field)))
      )
      .map((row) => JSON.stringify(row, Object.keys(row).sort()))
      .sort();
  const restored = (await api.get('/api/export', { token: to.token })).body;
  for (const table of [...tables, 'goals']) {
    assert.deepEqual(comparable(restored[table]), comparable(exported[table]), table);
  }

  const again = await api.post('/v1/import', exported, { token: to.token });
  assert.deepEqual(again.body.restored, [], 'restoring twice adds nothing');
  assert.equal(again.body.tables.measurements.kept, 1);

  const undone = await api.post(
    '/v1/import/undo',
    { restore_id: first.body.restore_id, rows: first.body.restored },
    { token: to.token }
  );
  assert.equal(undone.status, 200, JSON.stringify(undone.body));
  assert.equal(undone.body.removed, first.body.restored.length);
  const after = (await api.get('/api/export', { token: to.token })).body;
  for (const table of tables) assert.deepEqual(comparable(after[table]), [], `${table} undone`);
  const feed = (await api.get('/api/sync?after=0', { token: to.token })).body;
  assert.ok(
    (feed.changes ?? []).some((c) => c.kind === 'measurement' && c.deleted),
    'the phone hears that the restored measurement is gone'
  );
});

test("an import's body is read only for the signed-in app", async () => {
  // Malformed JSON shows whether the body was parsed: a parse error is 400.
  const raw = (headers) =>
    fetch(`${api.base}/v1/import`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...headers },
      body: `{"documents": [${'1,'.repeat(200_000)}`,
    });
  assert.equal((await raw({})).status, 401, 'refused before reading it');
  const user = await signUp(api);
  const minted = await api.post(
    '/v1/tokens',
    { name: 'Synthetic agent', scopes: ['read', 'write'], password: user.password },
    { token: user.token, headers: key() }
  );
  assert.equal((await raw({ Authorization: `Bearer ${minted.body.token}` })).status, 403);
  assert.equal((await raw({ Authorization: `Bearer ${user.token}` })).status, 400);

  // An export bigger than the usual 256 kB cap still imports.
  const notes = 'n'.repeat(1000);
  const documents = Array.from({ length: 400 }, (_, i) => {
    const date = new Date(Date.UTC(2025, 0, 1 + i)).toISOString().slice(0, 10);
    return {
      kind: 'nutrition_day',
      document_id: date,
      revision: 1,
      payload: { id: date, date, status: 'complete', notes, tags: [] },
    };
  });
  const big = await api.post('/v1/import', { documents }, { token: user.token });
  assert.equal(big.status, 200, JSON.stringify(big.body).slice(0, 300));
  assert.equal(big.body.imported, 400);
});

// Review round 2's probes of the restore of older tables, as tests.

const today = () => new Date().toISOString().slice(0, 10);
const legacyExport = (rows) => ({ exported_at: new Date().toISOString(), documents: [], ...rows });

test('a weigh-in on a day the account already has is kept, not a 500', async () => {
  const from = await signUp(api);
  await api.post('/api/weight', { weight: 80.4 }, { token: from.token });
  const exported = (await api.get('/api/export', { token: from.token })).body;

  const to = await signUp(api);
  await api.post('/api/weight', { weight: 81.0 }, { token: to.token });
  const into = await api.post('/v1/import', exported, { token: to.token });
  assert.equal(into.status, 200, JSON.stringify(into.body));
  assert.deepEqual(into.body.tables.weights, { restored: 0, kept: 1, skipped: 0 });
  const kept = await api.store.find('weights', { email: to.email });
  assert.deepEqual(
    kept.map((row) => row.weight_kg),
    [81],
    "the account's own weigh-in stays"
  );

  // Your own export, after changing that day's weigh-in.
  await api.put('/api/weight', { weight: 80.9, base_revision: 1 }, { token: from.token });
  const own = await api.post('/v1/import', exported, { token: from.token });
  assert.equal(own.status, 200, JSON.stringify(own.body));
  assert.equal(own.body.tables.weights.kept, 1);
});

test('restored activities and sleep get identities of the account they are restored into', async () => {
  const from = await signUp(api);
  const activity = randomUUID();
  const night = randomUUID();
  const made = await api.post(
    '/api/activities',
    { client_id: activity, activity: 'Synthetic walk', duration_min: 30 },
    { token: from.token }
  );
  assert.equal(made.status, 201, JSON.stringify(made.body));
  await api.post('/api/sleep', { client_id: night, hours: 7.5 }, { token: from.token });
  const exported = (await api.get('/api/export', { token: from.token })).body;
  assert.equal(exported.activities[0].identity_key, `${from.user._id}:${activity}`);

  const to = await signUp(api);
  const into = await api.post('/v1/import', exported, { token: to.token });
  assert.equal(into.status, 200, JSON.stringify(into.body));
  assert.equal(into.body.tables.activities.restored, 1);
  assert.equal(into.body.tables.sleep.restored, 1);
  const [walk] = await api.store.find('activities', { account_id: to.user._id });
  const [rest] = await api.store.find('sleep', { account_id: to.user._id });
  assert.equal(walk.identity_key, `${to.user._id}:${activity}`);
  assert.equal(rest.identity_key, `${to.user._id}:${night}`);
});

test('Undo removes only what the restore added, and keeps rows changed since', async () => {
  const from = await signUp(api);
  await api.post('/api/workouts', { name: 'Synthetic push', exercises: [] }, { token: from.token });
  await api.post('/api/goals', { dailyCalories: 2200 }, { token: from.token });
  await api.post(
    '/api/measurements',
    { client_id: randomUUID(), type: 'waist', value: 81.5, unit: 'cm' },
    { token: from.token, headers: key() }
  );
  const exported = (await api.get('/api/export', { token: from.token })).body;
  delete exported.measurements[0].revision;

  const to = await signUp(api);
  const auth = { token: to.token };
  const own = await api.post('/api/workouts', { name: 'Mine', exercises: [] }, auth);
  const first = await api.post('/v1/import', exported, auth);
  assert.equal(first.status, 200, JSON.stringify(first.body));
  assert.ok(first.body.restore_id, 'the restore has an ID');
  const workout = first.body.restored.find((row) => row.table === 'workouts');
  const measurement = first.body.restored.find((row) => row.table === 'measurements');
  assert.equal(measurement.revision, 1, 'a row restored without a revision gets 1');
  await api.put(`/api/workouts/${workout.id}`, { name: 'Renamed', exercises: [] }, auth);
  const [stored] = await api.store.find('measurements', { account_id: to.user._id });
  await api.store.update('measurements', { id: stored.id }, { note: 'Edited behind the revision' });

  const outsider = await api.post(
    '/v1/import/undo',
    { restore_id: first.body.restore_id, rows: [{ table: 'workouts', id: own.body.id }] },
    auth
  );
  assert.equal(outsider.status, 400, 'a row the restore never added is refused');
  assert.equal((await api.get(`/api/workouts`, auth)).body.length, 2);
  const other = await signUp(api);
  const stolen = await api.post(
    '/v1/import/undo',
    { restore_id: first.body.restore_id },
    { token: other.token }
  );
  assert.equal(stolen.status, 404, "another account's restore isn't found");

  const undone = await api.post('/v1/import/undo', { restore_id: first.body.restore_id }, auth);
  assert.equal(undone.status, 200, JSON.stringify(undone.body));
  assert.equal(undone.body.kept, 2, 'the renamed workout and the edited measurement stay');
  assert.equal(undone.body.removed, first.body.restored.length - 2);
  const names = (await api.get('/api/workouts', auth)).body.map((w) => w.name).sort();
  assert.deepEqual(names, ['Mine', 'Renamed']);
  assert.deepEqual((await api.get('/api/goals', auth)).body, {});
  const twice = await api.post('/v1/import/undo', { restore_id: first.body.restore_id }, auth);
  assert.equal(twice.status, 409, 'a restore is undone once');
});

test('restored rows pass the checks an API write gets, and the rest are listed as skipped', async () => {
  const to = await signUp(api);
  const body = legacyExport({
    measurements: [
      { client_id: randomUUID(), type: 'nonsense', unit: 'parsecs', value: 'abc' },
      { client_id: 'not-a-uuid', type: 'waist', value: 80, unit: 'cm', entry_date: today() },
      { client_id: randomUUID(), type: 'waist', value: 80, unit: 'cm', entry_date: today() },
    ],
    weights: [{ entry_date: 'not-a-date', weight_kg: -5000 }],
  });
  const res = await api.post('/v1/import', body, { token: to.token });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.tables.measurements.restored, 1);
  assert.equal(
    res.body.tables.measurements.skipped,
    2,
    'a client ID must be a UUID, as for a new entry'
  );
  assert.equal(res.body.tables.weights.skipped, 1);
  const tables = res.body.skipped.map((row) => row.table).sort();
  assert.deepEqual(tables, ['measurements', 'measurements', 'weights']);
  assert.equal(res.body.skipped_count, 3);
  assert.ok(
    res.body.skipped.every((row) => row.reason),
    'each says why'
  );
  const feed = (await api.get('/api/sync?after=0', { token: to.token })).body.changes ?? [];
  assert.equal(feed.filter((c) => c.kind === 'weight').length, 0);
  assert.deepEqual(
    feed.filter((c) => c.kind === 'measurement').map((c) => c.payload.type),
    ['waist']
  );
});

test('older food rows without a client ID match on what they are, and restoring twice adds nothing', async () => {
  const to = await signUp(api);
  const row = (name, logged) => ({
    name,
    calories: 300,
    entry_date: today(),
    logged_at: logged,
    created_at: logged,
  });
  const body = legacyExport({
    food: [row('Oats', '2026-10-01T08:00:00.000Z'), row('Rice', '2026-10-01T12:00:00.000Z')],
    target_versions: [
      {
        effective_date: today(),
        targets: { calories: 2000 },
        reason: 'onboarding',
        created_at: '2026-10-01T08:00:00.000Z',
      },
      {
        effective_date: today(),
        targets: { calories: 2100 },
        reason: 'checkin',
        created_at: '2026-10-01T09:00:00.000Z',
      },
    ],
  });
  const first = await api.post('/v1/import', body, { token: to.token });
  assert.equal(first.status, 200, JSON.stringify(first.body));
  assert.equal(first.body.tables.food.restored, 2, 'two different foods, not one');
  assert.equal(first.body.tables.target_versions.restored, 2, 'both versions of the day');
  const foods = await api.store.find('food', { account_id: to.user._id });
  assert.ok(
    foods.every((food) => food.client_id),
    'each gets an ID the phone can sync'
  );
  const again = await api.post('/v1/import', body, { token: to.token });
  assert.deepEqual(again.body.restored, []);
});

test('import and Undo are limited per account, each on its own', async () => {
  const user = await signUp(api);
  const other = await signUp(api);
  const empty = legacyExport({});
  for (let i = 0; i < 10; i++)
    assert.equal((await api.post('/v1/import', empty, { token: user.token })).status, 200);
  assert.equal((await api.post('/v1/import', empty, { token: user.token })).status, 429);
  assert.equal(
    (await api.post('/v1/import', empty, { token: other.token })).status,
    200,
    'another account on the same address is not limited'
  );
  const undo = await api.post(
    '/v1/import/undo',
    { restore_id: randomUUID() },
    { token: user.token }
  );
  assert.equal(undo.status, 404, 'Undo has its own limit');
});

test('importing again after Undo brings the rows back, but not a row the person deleted', async () => {
  const to = await signUp(api);
  const auth = { token: to.token };
  const measurement = randomUUID();
  const day = today();
  const body = legacyExport({
    weights: [{ entry_date: day, weight_kg: 80.4 }],
    measurements: [
      { client_id: measurement, type: 'waist', value: 80, unit: 'cm', entry_date: day },
    ],
  });
  const first = await api.post('/v1/import', body, auth);
  await api.post('/v1/import/undo', { restore_id: first.body.restore_id }, auth);
  const again = await api.post('/v1/import', body, auth);
  assert.equal(again.status, 200, JSON.stringify(again.body));
  assert.equal(again.body.restored.length, 2, 'both come back');
  const [weighIn] = await api.store.find('weights', { email: to.email });
  assert.equal(weighIn.revision, 3, 'newer than its deletion, so the phone takes it');
  const feed = (await api.get('/api/sync?after=0', auth)).body.changes;
  assert.deepEqual(
    feed.filter((c) => c.kind === 'weight').map((c) => [c.revision, c.deleted]),
    [
      [1, false],
      [2, true],
      [3, false],
    ]
  );

  const [row] = await api.store.find('measurements', { account_id: to.user._id });
  const deleted = await api.del(`/api/measurements/${row.id}`, {
    ...auth,
    headers: { 'If-Match': String(row.revision), ...key() },
  });
  assert.equal(deleted.status, 200, JSON.stringify(deleted.body));
  const third = await api.post('/v1/import', body, auth);
  assert.equal(third.body.tables.measurements.kept, 1, 'a deletion of their own stays');
});
