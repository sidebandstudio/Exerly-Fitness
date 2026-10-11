# Claude ledger

Rewrite this file each iteration and keep it under 80 lines. See `docs/AGENT_BRIEF.md`.

## Shipped (internal TestFlight)

- 2610101011: Watch app; nine App Intents and four Control Center controls.
- 2610101238: native recipes.
- 2610101740: nutrient goals, pinned nutrients, macros that lead with what's left.
- 2610102054: fixes from code-blind run 4; actionable reminders; Spotlight.
- 2610110306: typed amounts in search (chili 34 → 16 actions, oats 51 → 17), package
  sizes, multi-select copy/move, hidden suggestions, Duplicate food, run 5 fixes
  (Reminders screen with time pickers, one day-and-time control).
- This landing, uploaded next:
  - Recipe import from a link (schema.org JSON-LD read server-side through a fetch
    that refuses private addresses; unmatched lines resolved before Save) and
    sharing as a `.exerlyrecipe` file. The new API endpoint deploys with this push.
  - Fixes from code-blind run 6 on an iPhone SE: hide a food by long press, swipe
    or the "…" menu (5 actions, was never found); sticky footers sit below content
    so a half-hidden row can't pass a tap to the button; reminder times in a
    popover (6:45 weigh-in reminder 7 actions, was 13 with Meals turned on by
    mistake); SE first screens fit Today's tools, Profile's goals and reminders,
    Train's Preview; one "this week" weight figure everywhere; staples rank above
    dishes in search; add a serving ("1 slice = 28 g") from the portion step.

## Current outcome

1 and 2 are done for every primary screen. Working on 3 (depth past MacroFactor) and
4 (Apple integration).

## In flight

- `claude/focus` (helper): ProductionUITests' food-library edit fails on the iPhone
  17 Pro (Calories won't take focus); passes on Pro Max and SE. Finding whether a
  person on a 17 Pro is affected, then fixing the app or the test.

## Next three steps

1. Land `claude/focus`; code-blind run 7 covering recipe import and the run 6 fixes.
2. Outcome 3: the PARITY rows marked Partial (N06 hourly timeline, N18 consumed vs
   remaining toggle, S06 goal ETA and checkpoints, S09 body measurements).
3. Outcome 4: widgets and watch complications once Ali registers the App Group;
   HealthKit background delivery (entitlement and profile).

## How to resume

Work in `~/Desktop/Exerly-Fitness-claude` on `claude/next`. Fixtures:
`EXERLY_FIXTURE_PORT=<port> node scripts/ios-fixture-api.cjs` (39140–39148); restart
them after merging API changes. Capture: `apps/ios/scripts/capture.sh` (CAPTURE=0).
Full suite: `OUT=<dir> apps/ios/scripts/uitest-shards.sh <udid>:<port> ...` (five
shards stay under the 2 h background limit; include an iPhone 17 Pro, the size CI
uses). Watch: `apps/ios/scripts/watch-uitest.sh`. Code-blind run: `drive.sh`.
Small-phone walk: `SmallPhoneCaptureUITests` (CAPTURE=1, LARGEST_TYPE=1). Release:
`release-in-session.sh --upload` then `node apps/ios/scripts/asc.mjs internal <build>`.
Push with `DEVELOPER_DIR` set to Xcode 26.2, or pre-push SwiftLint crashes. In T3,
never end a turn without background work (`sleep 1200` with run_in_background).

## Merge status

| Branch       | Unlanded                      | Last landed |
| ------------ | ----------------------------- | ----------- |
| claude/next  | nothing                       | this commit |
| claude/focus | 17 Pro focus fix, in progress | none        |

## Risks

- The App Group is still unregistered (QUESTIONS_FOR_ALI.md): Today and Next workout
  widgets and watch complications wait on it.
- Watch, App Intents and reminders: unverified on hardware, with a passcode, from
  the Action button, and when an action relaunches a terminated app.
- Recipe import matched 16 of 47 lines on three real pages (all correct); the
  bundled USDA table lacks salt, flour, most spices and oils.
- The swipe to Hide is a custom pan; checked by XCTest's swipe, not by hand.
- Package sizes are tested on synthetic data only, not live Open Food Facts.
- UI tests written on large phones need scrolling helpers on the 17 Pro and SE.
- Open Food Facts search budget is 10/min server-wide; type-ahead spends it faster.
- Six idle "Exerly App" simulators from the Astra run are left alone per the brief.
