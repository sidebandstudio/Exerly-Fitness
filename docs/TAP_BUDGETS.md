# Tap budgets: Exerly against MacroFactor

The brief's outcome 1 budgets, counted. Exerly's figures come from
`apps/ios/ExerlyUITests/TapBudgetUITests.swift`, which CI runs on every push;
MacroFactor's are counted from its public material only. Checked 2026-10-20.

## Method

- **From the home screen.** Exerly starts on Today, scrolled to the top, signed
  in with a week of synthetic history (food, weigh-ins, a two-day program with
  last session logged). MacroFactor starts on its dashboard, or the Workout tab's
  first screen for MacroFactor Workouts.
- **What counts.** Every tap until the item is saved. Typing (a food's name, a
  weight, a barcode's digits) counts as no taps, for both apps; nor does a drag
  or swipe, which the table lists separately. Exerly's tests count every
  scroll the test helper makes to reach a control; each row below needs none
  in the tested configuration: an iPhone 17 Pro Max simulator at the default
  text size, with no weekly check-in waiting. On a smaller phone, or at the
  largest text sizes, Today's later cards (the workout's Start among them) can
  need a scroll; at the largest sizes the workout card moves up to follow Log
  again so that it needs less.
- **Saved means saved.** Each Exerly test passes only once the entry is on the
  fixture server (a workout set: once it survives the app being killed and
  reopened, because sets sync with their workout).
- **In MacroFactor's favour.** Where its material is ambiguous, the smaller
  count is used: a toolbar shortcut is assumed set up, a date defaults to
  today, a field is assumed focused, a paste option is assumed in view.
- **The barcode scan** counts as one action in both. The simulator has no
  camera, so Exerly's test shows the code to the scanner's stand-in camera
  (the fixture's barcode feed); on a phone the camera reads it.

## Side by side

| Task                   | Budget                            | Exerly                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | Exerly test (`TapBudgetUITests`)                                                                              | MacroFactor               | MacroFactor steps and source                                                                                                                                        |
| ---------------------- | --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Food eaten before      | 3                                 | **2**: Search, type its name, + (1 if it's on Log again)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | `testAFoodEatenBeforeTakesTwoTaps`, `testTheFoodMostLikelyNowTakesOneTap`                                     | 3                         | Toolbar search bar, Multi-Add + on a go-to, recent or favourite, Log Foods. [How to log food][mf-log], [new food logger][mf-logger], [favourites][mf-fav]           |
| Meal repeat            | 2                                 | **1**: Log again's "Yesterday's breakfast"                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | `testRepeatingAMealTakesOneTap`                                                                               | 4 + 1 swipe               | Food Log tab, swipe back a day, tap the hour (selects its foods), Copy, To Today. [Copy and paste][mf-copy], [past days][mf-past]                                   |
| Day repeat             | 2                                 | **1**: "Repeat yesterday" beside Log again (the rest of it once today has food)                                                                                                                                                                                                                                                                                                                                                                                                                                                               | `testRepeatingAWholeDayTakesOneTap`, rest of day in `testRepeatingAMealTakesOneTap`                           | 4 + 1 swipe               | Food Log tab, swipe back a day, menu, Copy day, To Today. [Copy and paste][mf-copy]                                                                                 |
| Barcode to logged      | 3                                 | **3**: Scan, the scan, Log                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | `testBarcodeToLoggedTakesThreeTaps`                                                                           | 3                         | Toolbar barcode button, the scan, Log Foods; 4 through the + menu. [Toolbar][mf-toolbar], [dashboard revamp][mf-dash], [How to log food][mf-log]                    |
| Weigh-in               | 3                                 | **2**: Weigh in, type the weight, Save; or Weigh in, Same as last                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | `testAWeighInTakesTwoTaps`; Same as last in `TodayLoggingUITests.testANewWeighInSavesOnlyAWeightSomeoneChose` | 2                         | Toolbar Weight shortcut, type the weight, checkmark; 3 by default (+, Weight, checkmark). [Log your weight][mf-weight], [Toolbar][mf-toolbar]                       |
| Start today's workout  | 2                                 | **1**: Start on Today's workout card (2 from the Train tab)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | `testTodaysWorkoutStartsInOneTapAndAPrefilledSetTakesOne`                                                     | 2                         | From the Workout tab, its first screen: the workout, Start Workout; 3 if its program block is collapsed. [Start a workout][mf-start]                                |
| Prefilled set          | 1                                 | **1**: the set's check                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | `testTodaysWorkoutStartsInOneTapAndAPrefilledSetTakesOne`                                                     | 1                         | The set's checkmark, with values prefilled by Smart Progression or Previous; no prefill without history. [Smart progressions][mf-prog], [Log a workout][mf-workout] |
| Cold launch to logging | under 1 s on a phone (PARITY B03) | **1 tap** from launch to a logged food (Log again's chip); process start to the commit of the frame that lays out Today and Log again: 2.43 s p50, 3.22 s p95 (21 cold launches, Debug, simulator, a busy machine, 2026-10-23); gated as 1.002 to 1.032 times an empty account's launch in the same run (ceiling 1.10), and at most 3.25 s p50 on that simulator; with three years of history 4.50 to 5.21 s p50 under XCTest (over its 3.5 s ceiling, which is deferred to the sync slice), and 3.74 s p50 outside XCTest; not yet under 1 s | `LaunchToLoggingUITests.testColdLaunchToLoggingStaysUnderItsCeiling` (local, not CI)                          | 3 taps; no published time | Dashboard, toolbar search bar, Multi-Add +, Log Foods. Its release notes mention shortening a splash logo animation ([1.2.0][mf-120]); no launch time is published. |

Exerly is fewer or equal on every row.

## Notes

- **Smart suggestions.** Today's Log again shows the foods usually eaten around
  now, ranked by time of day and frequency, with the meal they make first: the
  food most likely now is one tap from the home screen. MacroFactor's hourly
  go-tos are in food search, three taps away ([How to log food][mf-log]); its
  2026 annual report lists one-tap logging from the food log as planned
  ([annual report][mf-ar]).
- **Typing.** Counting typing as free favours whichever app types more. Exerly's
  food repeat needs a name typed only when the food isn't on Log again;
  MacroFactor's go-tos and recents need none, but its repeat is a tap longer.
- **A first-time user.** A code-blind agent, given only the tasks, logged a
  past food, yesterday's lunch and the rest of yesterday in one tap each, a
  weigh-in in two (plus typing), and started a workout and its first set in two
  after one swipe: a waiting check-in had pushed Start below the fold, so it now
  follows the workout card. Its other findings are in DECISIONS.md, 2026-10-20.
- **Launch time.** `LaunchToLoggingUITests` times each launch from the process
  starting (the kernel's start time, so loading the app's code counts) to the
  commit of the frame whose layout placed Today's Log again: the end is when
  the main run loop, after Core Animation's commit, next goes to sleep, so the
  frame is with the render server, which presents it at the next refresh, and
  the main thread is free for a tap. An earlier version of this file called it
  the presented frame, which it isn't: nothing here times the refresh itself.
  The Debug build reports the time to the test fixture with where it put Log
  again; that place must hold Log again's chip in the accessibility tree as
  each launch returns, and the chip must be hittable then. The gate is paired:
  in the same run, each of 20 cold launches with a week of food is paired with
  one of a signed-in account with no food (its frame lays out the shortcuts),
  the order alternating, and the median of the week's time over the empty
  account's must stay under 1.10. Both launch the same app seconds apart, so
  the machine's load and its drift cancel out, and the ratio is what a week of
  food adds to a launch. The earlier gate, an absolute 2.55 s on the median,
  left 25 ms over a 2.525 s median and failed whenever the machine was busy.
  Eight runs on 2026-10-23, at load averages of 20 to 142, gave medians of
  1.002 to 1.032 (p95 of the pairs 1.065 to 1.154), with the week at 2.377 to
  2.498 s p50 and the empty account at 2.336 to 2.425 s p50; the three runs at
  loads of 72 to 142 were no higher than the others. Log again was hittable in
  all 160 week launches and where reported in 159. After rebasing onto
  polish6, each of three runs missed once (3 in 200 in all). The fixture's
  record of one of them, the fastest launch of its run, showed why: both
  logging controls were reported 126 pt higher than where they settled (the
  other two put Log again at the same place), so the first frame had come
  before the bars above Today were in place, and everything below them moved.
  Launch now ends at the commit of the frame that puts the logging controls
  where they stay: once a frame places them, it waits a quarter second for
  none to move, and a move makes the frame that moved them the end instead. A
  change of size where a control stands, as Log again's chips after a sync,
  doesn't count. Three runs since, at load averages of 25 to 207, placed all
  60 week launches, with ratios of 1.018 to 1.036 and the week at 2.363 to
  2.478 s p50; a miss still fails its run and saves a screenshot. The ceiling
  lets a week add about 0.17 s over an empty launch beyond the highest median
  seen. A slowdown of every launch alike, such as more work before Today,
  passes the ratio, so the week's own p50 has an absolute ceiling beside it:
  3.25 s, about 0.8 s over its 2.428 s median when set. It holds only on the
  configuration it was measured on, an iPhone 17 Pro Max simulator
  (iPhone18,2, iOS 26.2, Debug, M1 Max host), which the test stores with the
  empty account's 2.357 s and the week's 2.428 s medians from the eight runs;
  on another device the seconds are reported, not checked. Changing the
  ceiling, the stored medians or the configuration takes a deliberate commit
  with new measurements here; a run that fails reports the machine's load
  average, and a failure under heavy load is reported, not met by loosening
  the ceiling. Before the pairing, on an iPhone 17 Pro Max simulator (iOS
  26.2, M1 Max, Debug), on a machine loaded by other builds (load average 270
  to 1,000), on 2026-10-23: 2.43 s p50 and 3.22 s p95 over 21 cold launches
  with a week of food, under the 2.55 s gate; 1.49 s p50 from the app's own
  start; Log again hittable and where launch reported it in all 21 (the 2.55 s
  gate this replaced). With Today's logging cards moved last, 2.79 s p50; with
  water above the ring, 2.77 s p50 (5 launches each, Log again laid out below
  the fold and reported where it was). With the shortcuts hidden and the meal
  being eaten now logged, so Log again is the rest of the day on its own row,
  2.40 s p50 (5 launches, reported where it was). With three years of history
  (11,456 food entries), 4.50 and 5.21 s p50 (5.29 and 5.53 s p95) in two runs
  of 10 launches under XCTest, Log again or the shortcuts hittable and where
  reported in all 20, still over that test's 3.5 s ceiling; launched outside
  XCTest with simctl on the same data, 3.74 s p50 and 4.07 s p95 over 10
  launches, against 30.6 s p50 before a sync's push found entries by index
  rather than by scanning them all (DECISIONS.md, 2026-10-23). The three-years
  ceiling is deferred, not met: B03 stays Partial, and that test keeps failing
  its gate until the sync slice, now under way, pushes only changed documents
  instead of encoding every one to compare. About 0.9 s of each launch passes
  before the app's own code runs (loading a Debug build's libraries in the
  simulator). Earlier figures, on 2026-10-20 and 21 (2.41 to 2.52 s p50 with a
  week of food), ended at `onAppear` or at display-link ticks instead. PARITY
  B03's target, under 1 s on a phone, is not yet measured or met. MacroFactor
  publishes no launch time to compare; the counted comparison is the taps from
  launch to a logged food.
- **Not measured.** MacroFactor's figures are counted from its documentation,
  not timed in the app. Exerly's are counted on an iPhone 17 Pro Max simulator
  (iOS 26.2) and haven't been repeated on a phone.

[mf-log]: https://help.macrofactorapp.com/en/articles/215-how-to-log-food-in-macrofactor
[mf-logger]: https://macrofactor.com/new-food-logger/
[mf-fav]: https://help.macrofactorapp.com/en/articles/257-favorite-foods
[mf-copy]: https://help.macrofactorapp.com/en/articles/95-copy-and-paste
[mf-past]: https://help.macrofactorapp.com/en/articles/100-view-past-days-of-eating
[mf-toolbar]: https://help.macrofactorapp.com/en/articles/112-how-to-configure-your-shortcuts-and-toolbar
[mf-dash]: https://macrofactor.com/dashboard-revamp/
[mf-weight]: https://help.macrofactorapp.com/en/articles/15-log-your-weight
[mf-start]: https://help.macrofactorapp.com/en/articles/309-how-to-start-a-workout
[mf-prog]: https://help.macrofactorapp.com/en/articles/305-understanding-and-using-smart-progressions
[mf-workout]: https://help.macrofactorapp.com/en/articles/310-how-to-log-a-workout
[mf-120]: https://macrofactor.com/version-1-2-0/
[mf-ar]: https://macrofactor.com/annual-report-2026/
