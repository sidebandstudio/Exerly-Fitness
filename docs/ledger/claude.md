# Claude ledger

Rewrite this file each iteration and keep it under 80 lines. See `docs/AGENT_BRIEF.md`.

## Shipped (internal TestFlight)

- 2610101011: Watch app, App Intents, controls. 2610101238: recipes. 2610101740: nutrient goals,
  pinned nutrients. 2610102054: code-blind run 4 fixes; actionable reminders; Spotlight.
- 2610110306: typed amounts, package sizes, multi-select copy/move, hidden suggestions,
  Duplicate food. 2610111702: recipe import from a link and as a file; runs 5–6 fixes.
- This landing, uploaded next:
  - Body (PARITY S06, S07, S09, S10): weight goal with ETA, weekly checkpoints and on-track
    standing, goal line and planned path on the chart; edit and undo-delete readings, gaps drawn
    dashed, the trend's readings and ± explained; 18 measurement sites plus a visual body-fat
    estimate with history; front, side and back photos per date with a compare slider, stored per
    account on device.
  - Diary (PARITY N06, N18, N19, N20, N33): lead with "left" or "eaten"; water with quick adds,
    Undo, a daily goal and a Log water shortcut; By time view; habits calendar from the date; day
    status and note from a menu; hide or reorder Today's cards.
  - iOS 26's clear keyboard Done bar no longer takes taps meant for fields; a preference
    changed while its screen refreshed is no longer dropped; By time keeps every hour.
  - Import & export (I12–I14): MacroFactor, MF Workouts, Hevy, Strong, Exerly exports and
    measurements; preview, Undo, full export. Reviews 2–5 fixed: restores (validated, exact
    tombstones, replayable Undo, 3 years in 5 s), moves, measurement edits; on barcode. Synthetic.
- claude/ready (not landed): password reset, export-first delete, refresh reuse, privacy; review rounds
  1-5 fixed; do-connecting-ip trust stays off until Ali verifies the ingress. Needs deploy, app update.
- claude/polish6 (in claude/next 48f64e6d, not on TestFlight): run 7, reviews. Gain or Maintain past
  a goal weight; liquids by density, drained cans; Customize Today and water goal kept offline, sent
  alone, one writer per session, replays reconciled (QuickPreferences); Next in each form's order;
  weigh-ins read with time, fat, source; water's Undo in a row under its chips, which never move.
- claude/taps (not landed, rebased on polish6): tap budgets in CI; reviews 1-6 fixed; launch gated at
  1.10x an empty account's in the same run and 3.25 s p50; 3 years in 3.7 s, not 30 s (B03).

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

| Branch      | Unlanded               | Last landed                             |
| ----------- | ---------------------- | --------------------------------------- |
| claude/next | nothing                | this commit                             |
| taps        | 33 commits on 48f64e6d | not yet: fast-forwards onto claude/next |

## Risks

- The App Group is unregistered (QUESTIONS_FOR_ALI.md): Today/Next workout widgets, complications wait.
- Watch, App Intents, reminders: unverified on hardware, with a passcode, from Action button, relaunch.
- Recipe import matched 16 of 47 real lines (all correct); USDA table lacks salt, flour, spices, oils.
- Failures still cover Today's bottom (6 s; 15 s with Try again); water's row is unseen at the bottom.
- Progress photos: camera capture and moving a real older store unverified; kept on device.
- Hide's swipe is a custom pan, checked only by XCTest. At the largest text Progress scrolls only
  beside the trend chart, whose scrub takes drags (tests drag in the margin). Package sizes: synthetic.
- Open Food Facts search budget is 10/min server-wide; type-ahead spends it faster.
- Six idle "Exerly App" simulators are left alone. BarcodeScanSessionTests' row Undo is flaky.
- B03: 3 years take 4.5 to 5.5 s p50 under XCTest, failing its 3.5 s gate until the sync slice
  pushes only changed documents. The week gate missed Log again's place in 2 of 180 launches.
- Intents open a workspace synchronously (LoggingActions.swift:66): an older file's migration lock can
  hold the main actor up to 5 s. Left for the nutrition builder's change to that workspace.
