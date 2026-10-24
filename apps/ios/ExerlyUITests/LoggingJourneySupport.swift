import XCTest

/// Logging journeys measured from Today's top for a person with history,
/// checked against what reached the server: TapBudgetUITests and
/// TodayLoggingUITests.
extension ExerlyUITestCase {
    /// Yesterday's food in seedWeek, each once.
    static let yesterdaysFood = ["Greek yogurt, plain", "Blueberries", "Chicken breast, grilled", "Jasmine rice, cooked",
                                 "Salmon fillet", "Roasted potatoes"]

    /// A person with last week's food and weigh-ins, a two-day program with
    /// last Upper A logged, signed in on Today. Their breakfast habit is
    /// around now, so Breakfast is the meal Log again fills at any hour.
    func budgetHome(prefix: String, environment: [String: String] = [:]) async throws -> (XCUIApplication, (email: String, token: String)) {
        try await control([:])
        let person = try await createAccount(prefix: prefix, units: "imperial")
        try await seedLoggingWeek(token: person.token)
        try await deleteSetupWeight(token: person.token)
        try await seedTwoDayPlan(token: person.token)
        let app = launch(resetSession: true, environment: environment)
        signIn(app, email: person.email)
        settleAfterSignIn(app)
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 20))
        XCTAssertTrue(app.navigationBars["Today"].exists, "On the home screen")
        return (app, person)
    }

    /// seedWeek's foods, with breakfast as a habit around now on four days,
    /// but yesterday's lunch and dinner at 12:30 and 18:30 on yesterday's
    /// date, so `yesterdaysFood` is yesterday's at any hour of the day.
    func seedLoggingWeek(token: String) async throws {
        let yogurt = SeedFood(name: "Greek yogurt, plain", per100g: ["energy": 73, "protein": 10, "carbohydrate": 3.9, "fat": 1.9])
        let berries = SeedFood(name: "Blueberries", per100g: ["energy": 57, "protein": 0.7, "carbohydrate": 14.5, "fat": 0.3])
        let oats = SeedFood(name: "Rolled oats", per100g: ["energy": 380, "protein": 13, "carbohydrate": 67, "fat": 7])
        let chicken = SeedFood(name: "Chicken breast, grilled", per100g: ["energy": 165, "protein": 31, "carbohydrate": 0, "fat": 3.6])
        let rice = SeedFood(name: "Jasmine rice, cooked", per100g: ["energy": 130, "protein": 2.7, "carbohydrate": 28, "fat": 0.3])
        let salmon = SeedFood(name: "Salmon fillet", per100g: ["energy": 208, "protein": 20, "carbohydrate": 0, "fat": 13])
        let potato = SeedFood(name: "Roasted potatoes", per100g: ["energy": 149, "protein": 2.5, "carbohydrate": 24, "fat": 4.8])
        for food in [yogurt, berries, oats, chicken, rice, salmon, potato] {
            let payload: [String: Any] = ["id": food.id, "name": food.name, "source": "custom", "per100g": food.per100g,
                                          "servings": [], "favorite": false, "createdAt": "2026-10-01T12:00:00.000Z"]
            _ = try await request("PUT", "/v1/documents/saved_food/\(food.id)", body: ["base_revision": 0, "payload": payload], token: token)
        }
        // Breakfast a few minutes before now's time of day on yesterday's date
        // and three before, odd days with oats; only yesterday's is repeated.
        var clock = Calendar(identifier: .gregorian)
        clock.timeZone = Self.newYork
        let now = clock.dateComponents([.hour, .minute], from: Date())
        for day in 1...4 {
            let at = Self.local(-day, now.hour ?? 8, (now.minute ?? 0) - 5)
            for (food, grams) in [(yogurt, 170.0), (berries, 80)] + (day % 2 == 0 ? [(oats, 50.0)] : []) {
                try await seedEntry(food, grams: grams, date: Self.day(-day).date, at: at, meal: "Breakfast", token: token)
            }
        }
        for (food, grams, meal, hour) in [(chicken, 180.0, "Lunch", 12), (rice, 200, "Lunch", 12), (salmon, 150, "Dinner", 18), (potato, 220, "Dinner", 18)] {
            try await seedEntry(food, grams: grams, date: Self.day(-1).date, at: Self.local(-1, hour, 30), meal: meal, token: token)
        }
        try await seedEntry(chicken, grams: 150, date: Self.day(-3).date, at: Self.local(-3, 18, 30), meal: "Dinner", token: token)
    }

    private func seedEntry(_ food: SeedFood, grams: Double, date: String, at: Date, meal: String, token: String) async throws {
        let id = UUID().uuidString
        let entry: [String: Any] = ["id": id, "date": date, "meal": meal, "loggedAt": Self.iso(at),
                                    "food": ["foodID": food.id, "name": food.name, "source": "custom", "per100g": food.per100g],
                                    "grams": grams]
        _ = try await request("PUT", "/v1/documents/food_entry/\(id)", body: ["base_revision": 0, "payload": entry], token: token)
    }

    /// Counts the next task from zero.
    func startCounting() {
        tapCount = 0
        scrollCount = 0
    }

    /// Upper A and Lower A, with Upper A three days ago at 155 lb, so Upper A
    /// is today's and progresses to 160 lb, and a 181.4 lb weigh-in yesterday.
    func seedTwoDayPlan(token: String) async throws {
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
    func liveDocuments(_ kind: String, token: String) async throws -> [String: [String: Any]] {
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

    func waitForDocument(_ kind: String, token: String,
                                 _ matches: @escaping ([String: Any]) -> Bool) async throws -> [String: Any]? {
        for _ in 0..<60 {
            if let found = try await liveDocuments(kind, token: token).values.first(where: matches) { return found }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("No matching \(kind) reached the server")
        return nil
    }

    /// Waits until today's food on the server is exactly `names`, in any
    /// order, each once, and in `meal` when given.
    func expectEntries(token: String, _ names: [String], meal: String? = nil) async throws {
        let today = Self.day(0).date
        var found: [[String: Any]] = []
        for _ in 0..<60 {
            found = try await liveDocuments("food_entry", token: token).values.filter { $0["date"] as? String == today }
            if found.compactMap({ ($0["food"] as? [String: Any])?["name"] as? String }).sorted() == names.sorted() { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertEqual(found.compactMap { ($0["food"] as? [String: Any])?["name"] as? String }.sorted(), names.sorted(),
                       "Today's food on the server")
        if let meal { XCTAssertTrue(found.allSatisfy { $0["meal"] as? String == meal }, "In \(meal)") }
    }
}
