// Shared document logic for the v1 routes, the token routes and MCP:
// payload checks, the change feed, and server-written audit events.

const { randomUUID } = require('node:crypto');
const store = require('../data');
const sync = require('./sync');
const { badRequest } = require('./errors');
const { proposalProblems, auditEventProblems } = require('./documentSchemas');

// Each kind's check returns a list of problems. Training documents from the
// person's own devices get a light check; agent documents must match what
// ExerlyCore decodes, because a device can't apply what it can't read.
// Token writes of training documents are checked in full (routes/documents.js).
// Sources set aside for a Health import: one per source, at most five,
// each name at most 60 code points (Unicode scalars), as the app keeps them.
function healthAlsoIn(list) {
  return (
    Array.isArray(list) &&
    list.length <= 5 &&
    list.every(
      (item) =>
        item !== null &&
        typeof item === 'object' &&
        typeof item.source === 'string' &&
        item.source.length > 0 &&
        typeof item.name === 'string' &&
        [...item.name].length <= 60
    ) &&
    new Set(list.map((item) => item.source)).size === list.length
  );
}

const KINDS = {
  workout_session: (p) =>
    typeof p.startedAt === 'string' && Array.isArray(p.exercises)
      ? []
      : ['a session needs startedAt and exercises'],
  custom_exercise: (p) =>
    typeof p.name === 'string' && typeof p.metric === 'string'
      ? []
      : ['an exercise needs a name and a metric'],
  // Not "food": the legacy food log already uses that kind in sync_changes.
  saved_food: (p) =>
    typeof p.name === 'string' && p.per100g && typeof p.per100g === 'object'
      ? []
      : ['a food needs a name and per100g nutrients'],
  food_entry: (p) =>
    typeof p.date === 'string' &&
    p.food &&
    typeof p.food === 'object' &&
    typeof p.grams === 'number'
      ? []
      : ['an entry needs a date, a food and grams'],
  nutrition_day: (p) =>
    typeof p.date === 'string' && p.date === p.id && typeof p.status === 'string'
      ? []
      : ['a day needs its date as its ID and a status'],
  weight_entry: (p) =>
    typeof p.at === 'string' && p.weight && typeof p.weight.value === 'number'
      ? []
      : ['a weigh-in needs an instant and a weight'],
  program: (p) =>
    typeof p.name === 'string' && Array.isArray(p.days) ? [] : ['a program needs a name and days'],
  nutrition_plan: (p) =>
    typeof p.startDate === 'string' &&
    p.goal &&
    typeof p.goal.direction === 'string' &&
    Array.isArray(p.targets) &&
    p.targets.length === 7
      ? []
      : ['a plan needs a startDate, a goal and seven daily targets'],
  custom_metric: (p) =>
    typeof p.name === 'string' && ['number', 'scale', 'yesNo'].includes(p.kind)
      ? []
      : ['a metric needs a name and a kind: number, scale or yesNo'],
  metric_entry: (p) =>
    typeof p.metricID === 'string' && typeof p.date === 'string' && typeof p.value === 'number'
      ? []
      : ['a metric value needs a metricID, a date and a number'],
  experiment: (p) =>
    typeof p.name === 'string' &&
    typeof p.metric === 'string' &&
    ['baselineStart', 'baselineEnd', 'interventionStart', 'interventionEnd'].every(
      (key) => typeof p[key] === 'string'
    )
      ? []
      : ['an experiment needs a name, a metric and the dates of both phases'],
  gym_profile: (p) =>
    typeof p.name === 'string' &&
    Array.isArray(p.equipment) &&
    Array.isArray(p.plates) &&
    p.loads &&
    typeof p.loads === 'object' &&
    !Array.isArray(p.loads)
      ? []
      : ['a gym needs a name, equipment, plates and loads by equipment'],
  // "Don't suggest this": one per food, its ID the food's.
  hidden_suggestion: (p) =>
    typeof p.name === 'string' && p.name.trim() && typeof p.hiddenAt === 'string'
      ? []
      : ['a hidden suggestion needs the food name and when it was hidden'],
  // One record imported from Apple Health: the install that owns it and how
  // many times it changed hands, its entry or activity, other sources noted
  // as set aside, and whether it's in or taken out. One taken out is kept as
  // a tombstone, without its entry or activity.
  health_import: (p) =>
    ['food', 'workout'].includes(p.kind) &&
    (typeof p.target === 'string' || p.state === 'removed') &&
    typeof p.owner === 'string' &&
    (p.generation === undefined || (Number.isInteger(p.generation) && p.generation >= 0)) &&
    (p.alsoIn === undefined || healthAlsoIn(p.alsoIn)) &&
    ['imported', 'removed'].includes(p.state)
      ? []
      : ['a Health import needs a kind, a target, an owner, a whole generation and a state'],
  // Where imported records came from: written with them, never changed.
  import_provenance: (p) =>
    typeof p.source === 'string' &&
    typeof p.importedAt === 'string' &&
    Array.isArray(p.documents) &&
    Number.isInteger(p.part) &&
    Number.isInteger(p.parts)
      ? []
      : ['provenance needs a source, importedAt, its documents and its part'],
  // Two devices' versions of one record, kept until the person picks one.
  // ExerlyCore decodes and merges it; the server only keeps it in step.
  sync_conflict: (p) =>
    typeof p.kind === 'string' &&
    typeof p.documentID === 'string' &&
    typeof p.detectedAt === 'string' &&
    typeof p.changedAt === 'string' &&
    Array.isArray(p.fields)
      ? []
      : [
          'a conflict needs the kind and ID of its record, when it was found and changed, and its fields',
        ],
  // The entries Undo removed that one entry, logged again from their scan,
  // stands in for: its ID the entry's, never naming itself, at most eight.
  food_entry_link: (p) =>
    Array.isArray(p.replaces) &&
    p.replaces.length <= 8 &&
    p.replaces.every((id) => typeof id === 'string' && UUID_RE.test(id) && id !== p.id) &&
    new Set(p.replaces).size === p.replaces.length
      ? []
      : ['a link names up to eight other entries by ID, each once'],
  proposal: proposalProblems,
  audit_event: auditEventProblems,
};
// Kinds that can be created but never changed or deleted.
const APPEND_ONLY = new Set(['audit_event']);
const ID_RE = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * A UUID in the uppercase form ExerlyCore writes; other IDs as they are. One
 * document must never be stored under two IDs that differ only in case.
 */
const canonicalID = (value) =>
  typeof value === 'string' && UUID_RE.test(value) ? value.toUpperCase() : value;

const isKind = (value) => Object.prototype.hasOwnProperty.call(KINDS, value);

function readKind(value) {
  if (!isKind(value)) throw badRequest(`Unknown document kind ${value}`);
  return value;
}

function readID(value) {
  if (!ID_RE.test(value)) {
    throw badRequest(
      'Document IDs are 1 to 128 letters, digits, dots, colons, underscores or hyphens'
    );
  }
  return canonicalID(value);
}

const isObject = (value) => !!value && typeof value === 'object' && !Array.isArray(value);
/** `value` with `key` mapped by `f`, when it is an object that has the key. */
const mapKey = (value, key, f) =>
  isObject(value) && key in value ? { ...value, [key]: f(value[key]) } : value;
const mapEach = (f) => (list) => (Array.isArray(list) ? list.map(f) : list);
const withID = (value) => mapKey(value, 'id', canonicalID);

/**
 * The payload with its own ID and every document ID it refers to in canonical
 * form: a proposal's changes, the documents in them and its evidence, an audit
 * event's targets and proposal, a session's program and an entry's food.
 * Migration 0006 applies the same rule to the kinds stored before it.
 */
function canonicalPayload(kind, payload) {
  let document = withID(payload);
  if (kind === 'proposal') {
    document = mapKey(
      document,
      'changes',
      mapEach((change) => mapKey(mapKey(withID(change), 'before', withID), 'after', withID))
    );
    document = mapKey(
      document,
      'evidence',
      mapEach((item) => mapKey(item, 'dataRefs', mapEach(withID)))
    );
  } else if (kind === 'audit_event') {
    document = mapKey(document, 'targets', mapEach(withID));
    document = mapKey(document, 'proposalID', canonicalID);
  } else if (kind === 'workout_session') {
    document = mapKey(document, 'program', (ref) => mapKey(ref, 'programID', canonicalID));
  } else if (kind === 'food_entry') {
    document = mapKey(document, 'food', (ref) => mapKey(ref, 'foodID', canonicalID));
  } else if (kind === 'food_entry_link') {
    document = mapKey(document, 'replaces', mapEach(canonicalID));
  } else if (kind === 'metric_entry') {
    document = mapKey(document, 'metricID', canonicalID);
  }
  return document;
}

function readPayload(kind, id, payload) {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    throw badRequest('payload must be an object');
  }
  if (canonicalID(payload.id) !== id) throw badRequest('payload.id must match the document ID');
  payload = canonicalPayload(kind, { ...payload, id });
  const problems = KINDS[kind](payload);
  if (problems.length) {
    throw badRequest(`payload is not a valid ${kind}: ${problems.slice(0, 5).join('; ')}`);
  }
  return payload;
}

function present(row) {
  return {
    kind: row.kind,
    id: row.document_id,
    revision: row.revision,
    deleted: !!row.deleted_at,
    payload: row.payload ?? null,
    updated_at: row.updated_at,
  };
}

function acknowledge(row) {
  const { payload: _payload, ...rest } = present(row);
  return rest;
}

function current(account, kind, id) {
  return store.findOne('documents', { account_id: account.id, kind, document_id: id });
}

/** Appends a change to the account's feed. */
function record(account, row) {
  return records(account, [row]);
}

/** Appends changes to the account's feed, one per document, in order. */
async function records(account, rows) {
  if (!rows.length) return null;
  return sync.changes(
    account,
    rows.map((row) => ({
      kind: row.kind,
      record: {
        id: row.document_id,
        client_id: row.document_id,
        revision: row.revision,
        deleted_at: row.deleted_at,
        payload: row.payload ?? null,
        updated_at: row.updated_at,
      },
    }))
  );
}

/**
 * Writes an audit event as an append-only document, so it reaches every
 * device through the feed. `actor` is { kind, name, tokenID? }.
 */
async function appendAudit(account, { action, actor, proposalID, targets = [], note }) {
  const id = randomUUID().toUpperCase();
  const now = new Date();
  const payload = { id, at: now.toISOString(), action, actor, targets };
  if (proposalID) payload.proposalID = proposalID;
  if (note) payload.note = note;
  const row = await store.insert('documents', {
    account_id: account.id,
    kind: 'audit_event',
    document_id: id,
    revision: 1,
    payload,
    deleted_at: null,
    created_at: now,
    updated_at: now,
  });
  await record(account, row);
  return payload;
}

/** The identity a token acts under. MCP sets `via` to 'mcp'. */
function tokenActor(pat) {
  return { kind: pat.via === 'mcp' ? 'mcp' : 'api', name: pat.name, tokenID: pat.id };
}

module.exports = {
  KINDS,
  canonicalID,
  canonicalPayload,
  APPEND_ONLY,
  isKind,
  readKind,
  readID,
  readPayload,
  present,
  acknowledge,
  current,
  record,
  records,
  appendAudit,
  tokenActor,
};
