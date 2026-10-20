# Claude ledger

Rewrite this file each iteration and keep it under 80 lines. See `docs/AGENT_BRIEF.md`.

## Shipped (internal TestFlight)

- 2610101011: Watch app; nine App Intents and four Control Center controls. 2610101238: recipes.
- 2610101740: nutrient goals, pinned nutrients, macros leading with what's left.
  2610102054: fixes from code-blind run 4; actionable reminders; Spotlight.
- 2610110306: typed amounts in search, package sizes, multi-select copy/move, hidden
  suggestions, Duplicate food, run 5 fixes.
- 2610111702: recipe import from a link and sharing as a file; run 6 (iPhone SE) fixes.
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
  - iOS 26's clear keyboard Done bar took taps meant for fields drawn behind it
    (Calories in Edit food on a 17 Pro); the keyboard area is now filled, and a
    nutrient's caption focuses its field.
  - Found by the full suite: a preference changed while its screen was still
    refreshing (Done tapped right after opening Your details, or a reminder switch
    flipped at once) was dropped; a day with food in one hour lost By time's hour.
- claude/ready (not landed): password reset, export-first delete, refresh reuse, privacy; review round 1
  fixed (session alone can't add Apple, a token or delete). Needs round 2, API deploy, then an app update.

## Current outcome

1 and 2 are done for every primary screen. Working on 3 (depth past MacroFactor) and
4 (Apple integration).

## Next three steps

1. Code-blind run 7 on a 17 Pro covering recipe import, body goal and measurements,
   water and Customize Today; fix what it finds.
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

| Branch      | Unlanded | Last landed |
| ----------- | -------- | ----------- |
| claude/next | nothing  | this commit |

## Risks

- The App Group is still unregistered (QUESTIONS_FOR_ALI.md): Today and Next workout
  widgets and watch complications wait on it.
- Watch, App Intents and reminders: unverified on hardware, with a passcode, from
  the Action button, and when an action relaunches a terminated app.
- Recipe import matched 16 of 47 lines on three real pages (all correct); the
  bundled USDA table lacks salt, flour, most spices and oils.
- Progress photos: camera capture and moving photos from a real older store are
  unverified; photos never leave the device unless shared.
- The swipe to Hide is a custom pan; checked by XCTest's swipe, not by hand.
- Package sizes are tested on synthetic data only, not live Open Food Facts.
- Open Food Facts search budget is 10/min server-wide; type-ahead spends it faster.
- Six idle "Exerly App" simulators from the Astra run are left alone per the brief.
