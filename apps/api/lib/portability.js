// Data that can leave and come back. CSV files for spreadsheets, one per kind
// of data, and an import that restores an Exerly JSON export (/api/export)
// into an account. PARITY I14; see docs/design/022-export-import.md.

const { createHash, randomUUID } = require('node:crypto');
const store = require('../data');
const schema = require('../data/schema');
const docs = require('./documents');
const dates = require('./dates');
const users = require('./users');
const v = require('./validate');
const sync = require('./sync');
const { OWNERSHIP, ownerFilters } = require('./ownership');
const { NUTRIENTS, NUTRIENT_UNITS } = require('./nutrition/validate');
const { badRequest, notFound } = require('./errors');
const { DIET_TYPES } = require('./nutrition');
// Each table's checks, from the routes that write it.
const activities = require('../routes/activities');
const diary = require('../routes/diary');
const food = require('../routes/food');
const goals = require('../routes/goals');
const library = require('../routes/library');
const measurements = require('../routes/measurements');
const program = require('../routes/program');
const sleep = require('../routes/sleep');
const weight = require('../routes/weight');
const workouts = require('../routes/workouts');

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const round = (value) => (value == null ? null : Math.round(value * 10000) / 10000);

/** One CSV cell. Text that a spreadsheet would run as a formula is quoted with a leading apostrophe. */
function cell(value) {
  if (value == null) return '';
  let text = typeof value === 'object' ? JSON.stringify(value) : String(value);
  if (typeof value === 'string' && /^[=+\-@\t\r]/.test(text)) text = `'${text}`;
  return /[",\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

function csv(header, rows) {
  return [header, ...rows].map((row) => row.map(cell).join(',')).join('\r\n') + '\r\n';
}

const nutrientHeader = NUTRIENTS.map((n) => `${n}_${NUTRIENT_UNITS[n]}`);
// Unknown stays empty: a food that doesn't report a nutrient isn't zero.
const nutrientCells = (amounts, scale = 1) =>
  NUTRIENTS.map((n) => (amounts?.[n] == null ? null : round(amounts[n] * scale)));

const mass = (m) => (m ? [m.value, m.unit] : [null, null]);

/** For each CSV file: the documents it reads, its columns, and its rows for one document. */
const FILES = {
  food_entries: {
    kind: 'food_entry',
    header: [
      'id',
      'revision',
      'updated_at',
      'date',
      'meal',
      'logged_at',
      'food_id',
      'food_name',
      'brand',
      'source',
      'grams',
      'serving',
      'serving_grams',
      'quantity',
      'density_g_per_ml',
      'density_assumed',
      ...nutrientHeader,
    ],
    rows: (p, d) => [
      [
        d.document_id,
        d.revision,
        d.updated_at,
        p.date,
        p.meal,
        p.loggedAt,
        p.food?.foodID,
        p.food?.name,
        p.food?.brand,
        p.food?.source,
        // An unweighed portion's 100 g is nominal: its weight is unknown.
        p.food?.unweighed ? null : p.grams,
        p.serving?.name,
        p.serving?.grams,
        p.quantity,
        p.food?.volume?.density,
        p.food?.volume?.assumed,
        ...nutrientCells(p.food?.per100g, (p.grams ?? 0) / 100),
      ],
    ],
    order: (p) => `${p.date} ${p.loggedAt}`,
  },
  saved_foods: {
    kind: 'saved_food',
    header: [
      'id',
      'revision',
      'updated_at',
      'name',
      'brand',
      'source',
      'barcode',
      'favorite',
      'archived_at',
      'servings',
      'density_g_per_ml',
      'yield_grams',
      'serving_count',
      'ingredients',
      'preparation',
      ...nutrientHeader.map((h) => `${h}_per_100g`),
    ],
    rows: (p, d) => [
      [
        d.document_id,
        d.revision,
        d.updated_at,
        p.name,
        p.brand,
        p.source,
        p.barcode,
        p.favorite,
        p.archivedAt,
        (p.servings ?? []).map((s) => `${s.name} = ${s.grams} g`).join('; '),
        p.volume?.density,
        p.yieldGrams,
        p.servingCount,
        (p.ingredients ?? []).map((i) => `${i.food?.name} = ${round(i.grams)} g`).join('; '),
        p.preparation,
        ...nutrientCells(p.per100g),
      ],
    ],
    order: (p) => p.name?.toLowerCase() ?? '',
  },
  weigh_ins: {
    kind: 'weight_entry',
    header: [
      'id',
      'revision',
      'updated_at',
      'at',
      'date',
      'weight',
      'unit',
      'body_fat_percent',
      'source',
    ],
    rows: (p, d) => [
      [
        d.document_id,
        d.revision,
        d.updated_at,
        p.at,
        p.date,
        ...mass(p.weight),
        p.bodyFat,
        p.source,
      ],
    ],
    order: (p) => p.at ?? '',
  },
  days: {
    kind: 'nutrition_day',
    header: ['date', 'revision', 'updated_at', 'status', 'notes', 'tags'],
    rows: (p, d) => [
      [p.date, d.revision, d.updated_at, p.status, p.notes, (p.tags ?? []).join('; ')],
    ],
    order: (p) => p.date ?? '',
  },
  sets: {
    kind: 'workout_session',
    header: [
      'session_id',
      'revision',
      'updated_at',
      'session',
      'started_at',
      'ended_at',
      'time_zone',
      'exercise_position',
      'exercise_id',
      'superset_id',
      'set_position',
      'set_id',
      'kind',
      'side',
      'effort',
      'reps',
      'load',
      'load_unit',
      'duration_s',
      'distance_m',
      'rir',
      'completed_at',
      'bodyweight',
      'bodyweight_unit',
      'program_id',
      'program_day_id',
      'program_cycle',
    ],
    rows: (p, d) =>
      (p.exercises ?? []).flatMap((exercise, e) =>
        (exercise.sets ?? []).flatMap((set, s) =>
          (set.efforts ?? []).map((effort, f) => [
            d.document_id,
            d.revision,
            d.updated_at,
            p.name,
            p.startedAt,
            p.endedAt,
            p.timeZoneID,
            e + 1,
            exercise.exerciseID,
            exercise.supersetID,
            s + 1,
            set.id,
            set.kind,
            set.side,
            f + 1,
            effort.reps,
            ...mass(effort.load),
            effort.duration,
            effort.distance,
            set.rir,
            set.completedAt,
            ...mass(p.bodyweight),
            p.program?.programID,
            p.program?.dayID,
            p.program?.cycle,
          ])
        )
      ),
    order: (p) => p.startedAt ?? '',
  },
  metric_values: {
    kind: 'metric_entry',
    header: ['id', 'revision', 'updated_at', 'metric_id', 'date', 'value'],
    rows: (p, d) => [[d.document_id, d.revision, d.updated_at, p.metricID, p.date, p.value]],
    order: (p) => `${p.metricID} ${p.date}`,
  },
  metrics: {
    kind: 'custom_metric',
    header: [
      'id',
      'revision',
      'updated_at',
      'name',
      'unit',
      'kind',
      'minimum',
      'maximum',
      'archived',
    ],
    rows: (p, d) => [
      [
        d.document_id,
        d.revision,
        d.updated_at,
        p.name,
        p.unit,
        p.kind,
        p.minimum,
        p.maximum,
        p.archived,
      ],
    ],
    order: (p) => p.name?.toLowerCase() ?? '',
  },
};

/** One CSV file of the account's live documents, or null for an unknown name. */
async function exportCSV(account, name) {
  const file = FILES[name];
  if (!file) return null;
  const rows = (await store.find('documents', { account_id: account.id, kind: file.kind }))
    .filter((d) => !d.deleted_at && d.payload)
    .map((d) => ({ ...d, updated_at: d.updated_at ? new Date(d.updated_at).toISOString() : null }))
    .sort((a, b) => file.order(a.payload).localeCompare(file.order(b.payload)));
  return csv(
    file.header,
    rows.flatMap((d) => file.rows(d.payload, d))
  );
}

/**
 * Restores the documents in an Exerly JSON export. A document the account
 * already has is kept as it is; the rest are checked as an API write would be
 * and added with their exported revisions. Legacy tables aren't imported.
 */
// The server's older tables an export restores. `match`: the fields that tell
// whether the account already has a row, so restoring twice adds nothing and a
// row the account has (a weigh-in for the same day) is kept. `natural`: fields
// that match an older row without a client ID. `check`: the row run through
// the checks its routes make, as the columns to store. Rows get the importing
// account as owner and new IDs. Tables a phone syncs get a change in its feed.
const dayOf = (row, account) => {
  v.dateStr(row.entry_date, 'entry_date');
  return users.entryDateFor({ body: row, query: {}, get: () => undefined }, account);
};
// A client ID, when a row has one, is a UUID, as the routes require.
const clientID = (row) => (row.client_id == null ? undefined : sync.entityID(row.client_id));
const numbers = (row, fields, bounds = { min: 0, max: 100000 }) =>
  Object.fromEntries(
    fields.map((field) => [field, v.num(row[field], field, { required: false, ...bounds })])
  );
const RESTORABLE = {
  diary_days: {
    match: ['entry_date'],
    feed: 'diary_day',
    feedID: 'entry_date',
    check: (row, account) => ({
      entry_date: dayOf(row, account),
      status: v.oneOf(row.status, 'status', diary.STATUSES),
      note: v.str(row.note, 'note', { required: false, max: 500 }),
    }),
  },
  checkins: {
    match: ['entry_date'],
    check: (row) => ({
      entry_date: v.dateStr(row.entry_date, 'entry_date'),
      ...numbers(row, ['expenditure', 'mean_intake', 'calories', 'protein_g', 'carbs_g', 'fat_g']),
      ...numbers(row, ['trend_weight_kg', 'trend_change_kg'], { min: -500, max: 500 }),
      note: v.str(row.note, 'note', { required: false, max: 1000 }),
    }),
  },
  // Several versions can start on one day; they differ in when and why.
  target_versions: {
    match: ['effective_date', 'created_at', 'reason', 'targets'],
    // The source account's check-in becomes the restored one, or none.
    refs: { checkin_id: 'checkins' },
    check: (row) => {
      if (!row.targets || typeof row.targets !== 'object' || Array.isArray(row.targets))
        throw badRequest('targets must be an object');
      numbers(row.targets, Object.keys(row.targets));
      return {
        effective_date: v.dateStr(row.effective_date, 'effective_date'),
        reason: v.str(row.reason, 'reason', { required: false, max: 64 }),
      };
    },
  },
  measurements: {
    match: ['client_id'],
    natural: ['entry_date', 'type', 'value', 'created_at'],
    feed: 'measurement',
    check: (row, account) => ({
      ...measurements.readMeasurement({
        body: {
          ...row,
          value: row.entered_value ?? row.value,
          unit: row.entered_unit ?? row.unit,
          entry_date: dayOf(row, account),
        },
        account,
        query: {},
        get: () => undefined,
      }),
      timezone: dates.normalizeTimeZone(row.timezone ?? account.timezone ?? 'UTC'),
      client_id: clientID(row),
    }),
  },
  activities: {
    match: ['client_id'],
    natural: ['entry_date', 'activity', 'duration_min', 'created_at'],
    feed: 'activity',
    identity: true,
    check: (row, account) => ({
      ...activities.read(row),
      entry_date: dayOf(row, account),
      client_id: clientID(row),
    }),
  },
  food: {
    match: ['client_id'],
    natural: ['entry_date', 'name', 'calories', 'logged_at'],
    feed: 'food',
    // Stored macros are totals; the snapshot holds them per serving.
    check: (row, account) => ({
      ...food.readEntry({ ...row, ...(row.nutrition_snapshot ?? {}) }),
      entry_date: dayOf(row, account),
      client_id: clientID(row),
    }),
  },
  sleep: {
    match: ['client_id'],
    natural: ['entry_date', 'hours', 'created_at'],
    feed: 'sleep',
    identity: true,
    check: (row, account) => ({
      ...sleep.read(row),
      entry_date: dayOf(row, account),
      client_id: clientID(row),
    }),
  },
  // One weigh-in a day: a day the account has keeps the account's.
  weights: {
    match: ['entry_date'],
    feed: 'weight',
    feedID: 'entry_date',
    check: (row, account) => ({
      entry_date: dayOf(row, account),
      weight_kg: Number(weight.toKilograms(row).toFixed(2)),
      body_fat_pct: v.num(row.body_fat_pct, 'body_fat_pct', { required: false, min: 1, max: 70 }),
      note: v.str(row.note, 'note', { required: false, max: 280 }),
      source: v.oneOf(row.source ?? 'manual', 'source', [
        'manual',
        'healthkit',
        'import',
        'onboarding',
      ]),
    }),
  },
  water: {
    match: ['entry_date'],
    feed: 'water',
    feedID: 'entry_date',
    check: (row, account) => ({
      entry_date: dayOf(row, account),
      ml: Math.round(v.num(row.ml, 'ml', { min: 0, max: 30000 })),
    }),
  },
  goals: {
    collection: 'goals',
    match: [],
    check: (row) =>
      Object.fromEntries(
        goals.FIELDS.map(([column, , bounds]) => [
          column,
          v.num(row[column], column, { required: false, ...bounds }),
        ])
      ),
  },
  program: {
    collection: 'programs',
    match: [],
    check: (row) => ({
      goal_type: v.oneOf(row.goal_type, 'goal_type', program.GOAL_TYPES, { required: false }),
      diet_type: v.oneOf(row.diet_type, 'diet_type', DIET_TYPES, { required: false }),
      protein_strategy: v.oneOf(
        row.protein_strategy,
        'protein_strategy',
        program.PROTEIN_STRATEGIES,
        {
          required: false,
        }
      ),
      target_weight_kg: v.num(row.target_weight_kg, 'target_weight_kg', {
        required: false,
        min: 20,
        max: 500,
      }),
      rate_kg_per_week: v.num(row.rate_kg_per_week, 'rate_kg_per_week', {
        required: false,
        min: -program.MAX_RATE_KG_PER_WEEK,
        max: program.MAX_RATE_KG_PER_WEEK,
      }),
      ...numbers(row, ['calories', 'protein_g', 'carbs_g', 'fat_g', 'expenditure']),
      last_checkin_date: v.dateStr(row.last_checkin_date, 'last_checkin_date', { required: false }),
    }),
  },
  library_foods: { match: ['name', 'brand', 'barcode'], check: (row) => library.readFood(row) },
  recipes: {
    match: ['name', 'created_at'],
    // An ingredient is stored as totals for its servings; the route's check
    // takes it per serving, so it's read back that way first.
    check: (row) => ({
      name: v.str(row.name, 'name', { max: 200 }),
      ingredients: library.readIngredients(
        Array.isArray(row.ingredients)
          ? row.ingredients.map((item, i) => {
              const servings =
                v.num(item?.servings, `ingredients[${i}].servings`, {
                  required: false,
                  min: 0.01,
                  max: 100,
                }) ?? 1;
              const per = (value) =>
                value == null || value === '' || !Number.isFinite(Number(value))
                  ? value
                  : Number(value) / servings;
              const out = { ...item, servings };
              for (const field of ['calories', 'protein', 'carbs', 'fat', 'fiber', 'sugar'])
                out[field] = per(item?.[field]);
              return out;
            })
          : row.ingredients
      ),
      servings: v.num(row.servings, 'servings', { required: false, min: 0.5, max: 100 }) ?? 1,
      note: v.str(row.note, 'note', { required: false, max: 1000 }),
    }),
  },
  workouts: {
    match: ['name', 'created_at'],
    check: (row) => ({
      name: v.str(row.name, 'name', { max: 120 }),
      exercises: workouts.readExercises(row.exercises),
    }),
  },
  ai_plans: {
    match: ['type', 'createdAt'],
    check: (row) => ({
      type: v.str(row.type, 'type', { max: 32 }),
      prompt: v.str(row.prompt, 'prompt', { required: false, max: 2000 }),
      response: v.str(row.response, 'response', { max: 100000 }),
    }),
  },
};
// Exported but never restored into another account, and why.
const NOT_RESTORED = {
  account_identities: 'Sign-in methods belong to the account they were set up for.',
  webhooks:
    'Webhooks would send this account’s data to addresses set up elsewhere, and their secrets aren’t exported.',
  onboarding_drafts: 'A setup draft belongs to the account being set up.',
};
const METADATA = ['documents', 'account', 'exported_at', 'version', 'source', 'note', 'context'];

/** A value with its keys in order, so the same row always reads the same. */
const ordered = (value) =>
  value instanceof Date
    ? value.toISOString()
    : Array.isArray(value)
      ? value.map(ordered)
      : value && typeof value === 'object'
        ? Object.fromEntries(
            Object.keys(value)
              .sort()
              .map((key) => [key, ordered(value[key])])
          )
        : value;

/** A value as a match key: times, numbers and objects as text, so a JSON row and a stored row compare equal. */
function matchValue(value) {
  if (value == null) return '';
  if (value instanceof Date) return value.toISOString();
  if (typeof value === 'string' && /^\d{4}-\d\d-\d\dT/.test(value)) {
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? value : date.toISOString();
  }
  return typeof value === 'object' ? JSON.stringify(ordered(value)) : String(value);
}

/**
 * A stored row's fingerprint, of what it says rather than when or how often it
 * was written. Undo removes a restored row only while it says the same.
 */
const WRITE_FIELDS = ['updated_at', 'revision', 'revision_locked'];
const fingerprint = (row) =>
  createHash('sha256')
    .update(
      JSON.stringify(
        ordered(Object.fromEntries(Object.entries(row).filter(([f]) => !WRITE_FIELDS.includes(f))))
      )
    )
    .digest('hex');
// How long an undone receipt with nothing left to bring back answers a replayed Undo.
const RECEIPT_DAYS = 30;

/** A row as the phone's feed carries it, as the table's routes send it. */
function feedRecord(rule, row) {
  if (rule.feedID) return { ...row, client_id: row[rule.feedID] };
  if (rule.identity) {
    const { identity_key: _identityKey, ...value } = row;
    return value;
  }
  return row;
}

/**
 * The keys a row matches on: its own when it has them, else what it is. A
 * stored row answers to both, so a row restored without a client ID, which
 * got one, still matches the same row restored again.
 */
function matchKeys(rule, row, { stored = false } = {}) {
  const keys = [];
  const has = rule.match.every((field) => row[field] != null && row[field] !== '');
  const key = (fields) => fields.map((field) => matchValue(row[field])).join('|');
  if (rule.match.length && (has || !rule.natural)) keys.push(`own:${key(rule.match)}`);
  if (rule.natural && (stored || !has)) keys.push(`is:${key(rule.natural)}`);
  return keys;
}

/** Restores the server's older tables in the export into the account. Call inside a transaction. */
async function restoreTables(account, body, result, now) {
  const added = [];
  // The deletions earlier Undos made: restoring again brings back exactly
  // those, while they're still at the revision Undo left. A row deleted any
  // other way, or changed since, stays as it is.
  const receipts = await store.find('restores', {
    account_id: account.id,
    undone_at: { ne: null },
  });
  // Read in one go per table: a reference whose row is gone, isn't deleted,
  // or has moved past the revision Undo left is stale, and is dropped.
  const current = new Map();
  const byTable = new Map();
  for (const receipt of receipts)
    for (const ref of receipt.rows)
      byTable.set(ref.table, [...(byTable.get(ref.table) ?? []), ref.id]);
  for (const [table, ids] of byTable) {
    const collection = RESTORABLE[table].collection ?? table;
    for (const filter of ownerFilters(collection, account))
      for (let i = 0; i < ids.length; i += 5000)
        for (const row of await store.find(
          collection,
          { ...filter, id: { in: ids.slice(i, i + 5000) } },
          { includeDeleted: true }
        ))
          current.set(`${table}/${row.id}`, row);
  }
  const live = (ref) => {
    const row = current.get(`${ref.table}/${ref.id}`);
    return !!row?.deleted_at && row.revision === ref.revision;
  };
  const tombstones = new Map();
  for (const receipt of receipts)
    for (const ref of receipt.rows.filter(live))
      tombstones.set(`${ref.table}/${ref.id}`, { receipt, ref });
  const revived = new Set();
  // Each table's rows by their ID in the export, for rows that point at them.
  const ids = {};
  for (const [key, rule] of Object.entries(RESTORABLE)) {
    const collection = rule.collection ?? key;
    const rows = Array.isArray(body[key])
      ? body[key]
      : body[key] && typeof body[key] === 'object'
        ? [body[key]]
        : [];
    if (!rows.length) continue;
    // Deleted rows too: the account's tombstone for a day or ID still holds it.
    const existing = [];
    for (const filter of ownerFilters(collection, account))
      existing.push(...(await store.find(collection, filter, { includeDeleted: true })));
    const have = new Map();
    for (const row of existing)
      for (const k of matchKeys(rule, row, { stored: true })) if (!have.has(k)) have.set(k, row);
    const counts = (result.tables[key] = { restored: 0, kept: 0, skipped: 0 });
    const fields = schema.collections[collection].fields;
    const saved = [];
    const pending = [];
    const origins = { revived: [], pending: [] };
    const mapped = (ids[key] = new Map());
    for (const original of rows) {
      if (!original || typeof original !== 'object' || original.deleted_at) continue;
      let checked;
      try {
        checked = rule.check(original, account);
      } catch (error) {
        counts.skipped += 1;
        result.skipped_count += 1;
        if (result.skipped.length < 50)
          result.skipped.push({ table: key, id: original.id ?? null, reason: error.message });
        continue;
      }
      const row = { ...original, ...checked };
      for (const [field, table] of Object.entries(rule.refs ?? {}))
        row[field] = ids[table]?.get(String(original[field])) ?? null;
      // A single row (goals, program) is kept when the account has its own.
      const match = matchKeys(rule, row)
        .map((k) => have.get(k))
        .find(Boolean);
      const tombstone = match?.deleted_at && tombstones.get(`${key}/${match.id}`);
      const revive = tombstone && tombstone.ref.revision === match.revision ? match : null;
      if (rule.match.length === 0 ? existing.length > 0 : match && !revive) {
        if (match?.id && original.id != null) mapped.set(String(original.id), match.id);
        counts.kept += 1;
        continue;
      }
      if (revive) revived.add(`${key}/${revive.id}`);
      for (const field of ['id', '_id', 'pending_sync', ...OWNERSHIP[collection].keys])
        delete row[field];
      const values = { account_id: account.id, userId: account.id, email: account.email };
      for (const field of OWNERSHIP[collection].keys) row[field] = values[field];
      if (rule.natural && !row.client_id) row.client_id = randomUUID();
      if (rule.identity) row.identity_key = `${account.id}:${row.client_id}`;
      if (fields.revision && !(Number.isInteger(row.revision) && row.revision > 0))
        row.revision = 1;
      if ('updated_at' in original) row.updated_at = now;
      // Revived in place, with a newer revision than its deletion, so a phone takes it.
      if (revive) {
        saved.push(
          await store.update(
            collection,
            { id: revive.id },
            {
              ...row,
              client_id: revive.client_id ?? row.client_id,
              identity_key: revive.identity_key ?? row.identity_key,
              deleted_at: null,
              revision: (revive.revision ?? 1) + 1,
              updated_at: now,
            }
          )
        );
        origins.revived.push(original);
      } else {
        pending.push(row);
        origins.pending.push(original);
      }
      // The same row twice in one file is kept the second time.
      for (const k of matchKeys(rule, row, { stored: true })) have.set(k, row);
    }
    // Added a few hundred rows per statement: one at a time, three years took minutes.
    saved.push(...(await store.insertMany(collection, pending)));
    if (rule.feed && saved.length)
      await sync.changes(
        account,
        saved.map((row) => ({ kind: rule.feed, record: feedRecord(rule, row) }))
      );
    const from = [...origins.revived, ...origins.pending];
    saved.forEach((row, i) => {
      if (from[i].id != null) mapped.set(String(from[i].id), row.id);
    });
    for (const row of saved) {
      added.push({ table: key, id: row.id, fingerprint: fingerprint(row) });
      result.restored.push({ table: key, id: row.id, revision: row.revision ?? null });
    }
    counts.restored += saved.length;
  }
  // A tombstone brought back is spent, and a stale one dropped. An undone
  // receipt with nothing left to bring back is kept a while, to answer a
  // replayed Undo, then removed.
  const cutoff = now.getTime() - RECEIPT_DAYS * 24 * 3600 * 1000;
  for (const receipt of receipts) {
    const left = receipt.rows.filter((ref) => live(ref) && !revived.has(`${ref.table}/${ref.id}`));
    if (!left.length && new Date(receipt.undone_at).getTime() < cutoff)
      await store.remove('restores', { id: receipt.id });
    else if (left.length !== receipt.rows.length)
      await store.update('restores', { id: receipt.id }, { rows: left });
  }
  // What this restore added, so Undo removes exactly those rows.
  if (added.length) {
    const record = await store.insert('restores', {
      account_id: account.id,
      rows: added,
      created_at: now,
    });
    result.restore_id = record.id;
  }
}

async function importExport(account, body, { now = new Date() } = {}) {
  if (!body || typeof body !== 'object' || (!Array.isArray(body.documents) && !body.exported_at)) {
    return { error: 'This is not an Exerly export: it has no documents.' };
  }
  const result = {
    imported: 0,
    kept: 0,
    skipped: [],
    skipped_count: 0,
    tables: {},
    restored: [],
    not_restored: {},
    ignored_tables: [],
  };
  const tables = Object.keys(body).filter(
    (key) =>
      !METADATA.includes(key) &&
      ((Array.isArray(body[key]) && body[key].length) ||
        (body[key] && typeof body[key] === 'object' && !Array.isArray(body[key])))
  );
  for (const key of tables) {
    if (NOT_RESTORED[key]) result.not_restored[key] = NOT_RESTORED[key];
    else if (!RESTORABLE[key]) result.ignored_tables.push(key);
  }
  await store.transaction(async () => {
    await restoreTables(account, body, result, now);
    // The account's documents, deleted ones too, in one read.
    const { rows: present } = await store.query(
      'SELECT kind, document_id FROM documents WHERE account_id = $1',
      [account.id]
    );
    const have = new Set(present.map((row) => `${row.kind}/${row.document_id}`));
    const pending = [];
    for (const row of body.documents ?? []) {
      if (!row || row.deleted_at) continue;
      const kind = String(row.kind ?? '');
      const id = docs.canonicalID(String(row.document_id ?? ''));
      try {
        docs.readKind(kind);
        docs.readID(id);
        const payload = docs.readPayload(kind, id, row.payload);
        if (have.has(`${kind}/${id}`)) {
          result.kept += 1;
          continue;
        }
        have.add(`${kind}/${id}`);
        pending.push({
          account_id: account.id,
          kind,
          document_id: id,
          revision: Number.isInteger(row.revision) && row.revision > 0 ? row.revision : 1,
          payload,
          deleted_at: null,
          created_at: now,
          updated_at: now,
        });
      } catch (error) {
        result.skipped_count += 1;
        if (result.skipped.length < 50) result.skipped.push({ kind, id, reason: error.message });
      }
    }
    await docs.records(account, await store.insertMany('documents', pending));
    result.imported = pending.length;
    if (result.imported || result.restored.length) {
      await docs.appendAudit(account, {
        action: 'directWrite',
        actor: { kind: 'builtIn', name: 'Exerly import' },
        targets: [],
        note:
          `Imported ${result.imported} documents and restored ${result.restored.length} older rows ` +
          `from an export made ${body.exported_at ?? 'at an unknown time'}.`,
      });
    }
  });
  return result;
}

/**
 * Undoes a restore of older tables: removes the rows that restore added,
 * unless they changed since. Only rows the server recorded for this restore
 * of this account; `rows`, when sent, must be among them. All or nothing.
 * Rows a phone syncs leave a deletion in its feed, as a delete from the app
 * would. Undoing again answers with what the first Undo did and
 * `already_undone`, so a phone that lost the answer can finish its own part.
 * The receipt then keeps only the deletions a later restore may bring back.
 */
async function undoRestore(account, body) {
  const restoreID = body?.restore_id;
  if (typeof restoreID !== 'string' || !restoreID)
    return { error: 'Send the restore_id the import returned.' };
  if (body.rows != null && !Array.isArray(body.rows))
    return { error: 'rows must be the rows the import restored.' };
  let result = { removed: 0, kept: 0 };
  await store.transaction(async () => {
    const record = UUID.test(restoreID)
      ? await store.findOne('restores', { id: restoreID, account_id: account.id })
      : null;
    if (!record) throw notFound('That restore isn’t in this account.');
    if (record.undone_at) {
      result = { ...(record.outcome ?? { removed: 0, kept: 0 }), already_undone: true };
      return;
    }
    let refs = record.rows;
    if (body.rows) {
      const ids = new Map(record.rows.map((ref) => [`${ref.table}/${ref.id}`, ref]));
      refs = body.rows.map((ref) => {
        const known = ids.get(`${ref?.table}/${ref?.id}`);
        if (!known) throw badRequest(`Not a row this restore added: ${ref?.table} ${ref?.id}`);
        return known;
      });
    }
    const now = new Date();
    const tombstones = [];
    const tables = new Map();
    for (const ref of refs) tables.set(ref.table, [...(tables.get(ref.table) ?? []), ref]);
    // Read, removed and reported table by table, not row by row.
    for (const [table, list] of tables) {
      const rule = RESTORABLE[table];
      const collection = rule.collection ?? table;
      const rows = new Map();
      for (const filter of ownerFilters(collection, account)) {
        for (let i = 0; i < list.length; i += 5000) {
          const id = { in: list.slice(i, i + 5000).map((ref) => ref.id) };
          const found = await store.find(collection, { ...filter, id }, { includeDeleted: true });
          for (const row of found) rows.set(row.id, row);
        }
      }
      const gone = [];
      for (const ref of list) {
        const current = rows.get(ref.id);
        if (!current || current.deleted_at) continue;
        if (fingerprint(current) !== ref.fingerprint) result.kept += 1;
        else gone.push({ ...current, deleted_at: now, revision: (current.revision ?? 1) + 1 });
      }
      if (!gone.length) continue;
      if (schema.collections[collection].fields.deleted_at) {
        // Marked deleted, a revision on, as a delete from the app would be.
        const revisions = new Set(gone.map((row) => row.revision));
        for (const revision of revisions) {
          const ids = gone.filter((row) => row.revision === revision).map((row) => row.id);
          for (let i = 0; i < ids.length; i += 5000)
            await store.updateMany(
              collection,
              { id: { in: ids.slice(i, i + 5000) } },
              { deleted_at: now, updated_at: now, revision }
            );
        }
        for (const row of gone) {
          row.updated_at = now;
          tombstones.push({ table, id: row.id, revision: row.revision });
        }
      } else {
        const ids = gone.map((row) => row.id);
        for (let i = 0; i < ids.length; i += 5000)
          await store.remove(collection, { id: { in: ids.slice(i, i + 5000) } });
      }
      if (rule.feed)
        await sync.changes(
          account,
          gone.map((row) => ({ kind: rule.feed, record: feedRecord(rule, row) }))
        );
      result.removed += gone.length;
    }
    await store.update(
      'restores',
      { id: record.id },
      { undone_at: now, outcome: result, rows: tombstones }
    );
  });
  return result;
}

module.exports = { FILES, cell, exportCSV, importExport, undoRestore, RESTORABLE, NOT_RESTORED };
