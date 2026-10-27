// TLS settings for database connections. None of these need a database.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const tls = require('node:tls');
const { X509Certificate } = require('node:crypto');
const { connectionConfig } = require('../data/postgres');

const SUPABASE_CA = fs.readFileSync(
  path.join(__dirname, '../data/supabase-prod-ca-2021.crt'),
  'utf8'
);
const url = (host) => `postgresql://user:password@${host}:5432/postgres`;

test('the bundled Supabase root is the one Supabase publishes', () => {
  const cert = new X509Certificate(SUPABASE_CA);
  assert.ok(cert.ca);
  assert.match(cert.subject, /^CN=Supabase Root 2021 CA$/m);
  assert.equal(
    cert.fingerprint256,
    '80:70:25:AD:50:D4:ED:21:9D:2C:9C:7D:29:9C:00:4F:82:4E:B0:0C:F7:F6:5A:FE:F6:07:D0:7B:72:E6:CA:FA'
  );
});

test("Supabase hosts trust Supabase's root and the usual roots, with verification on", () => {
  for (const host of ['aws-0-us-east-1.pooler.supabase.com', 'db.abcdefghijklmnop.supabase.co']) {
    const { ssl } = connectionConfig(url(host));
    assert.equal(ssl.rejectUnauthorized, true);
    assert.ok(ssl.ca.includes(SUPABASE_CA));
    assert.ok(tls.rootCertificates.every((root) => ssl.ca.includes(root)));
  }
});

test("other hosts, lookalikes included, keep Node's default roots", () => {
  for (const host of ['db.example.com', 'supabase.com.example.net', 'notsupabase.com']) {
    assert.deepEqual(connectionConfig(url(host)).ssl, { rejectUnauthorized: true });
  }
});

test('DATABASE_SSL=disable still turns TLS off, Supabase or not', (t) => {
  const previous = process.env.DATABASE_SSL;
  process.env.DATABASE_SSL = 'disable';
  t.after(() => {
    if (previous === undefined) delete process.env.DATABASE_SSL;
    else process.env.DATABASE_SSL = previous;
  });
  assert.equal(connectionConfig(url('aws-0-us-east-1.pooler.supabase.com')).ssl, false);
});
