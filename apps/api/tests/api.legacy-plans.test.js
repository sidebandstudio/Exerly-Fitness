// Accounts with legacy targets get them back as manual nutrition plans, once.
// The golden file is decoded by ExerlyCore's LegacyPlanGoldenTests, so the
// server can't write a plan the phone rejects. Regenerate with
// EXERLY_WRITE_LEGACY_PLAN_GOLDEN=1 after a deliberate change.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { startServer, signUp } = require('./helpers/server');
const { planFrom, uuid5 } = require('../lib/nutrition/legacyPlans');

let api;
test.before(async () => {
  api = await startServer();
});
test.after(async () => api.close());

const answers = {
  name: 'Synthetic',
  age: 30,
  sex: 'male',
  gender: 'male',
  height: 180,
  weight: 85,
  goal: 'weight_loss',
  nutritionGoal: 'lose',
  activityLevel: 'moderate',
  targetWeight: 78,
  timezone: 'America/New_York',
  unitSystem: 'metric',
  experienceLevel: 'beginner',
  workoutDaysPerWeek: 3,
  equipmentAccess: 'home',
  dietType: 'balanced',
};

const adopt = (user) => api.post('/v1/nutrition/plans/from-legacy', {}, { token: user.token });

test('saved targets become one manual plan with the same numbers, once', async () => {
  const user = await signUp(api);
  assert.equal(
    (await api.post('/api/user/onboarding', answers, { token: user.token })).status,
    200
  );
  const program = (await api.get('/api/program', { token: user.token })).body;

  const first = await adopt(user);
  assert.equal(first.status, 201, JSON.stringify(first.body));
  assert.equal(first.body.created, 1);
  const [plan] = first.body.plans;
  assert.equal(plan.mode, 'manual');
  assert.equal(plan.targets.length, 7);
  assert.deepEqual(plan.targets[0], {
    energy: program.targets.calories,
    protein: program.targets.protein_g,
    fat: program.targets.fat_g,
    carbohydrate: program.targets.carbs_g,
  });
  assert.equal(plan.goal.direction, 'lose');
  assert.ok(plan.goal.weeklyRate > 0 && plan.goal.weeklyRate <= 0.01);
  assert.deepEqual(plan.goal.goalWeight, { value: 78, unit: 'kg' });

  // It reaches the phone through the feed, with an audit event saying who wrote it.
  const changes = (await api.get('/v1/changes?after=0', { token: user.token })).body.changes;
  assert.ok(changes.some((c) => c.kind === 'nutrition_plan' && c.id === plan.id));
  const audit = changes.find((c) => c.kind === 'audit_event');
  assert.equal(audit.payload.actor.name, 'Exerly');

  const again = await adopt(user);
  assert.equal(again.status, 200);
  assert.deepEqual([again.body.created, again.body.reason], [0, 'has_plan']);
});

test('an account with a plan of its own, or without targets, is left alone', async () => {
  const fresh = await signUp(api);
  assert.deepEqual((await adopt(fresh)).body, { created: 0, reason: 'no_targets', plans: [] });

  const planned = await signUp(api);
  await api.post('/api/user/onboarding', answers, { token: planned.token });
  const id = randomUUID().toUpperCase();
  const day = { energy: 2000, protein: 150, fat: 60, carbohydrate: 200 };
  const own = await api.put(
    `/v1/documents/nutrition_plan/${id}`,
    {
      base_revision: 0,
      payload: {
        id,
        startDate: '2026-10-01',
        createdAt: '2026-10-01T08:00:00.000Z',
        goal: { direction: 'maintain', weeklyRate: 0 },
        mode: 'manual',
        diet: 'balanced',
        protein: 'moderate',
        weekdayWeights: [1, 1, 1, 1, 1, 1, 1],
        checkInDay: 2,
        allowBelowFloor: false,
        targets: Array.from({ length: 7 }, () => day),
      },
    },
    { token: planned.token, headers: { 'Idempotency-Key': randomUUID() } }
  );
  assert.equal(own.status, 201, JSON.stringify(own.body));
  // Even deleted, a plan of the person's own means the legacy targets are history.
  await api.del(`/v1/documents/nutrition_plan/${id}?base_revision=1`, {
    token: planned.token,
    headers: { 'Idempotency-Key': randomUUID() },
  });
  assert.deepEqual((await adopt(planned)).body.reason, 'has_plan');

  const minted = await api.post(
    '/v1/tokens',
    { name: 'Synthetic agent', scopes: ['read', 'write'], password: fresh.password },
    { token: fresh.token, headers: { 'Idempotency-Key': randomUUID() } }
  );
  assert.equal((await adopt({ token: minted.body.token })).status, 403);
});

test('Program screen changes reach the diary until the person sets a plan in the app', async () => {
  const user = await signUp(api);
  await api.post('/api/user/onboarding', answers, { token: user.token });
  const [bridged] = (await adopt(user)).body.plans;
  const plans = async () =>
    (await api.get('/v1/changes?after=0', { token: user.token })).body.changes
      .filter((c) => c.kind === 'nutrition_plan' && !c.deleted)
      .map((c) => c.payload);

  const changed = await api.post(
    '/api/goals',
    { daily_calories: 2500, protein_g: 180, carbs_g: 250, fat_g: 80 },
    { token: user.token }
  );
  assert.ok(changed.status < 300, JSON.stringify(changed.body));
  const followed = (await plans()).find((p) => p.id !== bridged.id);
  assert.ok(followed, 'a new manual version follows the Program screen');
  assert.equal(followed.mode, 'manual');
  assert.deepEqual(followed.targets[0], { energy: 2500, protein: 180, fat: 80, carbohydrate: 250 });
  assert.ok(followed.startDate >= bridged.startDate);

  // A plan the person sets in the app wins, and the Program screen no longer writes plans.
  const id = randomUUID().toUpperCase();
  const native = {
    ...followed,
    id,
    createdAt: new Date(Date.now() + 60_000).toISOString(),
    targets: followed.targets.map((t) => ({ ...t, energy: 2300 })),
  };
  const saved = await api.put(
    `/v1/documents/nutrition_plan/${id}`,
    { base_revision: 0, payload: native },
    { token: user.token, headers: { 'Idempotency-Key': randomUUID() } }
  );
  assert.equal(saved.status, 201, JSON.stringify(saved.body));
  const before = (await plans()).length;
  await api.post(
    '/api/goals',
    { daily_calories: 2700, protein_g: 180, carbs_g: 290, fat_g: 80 },
    { token: user.token }
  );
  assert.equal((await plans()).length, before);
});

test('the plan written matches the golden file ExerlyCore decodes', () => {
  const file = path.join(__dirname, '../../../docs/api/golden/legacy-plan-v1.json');
  const user = {
    id: '00000000-0000-4000-8000-000000000001',
    profile: { weight_kg: 85 },
  };
  const program = {
    goal_type: 'lose',
    rate_kg_per_week: -0.5,
    target_weight_kg: 78,
    diet_type: 'low_carb',
    protein_strategy: 'high',
  };
  const plan = planFrom(user, program, {
    key: 'version-1',
    startDate: '2026-09-01',
    targets: { calories: 2150, protein_g: 170, fat_g: 80, carbs_g: 190, fiber_g: 30 },
    createdAt: '2026-09-01T12:00:00.000Z',
  });
  assert.equal(plan.id, uuid5(`${user.id}/legacy-targets/version-1`));
  assert.equal(plan.goal.weeklyRate, 0.0059, '0.5 kg of 85 kg a week');
  if (process.env.EXERLY_WRITE_LEGACY_PLAN_GOLDEN === '1') {
    fs.writeFileSync(file, `${JSON.stringify(plan, null, 2)}\n`);
  }
  assert.deepEqual(plan, JSON.parse(fs.readFileSync(file, 'utf8')));
});
