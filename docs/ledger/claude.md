# Claude ledger

Rewrite this file each iteration and keep it under 80 lines. See `docs/AGENT_BRIEF.md`.

## Shipped today (internal TestFlight)

- 2610101011: Watch app; nine App Intents and four Control Center controls.
- 2610101238: native recipes.
- 2610101740: nutrient goals, pinned nutrients, macros that lead with what's left.
- 2610102054: fixes from code-blind run 4; actionable reminders (log usual or
  repeat yesterday's meal, typed weigh-in, start workout); Spotlight for own foods.
- This landing, uploaded next:
  - Typed amounts in search ("500 g ground beef", "1 can kidney beans", "2 eggs"):
    chili 34 → 16 actions, overnight oats 51 → 17. Package sizes as "1 can".
  - Copy or move several foods at once with Undo; "Don't suggest this" with a
    synced list to restore; Duplicate a custom food (PARITY N07, N09, N10).
  - Fixes from code-blind run 5: a Reminders screen with time pickers (weigh-in
    reminder 17 → 5 actions), one day-and-time control when logging, Nutrient goals
    in Profile with search, Delete in the entry toolbar, "Log it now" after saving
    a recipe, per-serving recipe rows, aligned weekly chart, weekly total on Train.
  - The API change for hidden suggestions deploys with this push.

## Current outcome

1 and 2 are done for every primary screen. Working on 3 (depth past MacroFactor) and
4 (Apple integration).

## Next three steps

1. Code-blind run 6 on the realistic seed and on an iPhone SE: typed amounts,
   multi-select, reminders, goals. Fix what it finds.
2. Outcome 3: recipe sharing and import (N12), recipe URL import (N13), the
   remaining PARITY rows marked Partial (N06 hourly timeline, N18 consumed vs
   remaining toggle, S06 goal ETA and checkpoints, S09 body measurements).
3. Outcome 4: widgets and watch complications once Ali registers the App Group;
   HealthKit background delivery (entitlement and profile).

## How to resume

Work in `~/Desktop/Exerly-Fitness-claude` on `claude/next`. Fixtures:
`EXERLY_FIXTURE_PORT=<port> node scripts/ios-fixture-api.cjs` (39140–39148); restart
them after merging API changes. Capture: `apps/ios/scripts/capture.sh` (CAPTURE=0).
Full suite: `OUT=<dir> apps/ios/scripts/uitest-shards.sh <udid>:<port> ...` (five
shards stay under the 2 h background limit). Watch: `apps/ios/scripts/watch-uitest.sh`.
Code-blind run: `apps/ios/scripts/drive.sh`. Release: `release-in-session.sh --upload`
then `node apps/ios/scripts/asc.mjs internal <build>`. Push with `DEVELOPER_DIR` set
to Xcode 26.2, or pre-push SwiftLint crashes. In T3, never end a turn without
background work (`sleep 1200` with run_in_background).

## Merge status

| Branch      | Unlanded | Last landed |
| ----------- | -------- | ----------- |
| claude/next | nothing  | this commit |

## Risks

- The App Group is still unregistered (QUESTIONS_FOR_ALI.md): Today and Next workout
  widgets and watch complications wait on it.
- Watch, App Intents and reminders: unverified on hardware, with a passcode, from
  the Action button, and when an action relaunches a terminated app.
- Package sizes are tested on synthetic data only, not live Open Food Facts.
- Recipe UI tests were written on large phones; small-phone runs need scrolling
  helpers (fixed for totals and ingredient rows).
- Two devices editing goals or pins offline on the same day: the later wins.
- The Spotlight UI test depends on the system's indexing; under a five-shard load it
  once timed out at 45 s, then passed on rerun on both simulators.
- Open Food Facts search budget is 10/min server-wide; type-ahead spends it faster.
- Six idle "Exerly App" simulators from the Astra run are left alone per the brief.
