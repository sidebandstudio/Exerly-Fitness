import XCTest

/// The diary's depth on Today: leading with what's eaten, water, a fasted day
/// in the calendar, By time and a customized Today. Kept apart from
/// TodayUITests, whose tap budgets are what CI runs on every push.
final class TodayDiaryUITests: ExerlyUITestCase {
    /// Your details turns Today's ring and macros to what's eaten, and back.
    func testTodayCanLeadWithWhatsEatenAndBack() async throws {
        let app = try await signedInWithWeek(prefix: "today-eaten")
        XCTAssertNotNil(targetEnergy(app))
        XCTAssertTrue(app.staticTexts["kcal left"].exists)
        let protein = app.descendants(matching: .any)["today.macro.protein"]
        XCTAssertTrue((protein.value as? String ?? "").contains("grams left, "), protein.value as? String ?? "")
        setNutritionDisplay("What you've eaten", in: app)
        XCTAssertTrue(app.staticTexts["kcal eaten"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["kcal left"].exists)
        XCTAssertTrue((protein.value as? String ?? "").contains("grams eaten, "), "Eaten first: \(protein.value as? String ?? "")")
        XCTAssertNotNil(targetEnergy(app), "The ring still says what's eaten of the target")
        setNutritionDisplay("What's left", in: app)
        XCTAssertTrue(app.staticTexts["kcal left"].waitForExistence(timeout: 15))
    }

    /// A glass of water is one tap from Today, Undo takes it back, and Other removes some.
    func testAGlassOfWaterLogsInOneTapAndCanBeUndone() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "today-water", units: "imperial")
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        let row = app.buttons["today.water"]
        reveal(row, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        XCTAssertTrue((row.value as? String ?? "").hasPrefix("0 fl oz logged"), row.value as? String ?? "")
        tapCount = 0
        tap(app.buttons["today.water.glass"], in: app)
        XCTAssertEqual(tapCount, 1)
        let undo = app.buttons["today.undoWater"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Added 8 fl oz of water"].exists)
        await fulfillment(of: [expectation(for: NSPredicate(format: "value BEGINSWITH %@", "8 fl oz logged"), evaluatedWith: row)], timeout: 10)
        try await waitForWater(237, token: person.token)
        undo.tap()
        XCTAssertTrue(undo.waitForNonExistence(timeout: 3))
        await fulfillment(of: [expectation(for: NSPredicate(format: "value BEGINSWITH %@", "0 fl oz logged"), evaluatedWith: row)], timeout: 10)
        try await waitForWater(0, token: person.token)

        tap(app.buttons["today.water.bottle"], in: app)
        tap(app.buttons["today.water.other"], in: app)
        tap(app.buttons["Remove"], in: app)
        replace(app.textFields["water.amount"], with: "8", in: app)
        tap(app.buttons["water.save"], in: app)
        XCTAssertTrue(app.staticTexts["Removed 8 fl oz of water"].waitForExistence(timeout: 5))
        await fulfillment(of: [expectation(for: NSPredicate(format: "value BEGINSWITH %@", "8.9 fl oz logged"), evaluatedWith: row)], timeout: 10)
        try await waitForWater(263, token: person.token)
    }

    /// Two taps mark today a fast; the calendar shows it, with the days before it.
    func testMarkingADayFastedShowsInTheCalendar() async throws {
        let app = try await signedInWithWeek(prefix: "today-fasted")
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 10))
        let today = try XCTUnwrap(shownDay(app))
        tapCount = 0
        tap(app.buttons["today.dayMenu"], in: app)
        tap(app.buttons["today.dayMenu.status.fasting"], in: app)
        XCTAssertEqual(tapCount, 2)
        let subtitle = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", " · Fasting")).firstMatch
        XCTAssertTrue(subtitle.waitForExistence(timeout: 5), "The day's status shows under its date")
        tap(app.buttons["today.chooseDate"], in: app)
        let day = app.buttons["calendar.day.\(today)"]
        XCTAssertTrue(day.waitForExistence(timeout: 10))
        XCTAssertTrue((day.value as? String ?? "").hasPrefix("Fasted"), day.value as? String ?? "")
        XCTAssertTrue(day.isSelected)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        let yesterday = formatter.string(from: formatter.date(from: today)!.addingTimeInterval(-86_400))
        let previous = app.buttons["calendar.day.\(yesterday)"]
        if !previous.exists { tap(app.buttons["calendar.previous"], in: app) }
        XCTAssertTrue((previous.value as? String ?? "").hasPrefix("Food logged"), previous.value as? String ?? "")
        XCTAssertTrue((previous.value as? String ?? "").hasSuffix("weighed in"), previous.value as? String ?? "")
        tap(previous, in: app)
        XCTAssertTrue(app.navigationBars["Yesterday"].waitForExistence(timeout: 5), "A day in the calendar opens on Today")
    }

    /// By time lists the day's food under the hours it was eaten, in order.
    func testByTimeListsTheDaysFoodAtTheHoursItWasEaten() async throws {
        let app = try await signedInWithWeek(prefix: "today-bytime")
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 10))
        shiftDay(-1, in: app)
        let entries = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "nutrition.entry."))
        reveal(entries.firstMatch, in: app)
        let logged = entries.count
        XCTAssertGreaterThan(logged, 0)
        tap(app.buttons["today.grouping.time"], in: app)
        XCTAssertTrue(app.buttons["today.grouping.time"].isSelected)
        let hours = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "today.byTime.hour."))
        XCTAssertTrue(hours.firstMatch.waitForExistence(timeout: 5))
        let shown = hours.allElementsBoundByIndex.compactMap { Int($0.identifier.split(separator: ".")[3]) }
        XCTAssertFalse(shown.isEmpty)
        XCTAssertEqual(shown, shown.sorted(), "Earliest hour first")
        XCTAssertEqual(entries.count, logged, "Every food is under an hour")
        XCTAssertTrue(entries.firstMatch.label.contains("Breakfast") || entries.firstMatch.label.contains("Lunch")
                      || entries.firstMatch.label.contains("Dinner"), "Each food names its meal: \(entries.firstMatch.label)")
        capture(app, "today-by-time")
        tap(entries.firstMatch, in: app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Save")).firstMatch.waitForExistence(timeout: 5)
                      || app.navigationBars.firstMatch.waitForExistence(timeout: 5))
    }

    /// Customize hides a card and moves another, and Today keeps it after a relaunch.
    func testATodayCardCanBeHiddenAndMoved() async throws {
        let app = try await signedInWithWeek(prefix: "today-customize")
        XCTAssertNotNil(targetEnergy(app))
        XCTAssertTrue(app.buttons["today.quickAdd"].exists)
        // From the day menu; after the relaunch, from the link under the meals.
        tap(app.buttons["today.dayMenu"], in: app)
        tap(app.buttons["today.dayMenu.customize"], in: app)
        XCTAssertTrue(app.navigationBars["Customize Today"].waitForExistence(timeout: 5))
        let quick = app.switches["today.customize.show.quickActions"]
        XCTAssertEqual(quick.value as? String, "1")
        tap(quick, in: app)
        XCTAssertEqual(quick.value as? String, "0")
        for _ in 0..<4 { tap(app.buttons["today.customize.up.water"], in: app) }
        XCTAssertFalse(app.buttons["today.customize.up.water"].isEnabled, "Water is first")
        capture(app, "today-customize")
        tap(app.buttons["today.customize.done"], in: app)
        XCTAssertTrue(app.buttons["today.water"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["today.quickAdd"].exists, "Quick actions are hidden")
        let ring = app.descendants(matching: .any)["nutrition.targetEnergy"]
        XCTAssertLessThan(app.buttons["today.water"].frame.minY, ring.frame.minY, "Water moved above the ring")

        app.terminate()
        app.launchArguments.removeAll { $0 == "--ui-testing" }
        app.launch()
        XCTAssertNotNil(targetEnergy(app))
        XCTAssertFalse(app.buttons["today.quickAdd"].exists, "Kept for this account")
        XCTAssertLessThan(app.buttons["today.water"].frame.minY, ring.frame.minY)
        openCustomize(in: app)
        tap(app.buttons["today.customize.reset"], in: app)
        tap(app.buttons["today.customize.done"], in: app)
        XCTAssertTrue(app.buttons["today.quickAdd"].waitForExistence(timeout: 10))
    }

    /// Opt-in visual review of the diary's newer parts, at whatever text size the run uses.
    func testDiaryDepthCapture() async throws {
        guard ProcessInfo.processInfo.environment["EXERLY_DESIGN_CAPTURE"] == "1" else { throw XCTSkip("Opt-in visual review") }
        let app = try await signedInWithWeek(prefix: "diary-capture")
        XCTAssertNotNil(targetEnergy(app))
        capture(app, "diary-01-top")
        let water = app.buttons["today.water"]
        reveal(water, in: app)
        tap(app.buttons["today.water.glass"], in: app)
        capture(app, "diary-02-water-logged")
        tap(water, in: app)
        XCTAssertTrue(app.buttons["water.save"].waitForExistence(timeout: 5))
        capture(app, "diary-03-water-sheet")
        app.swipeUp()
        capture(app, "diary-04-water-sheet-totals")
        tap(app.buttons["Cancel"], in: app)
        shiftDay(-1, in: app)
        tap(app.buttons["today.dayMenu"], in: app)
        capture(app, "diary-05-day-menu")
        tap(app.buttons["today.dayMenu.status.partial"], in: app)
        shiftDay(-2, in: app)
        tap(app.buttons["today.dayMenu"], in: app)
        tap(app.buttons["today.dayMenu.status.fasting"], in: app)
        capture(app, "diary-06-fasted-day")
        tap(app.buttons["today.chooseDate"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["calendar.month"].waitForExistence(timeout: 5))
        capture(app, "diary-07-calendar")
        app.swipeUp()
        capture(app, "diary-08-calendar-legend")
        tap(app.buttons["Done"], in: app)
        showToday(in: app)
        shiftDay(-1, in: app)
        tap(app.buttons["today.grouping.time"], in: app)
        app.swipeUp()
        capture(app, "diary-09-by-time")
        tap(app.buttons["today.grouping.meals"], in: app)
        showToday(in: app)
        openCustomize(in: app)
        capture(app, "diary-10-customize")
        tap(app.buttons["today.customize.done"], in: app)
        tap(app.buttons["Profile"], in: app)
        tap(app.buttons["profile.details"], in: app)
        let display = app.buttons["preferences.nutritionDisplay"]
        reveal(display, in: app)
        capture(app, "diary-11-your-details-food-log")
        tap(display, in: app)
        tap(app.buttons["What you've eaten"], in: app)
        tap(app.buttons["preferences.save"], in: app)
        XCTAssertTrue(app.navigationBars["Your details"].waitForNonExistence(timeout: 15))
        tap(app.buttons["Today"], in: app)
        XCTAssertTrue(app.staticTexts["kcal eaten"].waitForExistence(timeout: 15))
        capture(app, "diary-12-eaten-top")
    }

    /// Opens Customize Today from the link under the day's meals.
    private func openCustomize(in app: XCUIApplication) {
        tap(app.buttons["today.customize"], in: app)
        XCTAssertTrue(app.navigationBars["Customize Today"].waitForExistence(timeout: 5))
    }

    /// Chooses what Today leads with in Your details, saves, and returns to Today.
    private func setNutritionDisplay(_ choice: String, in app: XCUIApplication) {
        tap(app.buttons["Profile"], in: app)
        tap(app.buttons["profile.details"], in: app)
        XCTAssertTrue(app.navigationBars["Your details"].waitForExistence(timeout: 10))
        tap(app.buttons["preferences.nutritionDisplay"], in: app)
        tap(app.buttons[choice], in: app)
        tap(app.buttons["preferences.save"], in: app)
        XCTAssertTrue(app.navigationBars["Your details"].waitForNonExistence(timeout: 15))
        tap(app.buttons["Today"], in: app)
    }

    /// Waits for the server's water total for today to reach `milliliters`.
    private func waitForWater(_ milliliters: Int, token: String) async throws {
        var total = -1
        for _ in 0..<40 {
            total = try await request("GET", "/api/water", token: token)["ml"] as? Int ?? -1
            if total == milliliters { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("The server has \(total) ml of water, not \(milliliters)")
    }
}
