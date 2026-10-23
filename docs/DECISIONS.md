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

## 2026-10-10: Reminders get their own screen

Code-blind run 5 took 17 actions to set a 7:30 AM weigh-in reminder: free-text
24-hour times in the Preferences sheet, an "Enable reminders on this iPhone"
button that stayed grey until the sheet was reopened, and a result that only
said "1 reminder scheduled".

- **Where.** Profile has a Reminders row beside Units and Appearance. Its
  screen has a switch for each kind in the order of a day (weigh-in, meals,
  workouts, sleep). The whole row turns a switch on, its title included; the
  same style now serves the workout-day switches in the details sheet.
- **Times.** A switch that's on shows its time in a native time picker, in the
  person's locale (12-hour in the US). Meals have one picker per time, a remove
  button each and "Add a meal time", up to the API's ten; workouts show the day
  chips their reminder needs. Times are still saved as "HH:mm" in
  `reminderTimes`, so the API and other clients are unchanged.
- **Defaults.** A reminder turned on without a time starts at 7:00 for a
  weigh-in, 17:30 for workouts and 22:00 for sleep. Meals start at the person's
  usual breakfast, lunch and dinner (`NutritionStore.usualTime`, to the nearest
  5 minutes), which is 8:00, 12:30 and 18:30 before there's a habit.
- **No separate enable step.** Each change saves to the account as it's made,
  one save at a time; a change made during a save goes in the next one, and a
  conflict keeps this person's edits for the fields they touched. Turning a
  reminder on also turns on delivery on this iPhone, asking iOS for permission
  the first time. "Remind me on this iPhone" stays as a switch, so one device
  can be kept quiet.
- **What's scheduled, in words.** The screen lists what iOS holds
  (`NotificationService.scheduled`): "Weigh-in · every day at 7:30 AM",
  "Workout · Mon and Thu at 5:30 PM". Profile's row shows the first line.
- **Names match.** Reminders left the sheet that "Details & reminders" opened
  under the title "Preferences". Both the row and the sheet are now "Your
  details".

A 7:30 AM weigh-in from Profile is 5 actions: Reminders, Weigh-in, the time,
one turn of the minutes wheel, and closing the picker, plus Allow the first
time.

## 2026-10-10: One day and time for an entry

The portion sheet had a diary date and a separate "Eaten at"; moving the diary
date to Sunday left the meal eaten on Saturday at 7:30 AM. The portion sheet and
Log a meal now have one "Eaten" day-and-time control. The day chosen is the
diary day, and moving it keeps the time of day; a time no one set still follows
the meal on the new day. An entry saved with its time on another day (a late
snack an import counted for the day before) shows on its diary day and keeps its
exact time unless someone changes it. Logging to another day names it on the
button: "Log to Breakfast · Sun" within a week, else "Log to Breakfast · Oct 3".

## 2026-10-10: Delete sits in the entry sheet's toolbar

Delete entry was three swipes down, under the full nutrient panel. It's now a
trash button in the sheet's toolbar beside the favorite star, still behind the
confirmation, which names the day in words ("from Dinner on Sun, Oct 11",
"today", "yesterday") instead of "2026-10-10". Today's rows get no swipe action:
Today is a scroll view, not a list, and its meal list is being reworked for
multi-select.

## 2026-10-10: Reminder times turn in 5-minute steps

With the minute wheel in 1-minute steps, setting 7:30 from 7:00 took two or
three drags in the re-drive (7:10, then 7:22). Reminders don't need the minute,
so their pickers are the same system compact time picker with a 5-minute
interval, which SwiftUI's DatePicker can't set; :30 is six steps away. A time
saved off the step (07:03 from another client) keeps 1-minute steps, so the
picker never shows a different time from the one scheduled.

## 2026-10-10: Nutrient goals and Reminders under Your plan, with goal search

Nutrient goals was two screens into Your plan, and sodium was several screens
down its list. Profile now has a "Goals and reminders" group right under the
plan card: Nutrient goals ("Daily values · 2 on Today") and Reminders, which
moves up from Preferences so both are on screen without scrolling. The goals
list has a search field: typing part of a name shows only the matches, so "sod"
finds sodium without scrolling. Search was chosen over a jump index by group
because people look for a nutrient by its name, not its group.

## 2026-10-10: A recipe saved in the library can be logged now

A recipe saved from the food library used to leave the person in the list with
no way to eat it now; from food search it already goes straight to its portion.
In the library a card now says it was saved and offers "Log it now", which opens
the portion sheet at one serving, then says what was logged. The list shows a
recipe with servings by the serving ("297 kcal / serving"), as its page and
portion sheet do; other foods stay per 100 g.

## 2026-10-10: A lift's two estimates say which is which

The bench page's headline said 142 lb while its line said "best 141 lb" and the
Stats tile "Est. 1RM 141 lb". Both are right: the headline is the trend's value
at the last session, steadier than one session, and 141 is the best set's own
e1RM. They keep their maths and gain labels: "Trend estimate · best set e1RM
141 lb on Thu, Oct 8", and the tile is "Best e1RM". Changing the headline to the
best set would make Progress's list jump with every heavy or light day.

## 2026-10-10: Weekly bars are labelled under themselves

The weekly training chart labelled week boundaries, so dates sat between bars
and the last label named the week after the chart. Each label now sits centred
under its bar, every week for four weeks and fewer as the span grows, counted
back from this week so the current one is always labelled. Train's Recent list
starts with this week's total, "This week: 2 workouts · 31 sets", counted as
Progress counts its weeks.

## 2026-10-10: Re-tapping Profile already returns to its top

Run 5 read step 20 as Profile ignoring a re-tap, but that step switched back
from Today, which keeps a tab's place as iOS tabs do; the re-tap after it went
straight back to Profile's first screen. iOS pops Profile's stack and scrolls it
to the top itself, so a test now covers that instead of new code. Unlike
Today's, Profile's large title stays small after that scroll. Two attempts at an
extra animated scroll after iOS's own didn't bring it back, so it's left.

## 2026-10-10: A hard edge under Progress's sections

Text scrolling under Progress's Body, Nutrition, Training and Photos picker
showed through it blurred. The tabs' scroll views now use the hard top edge
effect, which backs the bar with the page's colour, as their bottom edges
already did.

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

## 2026-10-10: Recipe import from a link, and recipes shared as files

Import reads only a page's schema.org `Recipe` JSON-LD, which most recipe
sites publish for search engines; a page without it gets "This page has no
recipe data" rather than a guess. The server fetches the page, since it is
one hardened fetcher: http and https on ports 80 and 443; every address the
host resolves to must be public (private, loopback, link-local with
169.254.169.254, carrier-grade NAT, multicast, reserved, and IPv6 forms that
carry IPv4), checked by the connection's own DNS lookup so a rebinding
answer can't slip past, and again for each of at most three redirects; 2 MB
of decoded body and 8 s in all; no cookies or credentials; User-Agent
`ExerlyRecipeImport/1.0`. App sessions only, 30 an hour per account;
personal tokens get 403, so the agent API doesn't grow. The simulator
fixture serves synthetic pages from its own loopback address, allowed only
while `NODE_ENV=test` and `EXERLY_TEST_FIXTURE` are set, which nothing
deployed sets; a test checks both and that only the fixture makes the
allowance.

Lines are read on the device with the typed-amount parser, extended for
recipe pages: a weight in parentheses ("1 (15 oz) can" is a 425 g can; "2
cups (250 g)" is 250 g), ranges (the first number, marked to check), "1-1/2",
the fraction slash and more Unicode fractions, notes after a comma, "or" and
"plus", and preparation words. Each line matches a food of the person's own
with the same words, else the bundled USDA table through `/v1/foods/match`,
one request that spends no Open Food Facts searches. That match is stricter
than search: every word must be in the food's name and its first part made
of them, because "salt" found a salted granola bar and "flour" a flour
tortilla. The table lacks salt, flour and most spices, so those lines are
listed as not matched, with Search (starting from the line's amount and
food) and Skip; Save refuses until each is settled and scrolls back to them.
On three live recipe pages, checked once from devbox1, 16 of 47 lines
matched, all correctly; the rest were mostly spices, salt, oils, stock cubes
and branded cans. Matches from the person's own foods grow with use. A guessed amount (no
amount, a range, a unit the food can't take) uses the existing "Check the
amount" mark. The source URL is kept on the recipe and shown as a link.

Sharing sends a `.exerlyrecipe` JSON file (an exported UTType conforming to
public.json, opened by Exerly) with a plain-text summary as the message. The
file holds the name, yield, preparation, source and each ingredient's
snapshot; no ID, dates, favorite, brand or barcode. Opening it, or choosing
it in Import, opens the editor on a new copy whose totals are worked out
again from the ingredients. A file needs no server or link service and works
through AirDrop, Messages or Files. Not built: sharing a link from Safari's
share sheet, which needs a share extension and an App Group to hand the URL
over (still unregistered); people paste it, one tap with the system's Paste
button.

## 2026-10-11: One trend weight, and only one figure called "this week"

Code-blind run 6 saw 160.0 lb and −0.5 lb this week on Today, 159.8 lb and
−0.7 lb "a week" on Profile, the same with "this week" on Progress beside a
"Weekly rate" of −0.57 lb, and the trend line dipping on its last day below
the last two weigh-ins. Every screen reads `WeightTrend.summary` from the
same estimates. Between the screenshots the tester moved yesterday's 522 kcal
lunch to today, leaving yesterday complete at 989 kcal. With no weigh-in
today, today's trend is a forecast, yesterday's moved by yesterday's logged
balance: (989 − 1,861) / 7,700 kg, −0.25 lb instead of −0.10. Rebuilt from
the realistic seed, the trend goes from 159.96 to 159.81 lb and the week
from −0.55 to −0.70, exactly the screens' numbers. The trend sitting below
160.6 and 160.7 is water: the seed adds +0.6 and +0.8 lb those days to true
weights of 159.99 and 159.93. The model stays as it is.

The labels were the fault. "This week" now names only the summary's
seven-day change, worded by one function for Today, Profile, Progress and
Siri, with "Steady this week" when it rounds to zero. Progress's rate over
the chosen span is "Average, a week". A span now covers its full length, so
1W's change is this week's instead of six days'.

## 2026-10-11: The driver's screen text reads only the top layer

Run 6 reported no screen-reader text for the Log food sheet, the "…" menu,
New recipe, Choose foods, the Fiber goal and the workout summary. In
`app.debugDescription` each is there and labelled, as a later child of the
main window than the tabs, so the accessibility containers were not at fault.
The driver listed every layer, the screen under a sheet first and the sheet
last, so the sheet looked missing. VoiceOver reads only the top layer of a
modal presentation, and the dump now does too.

## 2026-10-11: Reminder times open in a popover

In run 6 the tap that closed the weigh-in time also turned on meal
reminders: the tester's tap fell outside the compact time picker's overlay,
on the Meals row, and iOS 26 passed it on. The time is now a button showing
it, which opens the same 5-minute wheels in a popover; a tap outside a
popover only closes it.

## 2026-10-11: Footers below the content, and the first screen on an SE

Run 6 tapped "About this food", half hidden under the portion sheet's Log
button on an iPhone SE, and logged the food. The brief asked for
`safeAreaInset` rather than an overlay, but the sheet already used it:
`safeAreaInset` insets the content yet still lays the scroll view out under
the footer, where XCTest (and the run's driver) treat a half-covered row as
visible and tap it, landing on the button. Every sticky footer (the portion
sheet, Choose foods, Log a meal, Quick add, the weigh-in, the plan editor,
gyms, plan setup and onboarding) and both floating bars (the rest timer and
Today's Copy and Move) now sit below the scroll view (`exFooter`): the content
ends at their top and scrolls clear of them, and nothing is under them.

The run also read the tab bar as covering content. Every tab already scrolls
its content clear of the tab bar; what it saw was the first screen's fold
falling across controls, and rows blurred under title bars that took their
taps. Bars now back onto the page's colour at the top as at the bottom (the
hard scroll edge Progress used), on Today, Profile and every screen built on
`ExScreen`, `ExList` or `ExForm`. On an SE's first screen:

- Today's Search, Scan, Quick add and Weigh in come right under the week
  strip. Under the ring, a check-in or a pinned nutrient pushed them under
  the tab bar. The ring is still on the first screen.
- Profile's Goals and reminders sit above Your plan, so Nutrient goals and
  Reminders are on the first screen, as the 2026-10-10 entry meant them to be.
- Train's workout card lists four exercises, so Preview and Empty workout show.
- The Apple Health offer sits under the weight chart rather than above it,
  and the chart is 30 points shorter, so its legend shows too.

## 2026-10-11: Hide a suggestion where it's suggested

Run 6 couldn't stop a food being suggested. It long-pressed a food in Add
food's Recent and got its portion sheet, then swiped one and got the sheet
again. Only usual foods had the menu, so on a recent food a long press was a
slow tap on the row's button, and a swipe that ended inside that full-width
button counted as a tap too. Now every usual and recent food in Add food, and
every Log again chip on Today, has a menu on a long press: Log (Undo once
logged), Details and Don't suggest this. Add food's rows also take a swipe
left, which uncovers Hide; a long swipe hides at once. SwiftUI's
`swipeActions` work only in a List, and these rows are in the screen's scroll
view, so the swipe is a sideways-only pan that never starts on a vertical drag
and, once started, keeps the row's button from taking the touch. The portion
sheet opened from one of these foods, or from a chip, has Don't suggest this
in its "…" menu. Each has Undo.

A hidden food now leaves Add food's Recent too. The 2026-10-10 entry kept it
there, but hiding a recent food that then stays put looks like nothing
happened. Search, Favorites and My foods still find it, and Food library lists
it with Suggest again.

## 2026-10-11: Today and Log food start fresh when entered from another tab

Run 6 came back to Log food with its last search still typed and to Today
scrolled past its week strip. Entered from another tab, Log food clears its
search and picks the meal for now, and Today returns to its top, keeping the
day it shows, as Profile already did. Re-tapping Today still also goes back to
today.

## 2026-10-11: A plain food before dishes named with it

In code-blind run 6, "1 slice toast" listed Shrimp toast and French toast
first under Food database. Generic foods rank by how directly the query
names them (design 023), and no FNDDS food is called "Toast": toast is
"Bread, white, toasted". A part of a name in the query's "-ed" form now
names it as the word does, the way "Fish, salmon" names salmon, so toasted
breads come before Shrimp, French and Melba toast, whose names add words. Of
99 common searches only "toast" and "roast" changed in their first five.
Among toasted breads the order is still by length (rye, soy, rice, white),
since FNDDS has no popularity. Two other fixes were tried and dropped:
matching "NFS", which design 023 calls plain but the code never matches,
and counting "NS as to" as plain. They put "Chicken, meatless, NFS" first
for chicken and a frozen spaghetti dinner first for spaghetti.

The person's own foods rank by the same rule (`FoodSearch.names`): those
the query names ("Eggs, scrambled" for eggs) first, then history before
saved foods as before. Their own "Whole wheat toast" doesn't name plain
toast, so it keeps its place by history, and it is listed above the
database anyway.

## 2026-10-11: Servings counted as named, and added where they're missing

Run 6 typed "2 eggs" and "1 slice toast", and the person's own Eggs,
scrambled and Whole wheat toast said "Choose amount": they have no
servings, and their portion sheet offered only g and oz. Nothing is
borrowed from a database food, since a raw egg's 50 g isn't the person's
scrambled eggs, so the rules of "Amounts typed with the food in search"
stand. Instead the missing serving is added once, where it's missed.

- Every portion step (Log food, an ingredient's, Log a meal's) shows the
  person's own food without a serving a chip after g and oz: "+ 1 slice"
  when the search named one ("2 eggs" gives 1 egg), else "+ Serving". An
  alert asks its weight in grams, as the food editor's servings do, saves
  it with the food as an ordinary saved_food change, and picks it at the
  count typed: 2 eggs, not 1. The next "1 slice toast" or "2 eggs" logs in
  one tap. An alert rather than fields keeps the sheet as short as it was
  on an iPhone SE. Database foods aren't offered it, as with Duplicate, and
  recipes have their own servings.
- A serving's leading number counts what it names. One slice of a label's
  "2 slices (56g)" is 28 g, where "1 slice" logged all 56 g, and one slice
  of USDA's "1/2 slice" is two of it. A measure before the name ("12 oz
  can") isn't a count.
- A typed serving word picks the plain serving ("1 slice") first, then the
  regular size ("1 medium or regular slice"). "1 slice" of toasted rye had
  picked "1 slice, crust not eaten", 13.5 g.

## 2026-10-11: Body depth: goal paths, gaps, what the trend rests on, every site, photos on the device

Outcome 3's body rows (PARITY S06, S07, S09, S10), each on Progress → Body or Photos.

- The goal stays in plan versions, edited in the plan editor that Targets
  uses, so a change starts a new version and earlier weeks keep theirs.
  `WeightGoal` adds the path each goal planned: it starts at the smoothed
  trend on the day the goal (direction, rate, goal weight) was set, and
  check-ins or nutrient-goal versions with the same goal continue it rather
  than restarting it. The chart draws the goal weight and that path for
  whichever goal was in force on each day. The rate stays a share of
  bodyweight a week, as MacroFactor's does, so its amount eases as weight
  falls; the editor already steps it in 0.1 lb or 0.05 kg, and
  `NutritionRate.share(ofWeekly:)` converts an amount back.
- On track means within 0.5 kg (about 1 lb) of the planned path, or within
  the trend's ±1 SD when that's wider, so a noisy trend can't be called
  ahead or behind. Maintaining has no ahead: any drift past the band is
  shown as up or down.
- Two or more days in a row without a reading draw the trend dashed and
  fainter, including the days since the last weigh-in. Dots are only real
  readings, as before.
- "What it rests on" gives each of the last 28 days' readings its exact
  effect on today's trend: the filter and smoother are linear in the
  readings, so nudging one by 1 kg and re-running gives its weight. It costs
  about 7 µs per day of history per reading in a release build and runs off
  the main thread. Older readings act through expenditure and are summed
  as the rest.
- Measurements sync through the daily-log API, `/api/measurements`, not
  ExerlyCore documents as the brief assumed. Its allowlist gains bust,
  shoulders and both sides of ankle, bicep, calf, forearm, thigh and wrist;
  `arms`, `thighs` and `calves` stay accepted so older history stays
  editable. Moving measurements to documents would mean a second migration
  for no gain the person sees. The one entry sheet saves its changed fields
  in one SwiftData transaction.
- Progress photos move from SwiftData to files, one folder per account in
  Application Support with complete file protection, and leave the device
  only through the share sheet. The `ProgressPhoto` model class is listed by
  all three frozen schema versions, so adding a pose to it would stop
  existing stores opening. Photos saved by earlier builds under the
  account's email are adopted once as front photos (the viewer moves one to
  another pose), each removed from SwiftData only after its copy is written.
  Deleting the account removes the folder. A UI test launch supplies
  synthetic images in place of the system photo picker, which XCTest can't
  fill.

## 2026-10-11: Today's diary depth: left or eaten, water, day status, By time, habits

PARITY N06, N18, N19, N20 and N33.

- Whether Today's ring and macros lead with what's left or what's eaten is
  a preference, `nutritionDisplay` (remaining or consumed), in Your details
  under Food log, saved through /api/preferences like the others and sent on
  the user, so Today follows it as it follows units. An overage is always
  signed: "+120 over" on the ring, the macros and Log food's confirmation.
- Water stays in its existing model: a day's total in millilitres on the
  API, queued offline by SyncEngine. The dashboard, agent tools and Daily
  health already read it, and a second store would drift from it. Removing
  is a negative change that stops at zero, as the API does, and Undo queues
  the opposite change. A glass is 250 ml or 8 fl oz; a bottle 500 ml or
  16.9 fl oz.
- The water goal is a preference, `waterGoalMl`, copied to goals.water_ml
  as the sleep goal is. Saving it through POST /api/goals would accept a
  new targets version. The goal counts water logged as water. Water in
  food, from the foods that report it, is shown apart and only added to the
  total: few foods report water (MacroFactor's help rates complete water
  tracking "very low"), so counting it would move the goal by which foods
  were logged, and it is never counted twice.
- "Log water" joins the Shortcuts. It opens SyncEngine's store for the
  signed-in account when the app was launched in the background for it.
  That makes ten App Shortcuts, iOS's limit.
- A day marked complete with nothing logged is unknown, not a zero, in the
  energy balance and its JavaScript port, as it already was in averages.
  Only a fast is a known zero. A day marked partial with nothing logged
  counts as partial, not as not logged. Check-ins say how many of their
  fully logged days were fasts and how many partial days were left out.
- By time groups a day's food by the clock hour it was eaten in the
  account's time zone. The hour clocks repeat in autumn shows twice, with
  its zone; food logged on another day or moved here is listed last.
  Moving an entry's day keeps its time of day, now in ExerlyCore with DST
  tests: a skipped time moves on by the gap, a repeated one is the first.
- Today's date button opens a month calendar of habits instead of the
  system date picker: complete, food logged, partial, fasted, not logged,
  and weigh-ins, each with its own shape. A tap opens the day. No streaks.
- Today's cards (quick actions, calories and macros, training, weight,
  water, meals) can be hidden and reordered in Customize Today. The layout
  is kept on the device for each account, not synced: it's a layout, it
  applies at once offline, and it needs no API. The day's status, note and
  Customize are in a menu beside the date button, and a status shows under
  the date.

## 2026-10-12: Today's diary tests run outside CI's tap-budget check

CI's iOS job runs the unit tests and `TodayUITests`, the tap budgets, within 60
minutes. The diary work added six slow tests to that class (water, leading with
what's eaten, a fasted day in the calendar, By time, a customized Today, and its
screenshots), which pushed the job past its limit. They now live in
`TodayDiaryUITests`, which the full local suite runs before every landing, and
`TodayUITests` holds the tap budgets again.

## 2026-10-20: password recovery by a mailed code

- Recovery mails an 8-character code (`ABCD-EFGH`, no 0/O or 1/I, 40 bits)
  rather than a link. A link needs universal links, an associated domain and
  a file hosted on sideband.studio; a code works in any mail app and needs
  nothing outside the API. It lasts 15 minutes, works once, is used up by
  five wrong guesses and is ended by a newer code. Only an HMAC keyed with
  the server secret and the account is stored, so a database copy can't be
  brute-forced offline.
- The request always answers 202 with one message, and the reset answers
  one 400 for an unknown address, a wrong code, a used code and an expired
  one, so neither says whether an account exists. The new password is
  hashed before the lookup so timing doesn't either. Limits: 5 requests per
  15 minutes per address, 3 per hour per email, 10 resets per 15 minutes
  per address.
- A reset revokes every session and every personal access token, unlike a
  password change: recovery is what someone does after losing control of a
  password, and whoever had it could have made a token. It doesn't mark the
  email verified; that stays a Sign in with Apple fact.
- Sign in with Apple accounts whose address is a real one can set a
  password this way. Accounts with a hidden-address placeholder can't
  receive mail and get the same answer as anyone else.
- Mail goes through `lib/mail.js`: a memory outbox in tests and the
  simulator fixture, the console in development, and nothing in production
  until Ali chooses a provider (QUESTIONS_FOR_ALI.md). Until then a
  production request answers as usual and logs that no mail was sent.

## 2026-10-20: deleting an account needs the password or a fresh Apple sign-in

- `DELETE /api/account` used to accept any valid session with
  `{"confirm": true}`, so a phone left unlocked or a copied access token could
  erase an account. It now also needs the password, or, for an account
  connected to Apple, a Sign in with Apple identity token for the same Apple ID
  issued in the last ten minutes, with its nonce (used up, like a sign-in's).
  The server verifies Apple's signature itself; the app's word isn't enough.
- A refusal is 403 (`wrong_password`, `apple_not_confirmed`), not 401: the
  session is fine, and a 401 makes the app refresh or sign out. Five attempts
  per account per hour, keyed by account so a copied session can't keep
  guessing, and so one person's guesses don't lock out others on a shared
  network.
- Accounts with both a password and Apple confirm with Apple in the app, since
  revoking Apple's authorization needs the authorization code from that same
  sheet. The API accepts either.
- Installed builds that send only `{"confirm": true}` get "Enter your password
  to delete your account" until they update. That's deliberate.

## 2026-10-20: a refresh credential presented twice ends its session

Refresh credentials already rotated on use. Now a genuine credential from an
earlier generation (checked by its HMAC, so a guess proves nothing) presented
again revokes the session: either the app or a copy of it is replaying, and the
server can't tell which. A retry of a lost acknowledgement with its own
operation key is still answered with the same credential, so a dropped
response never signs anyone out.

## 2026-10-20: the delete screen exports first, and sign-in errors say what happened

- Delete account now reads top to bottom: an Export my data button that shares
  the account file right there, what deleting removes and what it leaves
  (Apple Health records, saved exports), then "Confirm it's you": the password,
  or Sign in with Apple for an account connected to Apple. The alert that
  follows says so if nothing was exported. It reuses the export the Export
  screen makes rather than linking to that screen, which the imports slice is
  rebuilding.
- Forgot password lives on the sign-in screen and carries the typed email
  along. The code field formats as ABCD-EFGH while typing and offers the
  one-time-code keyboard suggestion. After a reset the app returns to sign-in
  with the email filled in and a note, instead of signing in by itself: the
  server ends every session on reset, and a fresh sign-in proves the new
  password works.
- A wrong password at sign-in said "Your session expired. Please sign in
  again." because every 401 read that way. Sign-in now says "That email and
  password don't match. Try again, or reset your password.", and a refused
  Apple sign-in says Apple couldn't confirm it.

## 2026-10-20: privacy declarations follow the 2026-10-20 data-flow audit

The manifest adds Search History (not linked: food searches and barcodes go to
Open Food Facts with no identity, and the server keeps them only in a
five-minute cache), Other Data Types (linked: age, sex and time zone), and the
file timestamp reason C617.1 for the label-photo import. The watch app gets its
own manifest for its UserDefaults, and release_checks.py requires it. Health
reads and writes that stay in Health or on the device aren't collected data.
The audit and the label table are in docs/release/privacy-review.md.

## 2026-10-20: a session alone never adds a way in, and password accounts always confirm with the password

The security review found a stolen session could connect its own Apple ID and
then use a fresh Sign in with Apple to delete a password account. Now:

- A password account confirms with its password, whatever else is connected.
  An account without one confirms with a fresh Sign in with Apple as an Apple
  ID it already has (lib/reauth.js).
- That proof is needed to delete the account, connect Apple, disconnect Apple
  and create a personal access token, since a token outlives the session that
  made it. Changing the password already needed the current one; there is no
  email change. Exporting stays session-only: a session can read everything
  the export holds anyway.
- Password fields are left out of the fingerprint kept with an idempotency
  receipt, so the receipts table holds nothing to test password guesses
  against.
- Refresh credentials carry their generation inside the MAC, so refusing a
  forged one is one HMAC, not one per rotation. Older two-part credentials
  rotate once more; reuse of one is recognised for 16 generations.
- Forgot password answers before looking the address up and issues the code
  afterwards, so its timing says nothing about which addresses have accounts.

## 2026-10-20: the app asks for the password to connect Apple or an agent, and confirms deletion on a sheet

- Connect Apple asks for the password first, Disconnect Apple asks for it in
  its alert, and Connect an agent has a "Confirm it's you" section: the
  password, or Sign in with Apple for an account without one. Delete account
  asks a password account for its password even when Apple is connected.
- The last "Delete this account?" step is a sheet (ExConfirmation) instead of
  an alert. At the largest text size the alert cut its warning off at
  "perma-" while Delete stayed tappable; the sheet scrolls and keeps Cancel and
  Delete reachable.
- The export on the delete screen counts only once the share sheet finishes
  sharing or saving it. Cancelling it used to count, which hid the "you
  haven't exported" warning.

## 2026-10-20: one guess budget per account, a new password ends agent access, and signup may say an email is taken

Security review round 2.

- Wrong passwords and refused Apple confirmations now share one budget of ten
  per account per hour across deleting, connecting and disconnecting Apple,
  creating a token and changing the password (lib/reauth.js). The separate
  per-route limits added up to 45 guesses an hour and are gone. Change
  password is also limited per account instead of per address. A missing
  proof, such as a password account asked for Sign in with Apple as well,
  doesn't count, so finishing a deletion never runs out of tries.
- Sign-in also allows ten wrong passwords per email per 15 minutes, whatever
  address they come from. Someone who knows an email can use that to hold
  its owner out of password sign-in for 15 minutes at a time; the message
  points to password reset, which still works. That is the usual trade, and
  better than unlimited guessing spread over many addresses.
- Changing the password now revokes every agent token, as a reset already
  did, and both pause webhooks made from a session. Such a webhook carries no
  data, but it tells whoever owns its URL when the account changes, so one
  set up by an intruder would keep leaking activity times. It is paused
  rather than deleted, stays listed with the reason, and the person can turn
  theirs back on. Webhooks made by a token stop with the token.
- Signup still answers 409 when an email already has an account. Accepted:
  a signup that never says so needs email verification, which needs the
  email provider Ali hasn't chosen yet (QUESTIONS_FOR_ALI.md). It's limited
  to 5 an hour per address and 5 an hour per email. Revisit once email
  verification exists.

## 2026-10-20: a password account connected to Apple deletes with its password and Sign in with Apple

This corrects two earlier entries from today. "The delete screen exports
first" said the delete screen confirms with "the password, or Sign in with
Apple for an account connected to Apple", and "the app asks for the password
to connect Apple" said a password account deletes with its password alone.
Neither holds once the server revokes Apple's authorization on deletion,
which the launch plan turns on (docs/RELEASE.md): an account with a password
and Apple then needs both, the password to prove who it is and a fresh Sign
in with Apple's authorization code so the server can revoke it.

- `AccountConfirmation.password` carries an optional authorization code.
- The delete screen asks for the password first. If the server answers that
  it needs Apple too, the password stays and a Sign in with Apple button
  finishes the deletion with both. Before, the screen swapped the password
  for the Apple button, every attempt was refused for lacking the password,
  and five refusals locked deletion for an hour.
- An account without a password still confirms with Sign in with Apple alone.
- For UI tests, a debug-only launch variable stands in for Apple's sheet, and
  the fixture can turn revocation on and records the codes it would revoke.

## 2026-10-20: sign-in limits are per network, so nobody can lock out a known address

Security review round 3. The per-email sign-in limit from round 2 could be
renewed by anyone: ten wrong passwords every 15 minutes kept a public address
(Ali's, for one) out of password sign-in indefinitely.

- The hard limit is now ten wrong passwords per email per network, the /24 of
  an IPv4 address or the /56 of an IPv6 one. Someone guessing from their own
  network shuts out only that network.
- Across all networks, wrong passwords for an email make every sign-in to it
  wait: nothing for the first three, then 100 ms doubling to a cap of 2 s.
  Guesses spread over many networks get slow, and the owner always gets in,
  at worst two seconds late.
- The trade: an attacker with many networks gets ten guesses per network per
  15 minutes, each slowed by up to 2 s, instead of ten in total. bcrypt and
  the 8-per-10-minutes per-address limit still apply. Against a reasonable
  password that is still hopeless, and a lockout anyone can trigger was the
  bigger risk for a small app with a public founder.
- A password reset proves the mailbox, so it clears the sign-in limits, the
  account's confirmation budget and its change-password limit.
- Both the confirmation budget and the sign-in limit now hold a place for an
  attempt before bcrypt or Apple's check runs, so requests sent at once can't
  all slip past the limit while they are being checked.
- The count of failed reset emails is no longer in the public /api/health: a
  failure only happens for an address with an account, so it told anyone who
  asked for a reset whether one existed. It's logged instead.

## 2026-10-20: rate limits read the client from do-connecting-ip, only on App Platform

Security review round 4. On App Platform, X-Forwarded-For names DigitalOcean's
ingress, so every client shared one address and anyone could throttle the
owner through it. Limits now take the client from `do-connecting-ip`, but
only when `EXERLY_APP_PLATFORM=1`, which `.do/app.yaml` sets. The header alone
proves nothing: anyone can send it to a self-hosted server, so without the
flag it is ignored and Express's one-proxy `req.ip` is used, as before.

A failure limit's in-flight attempts now count only against the window they
started in. A password reset clears the window, and guesses still being
checked when it happened no longer charge the fresh one.

A webhook paused while a successful delivery is in flight doesn't record that
delivery, so turning it back on can send that notice again. Notices carry no
data and receivers already handle repeats, so this stays.

## 2026-10-20: ship with do-connecting-ip trust off until it's verified on the live app

Security review round 5. DigitalOcean documents that App Platform adds
`do-connecting-ip` with the client's address, but not that it replaces or
strips one the client sent. If it doesn't, `EXERLY_APP_PLATFORM=1` would let
anyone send a different fake address with each request and slip past the
per-address and per-network limits. That is worse than leaving the flag off,
where every client shares the ingress's address: limits then over-count and
can throttle legitimate people together, but nobody can get around them.

So the flag is off in `.do/app.yaml`, and a test fails if it's switched on
there. `clientIP()` and its tests stay, ready for when Ali has checked the
deployed ingress: send a request with a forged `do-connecting-ip` through the
live app and confirm the server records the real address. The per-account
confirmation budget, the per-email sign-in backoff and the per-email signup
and reset limits don't depend on the address, so they work the same either
way.

## 2026-10-20: Barcode scanning reads camera frames with Vision, not DataScanner

Scan barcode now runs its own `AVCaptureSession` with a video data output and
reads each frame with Vision's `VNDetectBarcodesRequest` (`BarcodeDecoder` in
ExerlyCore). The alternatives:

- **VisionKit's `DataScannerViewController`** uses Vision underneath and is the least
  code, but it owns the camera: no torch, no exposure reading for a low-light prompt,
  no zoom from the lens's closest focus, and no way to feed it an image, so neither the
  simulator nor a benchmark could exercise it.
- **`AVCaptureMetadataOutput`**, the old scanner, decodes in hardware but can't be run on
  an image either, and it accepted the first read of a code, so a misread digit that
  passed its check digit could log the wrong food.
- **Vision on frames** gives one decoder for the camera, the simulator's stand-in feed and
  the benchmark; every retail symbology Vision reads, DataBar Limited and Expanded, Micro
  QR and DataMatrix included; and full control of torch, zoom, focus and exposure. Its
  cost is running Vision on each frame, with one frame in flight and late frames dropped.

The rest of the slice:

- A code is accepted after a valid check digit and two agreeing reads within 1.2 s. It is
  held while in view; shown again after a second away, it counts again, as a second pack.
- EAN-8 and UPC-E reads need 2.5 pixels a module. The benchmark caught Vision reading a
  small GS1 DataBar as an EAN-8 whose check digit passed, in two frames running, so two
  agreeing reads weren't enough. Closer than that they read at 100%; the scanner asks
  to hold the phone closer.
- Every form of a code is keyed by its GTIN-14. The phone normalizes and sends the
  GTIN-14; the server's `normalizeBarcode` already gives the same key, now checked by
  shared vectors. Prefixes 020–029 and 200–299 (in-store weighed or priced labels),
  040–049 (a store's own numbers), coupons and 977–979 publications are explained, not
  looked up. EAN-8s starting 0 or 2 are restricted numbers too but are looked up,
  because retailers' own-brand EAN-8s are stable and appear in Open Food Facts.
- Resolved codes are cached per account in the account's SQLite settings table: local,
  not synced, deleted with the account's database. It keeps 500 products and 60 scans,
  never dropping one waiting to resolve, and refreshes a product older than 30 days in
  the background. A scan offline with no cached product waits and resolves after the next
  sync or when the scanner opens; it logs to the meal, day and time it was scanned for.
- Several scans build one plate (`NutritionPlateDraft`) that logs in one tap. A found food
  no longer opens its portion sheet: it lands on the plate at its usual amount with −
  and + for one serving, so one item still logs in three taps from Today.
- A food entered for a missed code is remembered for that code on this device. Sending it
  to Open Food Facts is the next wave's.
- The iOS simulator can't run Vision's barcode revisions 2 to 4 ("Could not create
  inference context"), so the decoder falls back to revision 1 there and UI tests still
  go through Vision. The benchmark runs under `swift test` on the Mac at the revision a
  phone uses, and skips itself where only revision 1 is available, as it may on CI's VMs.
- Synthetic codes for the benchmark come from encoders in ExerlyCore, whose DataBar widths
  match bwip-js. DataBar Limited, DataBar Expanded, GS1 DataMatrix and Micro QR, which
  have large published tables, were rendered once by bwip-js (MIT) for synthetic GTINs
  under GS1's demonstration prefix 950, and are committed as test fixtures.

## 2026-10-20: Restricted EAN-8s aren't looked up; offline scans keep every intent

Review round 1 of the barcode slice changed four earlier calls:

- EAN-8s starting 0 or 2 are a company's own restricted circulation numbers (GS1 General
  Specifications), so two retailers can reuse one. They are no longer looked up, and no
  cached product answers them; a food the person entered for one does, on their account.
  This reverses the earlier entry, which looked them up for own-brand EAN-8s.
- Each scan made offline is kept as its own record with its meal, day and time, apart from
  the one-per-code history, so a later scan of the same code never overwrites it.
- A past scan with foods on the plate joins the plate rather than logging alone, and the
  plate can't be logged while an accepted scan is still being looked up.
- A pack accepted before the camera pauses stays held when it resumes and must leave the
  frame to count again.

## 2026-10-20: An offline scan is consumed in the transaction that logs it

Review round 2: an offline scan put on a plate was deleted before the plate logged, so a
discarded plate lost it. Now a plate only stages it, in memory and by scope (the scanner's
plate, or a meal being built, whose scope reaches the scanner through the environment).
The record is removed inside the same SQLite transaction as the entries that log it. A
crash, discard or cancel leaves it ready. While a scan is still being looked up, a past
scan always joins the plate, so nothing logs ahead of it.

## 2026-10-20: Offline scans travel with plate rows; logs publish after commit

Review round 3 found the staging registry could consume the wrong scan (it matched by
food) and that a failed outer commit could leave a draft marked logged. The registry is
gone. A plate row carries the offline scans it came from; a row removed or a portion
cancelled carries none away. `BarcodeLibrary.log` writes the entries and removes exactly
those scans in one transaction, and the store's entries, the library's pending list and
the draft's logged state change only after it commits. Discarding a plate needs no
cleanup elsewhere, so a running lookup can't hold scans hidden.

## 2026-10-20: Undo restores offline scans; a meal's scanner hides what's on the meal

Review round 4. A meal builder's scanner offered a scan already on the meal, and Undo after
logging offline scans deleted the entries but lost the scans. The meal's scanner now treats
the meal's scans as its own plate's: not offered, not counted as ready, not dismissed by Not
needed; a draft refuses a second row for one scan. `BarcodeLibrary.log` returns the scans it
consumed, refuses a scan no longer pending, and publishes through `afterCommit`, so nesting
it in a larger transaction is safe rather than forbidden. Undo goes through
`BarcodeLibrary.undo`, which deletes the entries and restores the scans of the foods undone
in one transaction. Undo is offered only while the app keeps the log in memory, as the toast
is. A liquid's amount now reads in ml, or fl oz for US units, from its density.

## 2026-10-21: An entry keeps the offline scans it consumed; Undo restores only those

Review round 5. Undo found a log's scans in memory, among the last 20 logs, and chose them
by food: a row's Undo spanning two logs, or one after 20 more logs or a relaunch, deleted
entries without their scans, and undoing one of two same-food entries put back both scans,
so the other could be logged twice. When `BarcodeLibrary.log` consumes a scan it now stores
the scan's whole pending record (ID, code, meal, day, time) against the entry it became,
under `barcode_library.consumed.v1` in the account's store, in the same transaction.
`BarcodeLibrary.undo(entryIDs)` deletes the entries still logged and puts back exactly the
scans stored against those, in one transaction; nothing in memory decides what returns, so
Undo of any log at any age, from any screen or after a relaunch, works the same.

A plain delete (Today, the entry editor) does not restore the scan. Deleting says "I didn't
eat it", which dismisses the scan too; its record stays, so undoing that delete makes the
entry the scan's one log again and a later Undo can still put it back.

`log` and `undo` read pending scans from the transaction they run in, not from memory, so
two calls in one caller's transaction see each other. A transaction's rollback now drops
only the after-commit actions it added; it used to drop every action at its depth, a saved
sibling's included. A pending scan's time is kept to the millisecond, as stored.

## 2026-10-21: A scan undone here and edited elsewhere can log twice; left to conflict review

Final review. The phone logs an offline scan as an entry and syncs; the tablet edits that
entry while the phone is offline; the phone undoes the entry, which puts the scan back, and
logs it again as a new entry. On the phone's next sync, `SyncEngine.receive` treats "deleted
here, changed there" as a reason to restore the entry, so both entries exist and the scan is
logged twice. That rule is the conflict policy for every synced entry kind, not something
barcode logging owns, and reviewing such conflicts is already the missing piece PARITY I03
and N08 track. Changing it here would fork the policy for one kind and pre-empt that slice.
`BarcodeLoggingModelTests.aScanUndoneHereAndEditedElsewhereIsLoggedOnceAfterSync` drives the
sequence through two real `SyncEngine`s and the fake document server and expects one entry,
under `withKnownIssue`, so it starts failing when the conflict-review slice fixes this.

## 2026-10-20: Imports are one undoable unit; export is made on the phone

PARITY I02, I12, I13, I14.

- One screen, Profile → Import & export, holds every import (MacroFactor,
  MacroFactor Workouts, Hevy, Strong and an Exerly export), the list of past
  imports with Undo, and Export. Setup's last page can open it once setup is
  done, and CSV, TSV, xlsx and JSON files shared to Exerly open the same
  preview. Exerly registers those types as Alternate, never Owner, so it
  doesn't take over other apps' files.
- The source is recognised from the file's contents, not its name or the row
  tapped: Hevy by `exercise_title` and `start_time`, Strong by `Exercise Name`
  and `Set Order`, MacroFactor Workouts by `Exercise` and `Date` alone,
  MacroFactor by a workbook or its food and day columns, an Exerly export by
  `documents` and `exported_at`. Formats follow each app's public help pages;
  the fixtures cite them.
- An import saves as one SQLite transaction across the account's stores,
  through `HistoryImporter`. A failure saves nothing, replacing the earlier
  kind-by-kind save that could leave half a MacroFactor import. A document
  that appeared or changed after the preview (a sync) is left as it is.
- Each import keeps a record in the account's own database: every document
  it wrote, what was there before, and a fingerprint of what it saved. Undo
  writes back the before, again as one unit, and keeps anything edited since
  the import. Records don't sync: their before copies can be large, and the
  documents themselves sync, removals included. Undo is on the device that
  imported. Importing a file again changes nothing and leaves no record.
- Exercise names are matched by name; the person can choose any exercise or
  leave a name's sets out, and the file is read again with that choice.
  Strong's unitless Weight column asks which unit was used.
- MacroFactor Workouts' mini-sets join the myo set before them as one myo set
  of several efforts. Strong's rest timers, Hevy's and Strong's routines and
  measurements, and MacroFactor's trend weight, expenditure, steps and body
  metrics are listed as not coming across. Body measurements stay out: they
  live in the server's older measurements table, outside the one-unit save
  and Undo.
- Export is built on the phone from the account's JSON export (server and
  device merged, or the device alone offline or when the server doesn't
  answer within 6 s, which the screen says): a zip with the JSON, a CSV per
  kind of data with the server's `/v1/export` columns plus nutrition targets,
  an .xlsx with the same sheets (inline strings, stored zip, no dependency),
  and a README. This reverses design note 022's "xlsx isn't produced": a
  writer turned out to be 80 lines and no dependency. The JSON gains
  `context` (time zone and mass unit) and `imports` (provenance: each
  import's source, files, time and documents).
- Restoring an Exerly export imports its `documents` into the account,
  keeping IDs; documents the account has are kept. The server's older tables
  and account details are listed as not restored. Exported, restored into a
  fresh account and exported again, documents and CSV files are identical;
  only `exported_at`, revisions (a fresh account hasn't synced) and `imports`
  differ.

## 2026-10-20: Imports after review: stale previews, workout identity, provenance, older tables

Supersedes parts of the entry above, after an independent review.

- A preview that a sync made stale is no longer saved in part: if any
  document it expects changed, nothing is saved, and the file is read again
  and shown with a note. A day's imported foods and the MacroFactor daily
  total they replace form one group: Undo keeps the whole day as imported
  when any food on it changed since, rather than putting the total back
  beside the foods, and says so.
- Hevy, Strong and MacroFactor exports have no workout ID (Hevy's CSV gives
  title, start and end; Strong's `Workout #` is a running count). A workout
  is known by its source and its start to the minute, with an ordinal for
  two starting in the same minute. A workout corrected in the app and
  exported again updates the imported one if Exerly still holds what the
  last import saved, judged from that import's record; one changed in
  Exerly is kept and the preview says so.
- Where imported records came from is an `import_provenance` document: the
  source, files, time and the documents (and measurements) it saved, in
  parts of 3,000 so each stays under the server's 256 kB. It syncs, is in
  every export and comes along when an export is restored. The `imports`
  key in the JSON export is gone; Undo records stay on the importing device.
- `POST /v1/import` restores the server's older tables too (food, measurements,
  weights, water, diary days, target versions, activities, sleep, goals, the
  older program, check-ins, library foods, recipes, workout templates, coach
  plans) with the importing account as owner and new row IDs, matched on
  natural keys so a second restore adds nothing. Sign-in identities, webhooks
  and setup drafts are never restored. `POST /v1/import/undo` removes what a
  restore added, keeping rows changed since. On the phone, a restore with
  older tables needs a connection: documents are saved, then the tables are
  restored through the account; if that fails, the documents are taken out
  again.
- Body measurements from MacroFactor's Body Metrics, Hevy's
  measurement_data.csv and Strong's measurement files go to the app's
  measurement log, saved before the document transaction and removed again
  if it fails; Undo removes them first and keeps any changed since. The
  server accepts `imported` as a measurement source, with the app in the
  note. Columns for sites Exerly doesn't keep (Hevy's abdomen) are listed as
  not coming across.
- The CSV files and workbook cover everything: every document kind without
  its own columns as id, revision, updated_at and payload JSON; the account
  and each of the server's older tables as they are; workout rows gain
  session and exercise notes.
- When the account can't make the export, the phone's copy is offered with
  the reason before anything is shared, instead of a note behind the share
  sheet.

## 2026-10-21: Restores of older tables after review round 2

- A restore records what it added in `restores` (migration 0009): each row's
  table, ID and a SHA-256 of the row as stored. `POST /v1/import` returns
  its `restore_id`; `POST /v1/import/undo` takes that ID, works only for the
  account that made it and only once (404 for another account's, 409 the
  second time), refuses any row the restore didn't add, and removes a row
  only while its fingerprint matches. That covers the tables with no
  revision (goals, program, check-ins, library foods, recipes, workout
  templates, target versions, coach plans) the same way as the rest. Tables
  the phone syncs get a deletion in its feed; soft-deleted tables keep their
  tombstones. Goals and the older program aren't in the feed, so they have
  none to leave.
- Importing again after Undo brings back what that Undo removed, in place
  and a revision past its deletion. A row the person deleted stays deleted.
- Matching: weigh-ins, water, day notes and check-ins on the day alone, so
  a day the account has keeps its own row and counts as kept. Deleted rows
  count, since their unique keys still hold. Food, measurements, activities
  and sleep without a client ID match on what they are (day, name or type,
  amount, time) and get a new client ID. Target versions match on effective
  date, creation time, reason and targets, since several can share a day.
- Activities and sleep get `identity_key` rebuilt for the importing account.
- Every restored row goes through its table's route checks (the routes now
  export them), a client ID must be a UUID, a missing revision becomes 1,
  and a row that fails is listed under `skipped` with its table and reason
  instead of being stored. The done screen lists them.
- Import and Undo are limited to 10 a minute per account, each separately,
  after sign-in. Per address, every account behind App Platform's ingress
  shared one limit.
- Restores insert a few hundred rows per statement and append their feed
  changes in one statement. At three years of synthetic data (11,315
  documents, 14,158 older rows, 7.5 MB) a restore took 185 s one row at a
  time and 5.2 s batched, and Undo took 35 s and 3.2 s, on devbox1 at a load
  average of about 250.
- Workouts from Hevy, Strong and MacroFactor are known by the start minute
  as the file writes it, not the instant it means in the account's zone, so
  re-reading a file after a move updates rather than duplicates. A workout
  the account already has keeps the zone it was saved in; only new ones
  take the current zone.
- A body measurement corrected in the source app updates the one an earlier
  import saved, while it still has that import's value. If it was changed in
  Exerly since, it's kept and the preview says so. Undo puts the earlier
  value back.

## 2026-10-21: Restores after review round 3

- Undo now writes into its receipt only the deletions it made, each with the
  revision it left, plus its counts (migration 0010 adds `outcome`). A later
  restore brings a row back only if it's still exactly that tombstone. A row
  Undo kept, or one the person deleted, stays deleted.
- Undo answers a replay with its first counts and `already_undone: true`
  instead of 409. The phone already treats that as success and goes on to
  its own part, so an Undo whose answer was lost, or whose local part
  failed, finishes when tried again.
- Receipts: restores read only undone receipts. A tombstone that's brought
  back is spent, and an undone receipt with none left is removed after 30
  days, which is also how long a replayed Undo can be answered. Receipts not
  yet undone stay, since Undo is offered later from Profile.
- A restored recipe's ingredients are stored as totals for their servings,
  so they're divided back to one serving before the route's check, and
  their servings are checked too.
- Check-ins restore before target versions. A version's `checkin_id` points
  at the check-in restored or kept for it, or is null.
- Undo compares what a row says, leaving out `updated_at`, `revision` and
  `revision_locked`, so a write that changes nothing doesn't keep it.
- On the phone, a measurement correction is applied and recorded only while
  the log still has the value the preview saw. Measurement Undo first puts
  corrected values back, then removes what the import added, each only
  while it's as the import left it. A failure at any step puts back what the
  earlier steps did.

## 2026-10-21: Restores and measurement Undo after review round 4

- Migration 0010 is folded into 0009, which now creates `restores` with
  `outcome` and the undone index. Neither had reached main or been deployed,
  so no database holds a 0009 receipt to upgrade. This replaces the round-3
  note that 0010 adds `outcome`. A test checks that receipts are created whole
  by one migration and that no later one changes them.
- An import compares a measurement's whole state (site, value, unit, day,
  source and note) before correcting or removing it. Any difference, a new
  day included, is an edit and keeps the measurement. Measurements have a day
  but no time of day.
- Taking back a measurement removal (when an Undo's record can't be saved)
  cancels a DELETE not yet sent, or queues the server's `/restore`, keeping
  the server ID and revision. It no longer re-adds, which queued a second
  create with the same client ID. Importing again after Undo goes the same
  way, followed by a change if the file's version differs.
- Importing again brings back a deleted measurement only when the latest
  import that touched it was undone and its Undo deleted it. Otherwise the
  person's deletion stands, and the preview says so.
- During cleanup, a restore receipt drops references whose tombstone is gone,
  no longer deleted, or at a different revision from the one Undo left.

## 2026-10-21: Imports on top of barcode's after-commit publishing

- `NutritionStore.writeAll` combines both branches: it prepares the writes,
  hidden suggestions included, inside the transaction and hands their
  publishing to `persistence.afterCommit`, so an import's records show once
  the outermost transaction commits and never after a rollback.
  `HistoryImporter.apply` still publishes after its own transaction, which
  is never nested.
- Saving an import checks each measurement against the preview first. A new
  one must still be absent, and one to bring back must still be the deletion
  the preview saw. Otherwise the preview is read again (`stale`). A deletion
  that arrived after the preview is never revived.
- If an Undo fails and can't put back the measurements it took back, it
  saves the import as still to undo, with the deletions it made, and says
  "Undo took back your imported measurements but couldn't finish. Tap Undo
  again." A retry adds to that list, so importing again brings back exactly
  those deletions.

## 2026-10-12: A goal weight already reached can't be saved as a loss or a gain

Code-blind run 7 set a 165 lb goal at "lose 1 lb a week" with the trend at
160 lb. The editor said the trend was already past it, then saved a 415 kcal
deficit, and Progress showed "On track" beside "at or past your goal".

- ExerlyCore: `NutritionGoal.isReached(trend:)` is true when the trend is at
  or past the goal weight in the goal's direction. `NutritionTargets.compute`
  then takes no rate, so a reached goal never cuts or adds calories, including
  in a check-in's proposal once a loss reaches its goal.
- The editor doesn't switch direction by itself. A goal weight on the wrong
  side is as likely a typo (155 meant) as a change of mind, and a silent switch
  would hide either. It says what's wrong under the goal weight and offers one
  tap: "Gain to 165 lb" or "Maintain instead". Save stays disabled, with the
  same reason above it, until the goal can be reached. Over a confirm-on-save
  alert, this shows the problem where it was made and keeps every choice on
  screen.
- Progress shows "Goal reached" instead of a path standing once the trend is
  at or past the goal weight, so it never says "On track" about a goal it has
  passed.
- Add a goal weight opens an empty field with the keypad up and the trend
  weight as its placeholder, instead of an unexplained 10 % under the trend.
  − and + start from the placeholder.
- With a trend weight, rate presets are round amounts in the person's unit:
  0.5, 1, 1.5 and 2 lb (0.25 to 1 kg) to lose, 0.2 to 0.8 lb (0.1 to 0.4 kg) to
  gain, on the 0.1 lb the editor shows, keeping those within the 1 % and
  0.5 % caps. A new direction starts on
  the preset nearest 0.5 % (0.25 % to gain).
- Faster and Slower step from the amount as shown (0.1 lb or 0.01 kg). The
  trend in a plan's basis is rounded to 0.01 kg, so 0.5 % of 72.57 kg is
  0.7999 lb; stepping from it kept "0.8 lb" for a tap.

## 2026-10-12: Spoons weigh by density, cans match canned food, and a drained can is an estimate

Run 7's "2 tbsp olive oil" matched the person's own olive oil, which names no
serving, couldn't convert a tablespoon, and came in at the 4 oz default
(about 1,000 kcal). "1 (15 oz) can black beans, drained and rinsed" matched
"Black beans, NFS", whose values are USDA's cooked-from-dried with fat added
(181 kcal/100 g): 770 kcal.

- A food's grams per millilitre come from its label, a measure it names (USDA
  spells them out: "1 tablespoon" now counts), or else its name: an oil is
  0.91 g/ml and water, broth, stock, vinegar, milk or juice 1.0, not when
  dried, powdered, concentrated or "in"/"with" one. Other foods have no
  density, and a volume of one comes in marked "Enter its weight": its
  placeholder amount counts for nothing and Save asks for a weight. No weight
  is guessed.
- Liquids offer 1 tbsp, 1 tsp and 1 cup beside grams and ounces in the
  ingredient and portion sheets, by the same density. Solids don't: a cup of
  a solid depends on how it's cut, and USDA names its own cups.
- Matching a recipe line: a can or tin asks for canned food, falling back to
  the plain name when nothing canned matches. "from dried", "from canned" and
  "no added fat" don't count as extra words, and no-added-fat forms win ties,
  since a recipe lists its own fat. Black beans are now "from dried, no added
  fat" (131 kcal/100 g); a can, "from canned, no added fat" (134).
- A drained can is 60 % of its label weight, typical for beans, chickpeas,
  corn and tomatoes, named "1 can, drained (9 oz)" and marked to check:
  342 kcal for the black beans. USDA's canned beans are the drained solids,
  so 425 g of them overstated the can by two thirds. The brief's 380 kcal
  assumed 90 kcal/100 g for the whole can; the bundled table has no
  solids-and-liquid entry.

## 2026-10-12: Next on the number keypad, and a found line goes back to its recipe

- The keypad has Next when a field follows on the same sheet or page (below,
  or to the right in a grid). Run 7 hid the keypad and tapped each of a new
  food's numbers in turn.
- A food made with "Enter a food manually" from a search with an amount
  ("3 oz tempeh") comes in at that amount, as a found food does, not at the
  4 oz default.
- Searching for an imported recipe's unmatched line closes once a food is
  added: one line, one food, back to the recipe.

## 2026-10-12: Preferences set where they're used, saved as they change

Run 7 looked for "lead with what's eaten" on the calorie ring and in Customize
Today before finding it in Profile → Your details, and reached the water goal
only through the expanded water sheet, which then opened Your details.

- Customize Today starts with "Calories and macros show: What's left / What
  you've eaten", and the water sheet has a Daily goal field (any amount the
  account accepts, 250 ml to 10 l, with − and + by a glass and three
  presets). Both save the account's preference at once, as a reminder switch
  does (`PreferencesStore.saveNow`), so it stays the single source and Your
  details shows the same value. The latest choice wins; one still sending is
  re-sent first.
- The water sheet opens whole, so the goal is in view. Its confirm reads
  "Log" (beside the Add / Remove choice it read "Add" twice), and once the
  goal has changed, Cancel reads Done.

## 2026-10-12: Today gives way to today after a long time away

Run 7 picked yesterday to see By time, spent 16 minutes importing a recipe in
Profile, and came back to "Yesterday". Coming back from another tab or the
background keeps the day shown for up to 3 minutes, so a quick look at Log
food doesn't lose it; after that, or on a new day, Today shows today. Re-tapping
Today still goes to today at once.

## 2026-10-20: Goal weight takes the same path from Targets and Progress

Driving the fix showed the goal editor's "Gain to 165 lb" and "Maintain
instead" under the keypad, which stays up after typing the goal weight. The
choice now replaces Save in the bar above the keypad ("Gain to 165 lb" and
"Maintain"), with the reason above it, until one is taken; the goal weight
keeps only the explanation. Save comes back once the goal can be reached.

Goal weight works the same from Targets and from Progress → Body:

- Run 7 tapped Add twice: "Add a goal weight" on Targets opened the editor
  with a second "Add a goal weight" in it. Add on Targets, and a new Add beside
  Body's "Add a goal weight" line, now open the editor at the empty field with
  the keypad up. Edit goal and Edit still open the editor as it was, since
  they may be for the rate or the macros.
- Targets said "already at or past this goal" in green under a loss rate, while
  Progress said "Goal reached". Targets now shows the same "Goal reached" pill
  and says to edit the plan to maintain or aim for a new goal.

## 2026-10-20: Next on the number keypad follows an order each form declares

Review round 1 found Next skipping Fat in the food editor at a larger text
size: it took the field below or beside on screen, within 8 pt, and
"Carbohydrate (g)" wrapping onto two lines moved Fat out of its row. In quick
add it also went from Fat on to the entry's name. Each form now names its
fields in order with `exFieldOrder` (the food and entry nutrient editors,
quick add, measurements, nutrient goals, manual targets, recipe yield,
activity and program targets). Next goes to the next one on screen, skipping
any not shown, such as a closed group of nutrients; a field outside an order
has no Next. Place on screen isn't used at all, so text size can't change it.

## 2026-10-20: One-tap preferences have their own queue, apart from Your details

Review round 1 found that Customize Today's eaten or left and the water
sheet's goal borrowed Your details' draft. Offline, with no draft, the change
did nothing and a relaunch showed the old one; a pending save blocked newer
ones; and the whole draft was sent, so an unfinished name or allergy went with
the water goal and could replace another device's change without review.

- `QuickPreferences` keeps these fields per account on the device the moment
  they change, shows them over the account's values (Today, the water row and
  the controls read it first), and says "Saved on this iPhone. It syncs when
  you're back online." while it waits.
- It sends only the fields it holds, against the revision it has just read,
  one send at a time; a change made while one is sending waits behind it, and
  only its newest value goes. A lost response is replayed as sent, so the
  server answers it again; a 409 reads the revision again and sends the same
  fields as a new write.
- Offline it retries after 3, 6, 12 and then every 20 seconds, and when the
  app comes back to the front or the connection returns.
- For these fields the last change wins, as a switch does, rather than asking:
  they hold one choice each and the person just made it. Your details' draft,
  its base revision and its conflict review are never touched, so an
  unfinished edit there still asks before replacing another device's save.

## 2026-10-20: Every repeat on Today's first screen, and a typed weigh-in in two taps

Counted against MacroFactor's public material (docs/TAP_BUDGETS.md), two flows
were in budget but not on the first screen, or not ahead of it:

- Repeating a meal or a day sat under the meals, past the training, weight
  and water cards: one tap, after scrolling, and a first-time user had to know
  to look there. Log again, under the calorie ring, now leads with the meal
  being eaten now as it was last logged ("Yesterday's breakfast · 2 foods"),
  one tap, a check after it, and a second tap takes it back like a food chip.
  Its title row carries "Repeat yesterday" for the whole day. Once today has
  food, that button repeats only the meals today hasn't logged ("Rest of
  yesterday"), never doubling one, and when the current meal is logged and
  the chips are gone it stands as a row of its own. A food from the meal
  logged on its own first is left out when the meal is repeated
  (`NutritionStore.repeatableDay` and `remaining`). Each meal's own Repeat
  row stays for the other meals; the meals header's Repeat button now shows
  only on other days, where it plans ahead.
- A typed weigh-in was three taps (Weigh in, the number, Save) against
  MacroFactor's two from a customised toolbar. A new weigh-in now opens on
  the last reading with the keypad up: the scale's number is typed over it,
  then Save, two taps; Save alone keeps the last reading. Done puts the
  keypad away for the ruler, ± and body fat. Editing a saved weigh-in opens
  on its reading as before. The ruler stays because a nudge of 0.1 is a
  single drag; it's no longer the first thing shown because people read a
  number off a scale and type it, as Apple Health asks.
- CI's tap-budget step now runs `TapBudgetUITests`, one counted test per
  budget, each from Today's top for a person with history, counting taps and
  scroll drags and passing only once the entry is on the server (a set:
  once it survives a relaunch, as PARITY B02 asks, because sets sync with
  the workout). `TodayUITests` joins the full local suite like
  `TodayDiaryUITests`, keeping the job inside its hour.
- Launch to logging is a signpost interval (`LaunchTiming`, app start to
  Today on screen) measured with XCTOSSignpostMetric and
  XCTApplicationLaunchMetric in `LaunchToLoggingUITests`, run locally, not on
  CI's shared runners.

## 2026-10-20: Fixes from a code-blind run of the five logging budgets

A fresh agent that hadn't seen the code logged a past food, yesterday's lunch,
the rest of yesterday, a weigh-in, and today's first set on a 17 Pro Max with
four weeks of history, without instructions. Every task took the budgeted taps;
these are what it hesitated over or got wrong, and what changed:

- One lunch food logged from a chip made "Rest of yesterday" skip the rest of
  lunch. A meal holding only foods from yesterday's same meal is now finished
  from it; a meal with anything else was eaten differently and is left alone.
- "Yesterday's lunch · 3 foods · 522 kcal" logged two foods (the third was in)
  and the ring moved less than promised. The chip shows what a tap will log,
  and every repeat's confirmation names it: "Repeated yesterday's lunch: 2
  foods, 290 kcal"; "the rest of yesterday" or "all of yesterday" for days.
- The day's button read as a "See all" link; it's a filled capsule now. "Usual
  for lunch" no longer shows once lunch has food.
- A waiting weekly check-in, above the ring, pushed Today's Start below the
  fold. It now follows the workout card (or Log again when training is hidden).
- The grey last reading, with a caret, read as a value already typed. The
  keypad's title says "Type over it, or Save to keep it", and the sheet opens
  at a height that fits the keypad and Save instead of full height with a gap.

Left for their owners: the workout screen doesn't mark which values are the
suggestion, nor explain RIR; Previous is low-contrast; the confirmation covers
the bottom of Today for six seconds.

## 2026-10-20: Each repeat owns what it logged; weigh-ins never save a placeholder

From an independent review of the tap-budget work:

- Log again's chips now agree with each other. A food chip shows its own
  check only for the entry it logged, and a softer "already in breakfast"
  check when a repeated meal or day put that food there; a tap on that logs
  nothing and leaves the other action's confirmation and Undo alone. The meal
  chip does the same ("already logged") once a day repeat covers it. The day's
  button stays after a tap, checked, so its Undo outlasts the six-second
  confirmation. Every Undo, a chip's second tap or the confirmation's, takes
  back exactly the entries its own tap created, and only those still as
  logged.
- Repeats match portions one by one, not foods. Yesterday's two bars at snack
  time leave one still to come after the first is logged today; a 30 g portion
  today stands for yesterday's 30 g, not its 60 g; a portion of neither size
  stands for the nearest. A meal holding more of a food than yesterday's did
  was eaten differently, and the day's repeat leaves it alone.
- A new weigh-in's last reading is a placeholder, not a value. Save stays off
  until a weight is typed, set on the ruler or ±, or picked again with "Same
  as last · 181.4 lb", which saves at once (Weigh in, Same as last: two taps).
  Clearing the typed digits with Delete, or putting the keypad away, leaves
  nothing to save. VoiceOver reads the number as a placeholder from the last
  reading. The shared keypad is unchanged.
- Launch is gated end to end: from the process starting (the kernel's start
  time, so loading the app's code counts) to the first frame drawn with Today
  and Log again, which the app's Debug build reports to the UI-test fixture.
  `onAppear` ran before anything was drawn, so the old interval flattered it.
  To shorten it: a saved session, its saved entries and its workspace open as
  the root view appears, not in tasks a render each later; the first frame
  draws Today's first three cards and the rest a frame later; today's workout
  is worked out for that frame, so Start shows instead of "No workout planned".
- At the largest text sizes the standard layout puts today's workout right
  under the shortcuts and Log again, above the ring and macros, which fill a
  screen there, and the four shortcuts sit two by two instead of four
  full-width rows. A layout someone chose in Customize keeps its order.
- CI runs four of Today's undo and navigation tests next to the tap budgets.

## 2026-10-21: Today's confirmation moves to the navigation bar; accounts open off the main actor

From the second independent review of the tap-budget work:

- A logging confirmation took the bottom of Today for six seconds, over
  Start and Log again's chips. It now takes the date's place under Today's
  title, with Undo at the bar's leading edge, and stays fifteen seconds (25
  with VoiceOver) since it covers nothing. Only a failure, which has nothing
  to undo, still shows at the bottom.
- Every Undo on Today (the confirmation's, a chip's second tap, the day's
  button) removes only entries still exactly as its tap logged them
  (`TodayUndo.removable`): one changed since, here or by another device's
  sync, stays. The confirmation keeps the entries as logged, not their IDs,
  and hides once another control has taken any of them back.
- Log again's checks and Undo survive refreshes on the day they were made:
  the launch's first sync, pull to refresh and coming back to the app. The
  shelf is rebuilt when the meal it was built for changes; the day's repeat
  keeps its Undo all day; a new day starts afresh.
- The weigh-in keypad keeps Same as last's row while typing, hidden once a
  digit is typed, so the keys never move under a finger.
- An account's sessions and food history are read and decoded on a
  background thread with a read-only connection of their own
  (`StoredAccount`); the stores start from that on the main actor. A file not
  yet migrated opens as before. A failed open is kept with its message until
  Try again, not repeated by every task that asks for the account.
- Launch ends once the frame that draws Log again (or the shortcuts) has
  been presented: two display refreshes after those controls appear, not the
  first callback, which only prepares the next frame. The logging cards are
  drawn in the first frame in any customized order.

## 2026-10-21: Launch ends on the commit of the frame that lays out the logging controls

Third pass at B03's end point, from review round 2. Display-link ticks don't
show when a frame is presented. With three years of history, Today was drawn
within 3 s, yet the two ticks the gate waited for arrived after 31 to 50 s,
with the main thread idle: an idle run loop isn't woken for them. Launch now
ends when the frame from the layout that places Log again (or the shortcuts)
has been committed. A run-loop observer ordered after Core Animation's commit
marks it, and the loop is woken so the observer runs even when nothing else
happens. The render server shows that frame at the next refresh. Today's
cards below the fold used the same display-link wait and now follow this as
well, so with a long history they no longer arrive half a minute late. The
launch reports where Log again was laid out, and LaunchToLoggingUITests checks
that place against the accessibility tree as each launch returns. With the
logging cards moved last, Log again is laid out below the fold, and the figure
for that order is the time to the frame that draws it there.

## 2026-10-23: A sync finds each food entry by ID, and Today's first frame draws every card above the logging tools

From finishing PARITY B03 after review round 2. With three years of history
(11,456 food entries), half the cold launches took 30 to 40 s to launch's end,
under XCTest and also launched directly with simctl. The 2026-10-21 entry put
this down to an idle run loop; a sample of a slow launch showed a busy one.
Today's first frame starts the launch's sync, and its push asks the nutrition
store for every document's payload to compare with the server's copy. Each
entry was found by scanning all of them, about 60 million comparisons on the
main actor before that frame could finish. Entries are now found through an
index by ID, dropped whenever the log changes. On the same simulator and data,
outside XCTest, launch went from 30.6 s p50 (2.8 to 33.4 s) to 3.7 s p50 (2.8
to 4.1 s). The launches near 4 s are still that sync: its push encodes every
document to compare, about a second with that history. Pushing only changed
documents would remove it; that belongs to the sync engine.

A customized order could also leave a card above the ring or the shortcuts for
the next frame, such as water fourth, above the ring, which then moved Log
again down after launch had reported its place. The first frame now draws the
first three cards and every card down to the last logging tool.
LaunchToLoggingUITests launches that order too: under the earlier rule, none of
its five launches reported Log again where it ended up.
## 2026-10-21: Two devices' changes to one record merge by field, and real conflicts wait for the person

PARITY I03 and N08. Foods, entries, weigh-ins, plans, programs, gyms and metrics merged as
whole values, so when two devices changed one record before syncing, the side that synced
second kept its whole version and the other edit vanished without a word. "Deleted here,
changed there" restored the record, which logged an undone scan twice.

Now every Core-synced kind merges three ways by top-level field against the version both
last agreed on (`Merge.fields`; sessions keep their set-by-set merge and days their own). An
entry's grams, serving, quantity and amountChanged merge as one amount, and a weigh-in's
time and day as one, so a merge never pairs one device's grams with the other's serving
count. Edits to different fields combine silently. When both changed one field differently,
or one deleted what the other changed, `SyncEngine.receive` keeps this device's value, or
keeps the record deleted, and writes a `SyncConflict` with the base and both versions in the
same transaction. A deleted record never comes back on its own, in either direction: a
deletion stands until the person brings a version back. The one exception is the workout in
progress, which isn't taken away mid-session; its conflict is still recorded. Inside a
session a set edited on one side and deleted on the other stays, as before, and is reported.

Conflicts are documents of kind `sync_conflict`, stored with the account's data and synced
like the rest, so every device sees them, they survive a relaunch, and an account never sees
another's. Both devices may change one at once; the later `changedAt` wins, which is safe
because a resolution's effect lives in the record it wrote, not in the conflict. The server
accepts the kind with a light check; an older server's 400 leaves the conflict on the device
for the next sync instead of failing sync. A device is named only by its kind ("iPhone") and
a random per-account ID, never its user-given name; the other side is "Another device",
since documents don't say who wrote them, with the server's `updated_at` as its time.

Resolving sets the conflicting fields to the chosen version by merging it into the current
record with that side preferred, so later edits to other fields stay. Keep both is offered for
entries and weigh-ins, where it means two records. Undo, for the last resolution this session,
writes the records back and reopens the conflict. When a conflict would bring back an entry
that barcode Undo removed, `ScanConflictEffects` keeps the scan logged once: if the scan was
logged again, that entry takes the other device's changes instead; if it is pending, bringing
the entry back logs it. `BarcodeLibrary.undo` now also keeps the scans it put back, by entry,
under `barcode_library.undone.v1`.

Today shows "Needs a look" with a count while any conflict is open; the review lists each with
both versions side by side and one-tap choices. Resolved conflicts are kept, not pruned, for
now: they are rare and small.

## 2026-10-22: Conflict review, round 1: versions stay as found, choices touch only what clashed

An independent review of the 2026-10-21 slice found five ways an edit could still vanish.

- A later clash about a record with an open conflict replaced that conflict's versions, so an
  unresolved 60 g against 90 g became 120 g against 150 g and the 60 g was gone without a
  decision. A conflict's base, versions and fields now never change once found; a later clash
  is a conflict of its own. Merging two copies of one conflict takes only the later resolution
  (`changedAt`), so a resolution or an Undo on one device can't take another's versions away.
- Resolving merged the whole chosen version against the original base, so a change made
  since, such as moving the entry to Dinner after the other device's Lunch merged in, could
  be put back. A choice now sets only the conflict's recorded fields (`Merge.apply`, with an
  amount's grams, serving and quantity as one group from `DocumentHost.fieldGroups`, and a
  workout's paths down to one set's field, one item, or a list's order), and everything else
  stays. Undo takes back only what the choice set and nobody changed since, merging three
  ways against what the choice wrote; a record changed since it was brought back, or a copy
  edited since Keep both, stays. Bringing back a record that is already back leaves it as it
  is. The randomized two-device check now keeps every edit a sync carries as an obligation
  until the person sees it and changes it, deletes it, or decides on a conflict holding it,
  and checks after every later step that some device shows it or some conflict holds it; it
  found the two Undo cases.
- The workout in progress was protected only when it had changed since the last sync, so a
  phone that had synced and logged nothing since lost its session and rest timer when the
  tablet discarded it. The check now comes before the unchanged-record fast path.
  The randomized check also counts a choice as the person's decision about what that device
  showed for the clashing fields, since the review shows it beside both versions, and follows
  a Keep both copy back to its conflict; run eight times over, its 120 seeds pass.
- Lists merged in the local order, so a phone that changed a workout's notes pushed its old
  exercise order back over the tablet's reorder without a word. `Merge.list` now compares the
  order of the items all three versions have against the base: one side's reorder is taken,
  two different reorders keep the preferred side's and are reported as `exercises[]` (or a
  set list's), and items only one side has follow, in that side's order.
- When the phone undid a scanned entry and logged the scan again, a tablet resolving the
  deletion conflict knew nothing of the phone's scans and brought the original back, and the
  phone took it in through an ordinary sync: the scan was logged twice. The entry logged
  again now carries `replaces`, the IDs of the entries Undo removed whose scans it logged,
  and it syncs (an additive, optional field; the server's food-entry check is unchanged).
  `DocumentHost.reconcile` lets the owning store keep its records true whenever a document
  comes back, through a resolution or through sync: `NutritionStore` turns an original coming
  back where its replacement is logged into the replacement's change, merged against the
  version both devices last agreed on, and keeps the original deleted. Only the device
  holding the replacement folds; folding on a device that merely hasn't received the
  deletion yet would decide the conflict for the person. A phone receiving an entry back
  whose scan is still pending consumes the scan (`ConflictSideEffects.broughtBack`), so it
  can't be logged again. The PARITY I03 pin from 2026-10-21 already passes on this branch;
  the tablet-resolves case is now a passing test with three variants.
- Undo of a delete wrote the deleted snapshot back as it was, so an edit another device made
  in the Undo window, pulled and kept in a "deleted here" conflict, was overwritten when the
  snapshot was pushed, and that conflict stayed open for a record that existed again.
  `SyncConflictStore.restore` brings the record back merged with each open deletion
  conflict's other version against its base, settles those conflicts, and records a new
  field conflict where both changed one field. `TrainingStore.restoreSession`, which the
  training review named, isn't on this base (the training branch hasn't landed), and nothing
  here offers Undo of a workout delete; `restore(_:)` for a session is ready for it and
  tested through sync. The diary's Undo of a food delete now goes through it.
- The review read a workout's nested paths as top-level fields, so a set conflict showed
  "None" on both sides and a goal "Its own goal". A workout path now reads as the exercise and
  set it names ("Barbell Bench Press: 102.5 kg × 5", with RIR, kind and "not done" when they
  apply, a whole exercise as its set count, an order as the names in turn), a plan's goal as
  "Lose 0.75% a week" or "Maintain", and other structured values as a mass or their first few
  named values. "Showing now" marked the finding device's version on every device and after
  every later edit; it now marks the version whose clashing fields match the record on this
  device (`SyncConflictStore.summary(of:)`), and when neither does, the card says what it
  shows now. The Undo bar is a bottom inset rather than an overlay, so at the largest text the
  last card scrolls clear of it. `EXERLY_SYNC_CONFLICT_SEED=all` adds a workout set and a goal
  conflict for the screenshots.

## 2026-10-23: Conflict review, round 2

- Undo of a resolution that brought a scanned entry back ran the barcode library's Undo first
  and unconditionally, so an edit made since (55 g brought back, then 65 g) was deleted and
  its scan put back as pending. The resolution now records what the bring-back wrote, and
  Undo runs the library's step only while the entry is still exactly that; changed or
  deleted since, the entry and its scan's log stay, as Undo keeps any record changed since a
  resolution, and the conflict reopens.
- An entry logged again from an undone scan named the entries it stands in for in its own
  `replaces` field. An app from before that field decodes entries with synthesized coding,
  drops it, and pushes the whole entry when the person edits it, so the link vanished and a
  device bringing the original back logged the scan twice. Of the three options the review
  named, the link is now a document of its own, kind `food_entry_link`, with the entry's ID:
  an older app has no host for the kind and skips it, so it can never rewrite it; it needs no
  server-side field preservation, which would have to guess which missing fields are
  "unknown"; and the barcode library's provenance is device-only by design. Links sync before
  entries, merge as a union, raise no conflict and are never deleted (a link whose entry is
  gone stands in for nothing). A link never names its own entry, names each entry once, and
  keeps at most eight: the first, which other devices most likely hold, and the latest seven.
  Logging again after another Undo inherits the undone entry's list, so a chain stays one
  list with its first entry first. The server checks the same rules and returns 400 for a
  bad link; a server from before the kind refuses it with 400 as well, and the app keeps the
  link and tries again next sync, as for conflicts. The branch never shipped, so `replaces`
  is simply removed from `FoodEntry`.
- Folding an original that comes back into the entry logged again from its scan took the
  original's value for every field both changed and dropped the clash, so 80 g logged again
  on the phone became the tablet's 60 g with nothing holding 80 g. `DocumentHost.reconcile`
  now returns its clashes with the writes (`Reconciliation`), and the caller stages each as a
  conflict about the entry logged again in the same transaction. Sync keeps that entry's
  value and offers the original's; a resolution that brings the original back keeps the
  person's choice and offers the entry's value, and Undo of that resolution removes the
  conflict it made. The fold needs the version both devices agreed on, which sync used to
  forget once the Undo's deletion was pushed, so every field differing from the relog (its
  time too) clashed. A tombstone's base now keeps the version agreed on before it
  (`SyncBase.previous`, SQLite schema 5 adds the column), and the fold merges against it.
