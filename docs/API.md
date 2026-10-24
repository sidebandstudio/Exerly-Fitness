# Exerly API reference

Base URL is `http://localhost:3001` in development and the DigitalOcean app in
production. Everything except `/ping`, `/api/health`, `/signup`, and `/login`
needs `Authorization: Bearer <token>`, except `/auth/token`, which uses a refresh credential.

## Conventions

**Dates.** `entry_date` is a `YYYY-MM-DD` calendar day in the user's timezone,
not UTC. Send one to log to any past day; omit it and the server uses today in
that user's zone. Future dates are rejected.

**Timezone.** The stored `timezone` on the account wins. Clients should also send
`X-Timezone: America/Detroit` so a brand new account behaves correctly before any
setting has been saved.

**Units.** Weight is kilograms, height is centimetres, water is millilitres.
Imperial display is a client concern.

**Identifiers.** Every document comes back with `id` and `_id` set to the same
string, whichever driver produced it.

**Errors.** `{ "message": "..." }` with the right status. Unexpected failures
return a generic message in production and include the stack in development.

**Operations.** Send a UUID in `Idempotency-Key` for mutations. The server commits the acknowledgement and data in one transaction. Retrying the same method, URL, body and `If-Match` returns that acknowledgement. Reusing the key for different content returns 409. Keys are scoped to the stable account ID and currently retained until account deletion. Clients must keep their key and body through an interrupted response.

## Auth

| Method | Path                    | Notes                                                                                                                                                                                                                                         |
| ------ | ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| POST   | `/signup`               | `{name, email, password, timezone?}` → `{token, user}`. Password must be 8+ characters. 5 per hour per IP and 5 per hour per email; a 409 says the email has an account (DECISIONS.md)                                                        |
| POST   | `/login`                | `{email, password}` → `{token, user}`. 8 attempts per 10 minutes per IP; 10 wrong passwords per email per network (/24 or /56) per 15 minutes; past the third wrong password for an email, every sign-in to it waits, doubling to at most 2 s |
| POST   | `/auth/refresh`         | Compatibility exchange. Modern clients use it only when upgrading an older saved credential                                                                                                                                                   |
| POST   | `/auth/token`           | `{refreshToken}` with a persisted `Idempotency-Key`; rotates a modern session                                                                                                                                                                 |
| POST   | `/auth/logout`          | Revokes the current server session                                                                                                                                                                                                            |
| GET    | `/api/sessions`         | Lists this account's active sessions without credentials                                                                                                                                                                                      |
| DELETE | `/api/sessions/:id`     | Revokes an owned session                                                                                                                                                                                                                      |
| POST   | `/api/change-password`  | `{currentPassword, newPassword}`; revokes every session and agent token and pauses session-made webhooks. 10 per hour per account                                                                                                             |
| POST   | `/auth/password/forgot` | `{email}` → 202 at once, before the address is looked up; the code is issued and mailed afterwards. 5 per 15 min per IP, 3 per hour per email                                                                                                 |
| POST   | `/auth/password/reset`  | `{email, code, newPassword}`; 400 `reset_code_invalid` for any wrong, used, expired or unknown case. 10 per 15 min per IP                                                                                                                     |

Signup, login and the compatibility refresh route accept `X-Session-Protocol: 2`. These clients receive a 15-minute access token and a rotating refresh credential with a 90-day session lifetime. They persist the refresh operation key until the replacement credential is saved. A lost acknowledgement can be retried using the same prior credential and operation. Password changes revoke all sessions. Clients without the protocol header receive the compatibility 30-day access token. Both native and browser clients use protocol 2. The browser stores its session under the configured API URL and assigns each refresh credential an operation key before use. Tabs replay the same credential/key pair; a successful rotation atomically replaces both. Fresh launches read `/api/me` without creating another session. Older scoped browser credentials upgrade once through the compatibility endpoint. An old unscoped browser token is adopted only for its original production API. Compatibility refresh remains limited to 60 calls per account per ten minutes.

A refresh credential this session already rotated past, presented again (not a retry of a lost acknowledgement with its own operation key), ends the session: one of its two holders copied it, and the server can't tell which. Credentials are `session.generation.mac`, with the generation inside the MAC, so recognising an earlier one is a single HMAC however often the session rotated. Credentials issued before that, `session.mac`, rotate once more into the new form; reuse of one is recognised for the 16 generations before the current one.

Password reset codes are 8 characters (shown `ABCD-EFGH`), last 15 minutes, work once, and stop working after five wrong guesses or when a newer code is requested. Only an HMAC keyed with the server secret and the account is stored. A successful reset revokes every session and personal access token. Mail goes through `lib/mail.js`: `MAIL_TRANSPORT=memory` in tests and the simulator fixture, `log` in development; production has no transport until an email provider is chosen.

`DELETE /api/account` needs `{confirm: true}` and proof of identity: `password` for a password account, always, even with Apple connected; for an account without a password, a Sign in with Apple `identityToken` and raw `nonce` from the last ten minutes for an Apple ID already connected to it. A missing proof is 400 (`password_required` or `apple_reauthorization_required`); a wrong one is 403 (`wrong_password` or `apple_not_confirmed`), never 401, so clients keep the session. When the account has Apple connected and the server can revoke Apple's authorization, a password account sends `appleAuthorizationCode` from a fresh Sign in with Apple as well as its password; without it the answer is 400 `apple_reauthorization_required`.

The same proof is needed to connect Apple (`POST /api/account/identities/apple` with `password`, or `currentIdentityToken` and `currentNonce` alongside the new `identityToken` and `nonce`), to disconnect it (`DELETE` with `{password}`), and to create a personal access token (`POST /v1/tokens` with `password`, or `identityToken` and `nonce`). Wrong passwords and refused Apple confirmations share one budget of ten per account per hour across deleting, connecting and disconnecting Apple, creating a token and changing the password; after that each of them answers 429 `too_many_attempts`, even with the right password. Attempts still being checked count too, so requests sent at once can't exceed it. A password reset clears this budget, the change-password limit and the sign-in limits for that account. Missing proof doesn't count. Token creation is also limited to 30 per account per hour. Password fields are left out of the request fingerprint kept with an `Idempotency-Key` receipt.

## Bootstrap and setup

| Method | Path                       | Notes                                                                                                 |
| ------ | -------------------------- | ----------------------------------------------------------------------------------------------------- |
| GET    | `/api/bootstrap`           | Account and stable `account_id`, setup/repair status, targets, contract version and feature flags     |
| GET    | `/api/onboarding/status`   | Authoritative setup completion status                                                                 |
| GET    | `/api/onboarding/draft`    | `{draft}` or `{draft: null}` for this account                                                         |
| PUT    | `/api/onboarding/draft`    | `{schema_version, revision, last_valid_step, answers}`; requires the current revision, initially 0    |
| POST   | `/api/onboarding/preview`  | Validates answers and returns proposed targets and program without completing setup                   |
| POST   | `/api/onboarding/complete` | Requires `Idempotency-Key`; atomically saves profile, initial weight, program, targets and completion |

Draft schema 2 has steps 0 through 4. Schema 1 remains accepted for earlier drafts. Completion accepts `draftRevision` when reconciling a saved draft and rejects stale answers. Bootstrap repairs incomplete legacy target records only when saved facts are sufficient; otherwise it returns the missing setup fields. It does not invent a goal or create a fresh weigh-in during repair.

## Profile

| Method     | Path                   | Notes                                                      |
| ---------- | ---------------------- | ---------------------------------------------------------- |
| GET        | `/api/me`              | The serialized user                                        |
| GET · POST | `/api/profile`         | Free-form profile object. POST merges rather than replaces |
| PUT        | `/api/profile`         | Structured update: name, age, gender, height, weight, goal |
| PUT        | `/api/settings`        | `{timezone, unitSystem}`. Rejects an unknown IANA zone     |
| POST       | `/api/user/onboarding` | Completes onboarding, returns the formula TDEE             |

## Weight and trend

| Method | Path                          | Notes                                                                                       |
| ------ | ----------------------------- | ------------------------------------------------------------------------------------------- |
| GET    | `/api/weight?from=&to=`       | Active weigh-ins, newest first; `include_deleted=true` also returns deleted records         |
| GET    | `/api/weight/day?entry_date=` | The day's reading, including a deletion marker; an empty day has null weight and revision 0 |
| GET    | `/api/weight/:id`             | One owned reading; `include_deleted=true` includes a deleted reading                        |
| GET    | `/api/weight/trend?days=90`   | Smoothed series and summary from active readings                                            |
| PUT    | `/api/weight/day`             | `{entry_date, weight_kg, note, source, base_revision}`; checked creation or update          |
| POST   | `/api/weight`                 | Compatibility creation/update with `{weight}` in kg, `{weightLb}`, or `weight_kg`           |
| DELETE | `/api/weight/:id`             | Sets a deletion marker; returns `{message, weight}`                                         |
| POST   | `/api/weight/:id/restore`     | Explicit restoration using the deleted reading's `base_revision`                            |

One record ID represents one account's calendar day through edits, deletion and restoration. A checked write requires the version the user reviewed, supplied by `base_revision` or `If-Match`. Stale writes return HTTP 409 with `details.current`; changing the reviewed payload or revision requires a new operation identity. Replaying an acknowledged operation returns its original result without applying it again.

Legacy records read as revision 1. Compatibility POST and DELETE may omit a revision until a checked write adopts the row; afterward all changes require a revision. Deleted readings cannot be recreated by an old POST. Clients must use the explicit restore endpoint. All accepted changes emit `weight` feed entries keyed by the calendar date, and new or adopted rows carry a stable account ID.

Storage uses kilograms to two decimal places. Manual and onboarding readings take precedence over imports. `healthkit` and `import` sources cannot replace a manual reading; replacement of an existing import also requires a matching revision. This source rule does not constitute a HealthKit importer. Sample identity and device/source selection remain separate integration work.

Deleting or restoring a reading updates the profile's current weight from the latest remaining active reading. It does not rewrite historical nutrition targets. Normal history, trend, summary and export reads omit deleted records.

`trend` returns one point per calendar day: `weight` is null on days you didn't
weigh in, and `trend` carries forward, so a chart can plot both lines without any
gap handling on the client.

`summary` gives `current_trend_kg`, `change_kg`, and `weekly_rate_kg`, which is
the number to act on.

## Program

| Method | Path                               | Notes                                                                       |
| ------ | ---------------------------------- | --------------------------------------------------------------------------- |
| GET    | `/api/program`                     | Current targets, measured expenditure, and what the next check-in would set |
| PUT    | `/api/program`                     | `{goalType, rateKgPerWeek, dietType, proteinStrategy, targetWeightKg}`      |
| POST   | `/api/program/checkin`             | Re-measures and moves the targets                                           |
| GET    | `/api/program/checkins`            | History, newest first                                                       |
| GET    | `/api/program/expenditure?days=28` | The estimate on its own, with its working                                   |

`goalType` is `lose`, `maintain`, or `gain`. `rateKgPerWeek` is capped at 1.5 and
its sign is normalized to match the goal. `dietType` is `balanced`, `low_carb`,
`low_fat`, `high_protein`, or `keto`.

Expenditure carries a `confidence`:

- `estimated`: insufficient evidence; the formula estimate is used when available.
- `low`: observed estimate with a short or incomplete data window.
- `medium`: more history with sufficient complete-day coverage.
- `high`: at least 28 days with 90% complete-day coverage and the required actual measurements.

Observed estimates require at least four actual weigh-ins, a measurement in the first week, one in the last seven days, and sufficient explicitly complete intake days. Carrying a trend forward does not create measurement evidence. Accepted target versions retain effective dates for historical diary reads.

## Day logging status

`GET /api/diary/day?entry_date=YYYY-MM-DD` returns `{entry_date, status, note, revision}` plus stored record metadata. An untouched day is `in_progress` at revision 0. `/api/summary` includes the same object as `diary_day`.

`PUT /api/diary/day` accepts `{entry_date, status, note, base_revision}`. `If-Match` can supply the revision, and the original `revision` body field remains an alias. A revision is required. A stale revision returns 409 with `details.current`. Notes are limited to 500 characters; future writes are rejected.

| Status        | Meaning                                                                                         |
| ------------- | ----------------------------------------------------------------------------------------------- |
| `in_progress` | Entries may be incomplete; not counted as a complete intake day                                 |
| `complete`    | The user has recorded all intake; may count when calorie and measurement evidence is sufficient |
| `estimated`   | Entries include estimates; excluded from the expenditure calculation                            |
| `excluded`    | Retained for review, excluded from the expenditure calculation                                  |

Logging one food does not mark a day complete. Status writes support operation replay, emit `diary_day` changes, and appear in exports under `diary_days`.

## Body measurements

| Method | Path                                               | Notes                                                                     |
| ------ | -------------------------------------------------- | ------------------------------------------------------------------------- |
| GET    | `/api/measurements?from=&to=&type=&limit=&offset=` | `{entries, total, limit, offset}`; limit up to 500, default 365-day range |
| GET    | `/api/measurements/:id`                            | Owned record; `include_deleted=true` includes its deletion marker         |
| POST   | `/api/measurements`                                | `{client_id, type, value, unit, entry_date?, note?, source?}`             |
| PUT    | `/api/measurements/:id`                            | Same measurement fields with `base_revision` or `If-Match`                |
| DELETE | `/api/measurements/:id`                            | Requires a revision; marks the record deleted                             |
| POST   | `/api/measurements/:id/restore`                    | Requires the deleted record's revision; explicitly restores it            |

Types are `bust`, `chest`, `hips`, `neck`, `shoulders` and `waist`; `left_` and `right_` `ankle`, `bicep`, `calf`, `forearm`, `thigh` and `wrist`; and `body_fat`, a visual estimate. The older sides-unknown `arms`, `thighs` and `calves` remain accepted so their history stays editable. Circumference accepts `cm` or `in` and stores centimetres. Body fat accepts `%`. The original value/unit remain in `entered_value` and `entered_unit`. Supported sources are `manual` and `legacy_device_import`. Weight retains its separate contract above.

The account/client UUID pair is unique, including deleted records. Revisions start at 1; stale edits return 409 with `details.current`. Export includes active owned records under `measurements`. Legacy device data requires explicit ownership review before import.

## Incremental synchronization

`GET /api/sync?after=0` returns `{changes, cursor, has_more}` with up to 500 changes. Persist the returned cursor atomically with the applied changes and request another page while `has_more` is true. A change carries `kind`, `entity_id`, `server_id`, `revision`, `deleted` and `payload`.

Current change kinds are `food`, `measurement`, `diary_day`, `water`, `weight`, `activity` and `sleep`. Diary-day, water and weight entity IDs are date strings; the others use client UUIDs or legacy record IDs. Local identity must include account, API environment, kind and entity ID. Activity and sleep retain stable `legacy-{id}` aliases for older records.

## Food

| Method | Path                                            | Notes                                                          |
| ------ | ----------------------------------------------- | -------------------------------------------------------------- |
| GET    | `/api/food?date=&include_deleted=&limit=&page=` | One day; pagination is optional for legacy callers             |
| GET    | `/api/food?from=&to=`                           | A range. Defaults to the last 90 days, hard cap 400            |
| POST   | `/api/food`                                     | See below                                                      |
| PUT    | `/api/food/:id`                                 | Send `entry_date` to move an entry to another day              |
| DELETE | `/api/food/:id`                                 | Soft deletion; returns `{message, food}` with the new revision |
| POST   | `/api/food/:id/restore`                         | Restore a deleted entry using its current `base_revision`      |
| GET    | `/api/food/:id?include_deleted=true`            | Authoritative entry or deletion marker for conflict review     |
| POST   | `/api/food/batch`                               | `{items: [...], mealType?, entry_date?}`, up to 50             |
| GET    | `/api/food/search?q=`                           | Your library first, then FatSecret and Open Food Facts         |
| POST   | `/api/food/barcode-lookup`                      | `{barcode}`, 8 to 14 digits. Cached 30 days                    |

A food entry body:

```json
{
  "name": "Chicken breast",
  "calories": 165,
  "protein": 31,
  "carbs": 0,
  "fat": 3.6,
  "servings": 1.5,
  "nutrition_basis": { "amount": 100, "unit": "g" },
  "entered_quantity": { "amount": 150, "unit": "g" },
  "client_id": "878e2f7e-3e66-4e46-a1dc-992917ba7ef8",
  "base_revision": 0,
  "servingSize": "100g",
  "mealType": "lunch",
  "entry_date": "2026-08-28"
}
```

Macros are **per serving**; the server multiplies by `servings` and stores the
total. Omitting `servings` means 1, so a client that sends absolute macros works
unchanged. `mealType` is matched case-insensitively and stored lowercase.

A stored `nutrition_snapshot` retains the original, unrounded per-basis values. Food totals round calories to an integer and the other nutrients to two decimal places, using positive half-up rounding after scaling. Unknown nutrients remain `null`; sodium is in mg, and protein, carbs, fat, fiber, sugar and saturated fat are in g. Library recents retain the original per-basis precision too.

`entered_quantity` records the quantity and unit used by the person. Its normalized value must match `servings`. Supported units are `serving`, `g`, `oz`, `ml` and `fl_oz`. Weight and volume cannot be converted without a compatible basis. Older requests without this field record their serving count. The same fields are available in JSON export.

New clients create with a stable UUID `client_id`, `base_revision: 0`, and an `Idempotency-Key`. Edits, deletion and restore include the revision that was reviewed. Once a food has received a revisioned mutation, unversioned writes are rejected with 409. An immutable retry uses the same operation key and payload; a reviewed correction uses a new operation. Batch logging creates up to 50 entries atomically and uses one operation key plus a client UUID for each item.

Anything logged is remembered in your library unless you pass
`saveToLibrary: false`.

## Library and recipes

| Method                    | Path                                     | Notes                                           |
| ------------------------- | ---------------------------------------- | ----------------------------------------------- |
| GET                       | `/api/library/foods?q=&favorites=&sort=` | `sort` is `recent` (default), `used`, or `name` |
| POST · PUT · DELETE       | `/api/library/foods[/:id]`               | Custom foods                                    |
| POST                      | `/api/library/foods/:id/favorite`        | Toggles, or set `{favorite: true}`              |
| GET · POST · PUT · DELETE | `/api/library/recipes[/:id]`             | Returns `total` and `per_serving` macros        |

## Diary and analytics

| Method | Path                         | Notes                                                                                                                                                               |
| ------ | ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| GET    | `/api/summary?entry_date=`   | One day: meals, totals, targets, remaining, activity, sleep, water, weight                                                                                          |
| GET    | `/api/summary/range?days=30` | Daily totals plus averages over logged days only                                                                                                                    |
| GET    | `/api/dashboard/weekly`      | Last 7 days of consumed and burned                                                                                                                                  |
| GET    | `/api/recent`                | Today's logs, newest first                                                                                                                                          |
| GET    | `/api/dashboard-data`        | Legacy card list                                                                                                                                                    |
| POST   | `/api/reset-today`           | Deletes a day and returns what it removed, so a client can undo                                                                                                     |
| GET    | `/api/export`                | Current account, log, program, library, measurement and diary-status records as JSON; excludes password hashes. Full lifecycle export coverage is still in progress |

`/api/summary/range` averages over days that were actually logged. Including
empty days would drag every average toward zero and make a missed day look like
a fast.

## Other resources

| Method                    | Path                    | Notes                                                               |
| ------------------------- | ----------------------- | ------------------------------------------------------------------- |
| GET · POST · PUT · DELETE | `/api/activities[/:id]` |                                                                     |
| GET · POST · PUT · DELETE | `/api/sleep[/:id]`      |                                                                     |
| GET · POST · PUT · DELETE | `/api/workouts[/:id]`   |                                                                     |
| GET · POST                | `/api/goals`            | Accepts camelCase and snake_case. A goal of 0 stays 0               |
| GET · POST                | `/api/water`            | `{ml}` or `{deltaMl}`. Still answers in `glasses` for older clients |

### Activity and manual sleep synchronization

Activity and sleep lists retain their array response and accept `date`, or `from`/`to`, with `limit` and `page` pagination. Normal reads omit deleted rows; `include_deleted=true` includes them on list and single-record reads. New records carry `account_id`, `client_id`, `revision` and timestamps.

New clients supply a UUID `client_id` and a separate `Idempotency-Key` when creating a record. Independent IDs merge as distinct activities or sleep entries. Reusing a client identity with another operation returns HTTP 409, including for a deleted entry. Retrying the same operation returns its original acknowledgement.

Edits and deletions use `base_revision` or `If-Match`. Records created with a client identity require revisions immediately. Older records retain compatibility until a checked write adopts them; afterward an unchecked update is rejected. Reads assign stable `legacy-<server ID>` aliases to unversioned records. The first update persists that alias and account ownership while keeping the original ID. New creation cannot use the reserved alias.

DELETE returns the compatible `{message, activity}` or `{message, sleep}` response with a revisioned deletion marker. `POST /api/activities/:id/restore` and `POST /api/sleep/:id/restore` require a matching revision and restore the same record. A stale edit cannot implicitly restore a deleted entry. All accepted changes appear as `activity` or `sleep` events in the account's change feed.

Both user and administrator day resets now mark food, activity and sleep entries deleted and emit changes for the affected account. Summary, history and export exclude these entries. Administrator operation receipts belong to the administrator; the resulting data changes belong to the target account.

This contract preserves the existing manual sleep fields. Imported sample identities, interval overlaps and daylight-saving reconciliation are not implemented by these routes.

Activity `duration_min` accepts fractional minutes from 0.1 to 1,440. Calories are optional: omitted or null means unknown; an explicit zero remains zero. Neither client estimates calories when that field is blank. Intensity and type are optional and retain existing values during editing.

Manual sleep accepts `hours` from 0 to 24, an optional quality string, and optional bedtime/wake-time text. Clients label `entry_date` as the wake date and allow naps as separate records. Hours are entered independently of the clock times. `/api/summary` returns all active records in `sleep_entries` and their sum in `sleep_hours`; the compatible `sleep` field retains the latest single entry. A day with no sleep records has an empty array, zero total and null `sleep`.

### Water synchronization

`GET /api/water?entry_date=YYYY-MM-DD` returns `{id, entry_date, ml, glasses, revision}`. An untouched day has zero millilitres and revision 0. Existing unversioned records read as revision 1 and gain a stored revision on their next write. `/api/summary` includes `{entry_date, ml, revision}` under `water`, alongside the compatible `water_ml` total.

`POST /api/water` accepts `{entry_date, deltaMl}`. Each addition should carry its own `Idempotency-Key`. Concurrent additions accumulate in the mutation transaction; replaying an old key returns its original acknowledgement without adding the amount again. Deltas range from -5,000 to 5,000 ml, and the total cannot go below zero. New mobile and browser controls submit positive whole millilitres.

Absolute `{ml}` updates accept `base_revision` or `If-Match` and reject a stale revision with HTTP 409 and `details.current`. Omitting a revision remains compatible with installed clients; new correction controls should require one. The legacy `glasses` and `delta` fields remain supported, with one glass equal to 250 ml. Writes emit `water` changes and appear in the existing water export.

A client with a pending addition must not blindly add that amount to a newly fetched server total: the server may already have committed it. Keep the operation until acknowledgement, then reconcile against its revision and newer server data. The browser displays its unacknowledged amount separately from the recorded total for this reason.

## AI coach

| Method       | Path                      | Notes                              |
| ------------ | ------------------------- | ---------------------------------- |
| GET          | `/api/ai/credits`         | 5 per rolling hour, 20 per UTC day |
| POST         | `/api/ai/coach`           | `{type, question?}`                |
| GET · DELETE | `/api/ai/plans[/:id]`     | Saved responses                    |
| PATCH        | `/api/ai/plans/:id/apply` |                                    |

Without `GEMINI_API_KEY` the coach returns canned responses and spends no credits,
which is what local development uses.

## Admin

All under `/api/admin`, all requiring `is_admin`. Users, stats, per-user entries,
admin toggle, and the AI error log. An admin cannot remove their own admin access,
because there is no way back in short of editing the database.

## Rate limits

Per-address and per-network limits use the client's address: `req.ip`, with Express trusting one proxy, as behind docker-compose's reverse proxy. On DigitalOcean App Platform that is the ingress, which every client shares, until `EXERLY_APP_PLATFORM=1` makes them read `do-connecting-ip`. The flag is off in `.do/app.yaml` until it's verified that App Platform replaces a forged `do-connecting-ip` (DECISIONS.md). Self-hosted servers must never set it. Per-account and per-email limits don't depend on the address.

| Scope          | Limit                                                                                                                      |
| -------------- | -------------------------------------------------------------------------------------------------------------------------- |
| All `/api`     | 600 per minute per IP                                                                                                      |
| Login          | 8 per 10 minutes per IP; 10 failures per email per /24 or /56 per 15 minutes, then a capped wait for that email everywhere |
| Signup         | 5 per hour per IP and per email                                                                                            |
| Food search    | 120 per hour                                                                                                               |
| Barcode lookup | 60 per hour                                                                                                                |
| AI coach       | 1 per 10 seconds, on top of the credit system                                                                              |

Counters are per instance and held in memory. Running more than one instance
would need a shared store.
