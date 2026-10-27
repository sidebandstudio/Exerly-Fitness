# Database operations

The API uses PostgreSQL 16 or later through `DATABASE_URL`.

## Supabase

Production's database is a Supabase project. The API runs on DigitalOcean and treats
Supabase as an ordinary PostgreSQL server. It doesn't use Supabase Auth, the client
libraries or the Data API.

- **Connection string.** Use the shared pooler in session mode, copied from the
  project's Connect dialog:
  `postgresql://postgres.[PROJECT-REF]:[PASSWORD]@aws-[N]-[REGION].pooler.supabase.com:5432/postgres`.
  The direct connection (`db.[PROJECT-REF].supabase.co`) answers only over IPv6 unless
  the project pays for the IPv4 add-on. Don't use the transaction pooler on port 6543.
  The migrator holds a session-level advisory lock across several transactions, and
  that pooler can run each transaction on a different server connection.
- **TLS.** Supabase's certificates chain to its own root CA, which Node doesn't ship.
  For `*.supabase.com` and `*.supabase.co` hosts the API also trusts
  `data/supabase-prod-ca-2021.crt`, and it still verifies every certificate. That root
  expires on 2031-04-26. Leave `DATABASE_SSL` unset.
- **Data API off.** Supabase's Data API serves the tables in `public` to anyone with
  the project's anon or publishable key, unless row-level security stops them. These
  tables don't use row-level security, so turn the Data API off under Integrations,
  Data API, Enable Data API. Once it's off, the generated REST endpoints stop
  answering.
- **Connections.** Each API instance opens at most `PG_POOL_MAX` connections (default
  5). During a deploy the old and new instances overlap, so keep twice that under the
  pool size in the project's database settings.

## Migrations

`migrations/` holds numbered pairs: `NNNN_name.up.sql` and `NNNN_name.down.sql`.

- The server applies pending up migrations at startup, before it listens.
- Each migration runs in its own transaction.
- A per-schema advisory lock means only one starting instance migrates.
- Applied versions and checksums live in `schema_migrations`. The server refuses to
  start if an applied migration was edited, or if the database has a version this
  code doesn't know.

Never edit an applied migration; add a new one. Commands, with `DATABASE_URL` set:

```sh
npm run migrate -w apps/api -- status
npm run migrate -w apps/api -- up
npm run migrate -w apps/api -- down 1   # operator rollback; the server never rolls back
```

Roll back the code first and the schema second, and only when the down script is safe
for the data in place.

## Backups

Supabase backs up a Pro project once a day and keeps the last 7 days. Point-in-time
recovery is a paid add-on that needs at least the Small compute size. For a portable
copy, or before a risky migration, use a `pg_dump` at least as new as the project's
PostgreSQL:

```sh
pg_dump --dbname "$DATABASE_URL" --format custom --file exerly-$(date +%F).dump
createdb exerly_restore
pg_restore --dbname postgresql://.../exerly_restore --no-owner --exit-on-error exerly-$(date +%F).dump
```

`tests/db.backup.test.js` runs this round trip on synthetic data and compares every
row.

Dumps contain personal data. Keep them encrypted, out of the repository, and delete
them when no longer needed.

## Tests

`npm test -w apps/api` starts a throwaway cluster on a Unix socket (no TCP port) and
gives each test file its own schema. In CI, `EXERLY_TEST_DATABASE_URL` points at the
service container instead. Tests never read `DATABASE_URL`.
