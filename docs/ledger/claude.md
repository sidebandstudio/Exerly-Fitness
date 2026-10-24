# Claude ledger

Rewrite this file each iteration and keep it under 80 lines. See `docs/AGENT_BRIEF.md`.

## Shipped (internal TestFlight)

- 2610101011: Watch app, App Intents, controls. 2610101238: recipes. 2610101740: nutrient goals,
  pinned nutrients. 2610102054: code-blind run 4 fixes; actionable reminders; Spotlight.
- 2610110306: typed amounts, package sizes, multi-select copy/move, hidden suggestions,
  Duplicate food. 2610111702: recipe import from a link and as a file; runs 5–6 fixes.
- This landing, uploaded next:
  - Body (S06, S07, S09, S10): weight goal with ETA, checkpoints, goal line and path; edit and
    undo-delete readings, dashed gaps, the trend explained; 18 measurement sites, visual body fat;
    front, side and back photos per date with a compare slider, on device.
  - Diary (N06, N18–N20, N33): lead with "left" or "eaten"; water with quick adds, Undo, a goal and
    a shortcut; By time; habits calendar; day status and note; hide or reorder Today's cards.
  - iOS 26's clear keyboard Done bar no longer takes taps meant for fields; a preference
    changed while its screen refreshed is no longer dropped; By time keeps every hour.
  - Import & export (I12–I14): MacroFactor, MF Workouts, Hevy, Strong, Exerly; preview, Undo, full
    export. Reviews 2–5 fixed restores (3 years in 5 s), moves, measurement edits, barcode. Synthetic.
- claude/apple (not landed; I04–06, I08, I17–19): Shortcuts, Log by JSON; Spotlight and Siri log with Undo;
  Health food, workouts, recovery. Review 3: owner generations, workout journal (finished as the
  account opens), plans rechecked as applied, tombstones, exported. Rebased on sync (fd55982b).
- claude/ready (not landed): password reset, export-first delete, refresh reuse, privacy; review rounds
  1-5 fixed; do-connecting-ip trust stays off until Ali verifies the ingress. Needs deploy, app update.
- claude/polish6 (in claude/next 48f64e6d, not on TestFlight): run 7, reviews. Gain or Maintain past
  a goal; liquids by density; Customize Today and water goal kept offline (QuickPreferences); Next in
  each form's order; weigh-ins with time, fat, source; water's Undo in a row under its chips.
- claude/taps (landed): tap budgets in CI; reviews 1-6 fixed; launch gated at 1.10x an empty
  account's in the same run and 3.25 s p50; 3 years in 3.7 s, not 30 s (B03).

## Current outcome

1 and 2 are done for every primary screen. Working on 3 (depth past MacroFactor) and 4.

## Next three steps

1. Ship claude/next (polish6, and taps once it lands) to TestFlight, then code-blind run 8 on a
   17 Pro; fix what it finds.
2. Outcome 3 from PARITY.md, reconciled (35 Built, 71 Partial, 5 Missing): rows whose Core
   is tested but unused (T13, T16-T18, I13, B07); waist ratios, hiding unused measurements.
3. Outcome 4: widgets and complications once Ali registers the App Group; HealthKit background delivery.

## How to resume

Work in `~/Desktop/Exerly-Fitness-claude` on `claude/next`. Fixtures: `EXERLY_FIXTURE_PORT=<port>
node scripts/ios-fixture-api.cjs` (39140–39148); restart them after merging API changes. Capture:
`apps/ios/scripts/capture.sh` (CAPTURE=0). Full suite: `OUT=<dir> apps/ios/scripts/uitest-shards.sh
<udid>:<port> ...` (six shards stay under the 2 h background limit; include an iPhone 17 Pro, the
size CI uses). Watch: `apps/ios/scripts/watch-uitest.sh`. Code-blind run: `drive.sh`. Small-phone
walk: `SmallPhoneCaptureUITests` (CAPTURE=1, LARGEST_TYPE=1). Release: `release-in-session.sh
--upload` then `node apps/ios/scripts/asc.mjs internal <build>`. Push with `DEVELOPER_DIR` set to
Xcode 26.2, or pre-push SwiftLint crashes. In T3, never end a turn without background work (`sleep
1200` with run_in_background). Helpers can stop on the API rate limit; check their worktree.

## Merge status

| Branch      | Unlanded                                            | Last landed     |
| ----------- | --------------------------------------------------- | --------------- |
| claude/next | nothing                                             | fd55982b (sync) |
| apple       | 28 commits on fd55982b, for Sol's confirming review | not yet         |

## Risks

- The App Group is unregistered (QUESTIONS_FOR_ALI.md): Today/Next workout widgets, complications wait.
- Watch, App Intents, reminders: unverified on hardware, with a passcode, from Action button, relaunch.
- Recipe import matched 16 of 47 real lines (all correct); USDA table lacks salt, flour, spices, oils.
- Failures still cover Today's bottom (6 s; 15 s with Try again); water's row is unseen at the bottom.
- Progress photos: camera capture and moving a real older store unverified; kept on device.
- Hide's swipe is a custom pan, checked only by XCTest. At the largest text Progress scrolls only
  beside the trend chart, whose scrub takes drags (tests drag in the margin). Package sizes: synthetic.
- Open Food Facts search: 10/min server-wide, type-ahead spends it. Idle "Exerly App" sims: left alone.
- Flaky: BarcodeScanSessionTests' row Undo. TodayDiary's eaten-and-back: fixed in the test (DECISIONS).
- B03: 3 years miss the 3.5 s gate: p50 4.50 s (p95 4.68) vs 5.08 s on claude/next; sync encodes nothing.
- Sync: ship the API (`food_entry_link`) with the app; bump `syncEncodingVersion` on encoding changes.
- Health imports: the API's `health_import` kind must deploy (a `main` merge) before the app ships;
  real HealthKit time on years of history is unmeasured.
- Intents open a workspace synchronously (LoggingActions.swift:66): an older file's migration lock can
  hold the main actor up to 5 s. Left for the nutrition builder's change to that workspace.
