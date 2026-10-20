// The MCP server, driven by the official MCP client over real HTTP. The data
// is the synthetic golden history, so every number can be checked against
// what ExerlyCore computes for the same sessions.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { Client } = require('@modelcontextprotocol/sdk/client/index.js');
const {
  StreamableHTTPClientTransport,
} = require('@modelcontextprotocol/sdk/client/streamableHttp.js');
const { startServer, signUp } = require('./helpers/server');

const golden = JSON.parse(
  fs.readFileSync(path.join(__dirname, '../../../docs/api/golden/training-v1.json'), 'utf8')
);
const BENCH = 'barbell-bench-press';
let api;

test.before(async () => {
  api = await startServer();
});
test.after(async () => {
  await api.close();
});

const key = () => ({ 'Idempotency-Key': randomUUID() });

async function token(user, scopes) {
  const res = await api.post(
    '/v1/tokens',
    { name: `Synthetic agent (${scopes.join('+')})`, scopes, password: user.password },
    { token: user.token, headers: key() }
  );
  assert.equal(res.status, 201, JSON.stringify(res.body));
  return res.body;
}

async function put(user, kind, payload) {
  const res = await api.put(
    `/v1/documents/${kind}/${payload.id}`,
    { base_revision: 0, payload },
    { token: user.token, headers: key() }
  );
  assert.equal(res.status, 201, JSON.stringify(res.body));
}

/** A person with the whole golden history synced. */
async function seededUser() {
  const user = await signUp(api, { timezone: 'America/New_York' });
  for (const exercise of golden.customExercises) await put(user, 'custom_exercise', exercise);
  for (const session of golden.sessions) await put(user, 'workout_session', session);
  return user;
}

async function connect(secret) {
  const client = new Client({ name: 'exerly-tests', version: '1.0.0' });
  await client.connect(
    new StreamableHTTPClientTransport(new URL(`${api.base}/mcp`), {
      requestInit: { headers: { Authorization: `Bearer ${secret}` } },
    })
  );
  return client;
}

async function call(client, name, args = {}) {
  const result = await client.callTool({ name, arguments: args });
  const text = result.content[0].text;
  return result.isError ? { error: text } : JSON.parse(text);
}

const round = (value, places = 2) => Math.round(value * 10 ** places) / 10 ** places;

test('a read token gets the read tools, with numbers that match ExerlyCore', async () => {
  const user = await seededUser();
  const client = await connect((await token(user, ['read'])).token);
  const names = (await client.listTools()).tools.map((t) => t.name).sort();
  assert.deepEqual(names, [
    'exercise_history',
    'generate_program',
    'get_document',
    'get_nutrition_day',
    'get_nutrition_summary',
    'get_profile',
    'get_workout',
    'list_programs',
    'list_proposals',
    'list_workouts',
    'next_workout',
    'search_exercises',
    'verify_metric',
    'weekly_volume',
  ]);

  const profile = await call(client, 'get_profile');
  assert.equal(profile.time_zone, 'America/New_York');
  assert.equal(profile.finished_workouts, golden.sessions.filter((s) => s.endedAt).length);

  const bench = await call(client, 'exercise_history', { exercise: 'Bench Press' });
  const expected = golden.expected.statistics[BENCH];
  assert.equal(bench.exercise.id, BENCH);
  assert.equal(bench.statistics.e1rm_kg, round(expected.estimatedOneRepMax));
  assert.equal(bench.statistics.total_volume_kg_reps, round(expected.totalVolume, 1));
  assert.equal(bench.statistics.total_sets, expected.totalSets);
  assert.deepEqual(
    bench.e1rm_trend.map((p) => p.e1rm_kg),
    golden.expected.trends[BENCH].map((p) => round(p.oneRepMax))
  );

  const listed = await call(client, 'list_workouts', { limit: 5 });
  assert.equal(listed.total, golden.sessions.length);
  assert.equal(listed.workouts.length, 5);
  assert.ok(listed.workouts[0].in_progress, 'the newest session is still in progress');
  const finished = listed.workouts.find((w) => !w.in_progress);
  const workout = await call(client, 'get_workout', { id: finished.id });
  const summary = golden.expected.summaries.find((s) => s.session === finished.id);
  assert.equal(workout.date, summary.localDate);
  assert.equal(workout.working_sets, summary.workingSets);
  assert.equal(workout.volume.total_kg_reps, round(summary.tonnage.total, 1));
  const records = golden.expected.records[finished.id] ?? [];
  assert.equal(workout.records.length, records.length);

  const weekly = await call(client, 'weekly_volume', { weeks: 2, through: '2026-10-04' });
  const week = golden.expected.weeklyVolume.monday['2026-09-28'];
  assert.equal(weekly.weeks[0].week_starting, '2026-09-28');
  for (const row of weekly.weeks[0].muscles) assert.equal(row.sets, round(week[row.muscle].sets));

  const search = await call(client, 'search_exercises', { query: 'zercher' });
  assert.equal(search.exercises[0].id, 'custom-golden-zercher-squat');
  assert.equal(search.exercises[0].custom, true);

  const metric = golden.expected.metrics[2];
  assert.equal((await call(client, 'verify_metric', metric.reference)).status, metric.status);
  await client.close();
});

test('MCP refuses sessions, missing tokens and other methods', async () => {
  const user = await signUp(api);
  const rpc = { jsonrpc: '2.0', id: 1, method: 'tools/list' };
  const accept = { Accept: 'application/json, text/event-stream' };
  assert.equal((await api.post('/mcp', rpc, { headers: accept })).status, 401);
  assert.equal((await api.post('/mcp', rpc, { token: user.token, headers: accept })).status, 403);
  assert.equal((await api.get('/mcp')).status, 405);
});

test('a token reads only its own account', async () => {
  const owner = await seededUser();
  const stranger = await signUp(api);
  const client = await connect((await token(stranger, ['read'])).token);
  assert.equal((await call(client, 'list_workouts')).total, 0);
  const id = golden.sessions[0].id;
  assert.match((await call(client, 'get_workout', { id })).error, /No workout/);
  assert.ok(owner);
  await client.close();
});

test('propose files a pending correction with the stored document as before', async () => {
  const user = await seededUser();
  const agent = await token(user, ['propose']);
  const client = await connect(agent.token);
  assert.ok((await client.listTools()).tools.some((t) => t.name === 'propose'));

  const target = golden.sessions.find(
    (s) => s.endedAt && s.exercises.some((p) => p.exerciseID === BENCH)
  );
  const stored = await call(client, 'get_document', { kind: 'workout_session', id: target.id });
  const after = structuredClone(stored.payload);
  const set = after.exercises.find((p) => p.exerciseID === BENCH).sets.at(-1);
  set.efforts[0].load = { unit: 'kg', value: 100 };
  set.completedAt ??= after.startedAt;
  set.efforts[0].reps ??= 5;

  const benchMax = golden.expected.metrics[0].reference;
  const filed = await call(client, 'propose', {
    title: 'Was that set 100 kg?',
    summary: 'The load is far from your usual working weight.',
    confidence: 'medium',
    falsifier: 'You confirm the load you logged.',
    evidence: [
      { claim: 'Your September best', level: 'personalData', metric: benchMax, caveats: ['n=1'] },
      {
        claim: 'Invented number',
        level: 'personalData',
        metric: { ...benchMax, claimed: benchMax.claimed + 25 },
      },
    ],
    changes: [{ kind: 'workout_session', id: target.id, after }],
  });
  assert.equal(filed.status, 'pending', JSON.stringify(filed));
  assert.deepEqual(
    filed.evidence_checks.map((c) => c.status),
    ['verified', 'mismatch']
  );

  const proposal = (
    await api.get(`/v1/documents/proposal/${filed.proposal_id}`, { token: user.token })
  ).body.payload;
  assert.equal(proposal.status, 'pending');
  assert.deepEqual(proposal.author, { kind: 'mcp', name: agent.name, tokenID: agent.id });
  assert.deepEqual(proposal.changes[0].before, stored.payload);
  assert.deepEqual(proposal.changes[0].after, after);
  assert.equal(proposal.evidence[0].metric.claimed, benchMax.claimed);
  assert.ok(!('verification' in proposal.evidence[0]), 'ExerlyCore recomputes; nothing stored');
  assert.match(proposal.createdAt, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);

  const changes = (await api.get('/v1/changes?after=0&limit=1000', { token: user.token })).body
    .changes;
  const audit = changes.filter((c) => c.kind === 'audit_event').map((c) => c.payload);
  assert.ok(
    audit.some(
      (e) =>
        e.action === 'proposalFiled' && e.proposalID === filed.proposal_id && e.actor.kind === 'mcp'
    )
  );
  // The session itself is untouched until the person accepts.
  const session = await api.get(`/v1/documents/workout_session/${target.id}`, {
    token: user.token,
  });
  assert.deepEqual(session.body.payload, stored.payload);

  const listed = await call(client, 'list_proposals', { status: 'pending' });
  assert.equal(listed.proposals[0].id, filed.proposal_id);
  await client.close();
});

test('propose refuses documents the phone could not apply', async () => {
  const user = await seededUser();
  const client = await connect((await token(user, ['propose'])).token);
  const target = golden.sessions.find(
    (s) => s.endedAt && s.exercises.some((p) => p.exerciseID === BENCH)
  );
  const base = { title: 'Fix', confidence: 'low', falsifier: 'You disagree.' };
  const broken = structuredClone(target);
  const set = broken.exercises.find((p) => p.exerciseID === BENCH).sets.find((s) => s.completedAt);
  delete set.efforts[0].load;
  const missingLoad = await call(client, 'propose', {
    ...base,
    changes: [{ kind: 'workout_session', id: target.id, after: broken }],
  });
  assert.match(missingLoad.error, /completed without the values Barbell Bench Press records/);

  const unknown = structuredClone(target);
  unknown.exercises[0].exerciseID = 'not-an-exercise';
  assert.match(
    (
      await call(client, 'propose', {
        ...base,
        changes: [{ kind: 'workout_session', id: target.id, after: unknown }],
      })
    ).error,
    /not a known exercise/
  );

  assert.match(
    (
      await call(client, 'propose', {
        ...base,
        changes: [{ kind: 'workout_session', id: target.id, after: target }],
      })
    ).error,
    /doesn't change/
  );
  assert.match(
    (
      await call(client, 'propose', {
        ...base,
        changes: [{ kind: 'workout_session', id: randomUUID().toUpperCase(), after: null }],
      })
    ).error,
    /doesn't exist/
  );
  const noFalsifier = await client.callTool({
    name: 'propose',
    arguments: { title: 'x', confidence: 'low', falsifier: '', changes: [] },
  });
  assert.equal(noFalsifier.isError, true);
  await client.close();
});

test('a read token cannot propose', async () => {
  const user = await seededUser();
  const client = await connect((await token(user, ['read'])).token);
  const result = await client.callTool({
    name: 'propose',
    arguments: { title: 'x', confidence: 'low', falsifier: 'y', changes: [] },
  });
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /not found/i);
  await client.close();
});

test('a workout stored with a lowercase UUID before migration 0005 works through MCP', async () => {
  const user = await signUp(api);
  const workout = structuredClone(
    golden.sessions.find(
      (s) => s.endedAt && s.exercises.every((p) => !p.exerciseID.startsWith('custom-'))
    )
  );
  const lower = randomUUID();
  workout.id = lower;
  const now = new Date();
  await api.store.insert('documents', {
    account_id: user.user._id,
    kind: 'workout_session',
    document_id: lower,
    revision: 1,
    payload: workout,
    deleted_at: null,
    created_at: now,
    updated_at: now,
  });
  for (const name of ['0005_canonical_document_ids', '0006_canonical_payload_ids']) {
    await api.store.query(
      fs.readFileSync(path.join(__dirname, '../db/migrations', `${name}.up.sql`), 'utf8')
    );
  }

  const client = await connect((await token(user, ['propose'])).token);
  for (const id of [lower, lower.toUpperCase()]) {
    const read = await call(client, 'get_document', { kind: 'workout_session', id });
    assert.equal(read.payload?.id, lower.toUpperCase(), JSON.stringify(read));
  }
  const filed = await call(client, 'propose', {
    title: 'Add a note',
    confidence: 'low',
    falsifier: 'You disagree.',
    evidence: [
      {
        claim: 'From this workout',
        level: 'personalData',
        dataRefs: [{ kind: 'workout_session', id: lower }],
      },
    ],
    changes: [{ kind: 'workout_session', id: lower, after: { ...workout, notes: 'Noted' } }],
  });
  assert.equal(filed.status, 'pending', JSON.stringify(filed));
  const proposal = (
    await api.get(`/v1/documents/proposal/${filed.proposal_id}`, { token: user.token })
  ).body.payload;
  const upper = lower.toUpperCase();
  assert.deepEqual(
    [
      proposal.changes[0].id,
      proposal.changes[0].before.id,
      proposal.changes[0].after.id,
      proposal.evidence[0].dataRefs[0].id,
    ],
    [upper, upper, upper, upper]
  );
  await client.close();
});

function programPayload(overrides = {}) {
  const slot = (exerciseID, minReps, maxReps) => ({
    id: randomUUID().toUpperCase(),
    exerciseID,
    notes: '',
    target: { sets: 3, minReps, maxReps, rir: 2, kind: 'standard', rest: 150 },
    cycleTargets: {},
    expandRepRange: false,
    weightMatch: true,
  });
  return {
    id: randomUUID().toUpperCase(),
    name: 'Synthetic full body',
    color: '#7C3AED',
    days: [
      {
        id: randomUUID().toUpperCase(),
        name: 'A',
        slots: [slot(BENCH, 6, 8), slot('back-squat', 3, 5)],
      },
      { id: randomUUID().toUpperCase(), name: 'Rest', slots: [] },
      { id: randomUUID().toUpperCase(), name: 'B', slots: [slot('pull-up', 6, 10)] },
    ],
    cycles: 6,
    deload: 'last',
    createdAt: '2026-11-01T12:00:00.000Z',
    activatedAt: '2026-11-01T12:00:00.000Z',
    ...overrides,
  };
}

test('programs: the active one, its next workout and recommendations, and proposing a new one', async () => {
  const user = await seededUser();
  const program = programPayload();
  await put(user, 'program', program);
  const reader = await connect((await token(user, ['read'])).token);

  const listed = await call(reader, 'list_programs');
  assert.equal(listed.programs.length, 1);
  assert.equal(listed.programs[0].active, true);
  assert.deepEqual(listed.programs[0].progress, { done: 0, total: 12 });
  assert.equal(listed.programs[0].days[1].rest, true);

  const next = await call(reader, 'next_workout');
  const byLowercaseID = await call(reader, 'next_workout', {
    program_id: program.id.toLowerCase(),
  });
  assert.equal(byLowercaseID.program?.id, program.id, JSON.stringify(byLowercaseID));
  assert.equal(next.day, 'A');
  assert.equal(next.cycle, 1);
  assert.equal(next.deload, false);
  assert.deepEqual(
    next.exercises.map((e) => e.exercise_id),
    [BENCH, 'back-squat']
  );
  // The same recommendation the golden-checked port gives for this history.
  const { ExerciseLibrary } = require('../lib/training/library');
  const training = require('../lib/training/history');
  const progression = require('../lib/training/progression');
  const library = ExerciseLibrary.withCustom(golden.customExercises);
  const history = new training.TrainingHistory(
    golden.sessions.filter((s) => s.endedAt),
    library
  );
  const bodyweight = [...history.sessions].reverse().find((s) => s.bodyweight).bodyweight;
  const expected = progression.recommend(
    program.days[0].slots[0].target,
    library.exercise(BENCH),
    history.sets(BENCH),
    { bodyweight }
  );
  const bench = next.exercises[0].recommendation;
  assert.equal(bench.reason, expected.reason);
  assert.equal(bench.sets.length, 3);
  assert.equal(bench.sets[0].reps, expected.sets[0].effort.reps);
  assert.equal(bench.sets[0].load.value, expected.sets[0].effort.load.value);
  assert.equal(bench.e1rm_kg, Math.round(expected.oneRepMax * 100) / 100);
  await reader.close();

  const agent = await connect((await token(user, ['propose'])).token);
  const plan = programPayload({ name: 'Upper and lower', activatedAt: undefined });
  const filed = await call(agent, 'propose', {
    title: 'An upper/lower split',
    summary: 'Four days a week.',
    confidence: 'medium',
    falsifier: 'You can only train three days.',
    changes: [{ kind: 'program', id: plan.id, after: plan }],
  });
  assert.equal(filed.status, 'pending', JSON.stringify(filed));
  const broken = programPayload();
  broken.days[0].slots[0].exerciseID = 'not-an-exercise';
  broken.cycles = 60;
  const refused = await call(agent, 'propose', {
    title: 'Broken',
    confidence: 'low',
    falsifier: 'n/a',
    changes: [{ kind: 'program', id: broken.id, after: broken }],
  });
  assert.match(refused.error, /cycles must be 1 to 52/);
  assert.match(refused.error, /not-an-exercise is not a known exercise/);
  await agent.close();
});

test('nutrition tools read the log, the targets in force and the energy balance', async () => {
  const user = await signUp(api, { timezone: 'UTC' });
  const plan = randomUUID().toUpperCase();
  const day = (energy) => ({ energy, protein: 150, fat: 70, carbohydrate: 200 });
  await put(user, 'nutrition_plan', {
    id: plan,
    startDate: '2026-09-01',
    createdAt: '2026-09-01T08:00:00.000Z',
    goal: { direction: 'lose', weeklyRate: 0.005 },
    mode: 'coached',
    diet: 'balanced',
    protein: 'moderate',
    weekdayWeights: [1, 1, 1, 1, 1, 1, 1],
    checkInDay: 2,
    allowBelowFloor: false,
    basis: { expenditure: 2500, expenditureError: 400, trendWeight: 80 },
    targets: [day(2100), day(2000), day(2000), day(2000), day(2000), day(2000), day(2100)],
  });
  const oats = {
    foodID: 'off:0012345678905',
    name: 'Oats',
    source: 'openFoodFacts',
    per100g: { energy: 380, protein: 13, sodium: 5 },
  };
  for (let offset = 0; offset < 14; offset++) {
    const date = `2026-09-${String(offset + 1).padStart(2, '0')}`;
    for (const grams of [200, 300]) {
      const id = randomUUID().toUpperCase();
      await put(user, 'food_entry', {
        id,
        date,
        meal: 'Breakfast',
        loggedAt: `${date}T08:00:00.000Z`,
        food: oats,
        grams,
      });
    }
    await put(user, 'nutrition_day', {
      id: date,
      date,
      status: offset === 3 ? 'partial' : 'complete',
      notes: '',
    });
    const id = randomUUID().toUpperCase();
    await put(user, 'weight_entry', {
      id,
      at: `${date}T07:00:00.000Z`,
      date,
      weight: { unit: 'kg', value: 80 - offset * 0.05 },
    });
  }
  const client = await connect((await token(user, ['read'])).token);

  const tuesday = await call(client, 'get_nutrition_day', { date: '2026-09-01' });
  assert.equal(tuesday.status, 'complete');
  assert.equal(tuesday.totals.energy, 1900, '500 g of oats at 380 kcal per 100 g');
  assert.equal(tuesday.totals.sodium, 25);
  assert.deepEqual(tuesday.targets, day(2000), 'Tuesday, from the plan in force');
  assert.equal(tuesday.remaining.energy, 100);
  assert.deepEqual(
    tuesday.entries.map((e) => [e.food, e.grams, e.energy]),
    [
      ['Oats', 200, 760],
      ['Oats', 300, 1140],
    ]
  );
  assert.equal((await call(client, 'get_nutrition_day', { date: '2026-08-31' })).targets, null);

  const summary = await call(client, 'get_nutrition_summary', {
    from: '2026-09-01',
    through: '2026-09-14',
  });
  assert.equal(summary.days.length, 14);
  assert.equal(summary.plan.check_in_day, 'monday');
  assert.equal(summary.days[3].status, 'partial');
  const last = summary.days.at(-1);
  assert.ok(Math.abs(last.trend - 79.35) < 0.2, JSON.stringify(last));
  assert.ok(
    last.expenditure > 1900 && last.expenditure < 2600 && last.expenditure_error > 0,
    JSON.stringify(last)
  );
  const { balanceDays } = require('../lib/nutritionTools');
  const ws = await require('../lib/agentTools').workspace({ id: user.user._id, timezone: 'UTC' });
  const known = balanceDays(ws.nutrition, '2026-09-01', '2026-09-14');
  assert.equal(known[3].intake, null, 'A partial day is not known intake');
  assert.equal(known[0].intake, 1900);
  await client.close();
});

test('an agent proposes a described meal as food entries the person confirms', async () => {
  const user = await signUp(api, { timezone: 'UTC' });
  const client = await connect((await token(user, ['propose'])).token);
  const entry = (overrides = {}) => {
    const id = randomUUID();
    return {
      kind: 'food_entry',
      id,
      after: {
        id,
        date: '2026-10-06',
        meal: 'Lunch',
        loggedAt: '2026-10-06T12:30:00.000Z',
        grams: 180,
        food: {
          foodID: 'agent:chicken-rice',
          name: 'Chicken and rice',
          source: 'custom',
          per100g: { energy: 160, protein: 12.5, carbohydrate: 18, fat: 3.5 },
        },
        ...overrides,
      },
    };
  };
  const base = {
    title: 'Log lunch: chicken and rice',
    confidence: 'medium',
    falsifier: 'The plate held a different amount or food.',
    evidence: [{ claim: 'Estimated from the photo you sent', level: 'anecdote' }],
  };
  const meal = entry();
  const filed = await call(client, 'propose', { ...base, changes: [meal] });
  assert.equal(filed.status, 'pending', JSON.stringify(filed));
  const proposal = (
    await api.get(`/v1/documents/proposal/${filed.proposal_id}`, { token: user.token })
  ).body.payload;
  assert.equal(proposal.changes[0].kind, 'food_entry');
  assert.equal(proposal.changes[0].id, meal.id.toUpperCase());
  assert.equal(proposal.changes[0].after.id, meal.id.toUpperCase());
  assert.equal(proposal.changes[0].before, null);

  const bad = await client.callTool({
    name: 'propose',
    arguments: {
      ...base,
      changes: [entry({ grams: 0, food: { ...meal.after.food, per100g: { kilojoules: 670 } } })],
    },
  });
  assert.ok(bad.isError);
  assert.match(bad.content[0].text, /grams must be a positive weight/);
  assert.match(bad.content[0].text, /kilojoules is not a nutrient Exerly knows/);
  await client.close();
});

test('a write token saves a valid food and is refused a broken one', async () => {
  const user = await signUp(api);
  const writer = (await token(user, ['write'])).token;
  const food = {
    id: 'agent-granola',
    name: 'Granola',
    source: 'custom',
    per100g: { energy: 450, protein: 10 },
    servings: [{ name: '1 cup', grams: 110 }],
    favorite: false,
    createdAt: '2026-10-06T12:00:00.000Z',
  };
  const saved = await api.put(
    '/v1/documents/saved_food/agent-granola',
    { base_revision: 0, payload: food },
    { token: writer, headers: key() }
  );
  assert.equal(saved.status, 201, JSON.stringify(saved.body));
  const broken = await api.put(
    '/v1/documents/saved_food/agent-muesli',
    {
      base_revision: 0,
      payload: { ...food, id: 'agent-muesli', servings: [{ name: '', grams: -1 }] },
    },
    { token: writer, headers: key() }
  );
  assert.equal(broken.status, 400);
  assert.match(broken.body.error ?? broken.body.message, /servings\[0\] needs a name/);
  const oil = { ...food, id: 'agent-oil', volume: { density: 0.92, assumed: true } };
  const liquid = await api.put(
    '/v1/documents/saved_food/agent-oil',
    { base_revision: 0, payload: oil },
    { token: writer, headers: key() }
  );
  assert.equal(liquid.status, 201, JSON.stringify(liquid.body));
  const dense = await api.put(
    '/v1/documents/saved_food/agent-lead',
    { base_revision: 0, payload: { ...oil, id: 'agent-lead', volume: { density: 11.3 } } },
    { token: writer, headers: key() }
  );
  assert.equal(dense.status, 400);
  assert.match(dense.body.error ?? dense.body.message, /volume needs a density/);
  const entryID = '7C1A6E2B-0000-4000-8000-000000000001';
  const entry = (density) => ({
    id: entryID,
    date: '2026-10-06',
    meal: 'Dinner',
    loggedAt: '2026-10-06T18:00:00.000Z',
    grams: 13.8,
    food: {
      foodID: 'off:3000000000013',
      name: 'Synthetic olive oil',
      source: 'openFoodFacts',
      per100g: { energy: 900, fat: 100 },
      volume: { density, assumed: true, note: 'Typical for oils' },
    },
  });
  const heavy = await api.put(
    `/v1/documents/food_entry/${entryID}`,
    { base_revision: 0, payload: entry(11.3) },
    { token: writer, headers: key() }
  );
  assert.equal(heavy.status, 400);
  assert.match(heavy.body.error ?? heavy.body.message, /food\.volume needs a density/);
  const poured = await api.put(
    `/v1/documents/food_entry/${entryID}`,
    { base_revision: 0, payload: entry(0.92) },
    { token: writer, headers: key() }
  );
  assert.equal(poured.status, 201, JSON.stringify(poured.body));
});

test("generate_program builds the app's program for the active gym, ready to propose", async () => {
  const user = await signUp(api);
  const gym = (name, equipment, extra) => ({
    id: randomUUID().toUpperCase(),
    name,
    equipment,
    bars: [{ value: 20, unit: 'kg' }],
    plates: [],
    loads: {},
    excluded: [],
    createdAt: '2026-10-01T12:00:00.000Z',
    ...extra,
  });
  const home = gym('Home', ['dumbbell', 'flatBench', 'pullUpBar'], {
    activatedAt: '2026-10-03T12:00:00.000Z',
    excluded: ['dumbbell-bench-press'],
  });
  await put(user, 'gym_profile', home);
  await put(
    user,
    'gym_profile',
    gym('Old gym', ['barbell', 'rack'], {
      activatedAt: '2026-10-05T12:00:00.000Z',
      archivedAt: '2026-10-06T12:00:00.000Z',
    })
  );
  const reader = await connect((await token(user, ['read'])).token);
  const request = { days_per_week: 3, goal: 'general', experience: 'beginner', minutes: 45 };
  const generated = await call(reader, 'generate_program', request);
  assert.deepEqual(generated.gym, { id: home.id, name: 'Home' });

  const { ExerciseLibrary } = require('../lib/training/library');
  const generation = require('../lib/training/generation');
  const library = ExerciseLibrary.withCustom([]);
  const program = generated.program;
  const slots = program.days.flatMap((day) => day.slots);
  assert.equal(program.name, '3-day Full body');
  assert.ok(slots.every((slot) => generation.allows(home, library.exercise(slot.exerciseID))));
  assert.ok(!slots.some((slot) => slot.exerciseID === 'dumbbell-bench-press'));
  const expected = generation.generate(
    { daysPerWeek: 3, goal: 'general', experience: 'beginner', minutes: 45 },
    library,
    { gym: home }
  );
  assert.deepEqual(
    program.days.map((day) => day.slots.map((slot) => [slot.exerciseID, slot.target])),
    expected.program.days.map((day) => day.slots.map((slot) => [slot.exerciseID, slot.target]))
  );
  assert.deepEqual(generated.shortfalls, expected.shortfalls);
  assert.equal(generated.weekly_sets.length, 12);
  assert.equal(
    generated.proposal.summary,
    "3 training days a cycle for general, 6 cycles. Under 80 % of the weekly target: Calves, Side delts, Abs, with this gym's equipment and session length."
  );
  assert.match(generated.proposal.falsifier, /45 minutes/);

  const anywhere = await call(reader, 'generate_program', { ...request, use_gym: false });
  assert.equal(anywhere.gym, null);
  assert.equal(anywhere.program.days[0].slots[0].exerciseID, 'back-squat');
  const refused = await call(reader, 'generate_program', { ...request, days_per_week: 7 });
  assert.ok(refused.error);
  await reader.close();

  const agent = await connect((await token(user, ['propose'])).token);
  const filed = await call(agent, 'propose', {
    ...generated.proposal,
    changes: [{ kind: 'program', id: program.id, after: program }],
  });
  assert.equal(filed.status, 'pending', JSON.stringify(filed));
  await agent.close();
});
