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
        let (app, person) = try await home(prefix: "budget-food")
        start()
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
        let (app, person) = try await home(prefix: "budget-suggestion")
        let chip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "today.suggestion.log.")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 20))
        let name = String(chip.label.dropFirst("Log ".count).prefix { $0 != "," })
        start()
        tap(chip, in: app)
        XCTAssertEqual(tapCount, 1)
        XCTAssertEqual(scrollCount, 0, "On the first screen")
        try await expectEntries(token: person.token, [name], meal: "Breakfast")
    }

    /// The meal being eaten now, as last logged, leads Log again: one tap,
    /// with no scrolling. Budget 2.
    func testRepeatingAMealTakesOneTap() async throws {
        let (app, person) = try await home(prefix: "budget-meal")
        let meal = app.buttons["today.repeatMeal"]
        XCTAssertTrue(meal.waitForExistence(timeout: 20))
        XCTAssertTrue(meal.label.hasPrefix("Repeat Yesterday's breakfast, 2 foods"), meal.label)
        start()
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
        try await expectEntries(token: person.token, Self.yesterday)
        XCTAssertTrue(rest.waitForNonExistence(timeout: 5), "Nothing of yesterday is left to repeat")
    }

    /// All of yesterday, beside Log again's title: one tap on an empty day.
    /// Budget 2.
    func testRepeatingAWholeDayTakesOneTap() async throws {
        let (app, person) = try await home(prefix: "budget-day")
        let day = app.buttons["today.repeatDay"]
        XCTAssertTrue(day.waitForExistence(timeout: 20))
        XCTAssertTrue(day.label.hasPrefix("Repeat all of yesterday, breakfast, lunch and dinner, 6 foods"), day.label)
        start()
        tap(day, in: app)
        XCTAssertLessThanOrEqual(tapCount, 2, "Budget: 2")
        XCTAssertEqual(tapCount, 1)
        XCTAssertEqual(scrollCount, 0, "On the first screen")
        try await expectEntries(token: person.token, Self.yesterday)
        XCTAssertTrue(day.waitForNonExistence(timeout: 5), "Nothing of yesterday is left to repeat")
    }

    /// Yesterday's food in seedWeek, each once.
    private static let yesterday = ["Greek yogurt, plain", "Blueberries", "Chicken breast, grilled", "Jasmine rice, cooked",
                                    "Salmon fillet", "Roasted potatoes"]

    /// Scan, the barcode, Log. The simulator has no camera, so the barcode
    /// builder's seam, its digits typed and looked up, stands in for the scan
    /// and counts as one action. Budget 3.
    func testBarcodeToLoggedTakesThreeTaps() async throws {
        let (app, person) = try await home(prefix: "budget-barcode")
        start()
        tap(app.buttons["nutrition.scanBarcodeDirect"], in: app)
        let field = app.textFields["nutrition.barcodeDigits"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let before = tapCount
        replace(field, with: "0012345678905", in: app)
        tap(app.buttons["nutrition.lookupBarcode"], in: app)
        tapCount = before + 1
        tap(app.buttons["nutrition.saveEntry"], in: app)
        XCTAssertLessThanOrEqual(tapCount, 3, "Budget: 3")
        XCTAssertEqual(tapCount, 3, "Scan, the scan, Log")
        XCTAssertEqual(scrollCount, 0)
        try await expectEntries(token: person.token, ["Synthetic oat bar"])
    }

    /// Weigh in, the scale's number typed over the last reading on the
    /// keypad that's already up, Save. Budget 3.
    func testAWeighInTakesTwoTaps() async throws {
        let (app, person) = try await home(prefix: "budget-weigh")
        start()
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
        let (app, person) = try await home(prefix: "budget-workout")
        start()
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

        start()
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

    /// Opt-in screenshots of Log again's repeats: offered, the meal
    /// repeated, and the rest of the day once the meal has food.
    func testRepeatShelfCapture() async throws {
        guard ProcessInfo.processInfo.environment["EXERLY_DESIGN_CAPTURE"] == "1" else {
            throw XCTSkip("Opt-in visual review of Log again's repeats")
        }
        let (app, _) = try await home(prefix: "budget-capture")
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

    // MARK: Support

    /// A person with last week's food and weigh-ins, a two-day program with
    /// last Upper A logged, signed in on Today. Their breakfast habit is
    /// around now, so Breakfast is the meal Log again fills at any hour.
    private func home(prefix: String) async throws -> (XCUIApplication, (email: String, token: String)) {
        try await control([:])
        let person = try await createAccount(prefix: prefix, units: "imperial")
        try await seedWeek(token: person.token)
        try await deleteSetupWeight(token: person.token)
        try await seedPlan(token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        settleAfterSignIn(app)
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 20))
        XCTAssertTrue(app.navigationBars["Today"].exists, "On the home screen")
        return (app, person)
    }

    /// Counts the next task from zero.
    private func start() {
        tapCount = 0
        scrollCount = 0
    }

    /// Upper A and Lower A, with Upper A three days ago at 155 lb, so Upper A
    /// is today's and progresses to 160 lb, and a 181.4 lb weigh-in yesterday.
    private func seedPlan(token: String) async throws {
        func day(_ name: String, _ slots: [(String, Int, Int, Int)]) -> [String: Any] {
            ["id": UUID().uuidString, "name": name, "slots": slots.map { slot -> [String: Any] in
                ["id": UUID().uuidString, "exerciseID": slot.0, "notes": "",
                 "target": ["sets": slot.1, "minReps": slot.2, "maxReps": slot.3, "rir": 2, "kind": "standard"],
                 "cycleTargets": [String: Any](), "expandRepRange": false, "weightMatch": true]
            }]
        }
        let id = UUID().uuidString
        let program: [String: Any] = ["id": id, "name": "Strength foundations", "cycles": 4, "deload": "none",
                                      "createdAt": "2026-10-01T12:00:00.000Z", "activatedAt": "2026-10-01T12:00:00.000Z",
                                      "days": [day("Upper A", [("barbell-bench-press", 3, 5, 8), ("barbell-row", 3, 6, 10)]),
                                               day("Lower A", [("back-squat", 3, 5, 8)])]]
        _ = try await request("PUT", "/v1/documents/program/\(id)", body: ["base_revision": 0, "payload": program], token: token)
        let yesterday = Self.day(-1)
        try await seedWeighIn(token: token, date: yesterday.date, at: yesterday.at, value: 181.4, unit: "lb")
        let start = Date().addingTimeInterval(-3 * 86_400 - 5_400)
        var minute = 0.0
        let exercises: [(String, Double, [Int])] = [("barbell-bench-press", 155, [8, 7, 6]), ("barbell-row", 135, [10, 9, 8])]
        let session: [String: Any] = [
            "id": UUID().uuidString, "name": "Upper A", "notes": "", "startedAt": Self.iso(start),
            "endedAt": Self.iso(start.addingTimeInterval(3_000)), "timeZoneID": "America/New_York",
            "exercises": exercises.map { exercise -> [String: Any] in
                ["id": UUID().uuidString, "exerciseID": exercise.0, "notes": "", "sets": exercise.2.map { reps -> [String: Any] in
                    minute += 3
                    return ["id": UUID().uuidString, "kind": "standard", "rir": 2,
                            "completedAt": Self.iso(start.addingTimeInterval(minute * 60)),
                            "efforts": [["reps": reps, "load": ["unit": "lb", "value": exercise.1]]]]
                }]
            },
        ]
        let sessionID = session["id"] as? String ?? ""
        _ = try await request("PUT", "/v1/documents/workout_session/\(sessionID)", body: ["base_revision": 0, "payload": session],
                              token: token)
    }

    /// The account's live documents of a kind, by ID, from the change feed.
    private func documents(_ kind: String, token: String) async throws -> [String: [String: Any]] {
        var latest: [String: [String: Any]?] = [:]
        var cursor = 0
        while true {
            let page = try await request("GET", "/v1/changes?after=\(cursor)&limit=1000", token: token)
            for change in page["changes"] as? [[String: Any]] ?? [] where change["kind"] as? String == kind {
                guard let id = change["id"] as? String else { continue }
                latest[id] = change["payload"] as? [String: Any]
            }
            cursor = page["cursor"] as? Int ?? cursor
            guard page["has_more"] as? Bool == true else { break }
        }
        return latest.compactMapValues { $0 }
    }

    private func waitForDocument(_ kind: String, token: String,
                                 _ matches: @escaping ([String: Any]) -> Bool) async throws -> [String: Any]? {
        for _ in 0..<60 {
            if let found = try await documents(kind, token: token).values.first(where: matches) { return found }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("No matching \(kind) reached the server")
        return nil
    }

    /// Waits until today's food on the server is exactly `names`, in any
    /// order, each once, and in `meal` when given.
    private func expectEntries(token: String, _ names: [String], meal: String? = nil) async throws {
        let today = Self.day(0).date
        var found: [[String: Any]] = []
        for _ in 0..<60 {
            found = try await documents("food_entry", token: token).values.filter { $0["date"] as? String == today }
            if found.compactMap({ ($0["food"] as? [String: Any])?["name"] as? String }).sorted() == names.sorted() { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertEqual(found.compactMap { ($0["food"] as? [String: Any])?["name"] as? String }.sorted(), names.sorted(),
                       "Today's food on the server")
        if let meal { XCTAssertTrue(found.allSatisfy { $0["meal"] as? String == meal }, "In \(meal)") }
    }
}
