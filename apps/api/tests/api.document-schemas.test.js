// The server stores only agent documents ExerlyCore can decode, and only
// training documents from tokens that ExerlyCore could apply. A device that
// can't read a document has to set it aside, so the server refuses it first.

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
const uuid = () => randomUUID().toUpperCase();

function session(id, extra = {}) {
  return {
    id,
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
            kind: 'standard',
            efforts: [{ reps: 5, load: { unit: 'kg', value: 100 } }],
            rir: 2,
            completedAt: '2026-10-06T18:10:00.000Z',
          },
        ],
      },
    ],
    ...extra,
  };
}

// As ExerlyCore encodes it: optional fields that are nil are left out.
function proposal(id, extra = {}) {
  return {
    id,
    createdAt: '2026-10-06T18:30:00.000Z',
    author: { kind: 'builtIn', name: 'Exerly' },
    title: 'Did you mean 100 kg?',
    summary: 'Ten times your other sets.',
    changes: [{ kind: 'workout_session', id: 'S', after: { id: 'S' } }],
    evidence: [
      {
        claim: 'Your best',
        level: 'personalData',
        caveats: ['n=1'],
        dataRefs: [{ kind: 'workout_session', id: 'S' }],
        metric: {
          name: 'exercise.e1rm.best',
          parameters: {
            exercise: 'barbell-bench-press',
            from: '2026-09-01',
            through: '2026-09-30',
          },
          claimed: 116.67,
        },
      },
    ],
    confidence: 'high',
    falsifier: 'You lifted it.',
    status: 'pending',
    ...extra,
  };
}

async function putAs(token, kind, payload) {
  return api.put(
    `/v1/documents/${kind}/${payload.id}`,
    { base_revision: 0, payload },
    { token, headers: key() }
  );
}

async function tokenFor(user, scopes) {
  const res = await api.post(
    '/v1/tokens',
    { name: 'Synthetic agent', scopes, password: user.password },
    { token: user.token, headers: key() }
  );
  return res.body.token;
}

test('a proposal shaped as ExerlyCore encodes it is stored', async () => {
  const user = await signUp(api);
  const res = await putAs(user.token, 'proposal', proposal(uuid()));
  assert.equal(res.status, 201, JSON.stringify(res.body));
  const decided = proposal(uuid(), { status: 'accepted', decidedAt: '2026-10-06T19:00:00.000Z' });
  assert.equal((await putAs(user.token, 'proposal', decided)).status, 201);
});

test('malformed proposals are refused, whoever writes them', async () => {
  const user = await signUp(api);
  const id = uuid();
  const cases = [
    [{ createdAt: undefined }, /createdAt/],
    [{ createdAt: 'yesterday' }, /createdAt/],
    [{ summary: undefined }, /summary/],
    [{ confidence: 'certain' }, /confidence/],
    [{ evidence: undefined }, /evidence/],
    [{ evidence: [{ claim: 'x', level: 'vibes', caveats: [], dataRefs: [] }] }, /level/],
    [{ evidence: [{ claim: 'x', level: 'anecdote', dataRefs: [] }] }, /caveats/],
    [
      {
        evidence: [
          {
            claim: 'x',
            level: 'anecdote',
            caveats: [],
            dataRefs: [],
            metric: { name: 'm', parameters: { n: 1 }, claimed: 1 },
          },
        ],
      },
      /metric/,
    ],
    [{ author: { kind: 'human', name: 'x' } }, /author.kind/],
    [{ changes: [{ kind: 'workout_session', id: 'S' }] }, /before or an after/],
    [
      {
        changes: [
          { kind: 'workout_session', id: 'S', after: { id: 'S' } },
          { kind: 'workout_session', id: 'S', before: { id: 'S' } },
        ],
      },
      /second time/,
    ],
    [{ decidedAt: 'soon' }, /decidedAt/],
  ];
  for (const [patch, pattern] of cases) {
    const res = await putAs(user.token, 'proposal', { ...proposal(id), ...patch });
    assert.equal(res.status, 400, JSON.stringify(patch));
    assert.match(res.body.message, pattern);
  }
  const notUUID = await api.put(
    '/v1/documents/proposal/not-a-uuid',
    { base_revision: 0, payload: proposal('not-a-uuid') },
    { token: user.token, headers: key() }
  );
  assert.match(notUUID.body.message, /id must be a UUID/);
});

test('malformed audit events are refused', async () => {
  const user = await signUp(api);
  const event = {
    id: uuid(),
    at: '2026-10-06T18:05:00.000Z',
    action: 'proposalAccepted',
    actor: { kind: 'builtIn', name: 'You' },
    targets: [],
  };
  assert.equal((await putAs(user.token, 'audit_event', event)).status, 201);
  for (const patch of [{ targets: undefined }, { action: 'deleted' }, { actor: { name: 'x' } }]) {
    const res = await putAs(user.token, 'audit_event', { ...event, id: uuid(), ...patch });
    assert.equal(res.status, 400, JSON.stringify(patch));
  }
});

test('a write token can only write training documents ExerlyCore could apply', async () => {
  const user = await signUp(api);
  const writer = await tokenFor(user, ['write']);
  assert.equal((await putAs(writer, 'workout_session', session(uuid()))).status, 201);

  const negative = session(uuid());
  negative.exercises[0].sets[0].efforts[0].reps = -8;
  const refused = await putAs(writer, 'workout_session', negative);
  assert.equal(refused.status, 400);
  assert.match(refused.body.message, /reps must be a whole number/);

  const noLoad = session(uuid());
  delete noLoad.exercises[0].sets[0].efforts[0].load;
  assert.match(
    (await putAs(writer, 'workout_session', noLoad)).body.message,
    /completed without the values/
  );

  const planned = session(uuid());
  planned.exercises[0].slotID = uuid();
  assert.equal((await putAs(writer, 'workout_session', planned)).status, 201);
  const badSlot = session(uuid());
  badSlot.exercises[0].slotID = 'slot-1';
  assert.match(
    (await putAs(writer, 'workout_session', badSlot)).body.message,
    /slotID must be a UUID/
  );

  const badExercise = { id: 'custom-x', name: 'X', metric: 'weightReps', mechanics: 'compound' };
  assert.equal((await putAs(writer, 'custom_exercise', badExercise)).status, 400);
});

test('a token proposal must target training documents it could apply', async () => {
  const user = await signUp(api);
  const agent = await tokenFor(user, ['propose']);
  const target = uuid();
  const valid = proposal(uuid(), {
    changes: [{ kind: 'workout_session', id: target, after: session(target) }],
  });
  assert.equal((await putAs(agent, 'proposal', valid)).status, 201);

  const broken = session(target);
  broken.exercises[0].exerciseID = 'not-an-exercise';
  const invalid = proposal(uuid(), {
    changes: [{ kind: 'workout_session', id: target, after: broken }],
  });
  assert.match((await putAs(agent, 'proposal', invalid)).body.message, /not a known exercise/);

  const unsupported = proposal(uuid(), {
    changes: [{ kind: 'audit_event', id: uuid(), after: { id: 'x' } }],
  });
  assert.match((await putAs(agent, 'proposal', unsupported)).body.message, /changes\[0\]\.kind/);
});
