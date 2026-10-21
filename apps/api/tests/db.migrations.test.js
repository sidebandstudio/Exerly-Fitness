// Migration behaviour on real PostgreSQL, each case in its own schema.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { Client } = require('pg');
const { connectionConfig } = require('../data/postgres');
const { collections } = require('../data/schema');
const { loadMigrations, migrateUp, migrateDown, status, DIRECTORY } = require('../db/migrate');

const url = process.env.EXERLY_TEST_DATABASE_URL;
const schemas = [];

async function client(schema) {
  const c = new Client(connectionConfig(url, { schema }));
  await c.connect();
  return c;
}

async function freshSchema() {
  const schema = `mig_${process.pid}_${schemas.length}_${Math.random().toString(36).slice(2, 6)}`;
  const admin = new Client(connectionConfig(url));
  await admin.connect();
  await admin.query(`CREATE SCHEMA ${schema}`);
  await admin.end();
  schemas.push(schema);
  return schema;
}

async function tables(c) {
  const { rows } = await c.query(
    `SELECT table_name FROM information_schema.tables WHERE table_schema = current_schema() ORDER BY 1`
  );
  return rows.map((r) => r.table_name);
}

test.after(async () => {
  const admin = new Client(connectionConfig(url));
  await admin.connect();
  for (const schema of schemas) await admin.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);
  await admin.end();
});

test('applies, reapplies as a no-op, rolls back and reapplies', async () => {
  const c = await client(await freshSchema());
  try {
    const all = loadMigrations().map((m) => m.version);
    assert.deepEqual(await migrateUp(c), all);
    assert.deepEqual(await migrateUp(c), []);
    assert.ok((await status(c)).every((m) => m.applied));
    assert.ok((await tables(c)).includes('users'));

    assert.deepEqual(await migrateDown(c, all.length), [...all].reverse());
    assert.deepEqual(await tables(c), ['schema_migrations']);

    assert.deepEqual(await migrateUp(c), all);
    assert.ok((await tables(c)).includes('food'));
  } finally {
    await c.end();
  }
});

test('the schema matches the field registry exactly', async () => {
  const c = await client(await freshSchema());
  try {
    await migrateUp(c);
    for (const [name, def] of Object.entries(collections)) {
      const { rows } = await c.query(
        `SELECT column_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1`,
        [name]
      );
      const columns = rows.map((r) => r.column_name).sort();
      const expected = ['id', 'seq', ...Object.keys(def.fields)].sort();
      assert.deepEqual(columns, expected, name);
    }
  } finally {
    await c.end();
  }
});

test('refuses to run when an applied migration was edited or is unknown', async () => {
  const c = await client(await freshSchema());
  const copy = fs.mkdtempSync(path.join(os.tmpdir(), 'exerly-migrations-'));
  try {
    await migrateUp(c);
    for (const file of fs.readdirSync(DIRECTORY)) {
      fs.copyFileSync(path.join(DIRECTORY, file), path.join(copy, file));
    }
    fs.appendFileSync(path.join(copy, '0001_initial.up.sql'), '\n-- edited\n');
    await assert.rejects(migrateUp(c, loadMigrations(copy)), /was edited after it ran/);

    await c.query(
      `INSERT INTO schema_migrations (version, name, checksum) VALUES (999, 'future', 'x')`
    );
    await assert.rejects(migrateUp(c), /does not know/);
  } finally {
    fs.rmSync(copy, { recursive: true, force: true });
    await c.end();
  }
});

test('concurrent starts apply each migration exactly once', async () => {
  const schema = await freshSchema();
  const clients = await Promise.all(Array.from({ length: 6 }, () => client(schema)));
  try {
    const results = await Promise.all(clients.map((c) => migrateUp(c)));
    const applied = results.flat();
    assert.deepEqual(
      applied.sort((a, b) => a - b),
      loadMigrations().map((m) => m.version)
    );
    const { rows } = await clients[0].query('SELECT count(*)::int AS n FROM schema_migrations');
    assert.equal(rows[0].n, loadMigrations().length);
  } finally {
    await Promise.all(clients.map((c) => c.end()));
  }
});

test('a failing migration leaves no partial change behind', async () => {
  const c = await client(await freshSchema());
  const copy = fs.mkdtempSync(path.join(os.tmpdir(), 'exerly-migrations-'));
  try {
    for (const file of fs.readdirSync(DIRECTORY)) {
      fs.copyFileSync(path.join(DIRECTORY, file), path.join(copy, file));
    }
    const next = String(loadMigrations().length + 1).padStart(4, '0');
    fs.writeFileSync(
      path.join(copy, `${next}_broken.up.sql`),
      'CREATE TABLE half_done (id int);\nSELECT 1/0;\n'
    );
    fs.writeFileSync(path.join(copy, `${next}_broken.down.sql`), 'DROP TABLE half_done;\n');
    await assert.rejects(migrateUp(c, loadMigrations(copy)), /division by zero/);
    assert.ok(!(await tables(c)).includes('half_done'));
    assert.equal((await status(c)).filter((m) => m.applied).length, loadMigrations().length);
  } finally {
    fs.rmSync(copy, { recursive: true, force: true });
    await c.end();
  }
});
