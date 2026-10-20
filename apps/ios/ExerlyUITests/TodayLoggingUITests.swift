import XCTest

/// Log again's chips agree with each other however the meal or day gets
/// logged, each Undo takes back only what its own tap logged, and a new
/// weigh-in can't save a reading nobody entered. Checked on the server.
@MainActor
final class TodayLoggingUITests: ExerlyUITestCase {
    private func foodChip(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "today.suggestion.log.", name)).firstMatch
    }

    /// Blueberries first, then the meal: the meal adds only the yogurt, and
    /// each check takes back only its own food.
    func testAFoodThenItsMealEachUndoOnlyTheirOwn() async throws {
        let (app, person) = try await budgetHome(prefix: "chips-food-first")
        let meal = app.buttons["today.repeatMeal"]
        XCTAssertTrue(meal.waitForExistence(timeout: 20))
        tap(foodChip("Blueberries", in: app), in: app)
        try await expectEntries(token: person.token, ["Blueberries"], meal: "Breakfast")
        XCTAssertTrue(meal.label.hasPrefix("Repeat Yesterday's breakfast, 1 food"), "What's left of it: \(meal.label)")
        tap(meal, in: app)
        try await expectEntries(token: person.token, ["Blueberries", "Greek yogurt, plain"], meal: "Breakfast")

        tap(foodChip("Blueberries", in: app), in: app)
        try await expectEntries(token: person.token, ["Greek yogurt, plain"])
        XCTAssertTrue(foodChip("Blueberries", in: app).label.hasPrefix("Log Blueberries"), "Its own entry gone, the chip logs again")
        tap(meal, in: app)
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
        tap(berries, in: app)
        try await Task.sleep(for: .seconds(2))
        try await expectEntries(token: person.token, ["Blueberries", "Greek yogurt, plain"])

        tap(meal, in: app)
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
        tap(foodChip("Blueberries", in: app), in: app)
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
}
