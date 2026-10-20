# Claude ledger

Rewrite this file each iteration and keep it under 80 lines. See `docs/AGENT_BRIEF.md`.

## Shipped (internal TestFlight)

- 2610101011: Watch app, App Intents, controls. 2610101238: recipes. 2610101740: nutrient goals,
  pinned nutrients. 2610102054: code-blind run 4 fixes; actionable reminders; Spotlight.
- 2610110306: typed amounts, package sizes, multi-select copy/move, hidden suggestions,
  Duplicate food. 2610111702: recipe import from a link and as a file; runs 5–6 fixes.
- This landing, uploaded next:
  - Body (PARITY S06, S07, S09, S10): weight goal with ETA, weekly checkpoints and
    on-track standing, goal line and planned path on the chart; edit and
    undo-delete readings, gaps drawn dashed, the trend's readings and ± explained;
    18 measurement sites plus a visual body-fat estimate with history; front, side
    and back photos per date with a compare slider, stored per account on device.
  - Diary (PARITY N06, N18, N19, N20, N33): lead with "left" or "eaten"; water
    with quick adds, Undo, a daily goal and a Log water shortcut; By time view;
    habits calendar from the date; day status and note from a menu; hide or
    reorder Today's cards.
  - iOS 26's clear keyboard Done bar no longer takes taps meant for fields; a preference
    changed while its screen refreshed is no longer dropped; By time keeps every hour.
  - Import & export (I12–I14): MacroFactor, MF Workouts, Hevy, Strong, Exerly exports and
    measurements; preview, Undo, full export. Reviews 2–5 fixed: restores (validated, exact
    tombstones, replayable Undo, 3 years in 5 s), moves, measurement edits; on barcode. Synthetic.
- claude/ready (not landed): password reset, export-first delete, refresh reuse, privacy; review rounds
  1-5 fixed; do-connecting-ip trust stays off until Ali verifies the ingress. Needs deploy, app update.
- claude/polish6 (not landed): run 7 and reviews. Gain or Maintain for a passed goal weight; liquids
  by density, drained cans; Customize Today and the water goal kept offline, sent alone, one writer
  per session, replays reconciled (QuickPreferences); Next in each form's order (iPad layout test);
  weigh-ins read with time, fat, source; water's Undo in a row under its chips, which never move.
- claude/taps (7 commits, not landed): budgets in TapBudgetUITests (CI) and TAP_BUDGETS.md;
  repeats lead Log again; keypad-first weigh-in; B03 launch 1.19 s p50 (sim), not < 1 s.
- claude/taps (13 commits, review round 1 fixed, not landed): budgets in TapBudgetUITests (CI);
  repeats own their Undo; weigh-ins never save a placeholder; B03 2.41 s p50 end to end (sim).

## Current outcome

1 and 2 are done for every primary screen. Working on 3 (depth past MacroFactor) and 4.

## Next three steps

1. Land `claude/polish6` after review and ship it to TestFlight, then code-blind run 8
   on a 17 Pro; fix what it finds.
2. Outcome 3 from PARITY.md, reconciled (35 Built, 71 Partial, 5 Missing): rows whose Core
   is tested but unused (T13, T16-T18, I13, B07); waist ratios, hiding unused measurements.
3. Outcome 4: widgets and watch complications once Ali registers the App Group;
   HealthKit background delivery (entitlement and profile).

## How to resume

Work in `~/Desktop/Exerly-Fitness-claude` on `claude/next`. Fixtures:
`EXERLY_FIXTURE_PORT=<port> node scripts/ios-fixture-api.cjs` (39140–39148); restart
them after merging API changes. Capture: `apps/ios/scripts/capture.sh` (CAPTURE=0).
Full suite: `OUT=<dir> apps/ios/scripts/uitest-shards.sh <udid>:<port> ...` (six
shards stay under the 2 h background limit; include an iPhone 17 Pro, the size CI
uses). Watch: `apps/ios/scripts/watch-uitest.sh`. Code-blind run: `drive.sh`.
Small-phone walk: `SmallPhoneCaptureUITests` (CAPTURE=1, LARGEST_TYPE=1). Release:
`release-in-session.sh --upload` then `node apps/ios/scripts/asc.mjs internal <build>`.
Push with `DEVELOPER_DIR` set to Xcode 26.2, or pre-push SwiftLint crashes. In T3,
never end a turn without background work (`sleep 1200` with run_in_background).
Helpers can stop on the API rate limit; check their worktree for uncommitted work.

## Merge status

| Branch      | Unlanded               | Last landed                             |
| ----------- | ---------------------- | --------------------------------------- |
| claude/next | nothing                | this commit                             |
| polish6     | 20 commits on b3981833 | not yet: fast-forwards onto claude/next |

## Risks

- The App Group is still unregistered (QUESTIONS_FOR_ALI.md): Today and Next workout
  widgets and watch complications wait on it.
- Watch, App Intents and reminders: unverified on hardware, with a passcode, from
  the Action button, and when an action relaunches a terminated app.
- Recipe import matched 16 of 47 real lines (all correct); USDA table lacks salt, flour, spices, oils.
- Other toasts still cover Today's bottom for 6 s; water's row is unseen if its card sits at the bottom.
- Progress photos: camera capture and moving a real older store unverified; kept on device.
- Hide's swipe is a custom pan, checked only by XCTest. At the largest text Progress scrolls only
  beside the trend chart, whose scrub takes drags (tests drag in the margin). Package sizes: synthetic.
- Open Food Facts search budget is 10/min server-wide; type-ahead spends it faster.
- Six idle "Exerly App" simulators from the Astra run are left alone per the brief.
