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

    /// A glass of water is one tap from Today, Undo takes it back, and Other
    /// removes some. Its confirmation never covers the chips: at the bottom
    /// of the screen it did, and Other tapped straight after a bottle landed
    /// on it and didn't open (confirming review). It's a row in the water
    /// card, under chips that stay put, and the card above doesn't change.
    func testAGlassOfWaterLogsInOneTapAndCanBeUndone() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "today-water", units: "imperial")
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        let row = app.buttons["today.water"]
        reveal(row, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        XCTAssertTrue((row.value as? String ?? "").hasPrefix("0 fl oz logged"), row.value as? String ?? "")
        let undo = app.buttons["today.undoWater"]
        // The whole card in view, as a person scrolls to it, so its
        // confirmation shows under the chips rather than under the tab bar.
        reveal(app.staticTexts["Lunch"], in: app)
        tapCount = 0
        tap(app.buttons["today.water.glass"], in: app)
        XCTAssertEqual(tapCount, 1)
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Added 8 fl oz of water"].exists)
        await fulfillment(of: [expectation(for: NSPredicate(format: "value BEGINSWITH %@", "8 fl oz logged"), evaluatedWith: row)], timeout: 10)
        try await waitForWater(237, token: person.token)
        undo.tap()
        XCTAssertTrue(undo.waitForNonExistence(timeout: 3))
        await fulfillment(of: [expectation(for: NSPredicate(format: "value BEGINSWITH %@", "0 fl oz logged"), evaluatedWith: row)], timeout: 10)
        try await waitForWater(0, token: person.token)

        reveal(app.buttons["today.water.bottle"], in: app)
        let before = waterLayout(app)
        tap(app.buttons["today.water.bottle"], in: app)
        let added = app.staticTexts["Added 16.9 fl oz of water"]
        XCTAssertTrue(added.waitForExistence(timeout: 5))
        checkWaterConfirmation(added, undo: undo, against: before, in: app)
        capture(app, "water-bottle-added")
        tap(app.buttons["today.water.other"], in: app)
        tap(app.buttons["Remove"], in: app)
        replace(app.textFields["water.amount"], with: "8", in: app)
        tap(app.buttons["water.save"], in: app)
        XCTAssertTrue(app.staticTexts["Removed 8 fl oz of water"].waitForExistence(timeout: 5))
        await fulfillment(of: [expectation(for: NSPredicate(format: "value BEGINSWITH %@", "8.9 fl oz logged"), evaluatedWith: row)], timeout: 10)
        try await waitForWater(263, token: person.token)
    }

    /// Where the water chips and the card above water are, before a change.
    private func waterLayout(_ app: XCUIApplication) -> (chips: [String: CGRect], above: CGRect) {
        let chips = ["glass", "bottle", "other"].map { ($0, app.buttons["today.water.\($0)"].frame) }
        return (Dictionary(uniqueKeysWithValues: chips), app.otherElements["weightCard"].frame)
    }

    /// The confirmation and its Undo sit inside the water card, over no chip;
    /// the chips haven't moved and the card above is as it was.
    private func checkWaterConfirmation(_ message: XCUIElement, undo: XCUIElement,
                                        against before: (chips: [String: CGRect], above: CGRect), in app: XCUIApplication) {
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.5)
        let card = app.otherElements["today.waterCard"].frame
        XCTAssertTrue(card.contains(message.frame) && card.contains(undo.frame), "\(message.frame), \(undo.frame) in \(card)")
        for (chip, frame) in before.chips {
            let now = app.buttons["today.water.\(chip)"].frame
            XCTAssertEqual(now, frame, "\(chip) moved")
            XCTAssertFalse(now.intersects(message.frame) || now.intersects(undo.frame), "\(chip) is covered")
        }
        XCTAssertEqual(app.otherElements["weightCard"].frame, before.above, "The card above changed")
    }

    /// Run 7 looked for "lead with what's eaten" in Customize Today before
    /// finding it in Your details. It's at the top of Customize, saved as it's
    /// chosen, and the account's preference changes with it.
    func testCustomizeTodayChoosesWhatCaloriesAndMacrosShow() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "today-customize-eaten", units: "imperial")
        try await seedWeek(token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        XCTAssertTrue(app.staticTexts["kcal left"].waitForExistence(timeout: 20))
        tapCount = 0
        openCustomizeFromDayMenu(app)
        XCTAssertTrue(app.buttons["What's left"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["What's left"].isSelected)
        tap(app.buttons["What you've eaten"], in: app)
        capture(app, "customize-display")
        try await waitForPreference("nutritionDisplay", "consumed", token: person.token)
        tap(app.buttons["today.customize.done"], in: app)
        XCTAssertEqual(tapCount, 4, "Day options, Customize Today, What you've eaten, Done")
        XCTAssertTrue(app.staticTexts["kcal eaten"].waitForExistence(timeout: 15))
        openCustomizeFromDayMenu(app)
        XCTAssertTrue(app.buttons["What you've eaten"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["What you've eaten"].isSelected, "Reopened on the saved choice")
        tap(app.buttons["What's left"], in: app)
        tap(app.buttons["today.customize.done"], in: app)
        XCTAssertTrue(app.staticTexts["kcal left"].waitForExistence(timeout: 15))
        try await waitForPreference("nutritionDisplay", "remaining", token: person.token)
    }

    /// Run 7 found the water goal only by expanding the sheet, then in Your
    /// details, and could leave only by Cancel. The goal is set in the sheet,
    /// any amount, saved as it changes; leaving is Done, and the confirm reads
    /// Log, not a second Add.
    func testTheWaterGoalIsSetInTheWaterSheet() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "today-water-goal", units: "imperial")
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        let row = app.buttons["today.water"]
        reveal(row, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        tap(app.buttons["today.water.other"], in: app)
        let close = app.buttons["water.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertEqual(close.label, "Cancel")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == 'Add'")).count, 1, "Add is the choice only")
        XCTAssertEqual(app.navigationBars.buttons["water.save"].label, "Log the amount added")
        let goal = app.textFields["water.goal"]
        reveal(goal, in: app)
        XCTAssertTrue(goal.exists, app.debugDescription)
        replace(goal, with: "90", in: app)
        XCTAssertEqual(close.label, "Done", "Nothing to cancel: the goal is saved")
        capture(app, "water-goal-sheet")
        try await waitForPreference("waterGoalMl", 2662, token: person.token)
        tap(close, in: app)
        await fulfillment(of: [expectation(for: NSPredicate(format: "value CONTAINS %@", "to go of 90 fl oz"), evaluatedWith: row)], timeout: 15)
    }

    /// Review round 1: offline, the choice of eaten or left and the water
    /// goal did nothing, so a relaunch showed the old ones. Each is kept on
    /// the device at once, shown, said to sync, and sent once back online.
    func testTodayChoicesMadeOfflineSurviveARelaunchAndSyncOnceOnline() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "today-offline-prefs", units: "imperial")
        try await seedWeek(token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        XCTAssertTrue(app.staticTexts["kcal left"].waitForExistence(timeout: 20))
        try await control(["offline": true])
        openCustomizeFromDayMenu(app)
        tap(app.buttons["What you've eaten"], in: app)
        XCTAssertTrue(app.buttons["What you've eaten"].isSelected)
        let displayNote = app.staticTexts["today.customize.displayNote"]
        XCTAssertTrue(displayNote.waitForExistence(timeout: 5) && displayNote.label.contains("online"), displayNote.label)
        tap(app.buttons["today.customize.done"], in: app)
        XCTAssertTrue(app.staticTexts["kcal eaten"].waitForExistence(timeout: 10), "Shown at once, offline")
        let row = app.buttons["today.water"]
        reveal(row, in: app)
        tap(app.buttons["today.water.other"], in: app)
        let goal = app.textFields["water.goal"]
        reveal(goal, in: app)
        replace(goal, with: "90", in: app)
        let note = app.descendants(matching: .any)["water.goal.note"]
        await fulfillment(of: [expectation(for: NSPredicate(format: "label CONTAINS %@", "online"), evaluatedWith: note)], timeout: 10)
        capture(app, "water-goal-offline")
        tap(app.buttons["water.close"], in: app)

        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.staticTexts["kcal eaten"].waitForExistence(timeout: 20), "Still eaten after a relaunch offline")
        reveal(row, in: app)
        await fulfillment(of: [expectation(for: NSPredicate(format: "value CONTAINS %@", "of 90 fl oz"), evaluatedWith: row)], timeout: 15)

        try await control([:])
        try await waitForPreference("nutritionDisplay", "consumed", token: person.token, attempts: 120)
        try await waitForPreference("waterGoalMl", 2662, token: person.token, attempts: 120)
    }

    /// Review round 1: setting the water goal sent the whole Your details
    /// draft, an unfinished name with it, and replaced another device's name
    /// without asking. Now it sends only the goal, and the draft and its
    /// review are left as they were.
    func testTheWaterGoalSendsOnlyItselfAndLeavesAnUnfinishedDetailsDraft() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "today-goal-only", units: "imperial")
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        XCTAssertTrue(app.buttons["today.water"].waitForExistence(timeout: 20))
        tap(app.buttons["Profile"], in: app)
        tap(app.buttons["profile.details"], in: app)
        XCTAssertTrue(app.navigationBars["Your details"].waitForExistence(timeout: 10))
        let name = app.textFields["preferences.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 15))
        replace(name, with: "Unfinished Morgan", in: app)
        dismissKeyboard(app)
        // Left unsaved: the draft stays on this iPhone.
        app.terminate(); app.launchArguments = []; app.launch()
        let remote = try await request("GET", "/api/preferences", token: person.token)
        _ = try await request("PATCH", "/api/preferences", body: ["base_revision": remote["revision"]!, "changes": ["name": "Other Device Morgan"]],
                              token: person.token)

        let row = app.buttons["today.water"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        reveal(row, in: app)
        tap(app.buttons["today.water.other"], in: app)
        let goal = app.textFields["water.goal"]
        reveal(goal, in: app)
        replace(goal, with: "90", in: app)
        try await waitForPreference("waterGoalMl", 2662, token: person.token)
        tap(app.buttons["water.close"], in: app)
        let saved = try await request("GET", "/api/preferences", token: person.token)
        XCTAssertEqual((saved["values"] as? [String: Any])?["name"] as? String, "Other Device Morgan",
                       "The other device's name stays: the goal sent only itself")

        tap(app.buttons["Profile"], in: app)
        tap(app.buttons["profile.details"], in: app)
        XCTAssertTrue(app.navigationBars["Your details"].waitForExistence(timeout: 10))
        XCTAssertTrue(name.waitForExistence(timeout: 15))
        XCTAssertEqual(name.value as? String, "Unfinished Morgan", "The unfinished draft is kept")
        XCTAssertTrue(app.buttons["Save my edits"].waitForExistence(timeout: 15), "And its conflict is left for review")
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
        openCustomizeFromDayMenu(app)
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
        // Under load the menu can still be opening when its item is tapped, or
        // the tap is lost and the menu stays open, and saving then closes it
        // unchosen, so Today never changed (3 of 6 runs on 2026-10-23, at load
        // averages over 60). Save only once the picker shows the choice,
        // choosing again if the first tap was lost.
        let picker = app.buttons["preferences.nutritionDisplay"]
        reveal(picker, in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
        let chosen = NSPredicate(format: "label ENDSWITH %@", choice)
        for _ in 0..<2 where !chosen.evaluate(with: picker) {
            tap(picker, in: app)
            // The menu may still be opening: tap its item once it can take the tap.
            let item = app.buttons[choice]
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: item)
            XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 10), .completed, app.debugDescription)
            item.tap()
            _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: chosen, object: picker)], timeout: 5)
        }
        XCTAssertTrue(chosen.evaluate(with: picker), "The picker shows \(choice): \(picker.label)")
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

    /// Day options, then Customize Today, two taps. At the largest text the
    /// menu runs under the tab bar, so it's dragged up first, as a person
    /// would; a drag beside it would close it.
    private func openCustomizeFromDayMenu(_ app: XCUIApplication) {
        tap(app.buttons["today.dayMenu"], in: app)
        let customize = app.buttons["today.dayMenu.customize"]
        XCTAssertTrue(customize.waitForExistence(timeout: 10), app.debugDescription)
        // A flick on an item the menu shows; a slow drag would choose the
        // item it ends on.
        let items = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'today.dayMenu.'"))
        for _ in 0..<3 where !customize.isHittable {
            items.allElementsBoundByIndex.first { $0.isHittable }?.swipeUp()
        }
        XCTAssertTrue(customize.isHittable, app.debugDescription)
        customize.tap()
        tapCount += 1
    }

    /// Waits for the account's preference `key` to be `value` on the server.
    private func waitForPreference<Value: Equatable>(_ key: String, _ value: Value, token: String, attempts: Int = 40) async throws {
        var found: Any?
        for _ in 0..<attempts {
            found = (try await request("GET", "/api/preferences", token: token)["values"] as? [String: Any])?[key]
            if found as? Value == value { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("The server's \(key) is \(String(describing: found)), not \(value)")
    }
}
