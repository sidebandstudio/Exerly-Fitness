import XCTest

/// Weigh-ins, trend weight and expenditure.
@MainActor
final class BodyUITests: ExerlyUITestCase {
    private var designCapture: Bool { ProcessInfo.processInfo.environment["EXERLY_DESIGN_CAPTURE"] == "1" }

    /// From the button that opens the sheet: open, drag once, Save.
    func testWeighInTakesThreeTapsFromItsButton() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "body-taps", units: "imperial")
        try await deleteSetupWeight(token: person.token)
        let yesterday = Self.day(-1)
        try await seedWeighIn(token: person.token, date: yesterday.date, at: yesterday.at, value: 184.6, unit: "lb")
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        settle(app)
        tap(app.buttons["Progress"], in: app)
        let open = app.buttons["body.weighIn"]
        XCTAssertTrue(open.waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["body.weighIn.\(yesterday.date)"].waitForExistence(timeout: 20))

        tapCount = 0
        tap(open, in: app)
        let value = app.buttons["weighIn.value"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        XCTAssertEqual(value.label, "Weight, 184.6 pounds", "The sheet starts on the last reading")
        XCTAssertTrue(app.buttons["exerly.keypadDone"].exists, "Ready to type the scale's number")
        // Typed over the last reading. Typing isn't counted, for Exerly or
        // MacroFactor, in docs/TAP_BUDGETS.md.
        for key in ["1", "8", "5", Locale.current.decimalSeparator ?? ".", "2"] { app.buttons["exerly.keypad.\(key)"].tap() }
        let entered = 185.2
        tap(app.buttons["weighIn.save"], in: app)
        XCTAssertLessThanOrEqual(tapCount, 2, "A weigh-in takes two taps from its button")
        XCTAssertTrue(app.buttons["Progress"].waitForExistence(timeout: 5))
        let today = Self.day(0).date
        XCTAssertTrue(app.descendants(matching: .any)["body.weighIn.\(today)"].waitForExistence(timeout: 10))
        let saved = try await waitForWeighIn(token: person.token) { $0["date"] as? String == today }
        let weight = try XCTUnwrap(saved?["weight"] as? [String: Any])
        XCTAssertEqual(weight["unit"] as? String, "lb")
        XCTAssertEqual(try XCTUnwrap(weight["value"] as? Double), entered, accuracy: 0.001)
        capture(app, "body-taps-saved")
    }

    /// A weigh-in saved offline survives a relaunch and syncs; edits keep its
    /// identity, and a deletion can be undone. Setup's weight arrives as one.
    func testWeighInOfflineRelaunchSyncEditDeleteAndUndo() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "body-offline", units: "metric")
        let today = Self.day(0).date
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        settle(app)
        tap(app.buttons["Progress"], in: app)
        // Setup's 72.25 kg becomes an ExerlyCore weigh-in.
        XCTAssertTrue(todayWeighIn("72.25 kilograms", in: app).waitForExistence(timeout: 30), app.debugDescription)
        let setup = try await waitForWeighIn(token: person.token) { ($0["weight"] as? [String: Any])?["value"] as? Double == 72.25 }
        XCTAssertEqual(setup?["date"] as? String, today)

        try await control(["offline": true])
        tap(app.buttons["body.weighIn"], in: app)
        XCTAssertEqual(app.buttons["weighIn.value"].label, "Weight, 72.3 kilograms")
        // Done puts the keypad away for the ruler and its steps.
        tap(app.buttons["exerly.keypadDone"], in: app)
        tap(app.buttons["weighIn.increase"], in: app)
        tap(app.buttons["weighIn.increase"], in: app)
        XCTAssertEqual(app.buttons["weighIn.value"].label, "Weight, 72.5 kilograms")
        tap(app.buttons["weighIn.save"], in: app)
        let offlineRow = todayWeighIn("72.5 kilograms", in: app)
        XCTAssertTrue(offlineRow.waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 20))
        tap(app.buttons["Progress"], in: app)
        XCTAssertTrue(offlineRow.waitForExistence(timeout: 15), "The offline weigh-in is still on the device")
        capture(app, "body-offline-relaunched")

        try await control([:])
        app.terminate()
        app.launch()
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 20))
        let found = try await waitForWeighIn(token: person.token) { ($0["weight"] as? [String: Any])?["value"] as? Double == 72.5 }
        let synced = try XCTUnwrap(found)
        let id = try XCTUnwrap(synced["id"] as? String)

        tap(app.buttons["Progress"], in: app)
        tap(offlineRow, in: app)
        XCTAssertTrue(app.staticTexts["Edit weigh-in"].waitForExistence(timeout: 5))
        tap(app.buttons["weighIn.value"], in: app)
        for key in ["7", "1", Locale.current.decimalSeparator ?? ".", "8"] { tap(app.buttons["exerly.keypad.\(key)"], in: app) }
        tap(app.buttons["weighIn.save"], in: app)
        let edited = try await waitForWeighIn(token: person.token) { ($0["weight"] as? [String: Any])?["value"] as? Double == 71.8 }
        XCTAssertEqual(edited?["id"] as? String, id, "An edit keeps the weigh-in's identity")

        tap(todayWeighIn("71.8 kilograms", in: app), in: app)
        tap(app.buttons["weighIn.delete"], in: app)
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 5))
        var gone = false
        for _ in 0..<40 where !gone {
            gone = try await weighIns(token: person.token)[id] == nil
            if !gone { try await Task.sleep(for: .milliseconds(250)) }
        }
        XCTAssertTrue(gone, "The deletion reaches the server")
        capture(app, "body-deleted-undo")
        tap(app.buttons["Undo"], in: app)
        XCTAssertTrue(todayWeighIn("71.8 kilograms", in: app).waitForExistence(timeout: 10))
        let restored = try await waitForWeighIn(token: person.token) { ($0["weight"] as? [String: Any])?["value"] as? Double == 71.8 }
        XCTAssertNotNil(restored)
    }

    /// Today, Profile and Progress show one trend weight and one change
    /// called "this week", and Progress's rate over its span says it's an average.
    func testTodayProfileAndProgressShowOneTrendWeightAndOneWeek() async throws {
        let trendWords = "Trend weight [0-9.,]+ pounds", weekWords = "(down|up) [0-9.]+ pounds this week|steady this week"
        let app = try await signedInWithRealisticHistory(prefix: "body-agree")
        let card = app.descendants(matching: .any)["weightCard.trend"]
        reveal(card, in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 30), app.debugDescription)
        reveal(card, in: app)
        // Read Today once its words hold still, so a sync landing late can't split the screens.
        var today = card.label
        for _ in 0..<15 {
            try await Task.sleep(for: .seconds(1))
            let next = card.label
            if next == today, today.contains("this week") { break }
            today = next
        }
        let trend = try XCTUnwrap(phrase(trendWords, in: today), today)
        let week = try XCTUnwrap(phrase(weekWords, in: today), today)
        // The week as the screens write it: "−0.5 lb this week".
        let shown = week.hasPrefix("steady") ? "Steady this week"
            : "\(week.hasPrefix("down") ? "−" : "+")\(phrase("[0-9.]+", in: week) ?? "") lb this week"
        func expectShown(on screen: String) {
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", shown)).firstMatch.exists,
                          "\(screen) writes \(shown)")
            // The goal's planned rate ("Lose 0.9 lb a week to 170 lb") is a rate, worded as Targets words it.
            let goalRate = "identifier == 'body.goal.headline' OR label BEGINSWITH 'Lose ' OR label BEGINSWITH 'Gain '"
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND NOT (\(goalRate))", "lb a week"))
                .firstMatch.exists, "\(screen) calls the seven-day change \"this week\", never \"a week\"")
        }
        expectShown(on: "Today")

        tap(app.buttons["Profile"], in: app)
        let stat = app.descendants(matching: .any)["profile.trendWeight"]
        reveal(stat, in: app)
        XCTAssertTrue(stat.waitForExistence(timeout: 10), app.debugDescription)
        let profile = "\(stat.label) \(stat.value as? String ?? "")"
        expectShown(on: "Profile")

        tap(app.buttons["Progress"], in: app)
        let readout = app.descendants(matching: .any)["body.trend"]
        reveal(readout, in: app)
        XCTAssertTrue(readout.waitForExistence(timeout: 20), app.debugDescription)
        expectShown(on: "Progress")

        for (screen, words) in [("Profile", profile), ("Progress", readout.label)] {
            XCTAssertEqual(phrase(trendWords, in: words), trend, "\(screen) says Today's trend: \(words)")
            XCTAssertEqual(phrase(weekWords, in: words), week, "\(screen) says Today's week: \(words)")
        }
        // The rate over the chart's span is an average, never "this week".
        let average = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Average: ")).firstMatch
        reveal(average, in: app)
        XCTAssertTrue(average.exists, app.debugDescription)
        XCTAssertTrue(average.label.hasSuffix(" a week") && !average.label.contains("this week"), average.label)
        capture(app, "body-agree-average")
    }

    func testBodyCapture() async throws {
        guard designCapture else { throw XCTSkip("Opt-in visual review") }
        try await control([:])
        let person = try await createAccount(prefix: "body-design", units: "imperial")
        try await deleteSetupWeight(token: person.token)
        try await seedHistory(token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        settle(app)
        tap(app.buttons["Progress"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["body.chart"].waitForExistence(timeout: 30))
        if app.buttons["body.range.3M"].exists { tap(app.buttons["body.range.3M"], in: app) }
        try await Task.sleep(for: .seconds(1))
        capture(app, "body-01-progress")
        app.swipeUp(velocity: .slow)
        capture(app, "body-02-expenditure")
        app.swipeUp(velocity: .slow)
        capture(app, "body-03-history")
        for _ in 0..<4 { app.swipeDown() }
        tap(app.buttons["body.weighIn"], in: app)
        XCTAssertTrue(app.buttons["weighIn.value"].waitForExistence(timeout: 5))
        try await Task.sleep(for: .seconds(0.6))
        capture(app, "body-04-weigh-in")
        app.buttons["exerly.keypad.1"].tap()
        app.buttons["exerly.keypad.8"].tap()
        try await Task.sleep(for: .seconds(0.6))
        capture(app, "body-05-typing")
        app.buttons["exerly.keypadDone"].tap()
        app.buttons["weighIn.cancel"].tap()
        tap(app.buttons["body.weighIn"], in: app)
        tap(app.buttons["exerly.keypadDone"], in: app)
        let ruler = app.descendants(matching: .any)["weighIn.ruler"]
        let start = ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 31, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.1)
        app.buttons["weighIn.save"].tap()
        try await Task.sleep(for: .seconds(1))
        capture(app, "body-06-after-save")
        if app.buttons["body.range.1M"].exists {
            tap(app.buttons["body.range.1M"], in: app)
            capture(app, "body-07-one-month")
        } else {
            app.swipeUp(velocity: .slow)
            capture(app, "body-07-chart-largest-type")
        }
        tap(app.buttons["Today"], in: app)
        let card = app.descendants(matching: .any)["weightCard.weighIn"]
        reveal(card, in: app)
        capture(app, "body-08-card")
    }

    // MARK: Fixture data


    /// The first match of `pattern` in `text`, lowercased, so "Down" and "down" compare equal.
    private func phrase(_ pattern: String, in text: String) -> String? {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]).map { text[$0].lowercased() }
    }

    /// The system offers to save the synthetic password a moment after sign-in.
    func settle(_ app: XCUIApplication) {
        for _ in 0..<12 {
            if dismissPasswordPrompt(in: app) { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// Today's weigh-in row for `weight`, read as "Weigh-in, Today at 7:11 AM, 72.5 kilograms".
    private func todayWeighIn(_ weight: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Weigh-in, Today at ", ", \(weight)")).firstMatch
    }
}
