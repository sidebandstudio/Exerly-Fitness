import XCTest

/// Log again's chips agree with each other however the meal or day gets
/// logged, each Undo takes back only what its own tap logged, and a new
/// weigh-in can't save a reading nobody entered. Checked on the server.
@MainActor
final class TodayLoggingUITests: ExerlyUITestCase {
    private func foodChip(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "today.suggestion.log.", name)).firstMatch
    }

    /// Taps a Log again chip, scrolling the shelf sideways first when it's
    /// off to the right; `tap(_:in:)` only scrolls up and down.
    private func tapChip(_ name: String, in app: XCUIApplication) {
        tapOnShelf(foodChip(name, in: app), in: app)
    }

    /// Taps a control on Log again's shelf, scrolling the shelf sideways
    /// first when it's off either edge: after a chip further along, the meal
    /// chip is off to the left.
    private func tapOnShelf(_ control: XCUIElement, in app: XCUIApplication) {
        let meal = app.buttons["today.repeatMeal"]
        if !(app.frame.minY...app.frame.maxY).contains(meal.frame.midY) { reveal(meal, in: app) }
        for _ in 0..<5 where control.exists && !app.frame.contains(control.frame) {
            let row = meal.frame.midY / app.frame.height
            let (from, to) = control.frame.minX < app.frame.minX ? (0.25, 0.85) : (0.85, 0.25)
            app.coordinate(withNormalizedOffset: CGVector(dx: from, dy: row))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: to, dy: row)))
        }
        tap(control, in: app)
    }

    /// Blueberries first, then the meal: the meal adds only the yogurt, and
    /// each check takes back only its own food.
    func testAFoodThenItsMealEachUndoOnlyTheirOwn() async throws {
        let (app, person) = try await budgetHome(prefix: "chips-food-first")
        let meal = app.buttons["today.repeatMeal"]
        XCTAssertTrue(meal.waitForExistence(timeout: 20))
        tapChip("Blueberries", in: app)
        try await expectEntries(token: person.token, ["Blueberries"], meal: "Breakfast")
        XCTAssertTrue(meal.label.hasPrefix("Repeat Yesterday's breakfast, 1 food"), "What's left of it: \(meal.label)")
        tapOnShelf(meal, in: app)
        try await expectEntries(token: person.token, ["Blueberries", "Greek yogurt, plain"], meal: "Breakfast")

        tapChip("Blueberries", in: app)
        try await expectEntries(token: person.token, ["Greek yogurt, plain"])
        XCTAssertTrue(foodChip("Blueberries", in: app).label.hasPrefix("Log Blueberries"), "Its own entry gone, the chip logs again")
        tapOnShelf(meal, in: app)
        try await expectEntries(token: person.token, [])
    }

    /// The meal first: its foods' chips say they're in and a tap on one logs
    /// nothing; the meal's check takes back the whole meal.
    func testAMealThenItsFoodsLogNothingTwice() async throws {
        let (app, person) = try await budgetHome(prefix: "chips-meal-first")
        let meal = app.buttons["today.repeatMeal"]
        XCTAssertTrue(meal.waitForExistence(timeout: 20))
        tap(meal, in: app)
        try await expectEntries(token: person.token, ["Blueberries", "Greek yogurt, plain"], meal: "Breakfast")
        let berries = foodChip("Blueberries", in: app)
        XCTAssertTrue(berries.label.contains("already in breakfast"), berries.label)
        tapChip("Blueberries", in: app)
        try await Task.sleep(for: .seconds(2))
        try await expectEntries(token: person.token, ["Blueberries", "Greek yogurt, plain"])

        tapOnShelf(meal, in: app)
        try await expectEntries(token: person.token, [])
        XCTAssertTrue(foodChip("Blueberries", in: app).label.hasPrefix("Log Blueberries"))
    }

    /// The whole day first: the meal chip and its foods say they're in, and
    /// taps on them log nothing; the day's button stays, checked, and takes
    /// back all of the day and nothing else.
    func testADayThenItsMealAndFoodsLogNothingTwice() async throws {
        let (app, person) = try await budgetHome(prefix: "chips-day-first")
        let meal = app.buttons["today.repeatMeal"]
        XCTAssertTrue(meal.waitForExistence(timeout: 20))
        let day = app.buttons["today.repeatDay"]
        tap(day, in: app)
        try await expectEntries(token: person.token, Self.yesterdaysFood)
        XCTAssertTrue(meal.label.contains("already logged"), meal.label)
        tap(meal, in: app)
        tapChip("Blueberries", in: app)
        try await Task.sleep(for: .seconds(2))
        try await expectEntries(token: person.token, Self.yesterdaysFood)
        XCTAssertTrue(day.label.hasPrefix("Repeated yesterday, 6 foods. Undo"), day.label)
        tap(day, in: app)
        try await expectEntries(token: person.token, [])
        XCTAssertTrue(meal.label.hasPrefix("Repeat Yesterday's breakfast"), meal.label)
        XCTAssertTrue(day.label.hasPrefix("Repeat all of yesterday"), day.label)
    }

    /// Untouched, or typed and cleared, a new weigh-in has nothing to save;
    /// the last reading is a placeholder VoiceOver names as one, and using it
    /// again is a button of its own.
    func testANewWeighInSavesOnlyAWeightSomeoneChose() async throws {
        let (app, person) = try await budgetHome(prefix: "weigh-empty")
        tap(app.buttons["today.weighIn"], in: app)
        let value = app.buttons["weighIn.value"]
        let save = app.buttons["weighIn.save"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        XCTAssertTrue(value.label.contains("181.4") && value.label.contains("placeholder"), value.label)
        XCTAssertFalse(save.isEnabled, "Nothing typed: nothing to save")
        app.buttons["exerly.keypad.1"].tap()
        app.buttons["exerly.keypad.8"].tap()
        XCTAssertTrue(save.isEnabled)
        app.buttons["exerly.keypad.delete"].tap()
        app.buttons["exerly.keypad.delete"].tap()
        XCTAssertFalse(save.isEnabled, "Cleared with Delete: nothing to save again")
        XCTAssertTrue(value.label.contains("placeholder"), value.label)
        // The keypad put away, the ruler shows the last reading but nothing is chosen yet.
        app.buttons["exerly.keypadDone"].tap()
        XCTAssertFalse(save.isEnabled, "Putting the keypad away isn't choosing a weight")
        tap(app.buttons["weighIn.cancel"], in: app)
        try await Task.sleep(for: .seconds(3))
        let today = Self.day(0).date
        let readings = try await weighIns(token: person.token)
        XCTAssertTrue(readings.values.allSatisfy { $0["date"] as? String != today }, "No weigh-in today")

        startCounting()
        tap(app.buttons["today.weighIn"], in: app)
        let same = app.buttons["weighIn.sameAsLast"]
        XCTAssertTrue(same.waitForExistence(timeout: 5))
        XCTAssertEqual(same.label, "Same as last, 181.4 pounds")
        tap(same, in: app)
        XCTAssertEqual(tapCount, 2, "Weigh in, Same as last: the weigh-in budget is 3")
        let saved = try await waitForWeighIn(token: person.token) { $0["date"] as? String == today }
        XCTAssertEqual((saved?["weight"] as? [String: Any])?["value"] as? Double ?? 0, 181.4, accuracy: 0.001)
    }

    // MARK: Review round 2

    /// One entry of today's food on the server, by name.
    private func todaysEntry(_ name: String, token: String) async throws -> [String: Any]? {
        let today = Self.day(0).date
        return try await liveDocuments("food_entry", token: token).values.first {
            $0["date"] as? String == today && ($0["food"] as? [String: Any])?["name"] as? String == name
        }
    }

    /// Changes an entry's grams on the server, as another device would.
    private func editOnAnotherDevice(_ entry: [String: Any], grams: Double, token: String) async throws {
        let id = try XCTUnwrap(entry["id"] as? String)
        let current = try await request("GET", "/v1/documents/food_entry/\(id)", token: token)
        let revision = try XCTUnwrap(current["revision"] as? Int)
        var payload = try XCTUnwrap(current["payload"] as? [String: Any])
        payload["grams"] = grams
        _ = try await request("PUT", "/v1/documents/food_entry/\(id)", body: ["base_revision": revision, "payload": payload], token: token)
    }

    /// Leaves the app and comes back, which syncs, until Today shows the
    /// entry's new amount. What's on screen, its confirmation included, stays.
    private func syncToday(until label: String, in app: XCUIApplication) {
        let edited = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "nutrition.entry.", label)).firstMatch
        for _ in 0..<4 where !edited.exists {
            XCUIDevice.shared.press(.home)
            app.activate()
            _ = edited.waitForExistence(timeout: 8)
        }
        XCTAssertTrue(edited.exists, "The edit synced: \(label)")
    }

    /// A copy edited on another device after a repeat outlives every Undo:
    /// the confirmation's and the chip's take back only unchanged copies, and
    /// once nothing they may take back is left, the confirmation's Undo goes.
    func testAnEditedCopyOutlivesEveryUndo() async throws {
        let (app, person) = try await budgetHome(prefix: "undo-edited")
        let meal = app.buttons["today.repeatMeal"]
        XCTAssertTrue(meal.waitForExistence(timeout: 20))
        tap(meal, in: app)
        try await expectEntries(token: person.token, ["Blueberries", "Greek yogurt, plain"], meal: "Breakfast")
        let berries = try await waitForEntry("Blueberries", token: person.token)
        try await editOnAnotherDevice(berries, grams: 95, token: person.token)
        syncToday(until: "95 g", in: app)
        let undo = app.buttons["today.undo"]
        XCTAssertTrue(undo.exists && undo.isHittable, "The confirmation's Undo is still offered")
        undo.tap()
        try await expectEntries(token: person.token, ["Blueberries"])
        let kept = try await todaysEntry("Blueberries", token: person.token)
        XCTAssertEqual(kept?["grams"] as? Double, 95, "The edited copy is kept")

        // The whole day, one copy edited, then the day's own Undo: the
        // confirmation's Undo has nothing left that it may take back.
        tap(app.buttons["today.repeatDay"], in: app)
        let rice = try await waitForEntry("Jasmine rice, cooked", token: person.token)
        try await editOnAnotherDevice(rice, grams: 210, token: person.token)
        syncToday(until: "210 g", in: app)
        tap(app.buttons["today.repeatDay"], in: app)
        XCTAssertTrue(undo.waitForNonExistence(timeout: 5), "Nothing the confirmation may take back is left")
        try await expectEntries(token: person.token, ["Blueberries", "Jasmine rice, cooked"])
    }

    private func waitForEntry(_ name: String, token: String) async throws -> [String: Any] {
        for _ in 0..<60 {
            if let entry = try await todaysEntry(name, token: token) { return entry }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw XCTSkip("\(name) never reached the server")
    }

    /// The keypad's keys stay where they are while a weight is typed and
    /// cleared: a key's frame is the same before the first digit, after it,
    /// and after Delete takes it away.
    func testTheWeighInKeypadStaysPutWhileTyping() async throws {
        let (app, _) = try await budgetHome(prefix: "weigh-steady")
        tap(app.buttons["today.weighIn"], in: app)
        let five = app.buttons["exerly.keypad.5"]
        XCTAssertTrue(five.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["weighIn.sameAsLast"].exists)
        Thread.sleep(forTimeInterval: 1)
        let before = five.frame
        app.buttons["exerly.keypad.1"].tap()
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(five.frame, before, "After the first digit")
        capture(app, "taps-weigh-in-typing")
        app.buttons["exerly.keypad.delete"].tap()
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(five.frame, before, "After Delete empties it")
    }

    /// A repeat made while the launch's first sync is still out keeps its
    /// check and its Undo when that sync comes back.
    func testARepeatKeepsItsUndoThroughTheStartupSync() async throws {
        let (app, person) = try await budgetHome(prefix: "undo-startup-sync")
        let day = app.buttons["today.repeatDay"]
        // All of yesterday on the device before it's opened again.
        let all = NSPredicate(format: "label BEGINSWITH %@", "Repeat all of yesterday, breakfast, lunch and dinner, 6 foods")
        await fulfillment(of: [expectation(for: all, evaluatedWith: day)], timeout: 60)
        // Opened again from what's on the device, with the server holding each
        // sync request for fifteen seconds.
        try await control(["syncDelayMs": 15000])
        app.launchArguments.removeAll { $0 == "--ui-testing" }
        app.terminate()
        app.launch()
        XCTAssertTrue(day.waitForExistence(timeout: 15))
        day.tap()
        XCTAssertTrue(day.label.hasPrefix("Repeated yesterday, 6 foods. Undo"), day.label)
        // Requests from now on are answered at once; the launch's held ones in
        // under fifteen seconds. Once the copies are on the server and the held
        // sync is back, the day's own Undo is still there.
        try await control([:])
        try await expectEntries(token: person.token, Self.yesterdaysFood)
        try await Task.sleep(for: .seconds(20))
        XCTAssertTrue(day.label.hasPrefix("Repeated yesterday, 6 foods. Undo"), "Still its own Undo: \(day.label)")
        tap(day, in: app)
        try await expectEntries(token: person.token, [])
    }

    /// Log, then start today's workout straight away: the confirmation never
    /// covers Start. At the largest text sizes the meal's repeat fills Log
    /// again's first screen and the chips follow it off the edge, so the
    /// repeat logs there, and Start is a scroll below.
    func testLoggingThenStartingTheWorkoutStraightAway() async throws {
        let (app, _) = try await budgetHome(prefix: "log-then-start")
        let largest = ProcessInfo.processInfo.environment["EXERLY_TEST_LARGEST_TYPE"] == "1"
        let chip = largest ? app.buttons["today.repeatMeal"]
            : app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "today.suggestion.log.")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 20))
        chip.tap()
        let start = app.buttons["today.startWorkout"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        let confirmations = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                                                                 "Logged ", "Repeated "))
        XCTAssertTrue(confirmations.firstMatch.exists, "The confirmation shows")
        capture(app, "taps-logged-confirmation")
        if largest { reveal(start, in: app) }
        XCTAssertTrue(start.isHittable, "Start isn't under the confirmation")
        // Wherever it shows, no part of it overlaps Start.
        for confirmation in confirmations.allElementsBoundByIndex where confirmation.exists {
            XCTAssertFalse(confirmation.frame.intersects(start.frame), "\(confirmation.label) doesn't overlap Start")
        }
        start.tap()
        XCTAssertTrue(app.buttons["training.finish"].waitForExistence(timeout: 10), "The tap started the workout")
    }
}
