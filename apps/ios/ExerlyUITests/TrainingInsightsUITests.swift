import XCTest

/// Progress → Training: volume per muscle, strength per lift, records,
/// consistency and stall signals, from synthetic workouts.
@MainActor
final class TrainingInsightsUITests: ExerlyUITestCase {
    private var designCapture: Bool { ProcessInfo.processInfo.environment["EXERLY_DESIGN_CAPTURE"] == "1" }

    /// A few seeded workouts show up as a lift with an estimate, the muscle
    /// list and records, and the lift opens its detail in the account's unit.
    func testTrainingInsightsSummarizeSeededWorkoutsAndOpenALift() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "insights", units: "imperial")
        for (index, days) in [20, 13, 6].enumerated() {
            let load = 185 + Double(index) * 10
            try await seedSession(name: "Synthetic upper", daysAgo: days, exercises: [
                ("barbell-bench-press", [(5, load, 2), (5, load, 2), (5, load, 1)]),
                ("barbell-row", [(8, 135, 2), (8, 135, 2)]),
            ], token: person.token)
        }
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        openTraining(in: app)

        let lift = app.buttons["training.lift.barbell-bench-press"]
        XCTAssertTrue(lift.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(lift.label.contains("Bench"), lift.label)
        XCTAssertTrue(lift.label.contains("pounds"), "Estimates are in the account's unit: \(lift.label)")
        XCTAssertTrue(app.descendants(matching: .any)["training.muscle.chest"].exists)
        tap(lift, in: app)
        let estimate = app.descendants(matching: .any)["liftDetail.estimate"]
        XCTAssertTrue(estimate.waitForExistence(timeout: 10), app.debugDescription)
        // Each session's best is its 5 reps at 2 RIR (7 to failure): 185, 195 and 205 lb a week
        // apart fit a straight trend ending at 205 × 36/30, 246 lb.
        XCTAssertTrue(estimate.label.contains("246 pounds"), estimate.label)
        // The trend's estimate and the best set's e1RM say which is which.
        XCTAssertTrue(estimate.label.contains("Trend estimate · best set e1RM "), estimate.label)
        let stats = app.descendants(matching: .any)["liftDetail.stats"]
        XCTAssertTrue(stats.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Best e1RM, ")).firstMatch.exists)
    }

    /// An account with no workouts says what will appear, not empty charts.
    func testTrainingInsightsExplainAnEmptyHistory() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "insights-empty", units: "metric")
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        openTraining(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["training.empty"].waitForExistence(timeout: 30), app.debugDescription)
    }

    /// Ten weeks of a synthetic three-day split, for design captures.
    func testTrainingInsightsCapture() async throws {
        try XCTSkipUnless(designCapture, "Set EXERLY_DESIGN_CAPTURE=1 to capture")
        try await control([:])
        let person = try await createAccount(prefix: "insights-capture", units: "imperial")
        try await seedTrainingBlock(token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        openTraining(in: app)
        guard app.descendants(matching: .any)["training.consistency"].waitForExistence(timeout: 30) else {
            capture(app, "training-1-top")
            return XCTFail(app.debugDescription)
        }
        try await Task.sleep(for: .seconds(1))
        capture(app, "training-01")
        // A signal's limits, then one muscle's weeks and exercises.
        let limits = app.buttons["training.signal.limits"]
        if limits.waitForExistence(timeout: 5) {
            scrollAboveTabBar(limits, in: app)
            limits.tap()
            capture(app, "signal-limits")
            limits.tap()
        }
        let hamstrings = app.buttons["training.muscle.hamstrings"]
        let showAll = app.buttons["training.muscles.showAll"]
        if !hamstrings.exists, showAll.exists {
            scrollAboveTabBar(showAll, in: app)
            showAll.tap()
        }
        scrollAboveTabBar(hamstrings, in: app)
        hamstrings.tap()
        XCTAssertTrue(app.descendants(matching: .any)["muscle.weeks"].waitForExistence(timeout: 5))
        try await Task.sleep(for: .seconds(1))
        capture(app, "muscle-sheet")
        tap(app.buttons["Done"], in: app)
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        // Page down a screen at a time until the footnote shows.
        let footnote = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Hard sets exclude")).firstMatch
        for page in 2...14 {
            scrollPage(app)
            capture(app, String(format: "training-%02d", page))
            if footnote.exists, footnote.isHittable { break }
        }
        tap(app.buttons["training.lift.back-squat"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["liftDetail.estimate"].waitForExistence(timeout: 10))
        try await Task.sleep(for: .seconds(1))
        capture(app, "lift-01")
        let method = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Estimated 1RM comes from")).firstMatch
        for page in 2...10 {
            scrollPage(app)
            capture(app, String(format: "lift-%02d", page))
            if method.exists, method.isHittable { break }
        }
    }

    /// Short drags until the element sits fully between the bars. The shared
    /// reveal helper can oscillate around a control just under the SE's tab bar.
    private func scrollAboveTabBar(_ element: XCUIElement, in app: XCUIApplication) {
        let bottom = (app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : app.frame.height) - 16
        for _ in 0..<20 where !(element.exists && element.frame.maxY < bottom && element.frame.minY > 140) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: element.frame.minY > 140 ? -120 : 120)),
                        withVelocity: .slow, thenHoldForDuration: 0.3)
        }
    }

    /// Scrolls the content up by most of the visible area, between the bars.
    private func scrollPage(_ app: XCUIApplication) {
        let top = app.navigationBars.firstMatch.frame.maxY + 90
        let bottom = (app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : app.frame.height) - 30
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: bottom / app.frame.height))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: top / app.frame.height))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    // MARK: Helpers

    private func openTraining(in app: XCUIApplication) {
        tap(app.buttons["Progress"], in: app)
        if app.buttons["progress.section"].waitForExistence(timeout: 3) {
            tap(app.buttons["progress.section"], in: app)
        }
        tap(app.buttons["Training"], in: app)
    }

    typealias SeedSet = (reps: Int, pounds: Double, rir: Double)

    /// One finished workout, `daysAgo` days back at about 6 pm New York time.
    private func seedSession(name: String, daysAgo: Int, bodyweight: Double = 181,
                             exercises: [(id: String, sets: [SeedSet])], token: String) async throws {
        let id = UUID().uuidString
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: Date()))!
        let start = day.addingTimeInterval(17.5 * 3600)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var minute = 4.0
        let performed = exercises.map { exercise -> [String: Any] in
            let sets = exercise.sets.map { set -> [String: Any] in
                minute += 2.5
                return ["id": UUID().uuidString, "kind": "standard", "rir": set.rir,
                        "completedAt": formatter.string(from: start.addingTimeInterval(minute * 60)),
                        "efforts": [set.pounds > 0 ? ["reps": set.reps, "load": ["unit": "lb", "value": set.pounds]] : ["reps": set.reps]]]
            }
            return ["id": UUID().uuidString, "exerciseID": exercise.id, "notes": "", "sets": sets]
        }
        let payload: [String: Any] = [
            "id": id, "name": name, "notes": "", "startedAt": formatter.string(from: start),
            "endedAt": formatter.string(from: start.addingTimeInterval((minute + 6) * 60)), "timeZoneID": "America/New_York",
            "bodyweight": ["unit": "lb", "value": bodyweight], "exercises": performed,
        ]
        _ = try await request("PUT", "/v1/documents/workout_session/\(id)", body: ["base_revision": 0, "payload": payload], token: token)
    }

    /// Ten weeks of a three-day split. The main lifts climb, accessories
    /// creep up every other week, the overhead press stays put (a stall),
    /// and abs and calves get little work.
    private func seedTrainingBlock(token: String) async throws {
        for week in 0..<10 {
            let base = 70 - week * 7
            let w = Double(week), every2 = Double(week / 2)
            let squat = 205 + w * 5, bench = 165 + w * 2.5, row = 135 + w * 2.5, dead = 255 + w * 10
            try await seedSession(name: "Squat and bench", daysAgo: base, exercises: [
                ("back-squat", [(5, squat, 2), (5, squat, 2), (5, squat, 2), (5, squat, 1)]),
                ("barbell-bench-press", [(5, bench, 2), (5, bench, 2), (5, bench, 2), (5, bench, 1)]),
                ("barbell-row", [(8, row, 2), (8, row, 2), (8, row, 2), (8, row, 2)]),
                ("incline-dumbbell-bench-press", [(10, 55 + every2 * 5, 2), (10, 55 + every2 * 5, 2), (10, 55 + every2 * 5, 1)]),
                ("dumbbell-lateral-raise", [(15, 20 + every2 * 2.5, 2), (15, 20 + every2 * 2.5, 1), (15, 20 + every2 * 2.5, 1)]),
                ("triceps-pushdown", [(12, 50 + w * 2.5, 2), (12, 50 + w * 2.5, 2), (12, 50 + w * 2.5, 1)]),
            ], token: token)
            try await seedSession(name: "Pull and press", daysAgo: base - 2, exercises: [
                ("deadlift", [(5, dead, 2), (5, dead - 30, 3), (5, dead - 30, 3)]),
                ("overhead-press", [(5, 115, 1), (5, 115, 1), (week % 2 == 0 ? 5 : 4, 115, 1), (4, 115, 0)]),
                ("pull-up", [(8 + week / 3, 0, 2), (8 + week / 3, 0, 2), (7 + week / 3, 0, 1), (7 + week / 3, 0, 1)]),
                ("romanian-deadlift", [(8, 185 + every2 * 10, 2), (8, 185 + every2 * 10, 2), (8, 185 + every2 * 10, 2)]),
                ("dumbbell-curl", [(10, 30 + every2 * 2.5, 2), (10, 30 + every2 * 2.5, 1), (10, 30 + every2 * 2.5, 1)]),
                ("face-pull", [(15, 40 + every2 * 5, 2), (15, 40 + every2 * 5, 2)]),
            ], token: token)
            guard base - 4 > 0 else { continue }
            try await seedSession(name: "Volume day", daysAgo: base - 4, exercises: [
                ("back-squat", [(8, squat - 40, 3), (8, squat - 40, 3), (8, squat - 40, 2)]),
                ("barbell-bench-press", [(8, bench - 25, 3), (8, bench - 25, 2), (8, bench - 25, 2)]),
                ("lat-pulldown", [(10, 140 + w * 5, 2), (10, 140 + w * 5, 2), (10, 140 + w * 5, 1)]),
                ("lying-leg-curl", [(10, 90 + every2 * 5, 2), (10, 90 + every2 * 5, 2), (10, 90 + every2 * 5, 1)]),
                ("dumbbell-lateral-raise", [(15, 20 + every2 * 2.5, 2), (15, 20 + every2 * 2.5, 1)]),
                ("standing-calf-raise", [(12, 180 + every2 * 10, 2), (12, 180 + every2 * 10, 2)]),
                ("cable-crunch", [(12, 70 + every2 * 5, 2), (12, 70 + every2 * 5, 2)]),
            ], token: token)
        }
    }
}
