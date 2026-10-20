# ExerlyCore

Exerly's domain logic as a local Swift package with no UI and no dependencies:
models, calculations, persistence, and later sync and the agent model. The app
target links it and uses only its public API. Screens never do domain maths or
call the network themselves.

Owner: the logic agent. Design notes: `docs/design/002-exerlycore-training.md`.

## Use

```swift
import ExerlyCore

let store = try TrainingStore(persistence: InMemoryTrainingPersistence())
try store.startSession(name: "Upper", bodyweight: .kg(80))
let bench = try store.addExercise("barbell-bench-press")   // prefilled from last time
let setID = store.activeSession!.exercises[0].sets[0].id
var set = store.activeSession!.set(setID)!.set
set.primary = Effort(reps: 5, load: .kg(100))
set.rir = 2
try store.updateSet(set, in: bench, propagate: true)
try store.completeSet(setID)                                // starts store.restTimer
let summary = try store.finishSession()                     // summary.records: PRs
```

Test with `DEVELOPER_DIR=/Applications/Xcode-26.2.app/Contents/Developer` set.

- `swift test` in this directory.
- `scripts/live-sync.sh` runs the client and sync engine against the real API on
  a throwaway PostgreSQL database, on port 39102.
- The Keychain store needs a host app, so its test runs only when
  `EXERLY_KEYCHAIN_TESTS` is set.

## Public interface

Units are explicit. `Mass` keeps the value and unit entered; loads in
statistics are `Mass` in kilograms, so convert with `value(in:)` for display.
Volume is in kilogram-reps, durations in seconds, distances in metres.

### Units

| Type | Purpose |
| --- | --- |
| `Mass`, `MassUnit` | `Mass(225, .pounds)`, `.kg(100)`, `.lb(45)`; `kilograms`, `value(in:)`, `converted(to:)`; compares by physical amount. `Mass(validating:_:)` rejects negative or non-finite input. |
| `LocalDate`, `Weekday` | A `YYYY-MM-DD` calendar date. `LocalDate("2026-10-06")`, `LocalDate(instant, in: zone)`, `adding(days:)`, `days(until:)`, `weekday`, `startOfWeek(firstWeekday:)`. Encodes as a string. |

- `USUnits`: U.S. fluid ounces and feet and inches for entry and display, with
  stored values staying metric. `wholeMilliliters(fluidOunces:)` rounds to the
  nearest millilitre for integer stores such as water, so whole fluid ounces
  come back when shown to 0.1 fl oz. `feetAndInches(centimeters:inchStep:)`
  carries 12 inches to a foot. `grams(ounces:)` and `ounces(grams:)` convert
  the amount of food eaten exactly; nutrients stay per 100 g.

### Exercise library

| Type | Purpose |
| --- | --- |
| `ExerciseLibrary` | `.bundled` (119 exercises), `exercise(_:)`, `search(_:muscle:available:)`, `adding(_:)` for custom exercises. Search ignores case, accents and punctuation, and expands db, bb, kb and bw. |
| `Exercise` | `id`, `name`, `aliases`, `category` (strength or cardio), `metric`, `laterality`, `mechanics`, `region`, `muscles` (share per muscle: 1 target, 0.5 synergist), `actions`, `equipment`, `support`, `bodyweightShare`, `targetMuscles`, `synergistMuscles`, `validationErrors`. |
| `ExerciseID` | Stable string ID, such as `"barbell-bench-press"`. `ExerciseID.custom()` makes `custom-<uuid>`. |
| `Muscle` | 21 regions, each with a display `name`. |
| `JointAction`, `Equipment` | Joint actions; resistance, support and cardio equipment. |
| `TrackingMetric` | `weightReps`, `bodyweightReps`, `assistedReps`, `duration`, `weightDuration`, `distanceDuration`, `weightDistance`. `tracksReps`, `tracksLoad`, `requiresLoad`, `tracksDuration` and `tracksDistance` say which fields to show. |
| `Laterality`, `Mechanics`, `BodyRegion`, `ExerciseCategory` | Classification used for set credit and rest. |

### Sessions

| Type | Purpose |
| --- | --- |
| `WorkoutSession` | `id`, `name`, `startedAt`, `endedAt`, `timeZoneID`, `notes`, `bodyweight`, `exercises`; `localDate` (from its own zone), `isFinished`, `duration`. |
| `PerformedExercise` | `exerciseID`, ordered `sets`, `notes`, `supersetID`, `restOverride`. |
| `PerformedSet` | `kind`, `side`, `efforts`, `rir` (0 to 6, where 6 means 6+), `completedAt`; `primary` (the first effort), `isCompleted`, `counts` (completed and not a warm-up), `isLoggable(for:)`, `PerformedSet.rir(fromRPE:)`. |
| `Effort` | `reps`, `load`, `duration`, `distance`. A drop or myo set has one effort per continuation. For bodyweight exercises `load` is added weight; for assisted ones it is the assistance. |
| `SetKind` | `warmUp`, `standard`, `drop`, `myo`, `failure`. |
| `Side` | `left`, `right`, for unilateral exercises logged one side at a time. |

Editing functions on `WorkoutSession` (the store wraps all of them):
`addExercise`, `removeExercise`, `moveExercise`, `replaceExercise(_:with:previous:library:)`,
`addSet`, `updateSet(_:in:propagate:)`, `completeSet`, `reopenSet`, `removeSet`, `makeSuperset`, `removeFromSuperset`,
`set(_:)`, `performanceOrder`, `nextSet(after:)` and `finish(at:discardIncompleteSets:)`.
Failures throw `WorkoutSession.EditError`.

`validate(library:)` throws the first problem that makes a session
untrustworthy:

- duplicate exercise or set IDs, or an unknown exercise or time zone;
- an end before the start;
- a set that isn't sane: no efforts, negative or non-finite numbers, RIR outside
  0 to 6, or continuations on a set kind that has none;
- a completed set missing a field its metric needs.

Incomplete sets are drafts and may leave fields empty. `PerformedSet.isSane` and
`isLoggable(for:)` expose the two levels.

- `propagate: true` copies each changed field down to later incomplete sets that
  held the old value, and stops at the first one that differs.
- `nextSet(after:)` walks straight sets exercise by exercise and superset members round by
  round, then wraps back to sets skipped earlier.
- A new set copies the previous one. Unilateral exercises alternate sides and copy the
  last set on that side.

### Calculations

| Function | Result |
| --- | --- |
| `OneRepMax.estimate(load:reps:rir:)`, `estimate(_ mass:reps:rir:)` | e1RM from reps to failure (reps + RIR): Brzycki up to 10, Epley above; nil past 20. |
| `OneRepMax.load(forReps:oneRepMax:)` | The inverse, for n-RM estimates. |
| `OneRepMax.confidence(repsToFailure:)` | `high` up to 5, `moderate` up to 10, `low` above. |
| `Volume.effectiveLoad(_:exercise:bodyweight:)` | Kilograms per rep, including the bodyweight share; nil if unknown. |
| `Volume.tonnage(_:exercise:bodyweight:)` | `Tonnage` with `resistance`, `bodyweight`, `total` and `isComplete` (false when bodyweight was missing). |
| `Volume.setCredit(_:exercise:)` | 0 for warm-ups, incomplete sets and cardio; 0.5 for one side of a unilateral exercise; otherwise 1. |
| `Volume.byMuscle(_:library:)`, `Volume.weeklyByMuscle(_:library:firstWeekday:)` | `[Muscle: MuscleVolume]` (fractional `sets`, `tonnage`), and the same per week keyed by the week's first `LocalDate`. |

### History

`TrainingHistory(sessions:library:)` sorts sessions and indexes sets by exercise.

- `lastPerformance(of:before:excluding:)`
- `sets(of:from:through:)`, which returns `[SetRecord]`
- `statistics(of:from:through:)`, which returns `ExerciseStatistics`. It has every
  metric in MacroFactor's exercise export: estimated 1-, 3- and 10-RM, total and
  best-set volume, heaviest load, total and best-set reps, total and best-set
  duration and distance, and total sets.
- `oneRepMaxTrend(of:)`
- `records(in:)`, which returns `[PersonalRecord]` (e1RM, heaviest load, set
  volume, reps at a load, duration, distance), compared with earlier sessions.
- `weeklyMuscleVolume(firstWeekday:)` and `muscleVolume(from:through:)`

`ExerciseStatistics.isVolumeComplete` is false when a bodyweight exercise was logged
without a known bodyweight.

`WorkoutSummary(session:library:at:)` totals one session:

- `exerciseCount`, `totalSets`, `completedSets` and `workingSets` (completed,
  not warm-ups);
- `duration`, measured to `at` while the session is in progress;
- `tonnage`, with its completeness;
- `muscles`.

`Tonnage.total(in:)`, `resistance(in:)` and `bodyweight(in:)` give kilogram-reps or
pound-reps for display.

### Rest

| Type | Purpose |
| --- | --- |
| `RestPolicy` | `compoundUpper` 150 s, `compoundLower` 180 s (also full body), `isolation` 90 s, `warmUp` 60 s, `betweenSides` 15 s, `betweenExercises` 120 s. `rest(after:in:library:)` picks one from what comes next; a set within a superset round gets 0. |
| `RestTimer` | `startedAt`, `duration`, `endsAt`, `remaining(at:)`, `isFinished(at:)`, `extend(by:)`. Time left comes from a clock, so it survives backgrounding and suits a Live Activity. |

### Store

`TrainingStore` is `@MainActor @Observable`. Bind screens to `library`, `history`,
`activeSession`, `restTimer` and `restPolicy`.

Every change is applied to a copy and validated with `validate(library:)`.
A change that writes more than one thing is one unit
(`TrainingPersistence.performAtomically`): completing a set saves the set and
its rest timer, and finishing or discarding saves the session and clears the
timer. A
whole-session edit may not change the ID. The copy is saved first and published
only after that, so a failed change leaves memory and disk as they were. The rest
timer and rest policy are saved too, and come back after relaunch.

- `startSession(name:bodyweight:timeZone:)`
- `addExercise(_:at:)`, which prefills from history
- `addSet(to:kind:)`
- `updateSet(_:in:propagate:)`
- `completeSet(_:)`, which starts the rest timer
- `reopenSet`, `removeSet`, `removeExercise`, `moveExercise`, `makeSuperset`,
  `removeFromSuperset`
- `replaceExercise(_:with:)` swaps an exercise in place before any of its sets
  is done (PARITY T15). It keeps the position, superset, program slot, notes,
  rest, and the number and kinds of sets, prefilled from the new exercise's
  last performance. After a set is done it throws `.alreadyStarted`.
- `updateActiveSession { $0.notes = ... }`
- `previousSets(for:)`, the "previous" column
- `summary(of:)`, which returns a `WorkoutSummary` measured to now
- `finishSession(discardIncompleteSets:)`, which returns a `FinishedSession` with
  `session` and `records`
- `discardSession()`
- `startRest(seconds:)`, `extendRest(by:)`, `skipRest()` and `setRestPolicy(_:)`,
  all of which save and can throw
- `saveSession(_:)` and `deleteSession(_:)` for finished sessions
- `addCustomExercise(_:)`

Errors are `TrainingStore.StoreError`. An unfinished session is restored at
launch.

`TrainingPersistence` is the storage protocol.

- `SQLiteTrainingPersistence(url:)` is the on-device store. Use
  `SQLiteTrainingPersistence.defaultURL(accountID:)`, which is
  `Application Support/Exerly/<accountID>/exerly.sqlite`. Each account has its
  own file.
  - Each session is one JSON document, written atomically in WAL mode with full
    sync.
  - The schema version is in `user_version`. A file from a newer version is refused,
    never downgraded.
  - Rows it cannot decode are listed in `unreadableRows` and left untouched.
  - `loadValue(forKey:)` and `saveValue(_:forKey:)` hold small values, such as the
    rest timer and settings.
  - `close()` ends its use: reads and writes after it throw. Close the account's
    persistence when the account signs out or switches.
    `deleteDatabase(accountID:)` closes any persistence still open on that file
    before removing it, so a store that outlives its account can't write there.
  - `performAtomically` runs on one transaction; a nested call uses a savepoint.
- `InMemoryTrainingPersistence` is for previews and tests.

## Accounts and sync

One object owns the session: it signs in, refreshes and stores credentials. In
the Exerly app that is the legacy `APIClient`, which implements
`SessionTransport`; `AuthViewModel` hands out an `AccountAPI` bound to the
signed-in account. `ExerlyAPI` is a standalone owner for tests, scripts and
future targets. Never run two owners against one session: rotating refresh
tokens would race.

Wiring, with `ExerlyAPI` as the owner:

```swift
let api = ExerlyAPI(baseURL: apiURL, credentials: KeychainCredentialStore())

// Sign in with Apple: give Apple nonce.sha256, send nonce.raw to Exerly.
let nonce = AppleSignInNonce()
request.nonce = nonce.sha256
// ... after ASAuthorization succeeds:
let result = try await api.signInWithApple(identityToken: token, rawNonce: nonce.raw,
                                           name: fullName, timeZone: .current, unitSystem: nil)

let account = try await api.account()   // bound to result.account.id
let persistence = try SQLiteTrainingPersistence(url: .defaultURL(accountID: account.accountID))
let store = try TrainingStore(persistence: persistence)
let sync = SyncEngine(store: store, state: persistence, api: account)
try await sync.sync()   // at launch, on foreground, after finishing a session, and every few minutes

// Signing out, switching or deleting the account:
await sync.shutdown()   // returns once nothing more will be written or sent
try await api.signOut()
```

### SessionTransport and AccountAPI

- `SessionTransport.send(_:path:body:headers:as:)` sends one request as an
  account, refreshing once after a 401. It throws `accountChanged` when the
  session belongs to someone else, or is replaced or removed while the request
  is in flight.
- `AccountAPI(accountID:transport:)` is one account's endpoints:
  - the document endpoints `SyncEngine` uses (it is a `DocumentAPI`);
  - `connectApple(identityToken:rawNonce:)` and `disconnectApple()`;
  - `exportAccount()`, which returns the JSON `Data`;
  - `deleteAccount(confirmation:)`, which deletes on the server once an
    `AccountConfirmation` (`.password` or a fresh `.apple` authorization) shows
    it's the owner. A refusal throws `wrongPassword`, `passwordRequired` or
    `appleReauthorizationRequired` and keeps the session. After a deletion the
    session owner forgets the session.
  - `accessTokens()`, `createAccessToken(name:scopes:expiresInDays:)` and
    `revokeAccessToken(id:)` for the person's own agents. Every token can read;
    `.propose` files proposals, and `.write` changes data. The secret in
    `CreatedAccessToken.secret` is shown once and never again.
  - `exportCSV(.foodEntries)` (and `.savedFoods`, `.weighIns`, `.days`,
    `.sets`, `.metricValues`, `.metrics`) returns a CSV file, and
    `importExport(_:)` restores an `exportAccount()` file into this account,
    returning an `ImportResult`. See design 022.
  - `adoptLegacyTargets()` keeps an older account's saved targets as manual
    `nutrition_plan`s with the same numbers, unless it has a plan already.
    It returns how many were made; sync brings them in.
  - `webhooks()`, `deleteWebhook(id:)` and `enableWebhook(id:)` show and
    control the endpoints the person's agents registered to hear about
    changes (design 019). A `Webhook` says which token created it, its
    failures and last error, and whether it is disabled.
  - `searchFoods(_:limit:)` and `food(barcode:)` look foods up in Open Food
    Facts and return `DatabaseFoods`: unsaved `Food`s, ready for
    `NutritionStore.saveFood` or `log`, and the attribution to show with them.
    A barcode with no match returns nil. Pass the camera's
    `BarcodeSymbology` to `food(barcode:symbology:)`: an eight-digit code is
    refused without one, since EAN-8 and UPC-E look alike. Search on submit,
    not as the person types. A product labelled per 100 ml has a `volume` basis: the density
    used to convert it to grams, whether it was assumed, and a note to show.
    `per100ml` gives the label back, `grams(milliliters:)` converts an
    amount poured, and `milliliters(grams:)` (also on `VolumeBasis`, for an
    entry's snapshot) gives it back.

### ExerlyAPI

An actor, and a `SessionTransport`.

- `signInWithApple(identityToken:rawNonce:name:timeZone:unitSystem:)` and
  `signIn(email:password:)` return a `SignInResult` with `created` and
  `account` (`id`, `email`, `name`).
- `account()` returns the signed-in account's `AccountAPI`.
- `signOut()` forgets the session at once, then revokes it on the server when
  reachable. `deleteAccount(confirmation:)` deletes, then forgets.
- `isSignedIn` and `accountID`.

It refreshes the 15-minute access token before it expires and once after a 401. A
refresh's idempotency key stays in the credential store until the rotated
credential is saved. Each sign-in or sign-out starts a new session generation:
a refresh or request begun under an older one never saves credentials or
returns its response.

Errors are `APIError`, with user-facing descriptions (`LocalizedError`):

- `sessionExpired`: sign in again.
- `linkRequired`: a password account owns that email.
- `linkConflict`: the Apple ID is connected to another account.
- `appleReauthorizationRequired`: deletion needs a fresh Apple authorization code.
- `accountChanged`: the account changed during the request; nothing was applied.
- `accountDeleted`: the account no longer exists, perhaps deleted by a request
  whose response was lost. `ExerlyAPI.deleteAccount` treats it as success.
  Otherwise, remove the account's local data.
- `server(status:message:)`, `notSignedIn` and `invalidResponse`.

### AccountExport

`AccountExport.merging(server:hosts:state:pending:)` overlays this device's
unsynced documents on the server's export from `exportAccount()`. `pending` adds
the legacy app's queued entries (`SyncEngine.shared.pendingExportRows()` in the
app) to their tables: food, water, weights, measurements, diary days, activities
and sleep. Each added or replaced row is marked `"pending_sync": true`, and
anything deleted on the device is left out. Pass `nil` while offline to export
this device's data only; the result says so in `note`.

### Credentials

- `KeychainCredentialStore` keeps the session in the Keychain, readable after first
  unlock and never migrated to another device. It updates in place, so a failed
  write keeps the previous credential.
- `InMemoryCredentialStore` is for previews and tests.

### SyncEngine

`@MainActor @Observable`.

- `sync()` pulls, pushes, then pulls again. Overlapping calls share one run;
  cancelling the call that started it cancels the run.
- `shutdown()` stops it for good and returns once the current run has stopped.
  After that it writes nothing locally and sends nothing. Call it before signing
  out, switching or deleting the account.
- `state` is `idle`, `syncing`, `offline` or `failed(message)`, and
  `lastSyncedAt` records the last success.
- `SQLiteTrainingPersistence` and `InMemoryTrainingPersistence` both provide the
  `SyncStateStore` the engine needs.

How it decides what to send:

- A document needs pushing when its canonical JSON differs from the last version
  the server acknowledged. A crash between saving and syncing therefore loses
  nothing.
- Conflicts merge three ways with `Merge`: whichever side changed a field wins,
  local wins when both did, and items merge by ID. Nothing logged on either side
  is lost.
- Sessions and custom exercises sync today.

### Wire format and storage

- `ExerlyJSON.encoder` and `ExerlyJSON.decoder` use sorted keys and ISO 8601 dates
  with milliseconds. The store creates dates at whole milliseconds
  (`Date.roundedToMilliseconds`), so they round-trip exactly.
- `SQLiteTrainingPersistence.deleteDatabase(accountID:)` removes an account's
  local data after it is deleted.

## Agents: proposals and the audit log

Agents propose and people decide. See `docs/design/004-agent-core.md`.

```swift
let agent = try AgentStore(persistence: persistence, hosts: [store])
let sync = SyncEngine(hosts: [store, agent], state: persistence, api: api)   // proposals sync too

try agent.file(proposal)      // validated; changes nothing; audited
agent.diff(proposal.id)       // [DocumentDiff]: field paths with before and after
try agent.accept(proposal.id) // all changes or none; throws .stale if the data moved on
try agent.undo(proposal.id)   // restores exactly, or throws .stale
try agent.reject(proposal.id)
```

### AgentStore

`@MainActor @Observable`.

- `proposals` are newest first and `auditLog` is oldest first.
- `file(_:)`, `accept(_:)`, `reject(_:)`, `undo(_:)`, `diff(_:)` and
  `proposal(_:)`.
- Errors are `AgentError`: `notFound`, `duplicate`, `invalid(message)`, `stale`,
  `alreadyDecided` and `notAccepted`.
- A decision, its data changes and its audit event are saved as one unit.

### Proposal

- `author`: an `AgentIdentity` (built-in, MCP or API, with a name and token ID).
- `title`, `summary`, `confidence` and `falsifier`, which must not be empty.
- `changes`: `[ProposedChange]`, each with a kind and ID, plus `before` and
  `after` as `JSONValue`.
- `evidence`: `[Evidence]`, each with a claim, an `EvidenceLevel`, caveats, data
  references, an optional `MetricReference` and an optional source.
- `status` and `decidedAt`.

### Supporting types

- `MetricReference` names a number ExerlyCore can recompute: the best e1RM or
  total volume of an exercise over a date range, or weekly sets for a muscle.
  `verify(against: history)` returns `verified(actual)`, `mismatch(actual)` or
  `unverifiable`. Show a mismatch: it means an agent's number is wrong.
- `AuditEvent` is append-only: proposal filed, accepted, rejected, undone or
  stale; a direct write; a token created or revoked.
- `JSONValue` is any JSON value; `JSONValue.diff(_:_:)` lists field changes.
- `DocumentHost` is the protocol `TrainingStore` and `AgentStore` implement, so
  sync and proposals can work on any kind of document.

## Built-in detectors

Code, not a model, finds these, from the training log alone. How they were
measured is in `docs/design/005-training-detectors.md`.

- `EntryErrorDetector` finds likely typing slips in a finished session:
  - a load ten times off;
  - a load entered in the unit this person doesn't use for that lift;
  - a stray digit in the reps.

  `proposal(for:history:existing:now:)` turns them into one `Proposal` from
  `EntryErrorDetector.author`, ready for `agent.file(_:)`. It never proposes
  twice for a session, whatever the person decided. Its ID comes from the
  session's, so two devices file one proposal. After finishing a session and
  after sync, call `proposals(in:existing:now:)`, which checks the workouts
  finished in the last `recentDays` (14) and leaves older ones alone.
- `TrainingSignals` gives evidence, not proposals, as a `Diagnosis` (kind,
  title, summary, exercises, evidence):
  - `stall(of:in:through:)` and `stalls(in:through:)`: an e1RM trend that hasn't
    gained 0.3 % a week over eight weeks, with its slope, sessions, RIR and
    volume caveats; a clearly falling trend is titled and summarised as a drop;
  - `deload(in:through:)`: several lifts down together over the last ten days.
  - `trend(of:in:through:days:)` exposes the numbers behind both.
- `WeeklyReview.make(training:proposals:checkIn:through:firstWeekday:)` returns
  at most three `ReviewItem`s, ranked, each with evidence and a falsifier: a
  nutrition goal that can't be kept, the deload signal, pending check-ins,
  falling lifts, pending entry checks, stalls, agents' proposals, then thin
  logging. Item IDs are stable within a week, so a dismissal can stick.

## Programs and progression

`docs/design/006-programs-progression.md` has the design and the measured
accuracy.

- `Program` is a synced document of kind `program`:
  - `days` is one cycle of `ProgramDay`s; a day without slots is a rest day;
  - `cycles` runs 1 to 52, and `deload` is `.none`, `.first` or `.last`;
  - icon, colour, and created, activated and archived dates.

  `validationErrors(library:)` explains what's wrong. `target(for:cycle:)` gives
  a slot's target, applying a deload: half the sets and 2 more RIR.
- `ProgramSlot` holds:
  - the exercise, notes and a superset group;
  - a `SlotTarget` (sets, rep range, RIR, rest and set kind);
  - per-cycle targets;
  - `expandRepRange` and `weightMatch`, both read by progression.
- `ProgramStore(persistence:training:)` is a `DocumentHost`. Put it after
  `TrainingStore` in `SyncEngine(hosts:)` and in `AgentStore(hosts:)`, so agents
  can propose programs. It offers:
  - `save`, `activate`, `archive`, `restore` and `duplicate(_:name:)`;
  - `active`, the most recently activated program that isn't archived;
  - `activeAfterArchiving(_:)` and `activeAfterRestoring(_:)`, which change
    nothing and say which program would be followed, for a confirmation;
  - `nextWorkout(bodyweight:)`, which returns a `WorkoutPlan` for the active
    program.
- `ProgramSchedule.next(for:in:)` finds the next training day from sessions'
  `ProgramRef`. `progress(of:in:)` counts done and total sessions, and
  `plan(_:at:history:bodyweight:)` builds a plan.
- `TrainingStore.startSession(from:bodyweight:)` starts a session with each
  exercise's planned sets prefilled, not completed, and links it to the program
  day through `WorkoutSession.program`. Each exercise keeps its `slotID`.
- After `finishSession`, `programs.proposal(applying: finished.session, existing:
  agent.proposals)` offers to keep the workout's changes in the program
  (PARITY P06). File it with `agent.file`; it is nil when nothing changed.
  - Swaps take over their slot.
  - A different number of working sets becomes the slot's sets for that
    cycle. A deload cycle without its own targets is left alone.
  - Exercises added and done become slots, with targets from what was done.
  - Skipped exercises stay, and the order is kept.
- `Progression.recommend(_:exercise:history:bodyweight:increments:expandRepRange:)`
  returns a `Recommendation`:
  - per-set `PlannedSet`s with reps, load and target RIR;
  - a `reason`: first session, progress, hold, reduce or repeat last;
  - the e1RM used, the basis set, and whether the reps went outside the range.

  Show the reason. `LoadIncrements.defaults(for:)` gives equipment steps, which
  the person can override.
- `Progression.adjust(_:exercise:done:remaining:planned:bodyweight:increments:expandRepRange:weightMatch:)`
  re-plans the rest of a slot after each working set, from how that set went,
  a little weaker per later set. With `weightMatch` the load stays and the reps
  follow; without it each set gets its own load. In a first session the first
  set is the assessment that gives the rest their loads. Call it whenever a
  set is completed and show the new plan for the sets left.
- `Plates.load(_:bar:stock:)` gives the heaviest load at or under a target that
  the bar and `PlateStock` pairs can make, the plates per side and any
  shortfall. It searches every combination, so limited or mixed-unit plates
  still reach the best load. On a tie it uses the fewest plates, then the
  heavier ones. A target lighter than the bar sets `isBelowBar`; say a lighter
  bar is needed.
- `WarmUpScheme` (`.standard` or `.heavy`, or custom steps of fraction and reps)
  turns a working load into prefilled, incomplete `warmUp` sets. It rounds to
  loadable weights and never repeats a load. Barbell schemes start with an
  empty-bar set (PARITY T17).

### Importing from Hevy and Strong

See `docs/design/018-workout-imports.md` (PARITY I13, T20).

- `WorkoutImport.parse(_ csv:timeZone:unit:library:mapping:)` reads a Hevy or
  Strong export and returns a `Result`: the `source`, finished `sessions`, how
  each name was `matched`, `unmatched` names with their set counts, `skipped`
  sets with reasons, and `assumptions` (a unit the file didn't state). It
  throws `.unrecognized(headers)` for any other file.
- Show the preview and let the person map unmatched names with
  `ExerciseLibrary.search`, then parse again with `mapping`.
- `training.importSessions(result.sessions)` adds them all or none and
  returns how many were new. IDs come from the file, so importing it twice
  adds nothing. Use it to backfill a past workout too.

### Recovery

See `docs/design/020-recovery.md` (PARITY B05).

- `RecoveryStatus.assess(days, on: today)` takes `RecoveryDay`s from Apple
  Health (sleep hours, HRV in ms, resting heart rate) and compares the last 3
  days with the person's 28-day baseline. Its `state` is `.strained` when at
  least two signals are a standard deviation worse than usual, `.normal`, or
  `.notEnoughData`. `readings` and `summary` say which and by how much.
- `plan.lightened()` keeps two thirds of each exercise's working sets at one
  more rep in reserve. Offer it on a strained day; don't apply it silently.

### Gyms

See `docs/design/016-gym-profiles.md` (PARITY T05, T06).

- `GymProfile` is a synced `gym_profile` document. It holds a name, the
  equipment the gym has, its bars (the usual one first), its `PlateStock`,
  `loads` (the weights equipment such as dumbbells or a stack comes in), and
  excluded exercises.
  - `allows(_ exercise:)` is true when the exercise isn't excluded and the
    gym has all its resistance and support equipment. Use it in pickers and
    swaps.
  - `increments(for:)` gives the steps for an exercise there. Listed loads
    become `LoadIncrements.available`, which progression chooses among.
- `GymStore` hosts them: `gyms`, `save`, `activate`, `archive`, and `active`,
  the most recently chosen gym that isn't archived. `increments(for:)` uses
  the active gym. Pass it to `ProgramStore.nextWorkout(bodyweight:increments:)`,
  and the active gym's bar and plates to `WarmUpScheme.sets` and
  `Plates.load`.

### Generating a program

See `docs/design/017-program-generation.md` (PARITY P02).

- `ProgramGeneration.Request(daysPerWeek:goal:experience:emphasis:minutes:)`:
  2 to 6 days; hypertrophy, strength or general; beginner, intermediate or
  advanced; muscles to emphasise; 30 to 150 minutes a session.
- `ProgramGeneration.generate(_:library:gym:)` returns a `Result`: the
  `program`, `weeklySets` and `targets` by muscle, and `shortfalls`, the
  muscles under 80 % of target. It throws `.invalid` for a request out of
  range.
- `ProgramGeneration.proposal(for:library:gym:)` wraps it as a proposal to
  add the program, with its research evidence and any gaps in the summary.
  File it with `agent.file`; accepting adds the program, not yet followed.

## Nutrition

`docs/design/007-nutrition.md` has the design and the measured accuracy of the
trend weight and expenditure.

- `Nutrient` is the catalog: energy, macros, carbohydrates and fats in detail,
  vitamins, minerals, essential amino acids, alcohol, caffeine and water, in
  `Nutrient.Group`s. Each has a `name`, a `unit` and, where public, an adult
  `reference` intake marked `.atLeast`, `.atMost` or `.target`.
  `NutrientAmounts` holds amounts per nutrient; a missing value means unknown,
  not zero.
- `NutritionStore(persistence:now:)` is a `DocumentHost` for four synced kinds:
  - `saved_food`: a `Food` (custom, recipe or database), with nutrients per
    100 g, servings as gram weights, a barcode and a favourite flag;
  - `food_entry`: a `FoodEntry` on a `LocalDate` and meal, which keeps a
    `FoodSnapshot` so editing the food later doesn't rewrite the log. The
    snapshot keeps a volume-labelled food's `volume` basis too;
  - `nutrition_day`: a `NutritionDay` with a `DayStatus` (unlogged, partial,
    complete or fasting) and notes;
  - `weight_entry`: a `WeightEntry`, with optional body fat.
- Foods: `saveFood`, `setFavorite`, `archiveFood`, `food(_:)` and
  `recentFoods(limit:)`.
- Logging: `log(_:grams:serving:quantity:on:meal:)`, `saveEntry`,
  `deleteEntry`, `entries(on:)` and `copy(from:meal:to:meal:)` for a meal or a
  whole day. `NutritionStore.defaultMeals` names the usual four.
  `Serving.quantity(grams:)` gives how many of a serving weigh an amount, so
  switching an entry to a named serving keeps the amount.
- Faster logging. Each call checks everything first, then saves all or
  nothing:
  - `log(_ plate: [PlateItem], on:meal:at:)` logs several foods at once. Each
    problem names its food.
  - `copy(_ ids:to:meal:)` copies chosen entries as new ones, and
    `move(_ ids:to:meal:)` moves them, keeping their IDs.
  - `logIngredients(of:grams:serving:quantity:on:meal:at:)` logs a recipe
    portion as its ingredients, scaled to the portion.
  - A recipe (`Food.recipe`) may say how many servings it makes and how it is
    made (`servingCount`, `preparation`). `recipeGrams` is its whole weight and
    `recipeServing` an equal share of it. `withIngredients(_:yieldGrams:)`
    changes the ingredients and recalculates the nutrients.
  - `FoodEntry.editingNutrients(_:)` corrects one entry's nutrients and marks
    its snapshot `edited`; the food it came from is unchanged.
  - `quickAdd(_:name:on:meal:at:)` logs calories and macros for a whole
    portion, with no food or weight. The snapshot is `unweighed`: show no
    weight and offer no amount; correct it with `editingNutrients`. Quick adds
    stay out of `recentFoods` and `suggestions`.
  - `suggestions(at:timeZone:days:limit:)` returns `FoodSuggestion`s: foods
    usually logged within 90 minutes of this time of day over the last 28
    days, with the amount and meal last used. Foods already logged today
    and archived foods are left out. `log(_ suggestion:on:meal:at:)` logs one
    in a single tap.
- Days: `day(_:)`, `setStatus(_:on:)`, `setNotes(_:on:)`, and `summary(on:)`,
  which gives totals, totals per meal and `energyShares`.
- `progress(on:)` returns a `DayProgress`: energy, protein, fat and carbs as
  `NutrientProgress`, each with `consumed`, `target`, `remaining` ("x left"),
  `over`, `fraction` for a bar, and `unreported`, the entries that don't give
  the nutrient. Unrounded; format for display.
  `contributors(of:on:)` ranks the entries behind one nutrient.
- Weight: `logWeight(_:bodyFat:at:timeZone:)` and `deleteWeight`.
- Labels: `NutritionLabel.read(lines)` turns the text the camera recognised
  on a nutrition label (US Nutrition Facts or an EU declaration) into a
  `LabelReading`. It holds the `basis` (per serving, per 100 g or per 100
  ml), the serving, the `amounts`, `per100g` when the weight is known,
  `approximated` "less than" values and `unread` lines. Show it for review
  before saving a food. See design 021.
- Shortcuts: `ShortcutsJSON` reads MacroFactor's "Log by JSON" food format and
  writes its today summary, from the public spec at
  github.com/MacroFactor/apple-shortcuts. `logShortcutFood(_:on:meal:at:)` logs
  one; `todaySummaryJSON(on:)` gives `consumed` and `remaining` (minimum,
  target, maximum) by MacroFactor's nutrient names.
- Apple Health: `importHealthWeights(_:deleted:timeZone:)` merges `HealthWeight`
  samples as one unit and returns what it added, updated, removed and skipped.
  Each weigh-in keeps its sample's UUID, so a repeat import, on any device,
  changes nothing. `deleted` sample IDs remove theirs, and weigh-ins entered in
  Exerly are never touched. These have `source == .appleHealth`: don't write
  them back to Health, and `deleteWeight` refuses them (delete in Health).
- Insights (`docs/design/013-nutrient-insights.md`):
  - `overview(from:through:)` gives per-nutrient averages over the days that
    count, observed days, the goal, the share of goal (each day against its
    own goal) and completeness;
  - `timing(from:through:timeZone:)` gives energy by local hour. Pass `at:` to
    `log` to record when a meal was eaten;
  - `plan.goal(for:on:)` is a nutrient's floor, target and ceiling that day,
    from `nutrientGoals` or the reference intake;
  - `NutritionGoal.eta(from:on:)` and `checkpoints(from:on:weeks:)` project the
    goal weight.
- `EnergyBalance.estimate(_:prior:parameters:)` smooths weigh-ins and logged
  intake into a daily `Estimate`: trend weight and expenditure, each with one
  standard deviation. Feed it `store.energyBalanceDays(from:through:)`; only
  complete and fasting days count as known intake. Show the band.

### Targets and check-ins

`docs/design/011-nutrition-targets.md` has the design and how closely simulated
dieters reach their goal.

- `NutritionPlan` is a synced `nutrition_plan` document, one per version. A
  version never changes once in force; a new goal or an accepted check-in adds
  a version with a later `startDate`, so past days keep their targets.
  - The goal is lose, maintain or gain, a weekly rate as a share of bodyweight
    (up to 1 % to lose, 0.5 % to gain) and an optional goal weight.
  - The mode is coached, collaborative or manual; the diet type balanced, low
    fat, low carb or keto; the protein level 1.4, 1.8 or 2.2 g/kg.
  - `weekdayWeights` share the weekly budget out, Sunday first; 0 is a fasting
    day. `checkInDay` is the weekly review day.
  - `computed(from: PlanBasis)` fills the seven `DailyTargets` from
    expenditure and trend weight, or throws `.invalid(messages)`: a day under
    1,200 kcal without `allowBelowFloor`, or macros that don't fit.
  - For the first plan, at onboarding, `PlanBasis.formula(BodyProfile)`
    estimates expenditure from sex, age, height, weight and activity, with a
    wide error. It throws `.invalid` for an age, height or weight out of range.
- `NutritionStore` hosts plans: `plans`, `plan(on:)`, `targets(on:)` and
  `savePlan(_:timeZone:)`, which refuses a start in the past or an edit to a
  version in force.
- `store.checkIn(today:existing:)` returns a `NutritionCheckIn.Review` for the
  latest check-in day: the estimate, the week's trend change, complete and
  weigh-in days, and an `outcome`:
  - `.proposed`, with a `proposal` to file in `AgentStore`; accepting it adds
    the new version, and undo removes it;
  - `.unchanged`, `.notEnoughData`, `.notDue` or `.manual`;
  - `.cannotKeepGoal`, with `problems` to show, when new targets would break a
    floor.

  The proposal's ID comes from the plan and the date, so two devices propose
  one check-in. Reviewed late, its version still starts today.
- For the targets screen (`NutritionPlanning.swift`):
  - `NutritionRate` gives presets, the weekly amount in the person's unit and
    `nudged(_:by:direction:trend:unit:)`, which steps 0.1 lb or 0.05 kg a week;
  - `WeekdayBudget` says whether days are even and steps one day's share;
  - `NutritionTargets.manual(_:weekdayWeights:)` shares a typed day over the week;
  - `PlanBasisChoice.current(summary:plans:profile:)` picks what a new version
    rests on: measured expenditure, else the last plan's, else the formula;
  - `NutritionPlanDraft(plan).preview(startingOn:basis:)` returns the version
    the editor would save, or its problems in words;
  - `NutritionGoal.projection(from:on:)` gives the goal weight's date in weeks;
  - `NutritionCheckIn.nextDate(plan:review:)`, `proposalID(plan:date:)`,
    `latest(in:)`, `proposedPlan(_:)` and `adjusted(_:to:from:)` for a
    collaborative plan's changed proposal; `store.plan(before:)` is the version
    a check-in replaced.

## Analytics: custom metrics, tags, correlations and experiments

`docs/design/014-analytics.md` has the statistics and their measured error
rates.

- `MetricsStore(persistence:)` is a `DocumentHost` for `custom_metric`,
  `metric_entry` and `experiment`. Put it in `SyncEngine(hosts:)`.
  - `saveMetric` takes a `CustomMetric`: a number, a 1–5 scale or yes/no, with
    an optional range.
  - `setValue(_:for:on:)` sets one value per metric per day, or clears it
    with nil. The entry's ID comes from the metric and the date.
  - `values(of:)` returns a metric's values; `saveExperiment` and
    `deleteExperiment` manage experiments.
- Tags: `NutritionStore.setTags(_:on:)` sets a day's labels, and `tags` lists
  them, most used first. They merge as a set across devices.
- `SeriesID` names a daily series: a nutrient, trend or scale weight, an
  exercise's e1RM, a custom metric or a tag. It is stored as text, such as
  `nutrient:protein`.
- `SeriesSources(training:nutrition:metrics:)`:
  - `values(_:from:through:)` returns one value per day; missing days stay
    missing.
  - `correlations(_:_:from:through:)` gives Spearman's ρ at lags of 0 to 3
    days, with an interval, an adjusted p-value and a verdict. It needs at
    least 14 paired days.
  - `analyze(_:)` compares an experiment's phases and lists caveats, including
    tags that differ between the phases.
- `Analytics` holds the statistics themselves, adjusted for autocorrelated
  days.
