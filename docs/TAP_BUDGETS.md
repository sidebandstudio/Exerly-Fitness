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
  camera, so Exerly's test types the digits into the scanner's manual field
  and looks them up; on a phone the camera reads them.

## Side by side

| Task                   | Budget                            | Exerly                                                                                                                                                                                                                       | Exerly test (`TapBudgetUITests`)                                                                              | MacroFactor               | MacroFactor steps and source                                                                                                                                        |
| ---------------------- | --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Food eaten before      | 3                                 | **2**: Search, type its name, + (1 if it's on Log again)                                                                                                                                                                     | `testAFoodEatenBeforeTakesTwoTaps`, `testTheFoodMostLikelyNowTakesOneTap`                                     | 3                         | Toolbar search bar, Multi-Add + on a go-to, recent or favourite, Log Foods. [How to log food][mf-log], [new food logger][mf-logger], [favourites][mf-fav]           |
| Meal repeat            | 2                                 | **1**: Log again's "Yesterday's breakfast"                                                                                                                                                                                   | `testRepeatingAMealTakesOneTap`                                                                               | 4 + 1 swipe               | Food Log tab, swipe back a day, tap the hour (selects its foods), Copy, To Today. [Copy and paste][mf-copy], [past days][mf-past]                                   |
| Day repeat             | 2                                 | **1**: "Repeat yesterday" beside Log again (the rest of it once today has food)                                                                                                                                              | `testRepeatingAWholeDayTakesOneTap`, rest of day in `testRepeatingAMealTakesOneTap`                           | 4 + 1 swipe               | Food Log tab, swipe back a day, menu, Copy day, To Today. [Copy and paste][mf-copy]                                                                                 |
| Barcode to logged      | 3                                 | **3**: Scan, the scan, Log                                                                                                                                                                                                   | `testBarcodeToLoggedTakesThreeTaps`                                                                           | 3                         | Toolbar barcode button, the scan, Log Foods; 4 through the + menu. [Toolbar][mf-toolbar], [dashboard revamp][mf-dash], [How to log food][mf-log]                    |
| Weigh-in               | 3                                 | **2**: Weigh in, type the weight, Save; or Weigh in, Same as last                                                                                                                                                            | `testAWeighInTakesTwoTaps`; Same as last in `TodayLoggingUITests.testANewWeighInSavesOnlyAWeightSomeoneChose` | 2                         | Toolbar Weight shortcut, type the weight, checkmark; 3 by default (+, Weight, checkmark). [Log your weight][mf-weight], [Toolbar][mf-toolbar]                       |
| Start today's workout  | 2                                 | **1**: Start on Today's workout card (2 from the Train tab)                                                                                                                                                                  | `testTodaysWorkoutStartsInOneTapAndAPrefilledSetTakesOne`                                                     | 2                         | From the Workout tab, its first screen: the workout, Start Workout; 3 if its program block is collapsed. [Start a workout][mf-start]                                |
| Prefilled set          | 1                                 | **1**: the set's check                                                                                                                                                                                                       | `testTodaysWorkoutStartsInOneTapAndAPrefilledSetTakesOne`                                                     | 1                         | The set's checkmark, with values prefilled by Smart Progression or Previous; no prefill without history. [Smart progressions][mf-prog], [Log a workout][mf-workout] |
| Cold launch to logging | under 1 s on a phone (PARITY B03) | **1 tap** from launch to a logged food (Log again's chip); process start to the presented frame that lays out Today and Log again: 2.52 s p50, 2.83 s p95 (21 cold launches, Debug, simulator, a busy machine, 2026-10-21; 2.41 to 2.46 s p50 to the earlier end on 2026-10-20); 5.26 s p50 with three years of history; not yet under 1 s | `LaunchToLoggingUITests.testColdLaunchToLoggingStaysUnderItsCeiling` (local, not CI)                          | 3 taps; no published time | Dashboard, toolbar search bar, Multi-Add +, Log Foods. Its release notes mention shortening a splash logo animation ([1.2.0][mf-120]); no launch time is published. |

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
- **Launch time.** `LaunchToLoggingUITests` gates on the time from the process
  starting (the kernel's start time, so loading the app's code counts) to the
  commit of the frame whose layout placed Today's Log again (the render server
  shows it at the next refresh), which the Debug build reports to the test
  fixture with where it put Log again; that place must
  hold Log again's chip in the accessibility tree, and the chip must be
  hittable, as each launch returns. It
  also reports the app's own signposted interval and XCTest's launch metrics.
  Over 21 cold launches on an iPhone 17 Pro Max simulator (iOS 26.2, M1 Max,
  Debug, with the machine loaded by other builds), back to back on 2026-10-20:
  2.67 s p50 before Today opened from the cache and drew its top cards first,
  2.41 to 2.46 s after; the gate is 2.55 s. About 0.9 s of it passes before the
  app's own code runs (loading a Debug build's libraries in the simulator), and
  most of the rest is SwiftUI and the Swift runtime preparing Today's views;
  Exerly's own work in that frame is under 0.2 s. An earlier figure here, 1.19 s,
  ended at `onAppear`, before anything was drawn, and left the process's start
  out. On 2026-10-21 the end moved from two display-link ticks after
  `onAppear` to that commit: with nothing on screen changing, the ticks
  could wait half a minute after Today was drawn. Measured that day on a much
  busier machine (load 60 to 700): the old end gave 3.49 s p50 and 3.88 s p95,
  and with three years of history on the device (11,456 food entries) 39.9 s
  p50, though Today was on screen within about 3 s. The new end gives 2.52 s
  p50 and 2.83 s p95, and 5.26 s p50 and 5.77 s p95 with three years, which is
  over that test's 3.5 s ceiling. With the logging cards moved last, Log
  again is laid out below the fold in the first frame. Launch reports it
  there, and the time is to that frame (2.78 s p50 over 5 launches). PARITY B03's target,
  under 1 s on a phone, is not yet measured or met.
  MacroFactor publishes no launch time to compare; the counted comparison is the
  taps from launch to a logged food.
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
