# Engineering decisions

## 2026-10-06: PostgreSQL foundation

Replace MongoDB with PostgreSQL and the `pg` driver. Keep route response shapes
during this milestone so the existing native offline queue can be tested against
the new database. Use relational columns for identifiers, ownership, dates,
numbers and revisions. Use JSONB only for existing structured snapshots.

Commit numbered SQL up/down migrations. Do not generate production schemas from
JavaScript at startup. Check migration checksums and serialize migration runners
with a PostgreSQL advisory lock. Ordinary API startup applies pending migrations
before accepting requests. Rollback is a separate operator command.

Use one checked-out connection for each transaction. Serializable transactions
retry conflicts from the beginning with a bounded retry count. Mutation receipts,
entity changes and sync cursors commit together. Add concurrency, rollback,
migration and restored-backup tests on real PostgreSQL.

Keep account filters explicit and test adversarial cross-account requests. RLS is
not adopted in M1 because the current schema mixes account IDs and email owners,
and authentication/admin maintenance require separate access policies. New tables
use account IDs. Database foreign keys and an ownership audit accompany later
conversion of the email-owned tables. Do not claim RLS protection.

The web dashboard is outside the product scope. Preserve its source and historical
evidence, but remove its deployment and required CI work after recording the first
baseline. Native tests and PostgreSQL integration tests become the release gate.

Production cutover requires Ali's Neon project and DigitalOcean `DATABASE_URL`.
Do not merge a deployment configuration that cannot boot before that prerequisite
is satisfied. Continue native and local database work on branches meanwhile.

References: [node-postgres transactions](https://node-postgres.com/features/transactions)
and [PostgreSQL isolation](https://www.postgresql.org/docs/16/transaction-iso.html).

## 2026-10-06: ExerlyCore holds training logic

The training domain lives in `apps/ios/ExerlyCore`, a dependency-free Swift 6
package tested with `swift test`, so logic needs no project-file edits and no
simulator.

- The exercise library is a bundled JSON file, so the API and MCP server can read
  the same data later.
- e1RM uses Brzycki up to 10 reps to failure and Epley above, which meet exactly
  at 10.
- Sets per muscle are fractional: 1 for a target muscle, 0.5 for a synergist.
- One side of a unilateral exercise counts as half a set.

Details and measured error are in `docs/design/002-exerlycore-training.md`.

`docs/AGENT_BRIEF.md` is excluded from Prettier. The brief is Ali's, and the
pre-push format check failed on its list spacing. Agents may not reformat it, so
it is ignored rather than edited.

## 2026-10-06: PostgreSQL behind the existing storage adapter

M1a keeps the route layer and the `apps/api/data` interface, and adds a PostgreSQL
driver. That kept every existing test as a regression check: all 153 pass
unchanged except the one that named the driver.

**Schema.**

- `db/migrations/0001_initial` creates one table per registry collection, with
  typed columns.
- Legacy camelCase columns are quoted, so their case survives.
- Every row has a UUID `id` and a `seq` identity. Callers that sort by id get
  insertion order, as they did with SQLite row IDs.

**Transactions.**

- They run `SERIALIZABLE`.
- Serialization failures, deadlocks and unique-index races retry from the
  start, up to five attempts.
- Every authenticated mutation already runs inside `executeMutation`, and no
  mutation handler calls an external service, so retries never repeat a side
  effect. AI routes are excluded and use their own reservation flow.

**Health.** `/api/health` reports pool state without querying the database, so
platform health checks don't keep a scale-to-zero database awake.

**Retired drivers.**

- MongoDB and its driver are removed.
- The SQLite driver stays only for the app agent's isolated simulator fixture
  (`scripts/ios-fixture-api.cjs`). `sqlite3` moved to devDependencies. It goes
  once that fixture runs on PostgreSQL.

**Deployment.**

- The API ships as a non-root `node:22-bookworm-slim` image that migrates before
  it listens.
- `docker-compose.yml` runs PostgreSQL 16 and the API for self-hosting.
- `.do/app.yaml` now builds that Dockerfile and expects `DATABASE_URL`.
- Production must not be redeployed from `main` until Ali sets `DATABASE_URL`.

**Devbox tooling.** Colima's existing default profile is used for Docker. The
`docker-compose` CLI plugin was installed with Homebrew. Colima is stopped again
after container checks.

## 2026-10-06: Sign in with Apple and account lifecycle

- **Verification.** Apple identity tokens are verified on the server against
  Apple's published keys: RS256 only, Apple as issuer, our bundle ID as audience,
  unexpired, with nonce = SHA-256(raw nonce). Each nonce is stored for a day, so a
  captured token can't be replayed.
- **Linking.** Apple sign-in never attaches to an existing password account by
  email unless that email was verified. Exerly doesn't verify emails yet, so such
  people get `link_required` and connect Apple from a signed-in session. This
  blocks takeover through a pre-registered, unverified address.
- **Hidden emails.** When Apple hides the email entirely, the account gets
  `apple-<hash>@users.exerly.invalid`. The legacy tables are keyed by email.
- **One ownership map.** `lib/ownership.js` drives account deletion and export,
  and a test fails if any table lacks a rule. Deletion runs in one transaction.
- **Revocation.** Apple token revocation happens before deletion. It uses a fresh
  authorization code exchanged at deletion time, so no Apple refresh tokens are
  stored. It needs a Sign in with Apple key from Ali; see QUESTIONS_FOR_ALI.md.
- **Sessions.** New sign-in paths always issue protocol 2 sessions: 15-minute
  access tokens and rotating refresh credentials.

## 2026-10-06: Document sync for ExerlyCore

- **Unit of sync.** ExerlyCore entities sync as whole documents, with server
  revisions, stale-base conflicts, idempotent writes and tombstones
  (`/v1/documents`), plus a document view of the shared change feed
  (`/v1/changes`).
- **Derived dirtiness.** The client marks nothing dirty. A document needs
  pushing when its canonical JSON (sorted keys, millisecond ISO dates) differs
  from the last acknowledged version. A crash between a save and a dirty flag
  therefore cannot lose a change, and no cross-table transaction is needed.
- **Push keys.** Each push key is tied to the content and the base revision. A
  lost response is retried with the same key and replays; a merged version gets
  a new key.
- **Merging.** Conflicts merge three ways, so sets logged on two devices both
  survive:
  - whichever side changed a field wins, and local wins when both did;
  - lists merge by ID, with additions from both sides kept;
  - a deletion applies only to an item the other side left unchanged.
- **Dates.** The store creates every date at whole milliseconds, so wire
  round trips are exact.
- **Server validation** checks the kind, the ID, that the payload is an object
  and that its `id` matches, plus each kind's essential fields. It does not
  reinterpret payloads. A JSON Schema shared with the Swift tests is due before
  the MCP server reads documents.
- **Forward compatibility.** An older client that pushes a document drops fields
  it doesn't know. Acceptable while there are no old clients; revisit before
  public release.

## 2026-10-06: Staging on devbox1

The staging API runs on devbox1 until production moves to PostgreSQL, under one
LaunchAgent (`com.aldo.exerly-staging`), following the devbox recovery README.

- **Code.** A deployed copy runs from `~/Services/exerly-staging`; LaunchAgents
  can't read `~/Desktop`.
- **Database.** A private PostgreSQL cluster on a Unix socket with no TCP port.
- **Network.** The API binds to `0.0.0.0` on logic scratch port 39110 and is
  reached at `http://100.80.149.7:39110`.
- **Recovery.** It is an advisory check in `~/Services/devbox-recovery/check.py`,
  so it never fails Ali's required startup checks.
- **Scripts.** Install and uninstall scripts live in `apps/api/deploy/staging/`.

## 2026-10-06: Personal access tokens

- **Format.** `exr_` plus 32 random bytes in base64url. Only a SHA-256 hash is
  stored, and the token is shown once.
- **Scopes.** `read` (every token), `propose` and `write`.
- **Reach.** Tokens reach only `/v1/*` and `/mcp`. Token management, sessions,
  identities, passwords, legacy `/api/*` routes and account deletion refuse them.
- **Proposals.** A token can file only new pending proposals. The server stamps
  the token's identity as the author, so an agent can't pose as the person or as
  Exerly, and only a signed-in session can decide.
- **Audit.** Every token write and filed proposal appends a server-written
  `audit_event` document in the same transaction, so the log reaches every
  device. Token creation and revocation are audited too.
- **Limits.** At most 20 active tokens per account. Last use is recorded at most
  once a minute.

## 2026-10-06: Preserve Exerly's existing brand

Ali rejected the unrelated mint monogram in the first internal build. The app
keeps the established purple E/pulse mark from apps/web/src/components/Assets/
ExerlyLogo.jpg. The app icon uses that symbol alone so it remains legible at home
screen size. Restore purple/pink brand accents and neutral purple-tinted surfaces;
retain adaptive light/dark colors, Dynamic Type and native controls. The green
palette introduced in A2 is superseded. No new brand direction is being adopted.

## 2026-10-06: Web CI job removed

The `web` job is gone from `ci.yml`, as the brief allows and both agents agreed
(to-logic.md, "A2 regression green"). The web sources stay, and so does the
cross-client step in `ios-tests`, which the app agent owns. Required CI now
covers the API, ExerlyCore, SwiftLint, the iOS build and tests, and workflow
lint.

## 2026-10-06: One session owner in the app

The app's legacy `APIClient` stays the only owner of the session: it signs in,
refreshes and stores credentials. ExerlyCore talks to the server through
`SessionTransport`, which `APIClient` implements, and `AccountAPI` binds every
document and account request to one account ID. Two refresh implementations
sharing rotating tokens would race, and a second session would leave the
legacy screens signed out. `ExerlyAPI` remains a standalone owner for tests,
scripts and future targets.

- A sign-in or sign-out starts a new session generation; nothing begun under an
  older one saves credentials or returns a response.
- `SyncEngine.shutdown()` stops sync and waits for it before an account is
  signed out, switched or deleted.

## 2026-10-06: The SQLite API driver is removed

PostgreSQL is the only database, in tests, the simulator fixture, staging and
production. The SQLite driver (`DB_MODE=local`) was kept only for the iOS
fixture. The fixture moved to a throwaway PostgreSQL cluster, and the app agent
approved the removal. `sqlite3` and `cross-env` left the API's dependencies with
it.

## 2026-10-06: Deleted accounts are recognisable

A request carrying a session token this server signed, even an expired one, for
an account that no longer exists gets 401 with code `account_deleted`. Only the
account's own tokens can learn it, so nothing is revealed to anyone else. A
client whose deletion response was lost can then tell the deletion happened and
remove the account's data from the device.

## 2026-10-06: UUID document IDs are uppercase

A document ID that is a UUID has one canonical form, uppercase, which is what
`UUID.uuidString` gives and what ExerlyCore always wrote. The API stores and
returns that form for document IDs and for the IDs proposals and audit events
refer to, and migration 0005 converts existing rows. ExerlyCore's `SyncEngine`
reads remote IDs and its own saved sync bases in the same form. Before this, a
lowercase ID written by another client became a second server document when a
device synced it. Other IDs, such as custom exercise IDs, stay as written.

## 2026-10-06: IDs inside payloads are canonical too

Migration 0006 gives the IDs inside stored and change-feed payloads the same
uppercase form: a payload's own ID, a proposal's change IDs and the documents
in them, its evidence references, and an audit event's targets and proposal.
`canonicalPayload` in `apps/api/lib/documents.js` applies the rule to every
write, and the migration mirrors it in SQL; a test checks that they agree.
ExerlyCore's `ProposedChange` and `DataRef` keep a UUID ID in uppercase however
it arrived, so a proposal stored before the fix can still be accepted and
undone.

## 2026-10-06: Expenditure follows weight in the estimator

`EnergyBalance` now moves expenditure 22 kcal a day for each kilogram of trend
weight gained or lost (Hall et al., 2011), on top of its random-walk drift.
As a pure random walk, the estimator lagged a diet's falling expenditure: in
simulated dieters it read 171 kcal high at a 1 % weekly loss, so check-in
targets undershot the goal. With the coupling, M5b's mean expenditure error
fell from 90 to 74 kcal with daily weigh-ins, and from 114 to 97 kcal with
weekly ones. The coefficient is a parameter, `expenditurePerKilogram`.

## 2026-10-06: Nutrition plans are versioned, and check-ins are proposals

A `nutrition_plan` version never changes once it starts, so any past day's
targets are the ones that held then. A weekly check-in is a built-in proposal
that adds a version, with the expenditure band, the week's trend and logging
coverage as evidence. A check-in whose new targets would break the 1,200 kcal
floor or the protein and fat minimums proposes nothing and says why, instead
of silently slowing the goal.

## 2026-10-09: The Xcode project is generated, with synchronized folders

`apps/ios/project.yml` is now the source of truth for `Exerly.xcodeproj`;
regenerate with `xcodegen generate` in `apps/ios`. The app and both test
targets use synchronized folders, so adding, moving or deleting a Swift file
needs no project change. Several agents can now build screens in parallel
without serialising on `project.pbxproj`. The generated project stays committed
so CI and the release script need no extra tool. Build settings were diffed
before and after: only the deployment target changed.

## 2026-10-09: iOS 26 is the minimum

Exerly now requires iOS 26. Nobody uses it yet, and the redesign builds on iOS
26 directly: the Liquid Glass tab bar, a search-role tab for logging from
anywhere, and a tab bar accessory for the live workout. Supporting older
systems would mean a second, plainer version of every primary screen.

## 2026-10-09: Confetti removed

`ConfettiView` was only reachable through an onboarding flag that nothing set.
It is deleted, consistent with the no-confetti principle.

## 2026-10-09: Today replaces the Diary, and the Library tab goes

The app opens on Today: the day's calories and macros against targets, the
foods usually eaten at this time with a plus that logs each in one tap, today's
workout with Start, and the meals, each with a one-tap repeat of the last time
it was logged. Measured on the simulator: a usual food, a repeated meal and
starting the planned workout each take one tap from launch.

The tabs are now Today, Train, Progress and Profile, plus an iOS 26 search tab
that opens food search from anywhere. The Library tab is removed: recents and
favourites already lead the food search, and the saved-foods manager moved to
Profile → Foods & recipes. The status menu ("In progress") became a single
"Mark this day complete" control, because complete days are what the
expenditure estimate uses. The week strip is the last seven days, so yesterday
is always one tap away.

## 2026-10-09: Today's workout starts from the Train tab without questions

Train → Start begins the active program's next workout in two taps from the
home screen. Removed along the way:

- The planned-workout review sheet's bodyweight field, and the "New workout"
  sheet that asked for a name and bodyweight. Bodyweight now comes from the
  latest weigh-in (or stays empty) and can be changed in the workout's
  details. An empty workout starts at once, named for the time of day, and is
  renamed from the workout menu. The review sheet stays as Preview.
- The set editor sheet for routine edits. Weight, reps and RIR are edited in
  place in each exercise's set grid with the training keypad, whose steppers
  follow the gym's plates. A change carries to later incomplete sets that
  still held the old value. The sheet remains under a set's "More options"
  for drops, myo continuations and sides.
- The red "Discard workout" row, now in the workout's overflow menu.
- The four large rows on the Train home (Programs, Gyms, Suggestions,
  Observations) and the Exercise library and history card, merged into one
  compact "Plan and tools" list. Observations is renamed Insights.
- Rest "+30 s", replaced by −15 and +15 on a floating rest bar.

Finishing a workout now shows a summary with time, working sets, volume and
any personal records.

## 2026-10-09: Releases sign in the user's session

Agent shells on devbox1 can run in a Background launchd session, where macOS
consults only the System keychain domain. There Xcode can't see the signing
identity that `release.sh` imports into its temporary keychain, and archives
fail with "No signing certificate". `apps/ios/scripts/release-in-session.sh`
runs the unchanged `release.sh` as a transient job in the logged-in user's GUI
session. That job can't read `~/Desktop`, so the committed `apps/ios` is
exported to `~/Library/Caches/exerly-release/<build>` first, which also means
every build comes from a commit. Nothing about certificates, profiles or the
keychain handling changed.

## 2026-10-09: CI runs unit tests and tap budgets; the full UI suite runs locally

The iOS job ran every UI test on one GitHub runner, took over three hours, and
never finished green. CI now runs the unit tests and the Today tap-budget tests
within an hour. The full UI suite runs locally before each landing, sharded
across simulators with one fixture each. The browser round-trip step went with
it, since the web dashboard is out of scope.

## 2026-10-09: Milestones removed; Progress gains Nutrition and Training

Progress is now Body, Nutrition, Training and Photos. The Milestones tab and
its unused achievement service are removed: badges for activity are the
motivational filler the brief rules out, and the space goes to analytics that
explain why numbers move. The SwiftData `Achievement` model stays in the stored
schema until a schema migration removes it.

## 2026-10-09: Food search logs in one tap

Each food in search has a "+" that logs it at once and keeps the search open,
with "Logged · Undo" and the kilocalories left for the day. What the row shows
is exactly what the tap records: the amount last eaten, or for a new food one
of its first label serving, else 100 g or 4 oz (100 ml or 8 fl oz for a food
labelled by volume). `NutritionStore.quickPortion(for:unit:)` in ExerlyCore
decides it, and the portion sheet opens on the same amount, so a new food no
longer starts at 1 oz. A food eaten before is two taps from the home screen:
open search, then "+". Recent and suggested rows are fixed while search is
open, so rows don't move under a finger as foods are logged.

## 2026-10-09: Food search queries the database as you type

Search now asks the food database 400 ms after typing pauses, from three
characters, cancelling a request a newer keystroke has made stale, and reuses
answers already fetched. Saved and previously logged foods match on the
device with no wait and work offline. This replaces submit-only search. The
server still guards Open Food Facts' shared budget of 10 searches a minute
and caches each query for five minutes; when the budget is spent, typed
searches return the bundled generic foods only. If that happens in
production, the server should add a per-account limit or move to a search
API meant for type-ahead.

## 2026-10-09: The portion sheet is compact, with unit chips

The portion editor is a sheet sized to show the energy, macros, unit chips,
amount, meal and a pinned Log button without scrolling; dates, nutrient
corrections and the source are below. Switching unit or serving chips
converts the amount and keeps its weight; the presets under the amount set
whole servings. The separate "Portion
measure" sheet (`NutritionMeasureSelection`) is removed, and the meal
builder's portion editor uses the same chips. A barcode that matches one food,
typed or scanned, opens its portion directly.

## 2026-10-09: Old food library screen removed

`Features/FoodLibrary/FoodLibraryView.swift` was not reachable from any
screen; the Nutrition library replaced it. It is deleted. `LogFoodView`,
`FoodDetailView`, `CreateFoodView` and `BarcodeScannerView` are reachable
only from `HomeView`'s non-health diary mode, which nothing opens; they can go
once that mode is removed. The barcode camera they shared now lives in
`Features/Nutrition/NutritionBarcodeCamera.swift`.

## 2026-10-09: The food library manages foods; search logs them

The food library's "Usual around now" and "Recently logged" lists repeated
what food search now shows with one-tap logging, so they are removed. The
library is for finding, editing, starring and archiving saved foods; its food
page still logs, at the meal usual for the time of day.

## 2026-10-09: Unlogged weeks no longer move expenditure

`EnergyBalance` assumed an unlogged day's intake was the recent logged average
or, before any logging, its own expenditure estimate. With weigh-ins but no
logging, each day's real weight change then raised expenditure, the assumed
intake followed, and the estimate climbed with a shrinking band: 3,354 ±192
kcal after four weeks for someone burning 2,590, and 1,456 kcal off after nine
weeks in simulation. A fourth state, `D`, is now how far a stretch of unlogged
days' intake sits from the recent logged average or, before any logging, from
expenditure. Each stretch starts its own `D` and logged days never inform it,
so weight change before logging moves the trend and leaves expenditure at its
starting guess with its full band; Exerly doesn't assume someone ate before
logging the way they log. For logging that starts on day 21, the smoothed
trend around the switch went from 0.70 kg off to 0.18 and the expenditure band
from covering the truth 29 % of the time to 97 %. M5b's rates and the coaching
simulation are unchanged within 2 kcal and 0.001 % a week. The public API is
unchanged; `Parameters` gains `unloggedBalance` (500) and `unloggedDrift` (30),
and the API's JavaScript port and golden file follow. See
docs/design/007-nutrition.md.

## 2026-10-09: A logged row keeps its check, and a second tap takes it back

From the usability run: food search's "+" turned back into "+" two seconds
after logging, and Today's "Log again" chips reflowed as soon as one was used.
Now a row or chip logged from the screen keeps a check while the screen is
open, and tapping the check removes exactly what it logged. Logging a second
portion of the same food goes through the row's portion sheet. Today's chips
are fixed when the screen opens and refresh on a new day, on returning to the
app and on pull to refresh. The finish summary headlines one record per
exercise (heavier weight, then estimated 1RM, then reps); Progress still lists
every record.

## 2026-10-09: The native/browser round-trip harness is removed

`scripts/test-cross-client.sh`, its two Playwright specs and the six native
tests that consumed browser-made data are gone. They existed to prove the web
dashboard and the app agreed, the dashboard is out of scope, the native tests
only ever skipped without the harness, and one could no longer pass after the
weigh-in flow moved to ExerlyCore. The rest of the web dashboard is untouched;
remove it too if it starts to cost time.

## 2026-10-09: Setup is five pages; Profile is a hub

Setup now asks only what targets and training need, in five pages: about you
(name, units, sex for the calorie equation, age, height, weight), goal, everyday
activity, training (workouts a week, experience, gym or home equipment), and a
review of the resulting targets. Removed from setup, and why:

- The welcome card and three-line feature list: the Welcome screen says it.
- Gender identity: it never chose the equation. It's in Profile, and setup asks
  only when repairing an account saved without one.
- Meals per day and diet style (vegetarian, keto and so on): neither changed a
  target or filtered a food. Diet style stays in Profile.
- The separate equipment and nutrition pages: equipment joins the training
  page; the macro split and "Use my own targets" moved to the review, where
  their effect on the numbers shows at once.
- Sleep and notification steps and their unreachable screens (`Step0Welcome`,
  `Step6ActivityTypes` to `Step9Equipment`, `Step11Notifications`) were deleted
  with the old step files. Reminders are set in Profile.

Steps 0 and 1 stay separate in the saved draft, so drafts, repair and the
server's `last_valid_step` (at most 4) are unchanged; they share one page.
Old drafts on a removed page resume on the training page. The weight entered
becomes the first ExerlyCore weigh-in as soon as the account's workspace opens.
Before, it reached ExerlyCore only when Today's import of older weigh-ins found
the server's copy, which skips silently when sync is busy and waits for the next
launch. The local copy takes that import's ID for the day, so it is never added
twice; a setup repair adds none. A unit test and a UI test check it.

Removed from Profile's preferences, which nothing in the app or API reads:
preferred activities, meals per day, preferred bedtime and wake time. The
values stay on the account. Gender identity is now a picker instead of free
text, and the change-password screen requires 8 characters like the server
(it allowed 6, which the server rejected).

Deleted as unreachable: `DashboardView`, `SocialView` with `SocialService`,
`AICoachView` (the agent API and MCP server are untouched), `NotificationsView`,
`HomeViewModel`, `StreakService`, `FoodLibraryService`, `StatMiniCard`,
`CalorieRing`, `MultiSelectGrid`, and the local `WizardService` calculator,
which only the deleted results screen used. Setup targets come from the API.

## 2026-10-10: The workout Live Activity ships before the widgets

The Today and Next workout widgets read a snapshot the app writes to an App
Group, and Apple's API can't register App Groups, so that waits on Ali (see
QUESTIONS_FOR_ALI.md). Until then, release builds sign the app and the
extension without the group, and the extension's bundle holds only the
workout Live Activity, which needs no group. Debug builds keep both. Turning
the widgets on is one change in `project.yml`: release entitlements with the
group, and `EXERLY_APP_GROUP` for ExerlyWidgets' Release configuration. The
extension has its own App ID and App Store profile, provisioned through the API
(`node apps/ios/scripts/asc.mjs provision widgets`), and `release.sh` signs and
checks both.

## 2026-10-10: Fixes from the second code-blind usability run

- **The last set rests on hold.** Completing a workout's last open set starts no
  rest timer and stops one that's running. The rest it earned is held, not lost:
  adding a set or an exercise within that rest starts it from when the set was
  done, so logging one set at a time still rests. A skipped rest stays skipped.
  With every set done, Finish saves without asking; it still asks when sets are
  left, since those are removed.
- **Targets push from both places.** The calorie ring on Today is now a button
  that pushes Targets onto Today's stack, as Profile's plan card does, instead of
  presenting a sheet with Close. Targets keeps one Edit, in the toolbar; its plan
  rows open the editor too.
- **Preferences has one action.** Done saves any edits, then closes once the
  account has them. It stays open, with the reason, on an error, a conflict to
  review or an unacknowledged save ("Retry save"). Swiping the sheet away still
  keeps edits as a draft on the device.
- **Chip rows wrap.** `ExChoiceChips` lays out as a flow and wraps to a new line
  instead of scrolling sideways, so no choice is cut off at the edge.
- **Every standard nutrient is listed.** Progress and a food's nutrient table
  list energy, the macros, fiber, sugars, saturated fat and the vitamins and
  minerals even when nothing reported them; the rest appear once reported. A
  food's nutrients are one table instead of three nested disclosures.
- **This month** joins the nutrition spans, labelled with the month ("Oct"). It
  runs from the 1st through today; the others still end yesterday.
- **The driver seeds a realistic month.** `signedInWithRealisticHistory` gives
  usability runs four weeks of meals at their usual times with full labels, a
  coached plan, a four-day split in round pounds and weigh-ins. `seedWeek`
  stays as the tap-budget tests' fixture.

## 2026-10-10: Logging without opening Exerly

Every logging action is an App Intent, listed in Shortcuts and Spotlight, said to
the assistant through `ExerlyShortcuts`, and four of them are Control Center and
Lock Screen controls.

- Log weight, Quick add, Log a food, Repeat a meal and Calories left live in the
  app and run in its process, launched in the background if needed. Like the
  Live Activity buttons, they go through the open screens' workspace, or open
  the account's own, change it without suspending and close it. A change made
  that way syncs, and reaches Health through its ledger, when Exerly next opens,
  as one made offline does. Each makes the same store call as its screen. They
  require an unlocked device, since they read and write food and body data.
- Repeat a meal fills only an empty meal, as Today's button does, so a second
  run can't log the meal twice. Log a food's servings count the food's serving
  when it was last logged by one, else multiples of the usual amount.
- Search foods, Scan a barcode, Weigh in and Start workout open the app. They
  live in `Shared` so the widget extension's controls can use them, and the
  system runs them in the app after bringing it forward. They hand the app the
  same `exerly://` link a widget would, followed once the account is open. A
  control can't open a custom-scheme URL through `OpenURLIntent`, and Xcode 26.2
  records only `static let supportedModes: IntentModes = .foreground` in the
  intents' metadata: `.foreground(.immediate)` or a computed property is
  recorded as a background intent, and the app doesn't open.
- The controls read nothing from the App Group, so they ship ungated.
- The search intent is "Search foods" so it doesn't read like "Log a food" in
  Shortcuts; its control keeps the tab's name, "Log food".

## 2026-10-10: The Watch app draws the phone's workout and sends commands

The first Watch app (`ExerlyWatch`, `com.exerly.fitness.watchkitapp`, watchOS 26) starts today's workout, logs sets in one tap with the Digital Crown for
reps and weight, runs rest with +30 s and Skip, and shows live heart rate. The
phone stays the source of truth: `WatchCoordinator` publishes the watch's
view of the workout as WatchConnectivity's application context and runs the
watch's commands with the store calls the screens use, opening the account's
workspace just for the command when the watch wakes the app in the
background. The watch never links ExerlyCore or opens the database. Both
sides share small versioned JSON types in `Shared/WatchWorkout.swift`. The
phone sends each exercise's loadable weights from the gym's increments, so the
Crown steps through the same weights the phone's steppers do.

Commands keep their order: one message at a time while the phone is
reachable, otherwise `transferUserInfo`, and once one goes as a transfer the
rest follow it. Each carries an ID the phone remembers, so a message that
timed out and was resent as a transfer runs once. The phone's state names the
last command it handled, and the watch shows that state with its later
commands applied the way the phone will apply them (a unit test checks the two
agree), so a tap shows at once even with the phone out of reach.

Health gets one workout. The watch records an `HKWorkoutSession` with
`HKLiveWorkoutBuilder` (traditional strength training) for live heart rate and
activity credit, and tells the phone once Health is collecting; the phone then
marks that workout written instead of saving its own. I chose that over
relying on the sync identifier alone: HealthKit documents that a save replaces
an object with the same `HKMetadataKeySyncIdentifier` and a lower
`HKMetadataKeySyncVersion`, but not whether that matching spans sources, and
the watch app is its own source. Even if it does, the phone saves later with a
higher version, so its bare workout would replace the watch's one with heart
rate and energy. The watch's workout still carries the phone's record ID and
sync identifier, so the phone can remove it when the session is deleted and a
late duplicate can still collapse. It's saved only with the Workouts switch on
and at least one set done; otherwise it's discarded. Finishing with no set
done discards the workout on the phone too, instead of saving an empty one.
Known gaps: if the watch's notice is still queued when the workout is
finished on the phone, both may save; if the watch's save fails after it
started recording, Health gets none.

Not in this slice: complications, which need a watch-side App Group Ali hasn't
registered (QUESTIONS_FOR_ALI.md), and a standalone mode
(`WKRunsIndependentlyOfCompanionApp` is NO). Release builds sign the watch
app with its own App Store profile (`asc.mjs provision watch`, HealthKit),
which `release.sh` installs and `release_checks.py` verifies like the
widgets'. `apps/ios/scripts/watch-uitest.sh` runs the watch's UI test beside a
phone UI test on a paired pair of simulators.

## 2026-10-10: Recipes are built in food search and logged like any food

A recipe is a saved food with ingredients, so it syncs as a `saved_food`
document and shows up in search, recents and suggestions with no new paths. The
legacy `/api/library/recipes` route (flat macros, no weights) has no client and
is left alone.

- Totals add what the ingredients report, as a day's totals do. A nutrient no
  ingredient reports stays unknown; one only some report counts those, and the
  editor names the ingredients that leave out calories or a macro. A recipe
  logged whole then counts exactly what its ingredients logged one by one would.
  Making a nutrient unknown whenever one ingredient lacks it would drop most
  micronutrients from any recipe with a packaged ingredient.
- A share of the pot is a serving named "whole recipe" that weighs the cooked
  (or raw) total, logged with the share as its quantity: "0.25 × whole recipe".
  Entries need no new fields.
- Ingredients keep the serving and count they were entered in (optional
  fields, validated by the API like an entry's), so 2 eggs reopen as 2 eggs and
  half the recipe expands to 1 egg.
- Ingredients are snapshots. Editing a food doesn't change recipes made with it,
  just as editing a recipe doesn't change entries logged from it.
- Save as recipe makes one serving of a meal's weighed entries. Quick adds have
  no weight, so they are left out.
- The saved-foods CSV gains cooked weight, serving count, ingredients and
  preparation, which it dropped.

## 2026-10-10: Nutrient goals and pins are part of the plan

A nutrient's floor, target and ceiling were already fields of a nutrition
plan version, so editing one saves a new version from today
(`NutritionStore.revisePlan`), the way a Targets edit does: past days, their
charts and their averages keep the goal they had, which `IntakeSeries`
already read per day. Saving the daily value itself, or resetting to it,
removes the custom goal, so a later change to the reference applies. Like
other plan edits there is no undo; only check-ins have one.

Pins live in the same document (`pinnedNutrients`, up to three, never energy
or a macro). The plan is already per account, saved offline first and synced,
and the server's `nutrition_plan` check accepts the extra field. Server
preferences would have needed an API change for a list only the app reads.
Today shows the pins of the version in force today, on any day it shows, with
each day's own goal. Like every plan edit, two devices changing goals or pins
offline on the same day don't merge: the later version wins whole.

Versions that change only goals or pins needed two rules in ExerlyCore, both
tested. A check-in dates such a version from the one whose targets it kept
(`checkInPlan(on:)`); otherwise pinning fiber on check-in day would postpone
that week's check-in. And a version replaced by another starting the same day
never applied to any day, so the Versions list shows only versions in force
(`versionsInForce`) and labels goal-only ones "Nutrient goals". After an
accepted check-in, a goal edit hides its Undo, which would leave the edit's
copy of those targets in force.

A day's total of a nutrient some of its foods don't report says how many it
came from ("From 3 of 5 foods") on Today's pins and in the day's Nutrients
sheet, from per-nutrient counts on `NutritionSummary`; spans keep
`NutrientContributions`' "N of M entries didn't report it". A pin no food
reports reads "Not reported", never 0.

Taps, counted by UI tests from the screen a person starts on: a fiber floor
from Progress is 5 (Progress, Nutrition, Fiber, Edit goal, Save; the amount
opens focused and selected, so it is typed straight away), where
MacroFactor's help describes 7 from its dashboard (See All, the nutrient, the
goal icon, Active Goal, Custom, the field, the checkmark). Pinning two
nutrients from Today is 6 (ring, Nutrient goals, two pins, back twice)
against 7 or more (More, Dashboard, Add or Remove Nutrients, two toggles,
Save, Save); from a nutrient's page a pin is one tap. Unpinning from Today is
3 (the pinned nutrient, its pin, Done) against the same 7.

## 2026-10-10: Today's macros read as what's left

A code-blind run read "645 kcal left" on the ring but "75 / 132 g" for
protein and had to work out the 57 g left. Protein, carbs and fat now lead
with what's left, "57 g left", or "12 g over" in the ring's over colour once
a whole gram past the target, with eaten and target under the bar. Pinned
nutrients read the same way: "16 g to go" or "2,091 mg left" first (a limit
passed is in the warning colour), then "8.9 / 25 g", counted to the bound the
standing refers to, then the completeness line. VoiceOver hears the same
order, "57 grams left, 75 of 132 grams eaten".

## 2026-10-10: Fixes from the fourth code-blind usability run

- **An untouched time follows the meal.** Choosing another meal for an entry,
  or for a meal being built, moves an "Eaten at" no one set to that meal's usual
  time: the median time of its first food over the last 28 days, when it was
  logged on the day it counts for on at least 3 of them, else 8:00, 12:30,
  18:30 or 15:00 (the times Health export already used). Going back to the
  first meal restores its time, and a time the person set stays.
- **A remembered amount ignores corrections.** Changing a logged entry's amount
  marks it `amountChanged`, an optional field on the entry that syncs as it is.
  The amount one tap logs comes from the latest entry as it was logged, so
  halving tonight's chili doesn't make half a bowl the recipe's default. A food
  whose every entry was corrected starts from its default again. "0.5 × 1
  serving" reads "0.5 serving", and two "2 servings"; "2 × 1 banana" stays rather
  than guess at a plural.
- **Ingredients ask for their amount.** In food search for a recipe or a meal
  being built, a food the person has logged still comes in at that amount in
  one tap. Any other opens a portion step first, with the keypad on the amount
  and every serving the food has. Add confirms it and Cancel leaves it out.
  Swiping the step away keeps the food at its default, marked "Check the
  amount", and Save or Log meal opens that amount before going on. While a
  new food's amount is still its default, a named serving's chip means one of
  it ("1 whole" is one onion, not 15 g in wholes); once an amount is entered,
  or for one logged before, every chip converts and keeps the weight. After an
  add the search clears for the next food.
- **The chili's data was real.** USDA FNDDS gives raw ground beef only "1 cup",
  canned tomatoes "1 whole" and "1 cup" (no can), and onions "1 slice", "1 ring",
  "1 cup" and "1 whole" (148 g, a medium). Its "Tomatoes, canned, cooked" counts
  fat added in cooking (3.04 g per 100 g). The fixture serves that table as it
  is, so no fixture data changed. Open Food Facts foods carry only their label
  serving; offering the package as a serving is left for later.
- **One amount keypad.** Focusing an amount selects it, as does a new amount
  arriving while it's focused (a preset, a step or another measure), so the
  first digit replaces it. Delete with the caret before every digit takes the
  last one. The keypad's own button hides it and is an icon, so the screen's
  Done, Add or Save is the only one.
- **Search falls back to most of the words.** Generic foods need every word;
  when none has them all, the foods with the most of them, at least half, rank
  by the same rules, so "diced tomatoes canned" finds canned tomatoes. Foods on
  the device match each word anywhere in the name or brand instead of the whole
  phrase, with the same fallback at more than half: they're listed above the
  database, and "ground beef" shouldn't offer ground turkey first. The
  simulator fixtures that ran this build serve claude/next's API, so the
  database half shows only in the API's tests until it lands.
- **A workout cut short leaves its day next.** A session does its program day
  once at least half of the day's planned working sets are done; until then the
  program doesn't advance and the day doesn't count toward its progress.
  Offering the choice at every finish was the alternative. A rule the finish
  prompt states ("2 of 16 sets are done, less than half, so Pull stays your next
  workout") decides the common case without a question and needs no new field.
  The API's `next_workout` and program progress follow the same rule. The
  prompt gains a Cancel with no cancel role, which a popover would hide.
- **Workouts go by their day.** Recent workouts, history, the finish summary,
  Today and the workout's spoken label show a planned session by its day
  ("Pull"), as older sessions already were named.
- **A set's checkmark is drawn.** The checkmark symbol showed up inside every
  set's button as an image read "Selected", even hidden and with the button
  ignoring its children. A drawn checkmark that looks the same carries nothing,
  so only a done set's button is selected. It pops with a spring instead of the
  symbol's bounce.
- **Weigh-ins step by 0.1** lb or kg, on the ruler and the ± buttons, so any
  reading a scale shows is a few taps away. The ruler marks half pounds as it
  marks half kilograms.
- **A waiting check-in shows on Today**, in a banner above the day's numbers,
  not inside them, and opens Targets, where it comes first. Its numbers are
  dated ("As of Oct 4, your expenditure was about…", "…in the week to Oct 4"):
  they stop the day before the check-in, so they can differ from Today's current
  estimate.
- **Log again stays out of a meal already logged.** Once the meal its chips log
  into has food, the row isn't shown; a second usual breakfast offered beside
  the first is how the tester logged breakfast twice. Chips are sized so two and
  a clear part of a third show, snap as the row scrolls, and carry their log or
  undo action for VoiceOver even when the + is off screen.
- **Today's tab goes back to today.** Tapping it while it shows returns it to
  today, at the top.
- **Meals have a "…" menu** with Copy and Save as recipe beside the +; the long
  press stays. A recipe belongs to a meal it was made from (its foods are that
  meal's on a day in the last 14) or was logged to. That meal's Add food lists
  it first, under "Usual for lunch", and the empty meal on Today offers it in
  one tap. Food search's menu says "Log a meal" (several foods, logged now) and
  "Create a recipe" (kept to log again), each with a line saying so.
- **Progress's section picker is a bar.** Each tab scrolls under it, with the
  system's edge effect and an inset that starts content below it, instead of
  being cut off at its edge.

## 2026-10-10: Reminder buttons and a weigh-in reminder

Meal reminders carry buttons for their meal: Log usual breakfast, Repeat
yesterday's breakfast and Search. The meal is named when the reminder is
scheduled, from its time, as `suggestedMeal(at:timeZone:)` names it: by the
account's habit once its data is open (reminders are rescheduled when it
opens), else by the clock (`NutritionStore.meal(atMinute:)`). The title can't
change after delivery, so the button logs into the meal it names. Log usual
logs Today's first Log again chip for the reminder's time of day; Repeat
copies yesterday's meal only, because the button says yesterday (Today's
repeat button still reaches back a week), and only into an empty meal. Search
opens food search, and a workout reminder's Start workout follows the Start
workout intent's link. A new weigh-in reminder (`reminders.weighIn`,
`reminderTimes.weighIn`, set in Profile like the others and allowed by the
API) takes the weight typed into the notification, in the person's unit,
with either decimal mark and an optional "lb" or "kg"; the range check and
its message are the weigh-in sheet's. Tapping it opens a weigh-in.

Logging buttons run in the background through the intents' actions and ask
for an unlocked phone, as the intents do. A silent notification then says
what was saved in the intents' words ("Logged Blueberries, 80 g, to
Breakfast. 1,934 kcal left today."), or, titled "Nothing was logged", why
not: signed out, no usual food, a bad number, or a reminder left by another
account (its ID's owner prefix doesn't match). Each replaces the last. It
doesn't update the delivered reminder, because re-adding a request with a
repeating reminder's ID would replace its schedule. Sign-out removes
delivered notifications.

Taps from a banner or the Lock Screen: a usual breakfast is 2 (hold, Log
usual breakfast); a weigh-in is 2 (hold, which opens the weight field because
it is the reminder's only button, type, Log).

## 2026-10-10: The person's foods in Spotlight

`FoodEntity` is an `IndexedEntity`, indexed with `indexAppEntities`, the
iOS 18+ way that lets Spotlight hand a result back to an `OpenIntent`. Only
the person's own foods are indexed: the 100 most recently logged and their
saved foods and recipes, not archived ones and never the food database. The
index follows the library through `Observations` while the app runs, is
rebuilt each time the account's data opens, and is emptied at sign-out and
account deletion.

Spotlight decides what choosing a result does, and on iOS 26 it splits the
way I'd choose anyway. A food the Log a food shortcut offers (usual now, or
one of the 30 most recent) shows as that shortcut: a tap logs the remembered
portion and Spotlight shows the sentence it logged ("Logged Greek yogurt,
plain, 170 g, to Breakfast. 1,856 kcal left today."), 1 tap after typing.
Other indexed foods, saved foods and recipes never logged or logged long ago,
run `OpenFoodIntent`, which opens the portion sheet over Today (at the last
portion, else the first serving): 2 taps after typing. A portion just logged
is safe to repeat without looking; a first serving is a guess worth seeing.

## 2026-10-10: Duplicate a custom food

Food library's actions offer Duplicate food for custom and imported foods,
opening the label editor on a copy ("… copy", not a favourite, no barcode),
as Duplicate recipe does. Database foods aren't offered: their labels aren't
the person's to edit.

## 2026-10-10: Hidden suggestions sync as their own documents

"Don't suggest this" (a long press on a Log again chip or a usual food in
search, or the VoiceOver action) keeps a food out of `suggestions(at:)` and
its recipes out of `recipes(for:)`; search and Recent still find it. Undo is
in the toast, and Food library lists hidden foods with Suggest again. Each
is a `hidden_suggestion` document whose ID is the food's, so two devices
hiding different foods never conflict. Pins live in the plan, but there a
dismissal would need a plan (accounts without targets couldn't hide
anything) and would add a plan version to Targets' history each time.
Preferences are a fixed profile schema the server validates, so they would
need an API change too. A document kind is one validation in the API and
syncs like everything else. The API must deploy before a
build that syncs one, or that sync fails until it does.

## 2026-10-10: Choosing several foods on Today

Meals has Select, and each meal's menu has Select foods, which chooses the
whole meal. While choosing, a tap on a food toggles it instead of opening
it, + and the meal menus hide, and a bar offers Copy and Move. Its sheet
picks a day (yesterday, today, tomorrow or any date) and a meal or "Same
meals". A copy starts on the next day, a move on the same day, and Move
stays off until the day or meal changes. Copies are new entries with each
food's snapshot and portion, as copying a meal makes; a move keeps the
entries. Both toast with Undo: removing the copies, or moving each entry
back to its own day and meal. MacroFactor selects with a plain tap on its
timeline and can paste to several dates at once. In Exerly a tap still
opens an entry, so choosing costs one tap more, and pasting to several
dates isn't done.

## 2026-10-10: Amounts typed with the food in search

Food search reads an amount before the food ("500 g ground beef", "2 eggs",
"1 can kidney beans", "1 1/2 cups milk") or after it with a unit ("chicken
200 g"), and searches for the rest. `FoodSearch.amount(in:)` and
`Food.portion(_:)` in ExerlyCore hold the rules; the one picker behind the
search tab, a meal's Add food, recipe ingredients and Log a meal uses them.

- Weights always fit: g and kg as grams, oz and lb as ounces (16 a pound),
  the portion sheet's own ounces.
- A volume fits by a measure the food names ("1 cup" of milk, 244 g), else
  by a density: the label's, or one implied by a named cup, fl oz, tbsp or
  tsp. Without either, nothing is guessed.
- A count needs a countable serving: one named after the food ("1 egg"), a
  whole one ("1 whole" onion), or a first serving that isn't a measure. The
  brief said "count × the food's default serving", but USDA's first serving
  is often "1 cup" or "1 slice", so "1 onion" would have logged a 15 g
  slice. A count of a measure, or a size the food doesn't name ("2 large
  eggs" when it has only "1 egg"), opens the portion step with that count
  filled in rather than logging it.
- A bare number after the food stays part of its name ("Omega 3"), as do
  7up, 2% milk and counts over 50 ("100 Grand").

Rows show what one tap does ("500 g · 1,065 kcal"). Foods the amount fits
come first; the rest say "Choose amount", show no numbers, and open their
portion step. After a typed food is logged or added, the search clears with
the keyboard up for the next. The placeholder says it once: "Search foods,
or type 200 g chicken" (8 oz in U.S. units). MacroFactor's search, by its
help centre, sets the amount on each food's own screen.

The chili (500 g ground beef, 1 can kidney beans, 1 can diced tomatoes, 1
onion, 4 servings) went from 34 actions to 16 in RecipeUITests (11 taps,
5 typed), and 17 driving the realistic seed, which needed one scroll.

## 2026-10-10: Package sizes as servings

An Open Food Facts product with a `product_quantity` in g or ml gets it as a
serving: "1 can" when a category tag says canned or tinned, else "1
package". A multipack ("6 x 330 ml") gets none, because the size is all of
them, and a package the size of its serving isn't repeated. A package in
millilitres uses the category's typical density, recorded as the food's
volume basis. USDA's household servings already include cans where FNDDS has
them (canned tomato soup, 1 can 525 g) but not for kidney beans or diced
tomatoes, which fall back to the portion step; nothing is invented. A typed
container word ("jar", "bag") matches any package; "can" and "tin" only
cans. The golden file gained synthetic canned beans and tomatoes, a
multipack and a carton, which the simulator fixture serves.

## 2026-10-10: Recipe ingredients always ask for their amount

In code-blind run 5 a food logged before went into a recipe at its usual
single amount without a prompt (oats 40 g, yogurt 200 g, blueberries 80 g);
the tester fixed three of four afterwards, and overnight oats took 51
actions. An ingredient's amount is rarely one serving of it, so every
ingredient now opens its portion step, starting at the usual amount with the
keypad's number selected: Add keeps it, typing replaces it. An amount typed
with the food skips the step, and Log a meal and logging keep their one-tap
adds. Overnight oats typed (80 g rolled oats, 200 g milk, 150 g Greek
yogurt, 100 g blueberries, two jars, one logged) is 17 actions: 12 taps and
5 typed.

The same run found the keypad covering the amount and its − and + when a
food's serving chips pushed them down, and that a tap on "Amount (g)" did
nothing. The system scrolls only the text field above the keypad, so once
the keypad is up the field scrolls its whole row, and the presets under it,
into view, in every portion sheet. The caption now focuses the field.
