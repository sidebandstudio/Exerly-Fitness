# Claude ledger

Rewrite this file each iteration and keep it under 80 lines. See `docs/AGENT_BRIEF.md`.

## Shipped today (internal TestFlight)

- 2610101011: Watch app; nine App Intents and four Control Center controls.
- 2610101238: native recipes.
- 2610101740: nutrient goals, pinned nutrients, macros that lead with what's left.
- 2610102054: fixes from code-blind run 4; actionable reminders; Spotlight for own foods.
- claude/next at 00a90f11: run 5 fixes, typed amounts, recipe import and sharing.

## Ready for review: `claude/polish5` (fixes from code-blind run 6, iPhone SE)

- Hide a usual or recent food by long press (Log, Details, Don't suggest this), a
  swipe (Hide) or the portion sheet's "…"; hidden foods leave Recent.
- Sticky footers and the rest and Copy bars sit below the content (`exFooter`);
  title bars back onto the page colour; Today's logging tools, Profile's goals and
  reminders, Train's Preview and the weight legend fit an SE's first screen.
- Reminder times open in a popover; closing it can't toggle the row under it.
- One "this week" figure for the trend on Today, Profile, Progress and Siri.
- Search ranks plain staples (toasted bread) above dishes; a serving can be added
  from the portion step ("1 slice = 28 g"), so the next typed count is one tap.
- Driver dump lists only the top layer; toasts opaque and say "N over"; Today and
  Log food start fresh from another tab; pinned nutrient precision; "1 set is done".
- Driver re-run on the SE (run 6 in brackets): breakfast of 2 eggs and 1 slice toast
  18 actions, 8 of them adding both servings once [9, but the wrong foods]; hide a
  recent food 5 [12, never found]; weigh-in reminder at 6:45 7 [13, Meals turned on].
- Merged claude/next (recipe import) in; API changes deploy when this lands.

## Current outcome

1 and 2 are done for every primary screen. Working on 3 (depth past MacroFactor) and
4 (Apple integration).

## Next three steps

1. Land `claude/polish5` on `claude/next` and ship a TestFlight build.
2. Outcome 3: the PARITY rows marked Partial (N06 hourly timeline, N18 consumed vs
   remaining toggle, S06 goal ETA and checkpoints, S09 body measurements).
3. Outcome 4: widgets and watch complications once Ali registers the App Group;
   HealthKit background delivery (entitlement and profile).

## How to resume

Work in `~/Desktop/Exerly-Fitness-claude` on `claude/next`. Fixtures:
`EXERLY_FIXTURE_PORT=<port> node scripts/ios-fixture-api.cjs` (39140–39148); restart
them after merging API changes. Capture: `apps/ios/scripts/capture.sh` (CAPTURE=0).
Full suite: `OUT=<dir> apps/ios/scripts/uitest-shards.sh <udid>:<port> ...` (five
shards stay under the 2 h background limit). Watch: `apps/ios/scripts/watch-uitest.sh`.
Code-blind run: `apps/ios/scripts/drive.sh`. Small-phone before/after walk:
`SmallPhoneCaptureUITests` (CAPTURE=1, LARGEST_TYPE=1 for the largest text). Release:
`release-in-session.sh --upload` then `node apps/ios/scripts/asc.mjs internal <build>`.
Push with `DEVELOPER_DIR` set to Xcode 26.2, or pre-push SwiftLint crashes. In T3,
never end a turn without background work (`sleep 1200` with run_in_background).

## Merge status

| Branch         | Unlanded                    | Last landed |
| -------------- | --------------------------- | ----------- |
| claude/next    | nothing                     | 00a90f11    |
| claude/polish5 | run 6 fixes, ready to review | –           |

## Risks

- The App Group is still unregistered (QUESTIONS_FOR_ALI.md): Today and Next workout
  widgets and watch complications wait on it.
- Watch, App Intents and reminders: unverified on hardware, with a passcode, from
  the Action button, and when an action relaunches a terminated app.
- The swipe to Hide is a custom pan (SwiftUI's swipeActions need a List); checked by
  XCTest's swipe on the simulator, not yet by hand on a device.
- Package sizes are tested on synthetic data only, not live Open Food Facts.
- ProductionUITests' food-library edit fails on the iPhone 17 Pro simulator on
  claude/next too (Calories won't take focus); passes on the SE. Not yet fixed.
- Two devices editing goals or pins offline on the same day: the later wins.
- Open Food Facts search budget is 10/min server-wide; type-ahead spends it faster.
- Six idle "Exerly App" simulators from the Astra run are left alone per the brief.
