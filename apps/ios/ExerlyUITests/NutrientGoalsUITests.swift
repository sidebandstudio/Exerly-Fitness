import XCTest

/// Nutrient goals and pins: a floor set from a nutrient's page, nutrients
/// pinned to Today, an ordering error that blocks Save, and unpinning.
@MainActor
final class NutrientGoalsUITests: ExerlyUITestCase {
    private var designCapture: Bool { ProcessInfo.processInfo.environment["EXERLY_DESIGN_CAPTURE"] == "1" }

    // MARK: Regression

    /// Progress → Nutrition → Fiber → Edit goal: a floor typed into the
    /// preselected "At least" shows on the page, and the plan gains a version
    /// from today with it.
    func testSettingAFiberFloorShowsOnItsPage() async throws {
        let (app, person) = try await signedInWithNutrients(prefix: "goals-floor")
        XCTAssertNotNil(targetEnergy(app))
        tapCount = 0
        openNutrition(in: app)
        let fiber = app.buttons["nutrition.nutrient.fiber"]
        reveal(fiber, in: app)
        tap(fiber, in: app)
        let goal = app.descendants(matching: .any)["nutrition.detail.goal"]
        XCTAssertTrue(goal.waitForExistence(timeout: 10))
        XCTAssertTrue((goal.value as? String ?? "").hasPrefix("At least 28 grams"), goal.value as? String ?? "")
        tap(app.buttons["nutrition.detail.editGoal"], in: app)
        XCTAssertTrue(app.buttons["At least"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["At least"].isSelected, "Fiber's daily value is a floor")
        // The amount opens focused and selected, so typing replaces it.
        let floor = app.textFields["goalEditor.floor"]
        XCTAssertTrue(waitFor(floor) { ($0.value(forKey: "hasKeyboardFocus") as? Bool) == true }, "The amount takes focus")
        floor.typeText("30")
        XCTAssertEqual(floor.value as? String, "30")
        tap(app.buttons["goalEditor.save"], in: app)
        XCTAssertTrue(waitForValue(goal, prefix: "At least 30 grams, your goal"), goal.value as? String ?? "")
        XCTAssertEqual(tapCount, 5, "Progress, Nutrition, Fiber, Edit goal, Save; the amount is typed")

        let plan = try await waitForPlan(token: person.token) { ($0["nutrientGoals"] as? [String: Any])?["fiber"] != nil }
        XCTAssertEqual(plan["startDate"] as? String, Self.day(0).date)
        XCTAssertEqual((plan["nutrientGoals"] as? [String: [String: Double]])?["fiber"], ["floor": 30])
    }

    /// Profile has Nutrient goals beside Your plan, and the list's search finds
    /// sodium without scrolling past the vitamins.
    func testNutrientGoalsFromProfileAndSearch() async throws {
        let (app, _) = try await signedInWithNutrients(prefix: "goals-profile", pinned: ["fiber"])
        XCTAssertNotNil(targetEnergy(app))
        tapCount = 0
        tap(app.buttons["Profile"], in: app)
        let row = app.buttons["profile.nutrientGoals"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertEqual(row.value as? String, "Daily values · 1 on Today")
        capture(app, "goals-profile-row")
        tap(row, in: app)
        XCTAssertTrue(app.navigationBars["Nutrient goals"].waitForExistence(timeout: 10))
        let search = app.textFields["goals.search"]
        tap(search, in: app)
        search.typeText("sod")
        let sodium = app.buttons["goals.nutrient.sodium"]
        XCTAssertTrue(sodium.waitForExistence(timeout: 5) && sodium.isHittable, "Sodium shows without scrolling")
        XCTAssertFalse(app.buttons["goals.nutrient.vitaminC"].exists, "Only matches while searching")
        capture(app, "goals-search-sodium")
        tap(sodium, in: app)
        XCTAssertTrue(app.buttons["goalEditor.save"].waitForExistence(timeout: 5))
        XCTAssertEqual(tapCount, 4, "Profile, Nutrient goals, search, Sodium; the name is typed")
    }

    /// From Today: the ring, Nutrient goals, two pins and back. Each pinned
    /// nutrient shows its day against its goal and the foods its total is from.
    func testPinningFiberAndSodiumShowsThemOnToday() async throws {
        let (app, person) = try await signedInWithNutrients(prefix: "goals-pin")
        XCTAssertNotNil(targetEnergy(app))
        XCTAssertFalse(app.buttons["today.pinned.fiber"].exists)
        tapCount = 0
        tap(app.buttons["nutrition.targetEnergy"], in: app)
        tap(app.buttons["targets.nutrientGoals"], in: app)
        tap(app.buttons["goals.pin.fiber"], in: app)
        tap(app.buttons["goals.pin.sodium"], in: app)
        XCTAssertEqual(app.buttons["goals.pin.fiber"].label, "Unpin Fiber from Today")
        tap(app.navigationBars.buttons["Targets"], in: app)
        tap(app.navigationBars.buttons["Today"], in: app)
        XCTAssertEqual(tapCount, 6, "Ring, Nutrient goals, two pins, back twice")

        let fiber = app.buttons["today.pinned.fiber"]
        let sodium = app.buttons["today.pinned.sodium"]
        XCTAssertTrue(fiber.waitForExistence(timeout: 10))
        XCTAssertTrue(sodium.exists)
        // Today: yogurt and chicken don't report fiber; berries and oats do.
        // Each reads like a macro: what's left first, then what's eaten of the goal.
        XCTAssertEqual(fiber.value as? String, "19 grams to go, 8.9 of 28 grams eaten, From 2 of 4 foods that report it")
        XCTAssertEqual(sodium.value as? String, "2,091 milligrams left, 209 of 2,300 milligrams eaten, From 3 of 4 foods that report it")
        let protein = app.descendants(matching: .any)["today.macro.protein"]
        XCTAssertEqual(protein.value as? String, "66 grams left, 84 of 150 grams eaten")
        let plan = try await waitForPlan(token: person.token) { ($0["pinnedNutrients"] as? [String])?.count == 2 }
        XCTAssertEqual(plan["pinnedNutrients"] as? [String], ["fiber", "sodium"])
    }

    /// A floor above the target says so in words and keeps Save off until fixed.
    func testAnOrderingErrorIsShownAndBlocksSave() async throws {
        let (app, _) = try await signedInWithNutrients(prefix: "goals-order")
        XCTAssertNotNil(targetEnergy(app))
        tap(app.buttons["nutrition.targetEnergy"], in: app)
        tap(app.buttons["targets.nutrientGoals"], in: app)
        tap(app.buttons["goals.nutrient.fiber"], in: app)
        tap(app.buttons["Range"], in: app)
        replace(app.textFields["goalEditor.floor"], with: "40", in: app)
        replace(app.textFields["goalEditor.target"], with: "30", in: app)
        let problem = app.descendants(matching: .any)["goalEditor.problem"]
        XCTAssertTrue(problem.waitForExistence(timeout: 5))
        XCTAssertEqual(problem.label, "The floor, 40 g, can't be above the target, 30 g.")
        XCTAssertFalse(app.buttons["goalEditor.save"].isEnabled)
        replace(app.textFields["goalEditor.target"], with: "45", in: app)
        XCTAssertTrue(problem.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["goalEditor.save"].isEnabled)
        tap(app.buttons["goalEditor.save"], in: app)
        let row = app.buttons["goals.nutrient.fiber"]
        XCTAssertTrue(waitForValue(row, prefix: "At least 40 grams, about 45 grams, your goal"), row.value as? String ?? "")
    }

    /// A pinned nutrient opens the goals sheet from Today; one tap unpins it.
    /// A pin no food today reports says "Not reported", never 0.
    func testUnpinningFromToday() async throws {
        let (app, person) = try await signedInWithNutrients(prefix: "goals-unpin", pinned: ["fiber", "sodium", "potassium"])
        XCTAssertNotNil(targetEnergy(app))
        let fiber = app.buttons["today.pinned.fiber"]
        XCTAssertTrue(fiber.waitForExistence(timeout: 20))
        let potassium = app.buttons["today.pinned.potassium"]
        XCTAssertTrue((potassium.value as? String ?? "").hasPrefix("Not reported"), potassium.value as? String ?? "")
        tapCount = 0
        tap(fiber, in: app)
        tap(app.buttons["goals.pin.fiber"], in: app)
        tap(app.buttons["goals.done"], in: app)
        XCTAssertEqual(tapCount, 3, "The pinned nutrient, its pin, Done")
        XCTAssertTrue(fiber.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["today.pinned.sodium"].exists && potassium.exists)
        let plan = try await waitForPlan(token: person.token) { ($0["pinnedNutrients"] as? [String])?.count == 2 }
        XCTAssertEqual(plan["pinnedNutrients"] as? [String], ["sodium", "potassium"])
    }

    func testGoalsCapture() async throws {
        guard designCapture else { throw XCTSkip("Opt-in visual review of nutrient goals and pins") }
        let (app, _) = try await signedInWithNutrients(prefix: "goals-capture", pinned: ["fiber", "sodium", "vitaminC"],
                                                       goals: ["fiber": ["floor": 25, "target": 35]])
        _ = targetEnergy(app)
        try await Task.sleep(for: .seconds(1.5))
        capture(app, "goals-01-today")
        app.swipeUp(velocity: .slow)
        try await Task.sleep(for: .seconds(0.5))
        capture(app, "goals-01b-today-pinned")
        for _ in 0..<2 { app.swipeDown(velocity: .fast) }

        tap(app.buttons["today.nutrients"], in: app)
        try await Task.sleep(for: .seconds(0.8))
        capture(app, "goals-02-day-nutrients")
        app.swipeUp(velocity: .slow)
        capture(app, "goals-03-day-nutrients-scrolled")
        app.buttons["Done"].firstMatch.tap()

        let pinned = app.buttons["today.pinned.fiber"]
        if pinned.waitForExistence(timeout: 2) {
            tap(pinned, in: app)
            try await Task.sleep(for: .seconds(0.8))
            capture(app, "goals-04-today-goals-sheet")
            app.buttons["goals.done"].firstMatch.tap()
            try await Task.sleep(for: .seconds(0.5))
        }

        for _ in 0..<4 { app.swipeDown(velocity: .fast) }
        tap(app.buttons["nutrition.targetEnergy"], in: app)
        let goalsRow = app.buttons["targets.nutrientGoals"]
        if goalsRow.waitForExistence(timeout: 3) {
            reveal(goalsRow, in: app)
        } else {
            let screen = app.scrollViews["targets.screen"]
            for _ in 0..<4 { screen.swipeUp() }
        }
        try await Task.sleep(for: .seconds(0.5))
        capture(app, "goals-05-targets-plan")
        if goalsRow.exists {
            tap(goalsRow, in: app)
            try await Task.sleep(for: .seconds(0.8))
            capture(app, "goals-06-goals-list")
            app.swipeUp(velocity: .slow)
            capture(app, "goals-07-goals-list-scrolled")
            for _ in 0..<3 { app.swipeDown(velocity: .fast) }
            tap(app.buttons["goals.nutrient.sodium"], in: app)
            XCTAssertTrue(app.buttons["goalEditor.save"].waitForExistence(timeout: 5))
            try await Task.sleep(for: .seconds(0.6))
            capture(app, "goals-08-editor")
            tap(app.buttons["Range"], in: app)
            replace(app.textFields["goalEditor.floor"], with: "2500", in: app)
            dismissKeyboard(app)
            try await Task.sleep(for: .seconds(0.5))
            capture(app, "goals-09-editor-error")
            app.buttons["goalEditor.cancel"].tap()
            try await Task.sleep(for: .seconds(0.5))
        }

        openNutrition(in: app, week: true)
        let fiber = app.buttons["nutrition.nutrient.fiber"]
        reveal(fiber, in: app)
        tap(fiber, in: app)
        try await Task.sleep(for: .seconds(1))
        capture(app, "goals-10-fiber-detail")
        app.swipeUp(velocity: .slow)
        try await Task.sleep(for: .seconds(0.5))
        capture(app, "goals-11-fiber-detail-scrolled")
    }

    // MARK: Navigation

    private func openNutrition(in app: XCUIApplication, week: Bool = false) {
        tap(app.buttons["Progress"], in: app)
        if app.buttons["progress.section"].waitForExistence(timeout: 3) {
            tap(app.buttons["progress.section"], in: app)
        }
        tap(app.buttons["Nutrition"].firstMatch, in: app)
        let range = app.buttons["nutrition.range.1W"]
        if week, range.waitForExistence(timeout: 5) { tap(range, in: app) }
    }

    private func waitForValue(_ element: XCUIElement, prefix: String, timeout: TimeInterval = 10) -> Bool {
        waitFor(element, timeout: timeout) { ($0.value as? String ?? "").hasPrefix(prefix) }
    }

    private func waitFor(_ element: XCUIElement, timeout: TimeInterval = 10, _ condition: (XCUIElement) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, condition(element) { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    /// The account's plan version in force now, from the change feed, once it matches.
    private func waitForPlan(token: String, _ matches: @escaping ([String: Any]) -> Bool) async throws -> [String: Any] {
        for _ in 0..<40 {
            var plans: [String: [String: Any]?] = [:]
            var cursor = 0
            while true {
                let page = try await request("GET", "/v1/changes?after=\(cursor)&limit=1000", token: token)
                for change in page["changes"] as? [[String: Any]] ?? [] where change["kind"] as? String == "nutrition_plan" {
                    if let id = change["id"] as? String { plans[id] = change["payload"] as? [String: Any] }
                }
                cursor = page["cursor"] as? Int ?? cursor
                guard page["has_more"] as? Bool == true else { break }
            }
            let latest = plans.compactMapValues { $0 }.values.max {
                ($0["startDate"] as? String ?? "", $0["createdAt"] as? String ?? "") < ($1["startDate"] as? String ?? "", $1["createdAt"] as? String ?? "")
            }
            if let latest, matches(latest) { return latest }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("The server's plan never matched")
        return [:]
    }

    // MARK: Seeding

    /// An account with a coached plan from three weeks ago, a week of
    /// logging and today's breakfast and lunch. Fiber is reported by some of
    /// today's foods, sodium by others, vitamin C by one.
    private func signedInWithNutrients(prefix: String, pinned: [String] = [], goals: [String: [String: Double]] = [:])
        async throws -> (XCUIApplication, (email: String, token: String)) {
        try await control([:])
        let person = try await createAccount(prefix: prefix, units: "metric")
        try await seedPlan(token: person.token, pinned: pinned, goals: goals)
        let yogurt = SeedFood(name: "Greek yogurt, plain", per100g: [
            "energy": 73, "protein": 10, "carbohydrate": 3.9, "fat": 1.9, "sodium": 36, "calcium": 110])
        let berries = SeedFood(name: "Blueberries", per100g: [
            "energy": 57, "protein": 0.7, "carbohydrate": 14.5, "fat": 0.3, "fiber": 2.4, "vitaminC": 9.7])
        let oats = SeedFood(name: "Rolled oats", per100g: [
            "energy": 380, "protein": 13, "carbohydrate": 67, "fat": 7, "fiber": 10, "iron": 4.3, "sodium": 6])
        let chicken = SeedFood(name: "Chicken breast, grilled", per100g: [
            "energy": 165, "protein": 31, "carbohydrate": 0, "fat": 3.6, "sodium": 74])
        let bar = SeedFood(name: "Protein bar", per100g: ["energy": 350, "protein": 33, "carbohydrate": 38, "fat": 10])
        for food in [yogurt, berries, oats, chicken, bar] {
            let payload: [String: Any] = ["id": food.id, "name": food.name, "source": "custom", "per100g": food.per100g,
                                          "servings": [], "favorite": false, "createdAt": "2026-10-01T12:00:00.000Z"]
            _ = try await request("PUT", "/v1/documents/saved_food/\(food.id)", body: ["base_revision": 0, "payload": payload],
                                  token: person.token)
        }
        for day in 0...7 {
            try await seedEntry(yogurt, grams: 200, daysAgo: day, meal: "Breakfast", minutes: 60, token: person.token)
            try await seedEntry(berries, grams: 120, daysAgo: day, meal: "Breakfast", minutes: 60, token: person.token)
            try await seedEntry(oats, grams: day % 2 == 0 ? 60 : 40, daysAgo: day, meal: "Breakfast", minutes: 60, token: person.token)
            try await seedEntry(chicken, grams: 180, daysAgo: day, meal: "Lunch", minutes: 30, token: person.token)
            if day > 0 { try await seedEntry(bar, grams: 60, daysAgo: day, meal: "Snacks", minutes: 10, token: person.token) }
        }
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        return (app, person)
    }

    /// A coached plan in force from three weeks ago, with optional pins and goals.
    private func seedPlan(token: String, pinned: [String], goals: [String: [String: Double]]) async throws {
        let id = UUID().uuidString
        func day(_ energy: Double) -> [String: Any] {
            ["energy": energy, "protein": 150, "fat": 65, "carbohydrate": ((energy - 150 * 4 - 65 * 9) / 4).rounded(.down)]
        }
        var payload: [String: Any] = [
            "id": id, "startDate": Self.day(-21).date, "createdAt": Self.iso(Self.day(-21).at),
            "goal": ["direction": "lose", "weeklyRate": 0.005], "mode": "coached", "diet": "balanced", "protein": "moderate",
            "weekdayWeights": [1, 1, 1, 1, 1, 1, 1], "checkInDay": 2, "allowBelowFloor": false,
            "basis": ["expenditure": 2500, "expenditureError": 200, "trendWeight": 80],
            "targets": Array(repeating: day(2060), count: 7),
        ]
        if !pinned.isEmpty { payload["pinnedNutrients"] = pinned }
        if !goals.isEmpty { payload["nutrientGoals"] = goals }
        _ = try await request("PUT", "/v1/documents/nutrition_plan/\(id)", body: ["base_revision": 0, "payload": payload], token: token)
    }
}
