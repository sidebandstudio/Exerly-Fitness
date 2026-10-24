import XCTest

/// The tap budgets in docs/AGENT_BRIEF.md outcome 1, as CI checks them and
/// docs/TAP_BUDGETS.md publishes them. Each starts on Today, the home screen,
/// at its top, for a signed-in person with history; counts every tap through
/// `tap(_:in:)` and every drag `reveal(_:in:)` makes to find a control; and
/// passes only once the entry is on the server, not just on screen. Typing a
/// number isn't counted, as it isn't for MacroFactor in the published table.
@MainActor
final class TapBudgetUITests: ExerlyUITestCase {
    /// Any food eaten before, not just one Log again offers: Search, its
    /// name typed into the field that opens focused, then its +, which logs
    /// the last portion. Budget 3.
    func testAFoodEatenBeforeTakesTwoTaps() async throws {
        let (app, person) = try await budgetHome(prefix: "budget-food")
        startCounting()
        tap(app.buttons["nutrition.addFood"], in: app)
        XCTAssertTrue(app.navigationBars["Add food"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Search opens ready to type")
        app.typeText("chicken")
        let chicken = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                                                       "nutrition.quickLog.", "Log 180 g of Chicken breast")).firstMatch
        XCTAssertTrue(chicken.waitForExistence(timeout: 10), "Yesterday's 180 g")
        tap(chicken, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["nutrition.loggedConfirmation"].waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(tapCount, 3, "Budget: 3")
        XCTAssertEqual(tapCount, 2, "Search, then the food's +")
        XCTAssertEqual(scrollCount, 0)
        try await expectEntries(token: person.token, ["Chicken breast, grilled"])
    }

    /// The food most likely now is the first Log again chip on Today: one tap.
    func testTheFoodMostLikelyNowTakesOneTap() async throws {
        let (app, person) = try await budgetHome(prefix: "budget-suggestion")
        let chip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "today.suggestion.log.")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 20))
        // "Log <name>, <portion>": a name can have commas of its own ("Greek yogurt, plain").
        let label = chip.label.dropFirst("Log ".count)
        let name = String(label[..<(label.range(of: ", ", options: .backwards)?.lowerBound ?? label.endIndex)])
        startCounting()
        tap(chip, in: app)
        XCTAssertEqual(tapCount, 1)
        XCTAssertEqual(scrollCount, 0, "On the first screen")
        try await expectEntries(token: person.token, [name], meal: "Breakfast")
    }

    /// The meal being eaten now, as last logged, leads Log again: one tap,
    /// with no scrolling. Budget 2.
    func testRepeatingAMealTakesOneTap() async throws {
        let (app, person) = try await budgetHome(prefix: "budget-meal")
        let meal = app.buttons["today.repeatMeal"]
        XCTAssertTrue(meal.waitForExistence(timeout: 20))
        XCTAssertTrue(meal.label.hasPrefix("Repeat Yesterday's breakfast, 2 foods"), meal.label)
        startCounting()
        tap(meal, in: app)
        XCTAssertLessThanOrEqual(tapCount, 2, "Budget: 2")
        XCTAssertEqual(tapCount, 1)
        XCTAssertEqual(scrollCount, 0, "On the first screen")
        XCTAssertTrue(app.buttons["Repeated Yesterday's breakfast. Undo"].waitForExistence(timeout: 5))
        try await expectEntries(token: person.token, ["Greek yogurt, plain", "Blueberries"], meal: "Breakfast")

        // With breakfast in, the day's repeat is the rest of it: lunch and
        // dinner, and breakfast isn't logged twice.
        let rest = app.buttons["today.repeatDay"]
        XCTAssertTrue(rest.waitForExistence(timeout: 5))
        XCTAssertTrue(rest.label.hasPrefix("Repeat the rest of yesterday, lunch and dinner, 4 foods"), rest.label)
        tap(rest, in: app)
        try await expectEntries(token: person.token, Self.yesterdaysFood)
        XCTAssertTrue(rest.label.hasPrefix("Repeated yesterday, 4 foods. Undo"), "Its own Undo stays: \(rest.label)")
    }

    /// All of yesterday, beside Log again's title: one tap on an empty day.
    /// Budget 2.
    func testRepeatingAWholeDayTakesOneTap() async throws {
        let (app, person) = try await budgetHome(prefix: "budget-day")
        let day = app.buttons["today.repeatDay"]
        XCTAssertTrue(day.waitForExistence(timeout: 20))
        XCTAssertTrue(day.label.hasPrefix("Repeat all of yesterday, breakfast, lunch and dinner, 6 foods"), day.label)
        startCounting()
        tap(day, in: app)
        XCTAssertLessThanOrEqual(tapCount, 2, "Budget: 2")
        XCTAssertEqual(tapCount, 1)
        XCTAssertEqual(scrollCount, 0, "On the first screen")
        try await expectEntries(token: person.token, Self.yesterdaysFood)
        XCTAssertTrue(day.label.hasPrefix("Repeated yesterday, 6 foods. Undo"), "Its own Undo stays: \(day.label)")
    }


    /// Scan, the scan, Log. The simulator has no camera, so its stand-in
    /// camera is shown the code (BarcodeTestFeed), which counts as one
    /// action, and the food found lands on the plate. Budget 3.
    func testBarcodeToLoggedTakesThreeTaps() async throws {
        _ = try await request("POST", "/__test/barcode-feed", body: [:])
        let (app, person) = try await budgetHome(prefix: "budget-barcode", environment: ["EXERLY_TEST_BARCODE_FEED": "1"])
        startCounting()
        tap(app.buttons["nutrition.scanBarcodeDirect"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["nutrition.scannerReady"].waitForExistence(timeout: 10), "The camera is watching")
        _ = try await request("POST", "/__test/barcode-feed", body: ["payload": "ean13:0012345678905"])
        tapCount += 1
        let log = app.buttons["nutrition.scanLogAll"]
        XCTAssertTrue(log.waitForExistence(timeout: 10), "The food found is on the plate")
        tap(log, in: app)
        XCTAssertLessThanOrEqual(tapCount, 3, "Budget: 3")
        XCTAssertEqual(tapCount, 3, "Scan, the scan, Log")
        XCTAssertEqual(scrollCount, 0)
        try await expectEntries(token: person.token, ["Synthetic oat bar"])
    }

    /// Weigh in, the scale's number typed over the last reading on the
    /// keypad that's already up, Save. Budget 3.
    func testAWeighInTakesTwoTaps() async throws {
        let (app, person) = try await budgetHome(prefix: "budget-weigh")
        startCounting()
        tap(app.buttons["today.weighIn"], in: app)
        let value = app.buttons["weighIn.value"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        XCTAssertTrue(value.label.contains("181.4"), "Opens showing the last reading: \(value.label)")
        XCTAssertTrue(app.buttons["exerly.keypadDone"].exists, "With the keypad up")
        // Typing isn't counted, as it isn't for MacroFactor.
        for key in ["1", "8", "0", Locale.current.decimalSeparator ?? ".", "6"] { app.buttons["exerly.keypad.\(key)"].tap() }
        tap(app.buttons["weighIn.save"], in: app)
        XCTAssertLessThanOrEqual(tapCount, 3, "Budget: 3")
        XCTAssertEqual(tapCount, 2, "Weigh in, Save")
        XCTAssertEqual(scrollCount, 0)
        let today = Self.day(0).date
        let saved = try await waitForWeighIn(token: person.token) { $0["date"] as? String == today }
        let weight = saved?["weight"] as? [String: Any]
        XCTAssertEqual(weight?["value"] as? Double ?? 0, 180.6, accuracy: 0.001)
        XCTAssertEqual(weight?["unit"] as? String, "lb")
    }

    /// Start on Today's workout card: one tap, budget 2, and the workout is
    /// on the server. Then the first set, prefilled from last time, in one
    /// tap, budget 1. A set is saved on the device as it's done and synced
    /// with the workout later, so it's checked the way PARITY B02 asks: the
    /// app is killed and opened again, and the set is still done.
    func testTodaysWorkoutStartsInOneTapAndAPrefilledSetTakesOne() async throws {
        let (app, person) = try await budgetHome(prefix: "budget-workout")
        startCounting()
        tap(app.buttons["today.startWorkout"], in: app)
        XCTAssertTrue(app.buttons["training.finish"].waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(tapCount, 2, "Budget: 2")
        XCTAssertEqual(tapCount, 1)
        XCTAssertEqual(scrollCount, 0, "Start is on the first screen")
        XCTAssertTrue(app.navigationBars["Strength foundations: Upper A"].waitForExistence(timeout: 5))
        let started = try await waitForDocument("workout_session", token: person.token) {
            $0["endedAt"] == nil
        }
        XCTAssertNotNil(started, "The started workout is on the server")
        let load = app.textFields["set.barbell-bench-press.1.load"]
        XCTAssertEqual(load.value as? String, "160", "Prefilled from 155 lb × 8 last time")
        let reps = app.textFields["set.barbell-bench-press.1.reps"].value as? String
        XCTAssertNotNil(Int(reps ?? ""), "Reps prefilled too")

        startCounting()
        tap(app.buttons["Complete set 1, Barbell Bench Press"], in: app)
        let done = app.buttons["Reopen set 1, Barbell Bench Press"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(tapCount, 1, "Budget: 1")
        XCTAssertEqual(tapCount, 1)

        // Killed at once and opened again: the workout and its done set are kept.
        app.launchArguments.removeAll { $0 == "--ui-testing" }
        app.terminate()
        app.launch()
        let resume = app.buttons["today.resumeWorkout"]
        if !done.waitForExistence(timeout: 10), resume.waitForExistence(timeout: 10) { tap(resume, in: app) }
        XCTAssertTrue(done.waitForExistence(timeout: 10), "The set is still done after a relaunch")
        XCTAssertEqual(load.value as? String, "160")
        XCTAssertEqual(app.textFields["set.barbell-bench-press.1.reps"].value as? String, reps)
    }

    /// Offline from the start: Start and the prefilled set take their one
    /// tap each, the set survives the app being killed, and once back online
    /// the finished workout reaches the server with that set done.
    func testAPrefilledSetLogsOfflineInOneTapAndSyncsLater() async throws {
        let (app, person) = try await budgetHome(prefix: "budget-offline-set")
        try await control(["offline": true])
        startCounting()
        tap(app.buttons["today.startWorkout"], in: app)
        XCTAssertTrue(app.buttons["training.finish"].waitForExistence(timeout: 10))
        XCTAssertEqual(tapCount, 1)
        let load = app.textFields["set.barbell-bench-press.1.load"]
        XCTAssertEqual(load.value as? String, "160", "Prefilled offline too")
        let reps = app.textFields["set.barbell-bench-press.1.reps"].value as? String
        startCounting()
        tap(app.buttons["Complete set 1, Barbell Bench Press"], in: app)
        let done = app.buttons["Reopen set 1, Barbell Bench Press"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertEqual(tapCount, 1, "Budget: 1")

        app.launchArguments.removeAll { $0 == "--ui-testing" }
        app.terminate()
        app.launch()
        let resume = app.buttons["today.resumeWorkout"]
        if !done.waitForExistence(timeout: 10), resume.waitForExistence(timeout: 10) { tap(resume, in: app) }
        XCTAssertTrue(done.waitForExistence(timeout: 10), "Still done after a relaunch, offline")

        try await control([:])
        tap(app.buttons["training.finish"], in: app)
        let save = app.buttons["Save workout"]
        if save.waitForExistence(timeout: 5) { tap(save, in: app) }
        let synced = try await waitForDocument("workout_session", token: person.token) { session in
            // Today's, not the Upper A seeded three days ago.
            guard session["endedAt"] != nil, (session["startedAt"] as? String ?? "") >= Self.day(0).date,
                  let bench = (session["exercises"] as? [[String: Any]])?.first(where: { $0["exerciseID"] as? String == "barbell-bench-press" }),
                  let first = (bench["sets"] as? [[String: Any]])?.first else { return false }
            return first["completedAt"] != nil
        }
        let effort = ((((synced?["exercises"] as? [[String: Any]])?.first { $0["exerciseID"] as? String == "barbell-bench-press" })?["sets"]
            as? [[String: Any]])?.first?["efforts"] as? [[String: Any]])?.first
        XCTAssertEqual(effort.flatMap { $0["reps"] as? Int }.map(String.init), reps, "The prefilled reps, synced")
    }

    /// Opt-in screenshots of Log again's repeats: offered, the meal
    /// repeated, and the rest of the day once the meal has food.
    func testRepeatShelfCapture() async throws {
        guard ProcessInfo.processInfo.environment["EXERLY_DESIGN_CAPTURE"] == "1" else {
            throw XCTSkip("Opt-in visual review of Log again's repeats")
        }
        let (app, _) = try await budgetHome(prefix: "budget-capture")
        XCTAssertTrue(app.buttons["today.repeatMeal"].waitForExistence(timeout: 20))
        capture(app, "taps-01-today-repeats")
        // At the largest text sizes Log again is a scroll down.
        reveal(app.buttons["today.repeatMeal"], in: app)
        capture(app, "taps-01b-log-again")
        tap(app.buttons["today.repeatMeal"], in: app)
        XCTAssertTrue(app.buttons["Repeated Yesterday's breakfast. Undo"].waitForExistence(timeout: 5))
        capture(app, "taps-02-meal-repeated")
        // Back on today after another day, breakfast has food: the rest of yesterday stands alone.
        shiftDay(-1, in: app)
        showToday(in: app)
        todayScreen(app).swipeDown()
        XCTAssertTrue(app.buttons["today.repeatDay"].waitForExistence(timeout: 5))
        capture(app, "taps-03-rest-of-day")
        reveal(app.buttons["today.repeatDay"], in: app)
        capture(app, "taps-03b-rest-of-day-row")
        tap(app.buttons["today.repeatDay"], in: app)
        XCTAssertTrue(app.buttons["today.repeatDay"].label.hasPrefix("Repeated yesterday"))
        capture(app, "taps-03c-rest-repeated")
        todayScreen(app).swipeDown()
        todayScreen(app).swipeDown()
        tap(app.buttons["today.weighIn"], in: app)
        XCTAssertTrue(app.buttons["exerly.keypadDone"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.6)
        capture(app, "taps-04-weigh-in")
        app.buttons["exerly.keypad.1"].tap()
        app.buttons["exerly.keypad.8"].tap()
        capture(app, "taps-05-weigh-in-typing")
    }
}
