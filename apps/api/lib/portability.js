// Data that can leave and come back. CSV files for spreadsheets, one per kind
// of data, and an import that restores an Exerly JSON export (/api/export)
// into an account. PARITY I14; see docs/design/022-export-import.md.

const store = require('../data');
const docs = require('./documents');
const sync = require('./sync');
const { OWNERSHIP, ownerFilters } = require('./ownership');
const { NUTRIENTS, NUTRIENT_UNITS } = require('./nutrition/validate');
const { badRequest } = require('./errors');

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
// The server's older tables an export restores, each with the fields that
// tell whether the account already has a row, so restoring twice adds nothing.
// Rows get the importing account as owner and new IDs. Tables a phone syncs
// get a change in its feed, so the phone sees them.
const RESTORABLE = {
  diary_days: { match: ['entry_date'], feed: 'diary_day' },
  target_versions: { match: ['effective_date'] },
  measurements: { match: ['client_id'], feed: 'measurement' },
  activities: { match: ['client_id'], feed: 'activity' },
  food: { match: ['client_id'], feed: 'food' },
  sleep: { match: ['client_id'], feed: 'sleep' },
  weights: { match: ['entry_date', 'weight_kg'], feed: 'weight' },
  water: { match: ['entry_date'], feed: 'water' },
  goals: { collection: 'goals', match: [] },
  program: { collection: 'programs', match: [] },
  checkins: { match: ['entry_date'] },
  library_foods: { match: ['name', 'brand', 'barcode'] },
  recipes: { match: ['name', 'created_at'] },
  workouts: { match: ['name', 'created_at'] },
  ai_plans: { match: ['type', 'createdAt'] },
};
// Exported but never restored into another account, and why.
const NOT_RESTORED = {
  account_identities: 'Sign-in methods belong to the account they were set up for.',
  webhooks:
    'Webhooks would send this account’s data to addresses set up elsewhere, and their secrets aren’t exported.',
  onboarding_drafts: 'A setup draft belongs to the account being set up.',
};
const METADATA = ['documents', 'account', 'exported_at', 'version', 'source', 'note', 'context'];

/** A value as a match key: dates and numbers as text, so a JSON row and a stored row compare equal. */
const matchValue = (value) =>
  value instanceof Date ? value.toISOString() : value == null ? '' : String(value);

/** Restores the server's older tables in the export into the account. Call inside a transaction. */
async function restoreTables(account, body, result, now) {
  for (const [key, rule] of Object.entries(RESTORABLE)) {
    const collection = rule.collection ?? key;
    const rows = Array.isArray(body[key])
      ? body[key]
      : body[key] && typeof body[key] === 'object'
        ? [body[key]]
        : [];
    if (!rows.length) continue;
    const owners = ownerFilters(collection, account);
    const existing = [];
    for (const filter of owners) existing.push(...(await store.find(collection, filter)));
    const keyOf = (row) => rule.match.map((field) => matchValue(row[field])).join('|');
    const have = new Set(existing.map(keyOf));
    const counts = (result.tables[key] = { restored: 0, kept: 0 });
    for (const original of rows) {
      if (!original || typeof original !== 'object' || original.deleted_at) continue;
      // A single row (goals, program) is kept when the account has its own.
      if (rule.match.length === 0 ? existing.length > 0 : have.has(keyOf(original))) {
        counts.kept += 1;
        continue;
      }
      const row = { ...original };
      for (const field of ['id', '_id', 'pending_sync', ...OWNERSHIP[collection].keys])
        delete row[field];
      const values = { account_id: account.id, userId: account.id, email: account.email };
      for (const field of OWNERSHIP[collection].keys) row[field] = values[field];
      if ('updated_at' in original) row.updated_at = now;
      const inserted = await store.insert(collection, row);
      if (rule.feed) await sync.change(account, rule.feed, inserted);
      have.add(keyOf(original));
      result.restored.push({ table: key, id: inserted.id, revision: inserted.revision ?? null });
      counts.restored += 1;
    }
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
    for (const row of body.documents ?? []) {
      if (!row || row.deleted_at) continue;
      const kind = String(row.kind ?? '');
      const id = docs.canonicalID(String(row.document_id ?? ''));
      try {
        docs.readKind(kind);
        docs.readID(id);
        const payload = docs.readPayload(kind, id, row.payload);
        if (await docs.current(account, kind, id)) {
          result.kept += 1;
          continue;
        }
        const inserted = await store.insert('documents', {
          account_id: account.id,
          kind,
          document_id: id,
          revision: Number.isInteger(row.revision) && row.revision > 0 ? row.revision : 1,
          payload,
          deleted_at: null,
          created_at: now,
          updated_at: now,
        });
        await docs.record(account, inserted);
        result.imported += 1;
      } catch (error) {
        if (result.skipped.length < 50) result.skipped.push({ kind, id, reason: error.message });
      }
    }
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
 * Undoes a restore of older tables: removes the rows it returned in `restored`,
 * unless they changed since. All or nothing. Rows a phone syncs are marked
 * deleted, with a change in the feed, as a delete from the app would be.
 */
async function undoRestore(account, rows) {
  if (!Array.isArray(rows)) return { error: 'Send the rows the import restored.' };
  const result = { removed: 0, kept: 0 };
  await store.transaction(async () => {
    for (const ref of rows) {
      const rule = RESTORABLE[ref?.table];
      if (!rule) throw badRequest(`Not a restored table: ${ref?.table}`);
      const collection = rule.collection ?? ref.table;
      let current = null;
      for (const filter of ownerFilters(collection, account)) {
        current = current ?? (await store.findOne(collection, { ...filter, id: String(ref.id) }));
      }
      if (!current || current.deleted_at) continue;
      if (ref.revision != null && current.revision !== ref.revision) {
        result.kept += 1;
        continue;
      }
      if ('deleted_at' in current) {
        const deleted = await store.update(
          collection,
          { id: current.id },
          { deleted_at: new Date(), updated_at: new Date(), revision: (current.revision ?? 1) + 1 }
        );
        if (rule.feed) await sync.change(account, rule.feed, deleted);
      } else {
        await store.remove(collection, { id: current.id });
        if (rule.feed)
          await sync.change(account, rule.feed, { ...current, deleted_at: new Date() });
      }
      result.removed += 1;
    }
  });
  return result;
}

module.exports = { FILES, cell, exportCSV, importExport, undoRestore, RESTORABLE, NOT_RESTORED };
