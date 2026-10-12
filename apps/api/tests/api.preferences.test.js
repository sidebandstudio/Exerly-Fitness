const test = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const { startServer, signUp } = require('./helpers/server');

let api;
test.before(async () => {
  api = await startServer();
});
test.after(async () => api.close());
const options = (user, key = randomUUID()) => ({
  token: user.token,
  headers: { 'Idempotency-Key': key },
});
async function complete() {
  const user = await signUp(api);
  const result = await api.post(
    '/api/onboarding/complete',
    {
      name: 'Taylor',
      age: 34,
      gender: 'other',
      sex: null,
      targetMode: 'manual',
      manualTargets: { calories: 2200, protein_g: 130, carbs_g: 260, fat_g: 70, fiber_g: 28 },
      height: 167.5,
      weight: 72.25,
      goal: 'gain_muscle',
      nutritionGoal: 'maintain',
      activityLevel: 'light',
      allergies: ['sesame'],
      equipment: ['rings'],
      bedtime: '22:45',
      wakeTime: '06:15',
      timezone: 'America/New_York',
      unitSystem: 'metric',
    },
    options(user)
  );
  assert.equal(result.status, 200);
  return user;
}
const get = async (user) => (await api.get('/api/preferences', options(user))).body;
const save = (user, revision, changes, key) =>
  api.patch('/api/preferences', { base_revision: revision, changes }, options(user, key));

test('accounts default to U.S. units, and an explicit metric choice is kept', async () => {
  const plain = await signUp(api);
  assert.equal(plain.user.unitSystem, 'imperial');
  const metric = await signUp(api, { unitSystem: 'metric' });
  assert.equal(metric.user.unitSystem, 'metric');
});

test('preferences preserve setup values and update non-nutrition goals atomically without rewriting accepted targets or weight history', async () => {
  const user = await complete();
  const initial = await get(user);
  assert.equal(initial.revision, 1);
  assert.deepEqual(initial.values.allergies, ['sesame']);
  const before = (await api.get('/api/export', options(user))).body;
  const versions = await api.store.find('target_versions', { email: user.email });
  const result = await save(user, initial.revision, {
    name: 'Edited Taylor',
    gender: 'nonbinary',
    height: 167.75,
    unitSystem: 'imperial',
    timezone: 'Europe/London',
    dietaryStyle: 'mediterranean',
    allergies: ['sesame', 'peanuts'],
    mealsPerDay: 4,
    experienceLevel: 'advanced',
    equipment: ['rings', 'kettlebell'],
    equipmentAccess: 'home',
    activityTypes: ['rowing'],
    workoutDays: ['monday', 'wednesday', 'friday'],
    workoutDaysPerWeek: 3,
    sleepGoalHours: 7.25,
    bedtime: '23:15',
    wakeTime: '06:45',
    reminders: { meals: true, workouts: false, sleep: true, weighIn: true },
    reminderTimes: { meals: ['18:00', '08:30', '12:00'], sleep: '22:45', weighIn: '07:15' },
  });
  assert.equal(result.status, 200);
  assert.equal(result.body.revision, 2);
  assert.equal(result.body.user.height, 167.75);
  assert.equal(result.body.user.name, 'Edited Taylor');
  assert.equal(result.body.user.preferencesRevision, 2);
  assert.deepEqual(result.body.values.reminderTimes.meals, ['08:30', '12:00', '18:00']);
  assert.equal(result.body.values.reminders.weighIn, true);
  assert.equal(result.body.values.reminderTimes.weighIn, '07:15');
  const after = (await api.get('/api/export', options(user))).body;
  assert.deepEqual(after.weights, before.weights);
  assert.deepEqual(after.program, before.program);
  assert.deepEqual(await api.store.find('target_versions', { email: user.email }), versions);
  for (const key of ['daily_calories', 'protein_g', 'carbs_g', 'fat_g', 'fiber_g'])
    assert.equal(after.goals[key], before.goals[key]);
  assert.equal(after.goals.sleep_hours, 7.25);
  assert.equal(after.goals.weekly_workouts, 3);
  assert.equal(after.account.profile.height_cm, 167.75);
});

test('lost response replay preserves one revision and does not undo a later edit', async () => {
  const user = await complete();
  const first = await get(user);
  const key = randomUUID();
  const accepted = await save(user, first.revision, { allergies: ['sesame', 'nuts'] }, key);
  assert.equal(accepted.status, 200);
  const newer = await save(user, accepted.body.revision, { dietaryStyle: 'vegan' });
  assert.equal(newer.status, 200);
  const replay = await save(user, first.revision, { allergies: ['sesame', 'nuts'] }, key);
  assert.deepEqual(replay.body, accepted.body);
  assert.equal(replay.headers.get('idempotency-replayed'), 'true');
  assert.equal((await get(user)).revision, newer.body.revision);
  assert.equal((await get(user)).values.dietaryStyle, 'vegan');
  assert.equal((await save(user, first.revision, { allergies: [] }, key)).status, 409);
});

test('competing revisions require review and patches preserve unrelated and unknown saved preferences', async () => {
  const user = await complete();
  const stored = await api.store.findOne('users', { email: user.email });
  await api.store.update(
    'users',
    { id: stored.id },
    { profile: { ...stored.profile, futurePreference: { kept: true } } }
  );
  const first = await get(user);
  const responses = await Promise.all([
    save(user, first.revision, { bedtime: '22:15' }),
    save(user, first.revision, { dietaryStyle: 'vegan' }),
  ]);
  assert.deepEqual(responses.map((response) => response.status).sort(), [200, 409]);
  const rejected = responses.find((response) => response.status === 409);
  assert.equal(rejected.body.details.current.account_id, first.account_id);
  const reviewed = await get(user);
  assert.equal((await save(user, reviewed.revision, { allergies: [] })).status, 200);
  const latest = await api.store.findOne('users', { email: user.email });
  assert.deepEqual(latest.profile.futurePreference, { kept: true });
  assert.deepEqual(latest.profile.equipment, ['rings']);
  assert.equal(latest.profile.wakeTime, '06:15');
});

test('invalid preference fields and values cannot partially change data or initialize a program', async () => {
  const user = await signUp(api);
  const before = await get(user);
  for (const changes of [
    { age: 17 },
    { height: '167junk' },
    { timezone: 'Invalid/Timezone' },
    { unitSystem: 'stone' },
    { workoutDays: ['monday', 'funday'] },
    { sleepGoalHours: 0 },
    { mealsPerDay: 2.5 },
    { allergies: 'sesame' },
    { reminders: { meals: 'maybe' } },
    { reminderTimes: { meals: ['25:00'] } },
    { reminders: { naps: true } },
    { reminderTimes: { weighIn: '7am' } },
    { calories: 2000 },
    { weight: 90 },
    { __proto__: null, isAdmin: true },
  ]) {
    assert.equal(
      (await save(user, before.revision, { name: 'Must roll back', ...changes })).status,
      400,
      JSON.stringify(changes)
    );
    assert.deepEqual(await get(user), before);
  }
  assert.equal(
    (await api.patch('/api/preferences', { changes: { name: 'No revision' } }, options(user)))
      .status,
    400
  );
  assert.equal(
    (
      await api.patch(
        '/api/preferences',
        { base_revision: 0, changes: { name: 'No key' } },
        { token: user.token }
      )
    ).status,
    400
  );
  assert.equal(await api.store.findOne('programs', { email: user.email }), null);
});

test('legacy profile and settings writes validate values, keep aliases aligned and advance the revision', async () => {
  const user = await complete();
  const before = await get(user);
  const updated = await api.post(
    '/api/profile',
    { age: '35', height_cm: '168.25', activity_level: 'moderate', privacy_settings: 'private' },
    options(user)
  );
  assert.equal(updated.status, 200);
  assert.equal(updated.body.user.age, 35);
  assert.equal(updated.body.profile.height, 168.25);
  assert.equal((await save(user, before.revision, { name: 'Stale' })).status, 409);
  const settings = await api.put(
    '/api/settings',
    { unitSystem: 'imperial', timezone: 'Europe/Paris' },
    options(user)
  );
  assert.equal(settings.status, 200);
  assert.equal(settings.body.user.preferencesRevision, before.revision + 2);
  assert.equal(
    (await api.put('/api/profile', { timezone: 'not-a-zone' }, options(user))).status,
    400
  );
  assert.equal(
    (await api.post('/api/profile', { name: 'Should roll back', age: 5 }, options(user))).status,
    400
  );
  assert.equal((await get(user)).values.name, before.values.name);
});

test('preference transactions roll back both profile and goals when the second write fails', async () => {
  const user = await complete();
  const before = await get(user);
  const original = api.store.upsert;
  api.store.upsert = async (collection, ...args) => {
    if (collection === 'goals') throw new Error('Injected goal storage failure');
    return original(collection, ...args);
  };
  try {
    assert.equal(
      (await save(user, before.revision, { name: 'Rollback', sleepGoalHours: 9 })).status,
      500
    );
  } finally {
    api.store.upsert = original;
  }
  assert.deepEqual(await get(user), before);
});

test('preference reads and operations belong only to the authenticated account', async () => {
  const first = await complete();
  const second = await complete();
  const key = randomUUID();
  assert.equal((await save(first, 1, { name: 'First' }, key)).status, 200);
  assert.equal((await save(second, 1, { name: 'Second' }, key)).status, 200);
  assert.equal((await get(first)).values.name, 'First');
  assert.equal((await get(second)).values.name, 'Second');
  assert.equal((await api.get('/api/preferences')).status, 401);
});

test('legacy goal changes participate in preference conflict detection and retain nutrition targets', async () => {
  const user = await complete();
  const initial = await get(user);
  const nutrition = (await api.get('/api/program', options(user))).body;
  const result = await api.post(
    '/api/goals',
    { weeklyWorkouts: 0, sleepHours: 7.25 },
    options(user)
  );
  assert.equal(result.status, 200);
  const current = await get(user);
  assert.equal(current.revision, initial.revision + 1);
  assert.equal(current.values.workoutDaysPerWeek, 0);
  assert.equal(current.values.sleepGoalHours, 7.25);
  assert.equal((await save(user, initial.revision, { sleepGoalHours: 8 })).status, 409);
  assert.deepEqual((await api.get('/api/program', options(user))).body, nutrition);
});

test("Today's display and the water goal are preferences, and the water goal is the account's goal", async () => {
  const user = await complete();
  const initial = await get(user);
  assert.equal(initial.values.nutritionDisplay, null);
  assert.equal(initial.user.nutritionDisplay, 'remaining');
  assert.equal(initial.user.waterGoalMl, null);
  const saved = await save(user, initial.revision, {
    nutritionDisplay: 'consumed',
    waterGoalMl: 2500,
  });
  assert.equal(saved.status, 200);
  assert.equal(saved.body.values.nutritionDisplay, 'consumed');
  assert.equal(saved.body.user.nutritionDisplay, 'consumed');
  assert.equal(saved.body.user.waterGoalMl, 2500);
  assert.equal((await api.get('/api/goals', options(user))).body.water_ml, 2500);
  for (const changes of [
    { nutritionDisplay: 'both' },
    { waterGoalMl: 100 },
    { waterGoalMl: 2500.5 },
  ])
    assert.equal((await save(user, saved.body.revision, changes)).status, 400);
  const cleared = await save(user, saved.body.revision, {
    nutritionDisplay: null,
    waterGoalMl: null,
  });
  assert.equal(cleared.status, 200);
  assert.equal(cleared.body.user.nutritionDisplay, 'remaining');
  assert.equal(cleared.body.user.waterGoalMl, null);
  assert.equal((await api.get('/api/goals', options(user))).body.water_ml, null);
});
