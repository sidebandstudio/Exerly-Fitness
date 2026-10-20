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
  scroll the test helper makes to reach a control; each row below needs none.
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

| Task                   | Budget                            | Exerly                                                                                                                                                                                              | Exerly test (`TapBudgetUITests`)                                                     | MacroFactor               | MacroFactor steps and source                                                                                                                                        |
| ---------------------- | --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Food eaten before      | 3                                 | **2**: Search, type its name, + (1 if it's on Log again)                                                                                                                                            | `testAFoodEatenBeforeTakesTwoTaps`, `testTheFoodMostLikelyNowTakesOneTap`            | 3                         | Toolbar search bar, Multi-Add + on a go-to, recent or favourite, Log Foods. [How to log food][mf-log], [new food logger][mf-logger], [favourites][mf-fav]           |
| Meal repeat            | 2                                 | **1**: Log again's "Yesterday's breakfast"                                                                                                                                                          | `testRepeatingAMealTakesOneTap`                                                      | 4 + 1 swipe               | Food Log tab, swipe back a day, tap the hour (selects its foods), Copy, To Today. [Copy and paste][mf-copy], [past days][mf-past]                                   |
| Day repeat             | 2                                 | **1**: "Repeat yesterday" beside Log again (the rest of it once today has food)                                                                                                                     | `testRepeatingAWholeDayTakesOneTap`, rest of day in `testRepeatingAMealTakesOneTap`  | 4 + 1 swipe               | Food Log tab, swipe back a day, menu, Copy day, To Today. [Copy and paste][mf-copy]                                                                                 |
| Barcode to logged      | 3                                 | **3**: Scan, the scan, Log                                                                                                                                                                          | `testBarcodeToLoggedTakesThreeTaps`                                                  | 3                         | Toolbar barcode button, the scan, Log Foods; 4 through the + menu. [Toolbar][mf-toolbar], [dashboard revamp][mf-dash], [How to log food][mf-log]                    |
| Weigh-in               | 3                                 | **2**: Weigh in, type the weight, Save                                                                                                                                                              | `testAWeighInTakesTwoTaps`                                                           | 2                         | Toolbar Weight shortcut, type the weight, checkmark; 3 by default (+, Weight, checkmark). [Log your weight][mf-weight], [Toolbar][mf-toolbar]                       |
| Start today's workout  | 2                                 | **1**: Start on Today's workout card (2 from the Train tab)                                                                                                                                         | `testTodaysWorkoutStartsInOneTapAndAPrefilledSetTakesOne`                            | 3                         | Workout tab, the workout, Start Workout; 4 if its program block is collapsed. [Start a workout][mf-start]                                                           |
| Prefilled set          | 1                                 | **1**: the set's check                                                                                                                                                                              | `testTodaysWorkoutStartsInOneTapAndAPrefilledSetTakesOne`                            | 1                         | The set's checkmark, with values prefilled by Smart Progression or Previous; no prefill without history. [Smart progressions][mf-prog], [Log a workout][mf-workout] |
| Cold launch to logging | under 1 s on a phone (PARITY B03) | **1 tap** from launch to a logged food (Log again's chip); Today with Log again up 1.19 s p50, 1.29 s p95 after the app starts (21 cold launches, simulator; first frame 2.9 s from process launch) | `LaunchToLoggingUITests.testColdLaunchToLoggingStaysUnderItsCeiling` (local, not CI) | 3 taps; no published time | Dashboard, toolbar search bar, Multi-Add +, Log Foods. Its release notes mention shortening a splash logo animation ([1.2.0][mf-120]); no launch time is published. |

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
- **Launch time.** `LaunchToLoggingUITests` signposts the app's own interval
  (`LaunchTiming`: from the app's start to Today on screen with Log again) and
  records XCTApplicationLaunchMetric's time to first responsive frame, over 21
  cold launches of a Debug build on an iPhone 17 Pro Max simulator (iOS 26.2,
  M1 Max). The test fails above 1.5 s at p50, to catch a regression. The
  optimised build measured the same (1.11 s), so the time is spent between
  SwiftUI's renders on the way to Today, not in loading data. PARITY B03's
  target, under 1 s on a phone, is not yet measured or met. MacroFactor
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
