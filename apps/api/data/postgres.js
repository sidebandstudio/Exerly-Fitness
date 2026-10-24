// PostgreSQL driver for the storage adapter.
//
// Tables come from the SQL files in db/migrations, applied at connect. Every
// row has a UUID `id` and a `seq` identity that keeps insertion order, which
// is what sorting by id means to callers.
//
// A transaction checks out one connection and runs SERIALIZABLE. Work called
// inside it joins it through AsyncLocalStorage. Serialization failures,
// deadlocks and first-insert unique races are retried from the start, so
// transaction bodies must only touch the database.

const { Pool } = require('pg');
const { AsyncLocalStorage } = require('node:async_hooks');
const { collections, JSON_FIELDS, assertCollection, types } = require('./schema');
const { normalizeFilter, normalizeOptions, normalizePatch } = require('./query');
const { migrateUp } = require('../db/migrate');

const RETRYABLE = new Set(['40001', '40P01', '23505']);
const MAX_ATTEMPTS = 6;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SCHEMA_RE = /^[a-z_][a-z0-9_]{0,62}$/;

let pool = null;
const scope = new AsyncLocalStorage();

/**
 * pg settings for a connection string. Remote hosts require verified TLS
 * unless DATABASE_SSL=disable (a private Compose network, for example).
 */
function connectionConfig(connectionString, { schema } = {}) {
  if (!connectionString) throw new Error('A PostgreSQL connection string is required');
  const url = new URL(connectionString);
  const host = url.searchParams.get('host') || url.hostname;
  const local = !host || host.startsWith('/') || ['localhost', '127.0.0.1', '::1'].includes(host);
  url.searchParams.delete('sslmode');
  const config = {
    connectionString: url.toString(),
    ssl: local || process.env.DATABASE_SSL === 'disable' ? false : { rejectUnauthorized: true },
    max: Number(process.env.PG_POOL_MAX) || 5,
    idleTimeoutMillis: 30_000,
  };
  if (schema) {
    if (!SCHEMA_RE.test(schema)) throw new Error('Invalid schema name');
    config.options = `-c search_path=${schema}`;
  }
  return config;
}

/** Host and database for logs; never the credentials. */
function describe(connectionString) {
  const url = new URL(connectionString);
  return `${url.searchParams.get('host') || url.hostname}${url.pathname}`;
}

async function connect({ connectionString = process.env.DATABASE_URL, schema } = {}) {
  const config = connectionConfig(connectionString, { schema });
  if (schema) {
    const { Client } = require('pg');
    const admin = new Client({ ...config, options: undefined });
    await admin.connect();
    await admin.query(`CREATE SCHEMA IF NOT EXISTS ${schema}`);
    await admin.end();
  }
  pool = new Pool(config);
  pool.on('error', () => {}); // Idle client errors surface on the next query.
  const client = await pool.connect();
  try {
    await migrateUp(client);
  } finally {
    client.release();
  }
  return { driver: 'postgres', target: describe(connectionString) };
}

async function disconnect() {
  if (!pool) return;
  const closing = pool;
  pool = null;
  await closing.end();
}

function query(sql, params = []) {
  const client = scope.getStore()?.client || pool;
  if (!client) throw new Error('Database is not connected');
  return client.query(sql, params);
}

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function transaction(fn) {
  if (scope.getStore()) return fn();
  for (let attempt = 1; ; attempt++) {
    const client = await pool.connect();
    try {
      await client.query('BEGIN ISOLATION LEVEL SERIALIZABLE');
      const result = await scope.run({ client }, fn);
      await client.query('COMMIT');
      return result;
    } catch (error) {
      await client.query('ROLLBACK').catch(() => {});
      if (attempt < MAX_ATTEMPTS && RETRYABLE.has(error.code)) {
        // Exponential backoff with jitter spreads out transactions that keep colliding.
        await delay(Math.random() * 5 * 2 ** attempt);
        continue;
      }
      throw error;
    } finally {
      client.release();
    }
  }
}

/** True for errors a fresh transaction may resolve. */
function isRetryable(error) {
  return RETRYABLE.has(error?.code);
}

// ---------- row <-> document ----------

function toColumn(collection, field, value) {
  const type = assertCollection(collection).fields[field];
  if (value === undefined) return undefined;
  if (value === null) return null;
  switch (type) {
    case types.json:
      return JSON.stringify(value);
    case types.bool:
      return Boolean(value);
    case types.date: {
      const date = value instanceof Date ? value : new Date(value);
      return Number.isNaN(date.getTime()) ? null : date;
    }
    case types.num: {
      const number = Number(value);
      return Number.isNaN(number) ? null : number;
    }
    case types.str:
      return String(value);
    default:
      return value;
  }
}

function fromRow(collection, row) {
  if (!row) return null;
  const def = assertCollection(collection);
  const doc = {};
  for (const field of Object.keys(def.fields)) {
    if (row[field] !== undefined) doc[field] = row[field];
  }
  // Both keys are populated because the native client reads `_id`.
  doc.id = row.id;
  doc._id = row.id;
  return doc;
}

// ---------- filter compilation ----------

const OP_SQL = { eq: '=', ne: '<>', gt: '>', gte: '>=', lt: '<', lte: '<=' };

// Field names are validated against the schema registry; quoting keeps the
// case of legacy camelCase columns.
const q = (field) => `"${field}"`;

function compileFilter(collection, filter, params = []) {
  const parts = [];
  const bind = (value) => {
    params.push(value);
    return `$${params.length}`;
  };
  for (const { field, op, value } of normalizeFilter(filter)) {
    const isID = field === 'id' || field === '_id';
    const column = isID ? 'id' : q(field);
    if (!isID && !(field in assertCollection(collection).fields)) {
      throw new Error(`Unknown field ${collection}.${field}`);
    }
    const encode = (v) => (isID ? String(v) : toColumn(collection, field, v));
    // A malformed id matches nothing rather than raising a cast error.
    const validID = (v) => !isID || (v != null && UUID_RE.test(String(v)));

    if (op === 'in' || op === 'nin') {
      const values = value.filter(validID).map(encode);
      if (values.length === 0) parts.push(op === 'in' ? 'FALSE' : 'TRUE');
      else
        parts.push(`${column} ${op === 'in' ? 'IN' : 'NOT IN'} (${values.map(bind).join(', ')})`);
    } else if (op === 'like') {
      const escaped = String(value).replace(/[\\%_]/g, (c) => `\\${c}`);
      parts.push(`${column} ILIKE ${bind(`%${escaped}%`)}`);
    } else if (op === 'exists') {
      parts.push(value ? `${column} IS NOT NULL` : `${column} IS NULL`);
    } else if (value === null) {
      parts.push(op === 'ne' ? `${column} IS NOT NULL` : `${column} IS NULL`);
    } else if (!validID(value)) {
      parts.push(op === 'ne' ? 'TRUE' : 'FALSE');
    } else {
      parts.push(`${column} ${OP_SQL[op]} ${bind(encode(value))}`);
    }
  }
  return { where: parts.length ? `WHERE ${parts.join(' AND ')}` : '', params };
}

function compileOptions(options) {
  const { sort, limit, skip } = normalizeOptions(options);
  const order = sort.length
    ? sort.map(
        (s) =>
          `${s.field === 'id' || s.field === '_id' ? 'seq' : q(s.field)} ${s.dir < 0 ? 'DESC' : 'ASC'}`
      )
    : ['seq ASC'];
  return [
    `ORDER BY ${order.join(', ')}`,
    limit != null ? `LIMIT ${limit}` : '',
    skip ? `OFFSET ${skip}` : '',
  ]
    .filter(Boolean)
    .join(' ');
}

function knownFields(collection, doc) {
  const def = assertCollection(collection);
  return Object.keys(doc).filter((f) => f in def.fields && doc[f] !== undefined);
}

// ---------- operations ----------

async function insert(collection, doc) {
  const fields = knownFields(collection, doc);
  if (fields.length === 0) throw new Error(`insert(${collection}) had no known fields`);
  const params = fields.map((f) => toColumn(collection, f, doc[f]));
  const { rows } = await query(
    `INSERT INTO ${collection} (${fields.map(q).join(', ')}) VALUES (${params.map((_, i) => `$${i + 1}`).join(', ')}) RETURNING *`,
    params
  );
  return fromRow(collection, rows[0]);
}

/**
 * Inserts rows a few hundred at a time, one statement each, and returns them
 * in the order given. A field a row leaves out gets the column's default.
 */
async function insertMany(collection, docs) {
  const out = [];
  let start = 0;
  while (start < docs.length) {
    const fields = [];
    let end = start;
    // Postgres takes at most 65,535 parameters per statement.
    while (end < docs.length) {
      const next = [...new Set([...fields, ...knownFields(collection, docs[end])])];
      if (end > start && next.length * (end - start + 1) > 30000) break;
      fields.splice(0, fields.length, ...next);
      end += 1;
    }
    if (fields.length === 0) throw new Error(`insertMany(${collection}) had no known fields`);
    const params = [];
    const values = docs.slice(start, end).map(
      (doc) =>
        `(${fields
          .map((f) => {
            if (doc[f] === undefined) return 'DEFAULT';
            params.push(toColumn(collection, f, doc[f]));
            return `$${params.length}`;
          })
          .join(', ')})`
    );
    const { rows } = await query(
      `INSERT INTO ${collection} (${fields.map(q).join(', ')}) VALUES ${values.join(', ')} RETURNING *`,
      params
    );
    rows.sort((a, b) => Number(a.seq) - Number(b.seq));
    out.push(...rows.map((row) => fromRow(collection, row)));
    start = end;
  }
  return out;
}

async function findById(collection, id) {
  assertCollection(collection);
  if (!UUID_RE.test(String(id))) return null;
  const { rows } = await query(`SELECT * FROM ${collection} WHERE id = $1`, [String(id)]);
  return fromRow(collection, rows[0]);
}

async function find(collection, filter = {}, options = {}) {
  const { where, params } = compileFilter(collection, filter);
  const { rows } = await query(
    `SELECT * FROM ${collection} ${where} ${compileOptions(options)}`,
    params
  );
  return rows.map((row) => fromRow(collection, row));
}

async function findOne(collection, filter = {}, options = {}) {
  return (await find(collection, filter, { ...options, limit: 1 }))[0] || null;
}

function compileSet(collection, patch, params) {
  const clean = normalizePatch(patch, JSON_FIELDS[collection]);
  const fields = knownFields(collection, clean);
  const sets = fields.map((f) => {
    params.push(toColumn(collection, f, clean[f]));
    return `${q(f)} = $${params.length}`;
  });
  return sets.join(', ');
}

/** Updates the first matching row. Returns it, or null when none matched. */
async function update(collection, filter, patch) {
  const params = [];
  const sets = compileSet(collection, patch, params);
  const { where } = compileFilter(collection, filter, params);
  const target = `SELECT id FROM ${collection} ${where} ORDER BY seq LIMIT 1`;
  if (!sets) {
    const { rows } = await query(`SELECT * FROM ${collection} WHERE id = (${target})`, params);
    return fromRow(collection, rows[0]);
  }
  const { rows } = await query(
    `UPDATE ${collection} SET ${sets} WHERE id = (${target}) RETURNING *`,
    params
  );
  return fromRow(collection, rows[0]);
}

async function updateMany(collection, filter, patch) {
  const params = [];
  const sets = compileSet(collection, patch, params);
  if (!sets) return 0;
  const { where } = compileFilter(collection, filter, params);
  const { rowCount } = await query(`UPDATE ${collection} SET ${sets} ${where}`, params);
  return rowCount;
}

async function upsert(collection, filter, patch) {
  return transaction(async () => {
    const existing = await findOne(collection, filter);
    if (existing) return update(collection, { id: existing.id }, patch);
    // The filter's equality clauses seed the row so the same filter finds it.
    const seed = {};
    for (const { field, op, value } of normalizeFilter(filter)) {
      if (op === 'eq' && field !== 'id' && field !== '_id') seed[field] = value;
    }
    return insert(collection, { ...seed, ...patch });
  });
}

async function increment(collection, filter, field, amount) {
  if (!(field in assertCollection(collection).fields)) {
    throw new Error(`Unknown field ${collection}.${field}`);
  }
  return transaction(async () => {
    const existing = await findOne(collection, filter);
    const next = (existing ? Number(existing[field]) || 0 : 0) + Number(amount || 0);
    return upsert(collection, filter, { [field]: next });
  });
}

async function removeOne(collection, filter) {
  const { where, params } = compileFilter(collection, filter);
  const { rows } = await query(
    `DELETE FROM ${collection} WHERE id = (SELECT id FROM ${collection} ${where} ORDER BY seq LIMIT 1) RETURNING *`,
    params
  );
  return fromRow(collection, rows[0]);
}

async function remove(collection, filter) {
  const { where, params } = compileFilter(collection, filter);
  const { rowCount } = await query(`DELETE FROM ${collection} ${where}`, params);
  return rowCount;
}

async function count(collection, filter = {}) {
  const { where, params } = compileFilter(collection, filter);
  const { rows } = await query(`SELECT COUNT(*)::int AS n FROM ${collection} ${where}`, params);
  return rows[0].n;
}

async function distinct(collection, field, filter = {}) {
  if (!(field in assertCollection(collection).fields)) {
    throw new Error(`Unknown field ${collection}.${field}`);
  }
  const { where, params } = compileFilter(collection, filter);
  const { rows } = await query(
    `SELECT DISTINCT ${q(field)} AS v FROM ${collection} ${where}`,
    params
  );
  return rows.map((r) => r.v).filter((v) => v != null);
}

// SUM(field) per distinct value of groupField. Returns [{ key, n, <field>: total }].
async function sumBy(collection, filter, groupField, sumFields) {
  const def = assertCollection(collection);
  const fields = Array.isArray(sumFields) ? sumFields : [sumFields];
  for (const f of [groupField, ...fields]) {
    if (!(f in def.fields)) throw new Error(`Unknown field ${collection}.${f}`);
  }
  const { where, params } = compileFilter(collection, filter);
  const sums = fields.map((f) => `COALESCE(SUM(${q(f)}), 0) AS ${q(f)}`).join(', ');
  const { rows } = await query(
    `SELECT ${q(groupField)} AS key, ${sums}, COUNT(*)::int AS n FROM ${collection} ${where} GROUP BY ${q(groupField)}`,
    params
  );
  return rows.map((r) => {
    const out = { key: r.key, n: r.n };
    fields.forEach((f) => (out[f] = Number(r[f]) || 0));
    return out;
  });
}

module.exports = {
  name: 'postgres',
  connect,
  disconnect,
  isReady: () => pool != null,
  connectionConfig,
  query,
  insert,
  insertMany,
  find,
  findOne,
  findById,
  update,
  updateMany,
  upsert,
  increment,
  remove,
  removeOne,
  count,
  distinct,
  sumBy,
  transaction,
  isRetryable,
  collections,
};
