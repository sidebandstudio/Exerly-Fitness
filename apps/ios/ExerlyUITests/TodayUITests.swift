import XCTest

/// The Today screen: what it shows for a realistic week, and the taps its
/// shortcuts take.
final class TodayUITests: ExerlyUITestCase {
    func testTodayCapture() async throws {
        guard ProcessInfo.processInfo.environment["EXERLY_DESIGN_CAPTURE"] == "1" else {
            throw XCTSkip("Opt-in visual review of the Today screen")
        }
        let app = try await signedInWithWeek(prefix: "today-capture")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "today.suggestion.log.")).firstMatch.waitForExistence(timeout: 20))
        capture(app, "today-01-top")
        app.swipeUp()
        capture(app, "today-02-meals")
        app.swipeUp()
        capture(app, "today-03-footer")
        app.swipeDown(); app.swipeDown()
        tap(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "today.suggestion.log.")).firstMatch, in: app)
        capture(app, "today-04-logged")
        tap(app.buttons["Train"], in: app)
        capture(app, "today-05-train-tab")
        tap(app.buttons["Log food"], in: app)
        capture(app, "today-06-search-tab")
    }

    func testLoggingAUsualFoodFromTodayTakesOneTap() async throws {
        let app = try await signedInWithWeek(prefix: "today-suggestion")
        let suggestion = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "today.suggestion.log.")).firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 20))
        tapCount = 0
        tap(suggestion, in: app)
        XCTAssertEqual(tapCount, 1)
        XCTAssertTrue(app.buttons["today.undo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Logged ")).firstMatch.exists)
        // Undo, tapped where it appears, removes the entry again.
        let undo = app.buttons["today.undo"]
        XCTAssertTrue(undo.isHittable)
        undo.tap()
        XCTAssertTrue(undo.waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "nutrition.entry.")).firstMatch.exists)
    }

    func testRepeatingYesterdaysMealTakesOneTap() async throws {
        let app = try await signedInWithWeek(prefix: "today-repeat")
        let repeatDinner = app.buttons["today.repeat.dinner"]
        reveal(repeatDinner, in: app)
        XCTAssertTrue(repeatDinner.waitForExistence(timeout: 20))
        tapCount = 0
        tap(repeatDinner, in: app)
        XCTAssertEqual(tapCount, 1)
        let salmon = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Salmon fillet")).firstMatch
        XCTAssertTrue(salmon.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["today.repeat.dinner"].exists)
    }

    func testTheWeekStripMovesBetweenDaysAndShowsTheTarget() async throws {
        let app = try await signedInWithWeek(prefix: "today-days")
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 10))
        let today = try XCTUnwrap(shownDay(app))
        XCTAssertNotNil(targetEnergy(app))
        shiftDay(-1, in: app)
        XCTAssertTrue(app.navigationBars["Yesterday"].waitForExistence(timeout: 5))
        shiftDay(-8, in: app)
        XCTAssertTrue(todayScreen(app).exists)
        showToday(in: app)
        XCTAssertEqual(shownDay(app), today)
        XCTAssertTrue(app.navigationBars["Today"].exists)
    }

    /// The calorie ring is a button that pushes Targets, as Profile does.
    func testTheCalorieRingIsAButtonThatOpensTargets() async throws {
        let app = try await signedInWithWeek(prefix: "today-ring")
        let ring = app.buttons["nutrition.targetEnergy"]
        XCTAssertTrue(ring.waitForExistence(timeout: 20), "The ring reads as a button")
        XCTAssertEqual(ring.label, "Calories")
        tap(ring, in: app)
        XCTAssertTrue(app.scrollViews["targets.screen"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars.buttons["Today"].exists, "Pushed, with a way back to Today")
    }

    /// A weigh-in saved from Today is confirmed like a logged food, and Undo deletes it.
    func testAWeighInFromTodayCanBeUndone() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "today-weigh", units: "imperial")
        try await deleteSetupWeight(token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        tap(app.buttons["today.weighIn"], in: app)
        tap(app.buttons["weighIn.save"], in: app)
        let undo = app.buttons["today.undoWeighIn"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Weighed in at ")).firstMatch.exists)
        let today = Self.day(0).date
        _ = try await waitForWeighIn(token: person.token) { $0["date"] as? String == today }
        undo.tap()
        XCTAssertTrue(undo.waitForNonExistence(timeout: 3))
        var left: [[String: Any]] = []
        for _ in 0..<40 {
            left = try await weighIns(token: person.token).values.filter { $0["date"] as? String == today }
            if left.isEmpty { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertTrue(left.isEmpty, "Undo deleted the weigh-in on the server too")
    }

    /// Tapping Today's tab while it shows another day, scrolled down, comes
    /// back to today at the top.
    func testTappingTheTodayTabReturnsToToday() async throws {
        let app = try await signedInWithWeek(prefix: "today-tab")
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 10))
        let today = try XCTUnwrap(shownDay(app))
        shiftDay(-1, in: app)
        XCTAssertTrue(app.navigationBars["Yesterday"].waitForExistence(timeout: 5))
        app.swipeUp()
        tapCount = 0
        tap(app.tabBars.buttons["Today"], in: app)
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 5))
        XCTAssertEqual(shownDay(app), today)
        XCTAssertEqual(tapCount, 1)
        let strip = app.descendants(matching: .any)["diary.selected-day"]
        XCTAssertTrue(strip.waitForExistence(timeout: 5) && strip.isHittable, "Back at the top, with the week in view")
    }

    /// Once the meal "Log again" fills has food, its usual foods aren't
    /// offered, so it isn't logged twice.
    func testAMealAlreadyLoggedIsNotOfferedAgain() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "today-logged-meal", units: "imperial")
        try await seedWeek(token: person.token)
        // The usual breakfast is around now; today's already has yogurt.
        let yogurt = SeedFood(name: "Synthetic yogurt", per100g: ["energy": 73, "protein": 10, "carbohydrate": 3.9, "fat": 1.9])
        try await seedEntry(yogurt, grams: 170, daysAgo: 0, meal: "Breakfast", minutes: 5, token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        let entry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Synthetic yogurt")).firstMatch
        reveal(entry, in: app)
        XCTAssertTrue(entry.waitForExistence(timeout: 20))
        app.swipeDown()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "today.suggestion.log.")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Log again"].exists)
    }

    /// Several foods chosen at once copy to tomorrow with their portions, and
    /// Undo takes the copies back; a move puts them back where they were.
    func testCopyingThreeFoodsToTomorrowCanBeUndone() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "today-select", units: "imperial")
        let foods = [SeedFood(name: "Synthetic oats", per100g: ["energy": 380, "protein": 13, "carbohydrate": 67, "fat": 7]),
                     SeedFood(name: "Synthetic milk", per100g: ["energy": 61, "protein": 3.2, "carbohydrate": 4.8, "fat": 3.3]),
                     SeedFood(name: "Synthetic banana", per100g: ["energy": 89, "protein": 1.1, "carbohydrate": 22.8, "fat": 0.3]),
                     SeedFood(name: "Synthetic coffee", per100g: ["energy": 2, "protein": 0.1, "carbohydrate": 0, "fat": 0])]
        for (food, grams) in zip(foods, [80.0, 250, 120, 300]) {
            try await seedEntry(food, grams: grams, daysAgo: 0, meal: "Breakfast", minutes: 5, token: person.token)
        }
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        func entries(_ name: String) -> XCUIElementQuery {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "nutrition.entry.", name))
        }
        let chosen = foods.prefix(3).map { entries($0.name).firstMatch }
        reveal(chosen[0], in: app)
        XCTAssertTrue(chosen[0].waitForExistence(timeout: 20))
        let labels = chosen.map(\.label)
        tapCount = 0
        tap(app.buttons["today.select"], in: app)
        for entry in chosen { tap(entry, in: app) }
        XCTAssertEqual(app.staticTexts["today.selectedCount"].label, "3 selected")
        XCTAssertTrue(chosen.allSatisfy(\.isSelected))
        capture(app, "today-select")
        tap(app.buttons["today.copySelected"], in: app)
        XCTAssertTrue(app.navigationBars["Copy 3 foods"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Tomorrow"].isSelected, "A copy goes to the next day unless changed")
        capture(app, "today-select-destination")
        tap(app.buttons["today.confirmDestination"], in: app)
        XCTAssertEqual(tapCount, 6, "Select, three foods, Copy, Copy")
        XCTAssertTrue(app.staticTexts["Copied 3 foods to tomorrow"].waitForExistence(timeout: 5))
        let undo = app.buttons["today.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 2) && undo.isHittable)
        undo.tap()
        XCTAssertTrue(undo.waitForNonExistence(timeout: 3))
        shiftDay(1, in: app)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "nutrition.entry.")).firstMatch
            .waitForExistence(timeout: 3), "Undo took the copies back")

        // Again, kept: tomorrow has the same three portions.
        showToday(in: app)
        tap(app.buttons["today.select"], in: app)
        for food in foods.prefix(3) { tap(entries(food.name).firstMatch, in: app) }
        tap(app.buttons["today.copySelected"], in: app)
        tap(app.buttons["today.confirmDestination"], in: app)
        XCTAssertTrue(app.staticTexts["Copied 3 foods to tomorrow"].waitForExistence(timeout: 5))
        shiftDay(1, in: app)
        let copies = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "nutrition.entry."))
        XCTAssertTrue(copies.element(boundBy: 2).waitForExistence(timeout: 5))
        XCTAssertEqual(Set(copies.allElementsBoundByIndex.map(\.label)), Set(labels), "The same portions; copies share one time, so any order")

        // A move to Lunch the same day, undone, leaves Breakfast as it was.
        showToday(in: app)
        tap(app.buttons["today.select"], in: app)
        tap(entries("Synthetic coffee").firstMatch, in: app)
        tap(app.buttons["today.moveSelected"], in: app)
        XCTAssertFalse(app.buttons["today.confirmDestination"].isEnabled, "Nothing to move until a day or meal changes")
        tap(app.buttons["Lunch"], in: app)
        tap(app.buttons["today.confirmDestination"], in: app)
        XCTAssertTrue(app.staticTexts["Moved 1 food to Lunch"].waitForExistence(timeout: 5))
        app.buttons["today.undo"].tap()
        XCTAssertTrue(app.buttons["today.undo"].waitForNonExistence(timeout: 3))
        XCTAssertEqual(entries("Synthetic").count, 4)
    }

    /// A Log again chip can be dismissed with a long press, undone at once,
    /// and let back later from the food library.
    func testASuggestionCanBeDismissedAndLetBack() async throws {
        let app = try await signedInWithWeek(prefix: "today-hide")
        let chips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "today.suggestion.log."))
        XCTAssertTrue(chips.firstMatch.waitForExistence(timeout: 20))
        let count = chips.count
        let id = chips.firstMatch.identifier
        let name = String(chips.firstMatch.label.dropFirst("Log ".count).prefix { $0 != "," })
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@)", "\(name),", "today.suggestion"))
            .firstMatch
        chip.press(forDuration: 1.0)
        let hide = app.buttons["Don't suggest this"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        capture(app, "today-suggestion-menu")
        hide.tap()
        XCTAssertTrue(app.buttons[id].waitForNonExistence(timeout: 5))
        XCTAssertEqual(chips.count, count - 1)
        XCTAssertTrue(app.staticTexts["Won't suggest \(name)"].waitForExistence(timeout: 3))
        app.buttons["today.undo"].tap()
        XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5), "Undo puts the chip back")

        chip.press(forDuration: 1.0)
        tap(app.buttons["Don't suggest this"], in: app)
        XCTAssertTrue(app.buttons[id].waitForNonExistence(timeout: 5))
        tap(app.buttons["nutrition.addFood"], in: app)
        let usual = app.descendants(matching: .any)["nutrition.group.suggested"]
        if usual.waitForExistence(timeout: 5) {
            XCTAssertFalse(usual.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(name),")).firstMatch.exists,
                           "Search's usual foods leave it out too")
        }
        tap(app.buttons["nutrition.closePicker"], in: app)
        openFoodLibrary(app)
        let hidden = app.descendants(matching: .any)["nutrition.hiddenSuggestions"]
        reveal(hidden, in: app)
        XCTAssertTrue(hidden.waitForExistence(timeout: 5))
        capture(app, "today-suggestion-library")
        let again = app.buttons["Suggest \(name) again"]
        tap(again, in: app)
        XCTAssertTrue(hidden.waitForNonExistence(timeout: 5))
        tap(app.buttons["Today"], in: app)
        app.swipeDown()
        XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 10), "Suggested again")
    }

    func testTheWeekStripReachesFutureDaysForPlanning() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "today-future", units: "imperial")
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        let today = try XCTUnwrap(shownDay(app))
        shiftDay(1, in: app)
        XCTAssertNotEqual(shownDay(app), today)
        XCTAssertTrue(app.navigationBars.matching(NSPredicate(format: "identifier != %@", "Today")).firstMatch.exists)
        showToday(in: app)
        XCTAssertEqual(shownDay(app), today)
    }

    func testStartingTodaysWorkoutTakesOneTapFromToday() async throws {
        let app = try await signedInWithWeek(prefix: "today-start")
        let start = app.buttons["today.startWorkout"]
        reveal(start, in: app)
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        tapCount = 0
        tap(start, in: app)
        XCTAssertEqual(tapCount, 1)
        XCTAssertTrue(app.buttons["training.finish"].waitForExistence(timeout: 10))
    }
}
