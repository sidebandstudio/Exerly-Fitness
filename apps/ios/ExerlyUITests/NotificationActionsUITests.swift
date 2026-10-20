import XCTest

/// Reminder buttons run from SpringBoard, and foods found in Spotlight. The
/// app schedules reminders from saved preferences as it does for anyone; only
/// their trigger is shortened (EXERLY_TEST_REMINDER_DELAY) so they arrive
/// during the test.
final class NotificationActionsUITests: ExerlyUITestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    /// A breakfast habit around now (see seedWeek), the reminders given, and
    /// the app signed in with reminders arriving 30 seconds after scheduling.
    private func signedIn(reminders: [String: Any], times: [String: Any], prefix: String,
                          environment: [String: String] = [:]) async throws -> (app: XCUIApplication, token: String) {
        try await control([:])
        let person = try await createAccount(prefix: prefix, units: "imperial")
        try await seedWeek(token: person.token)
        try await deleteSetupWeight(token: person.token)
        if !reminders.isEmpty { try await setReminders(reminders, times: times, token: person.token) }
        let app = launch(resetSession: true, environment: environment.merging(["EXERLY_TEST_REMINDER_DELAY": "30"]) { $1 })
        signIn(app, email: person.email)
        return (app, person.token)
    }

    private func setReminders(_ reminders: [String: Any], times: [String: Any], token: String) async throws {
        let current = try await request("GET", "/api/preferences", token: token)
        _ = try await request("PATCH", "/api/preferences", body: [
            "base_revision": current["revision"]!, "changes": ["reminders": reminders, "reminderTimes": times],
        ], token: token)
    }

    /// Now on the clock in New York, the seeded account's zone: "08:05".
    private var now: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.newYork
        let parts = calendar.dateComponents([.hour, .minute], from: Date())
        return String(format: "%02d:%02d", parts.hour!, parts.minute!)
    }

    /// Opens Profile's Reminders.
    private func openReminders(_ app: XCUIApplication) {
        guard !app.navigationBars["Reminders"].exists else { return }
        tap(app.buttons["Profile"], in: app)
        tap(app.buttons["profile.reminders"], in: app)
        XCTAssertTrue(app.navigationBars["Reminders"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["reminders.weighIn"].waitForExistence(timeout: 15), app.debugDescription)
    }

    /// Turns on delivery on this iPhone in Reminders, checks the one reminder
    /// it lists, then goes Home.
    private func deliverReminders(_ app: XCUIApplication, capturing name: String? = nil) {
        openReminders(app)
        let device = app.switches["reminders.device"]
        reveal(device, in: app)
        if device.value as? String != "1" {
            tap(device, in: app)
            if springboard.alerts.firstMatch.waitForExistence(timeout: 5) { springboard.alerts.buttons["Allow"].tap() }
        }
        let scheduled = app.descendants(matching: .any)["reminders.scheduled.0"]
        reveal(scheduled, in: app)
        XCTAssertTrue(scheduled.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["reminders.scheduled.1"].exists, "One reminder: \(app.debugDescription)")
        if let name { capture(app, name) }
        XCUIDevice.shared.press(.home)
    }

    /// A notification showing `text`, as a banner or, once that has gone, in Notification Center.
    private func notification(_ text: String, timeout: TimeInterval = 45) -> XCUIElement {
        let match = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        if match.waitForExistence(timeout: timeout), match.isHittable { return match }
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.003))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.7)))
        XCTAssertTrue(match.waitForExistence(timeout: 10), "No notification with \(text): \(springboard.debugDescription)")
        return match
    }

    /// Today's usual foods appear once the seeded history has synced.
    private func waitForHistory(_ app: XCUIApplication) {
        let chip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "today.suggestion.log.")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 30), app.debugDescription)
    }

    private func todayEntries(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "nutrition.entry."))
    }

    private func closeReminders(_ app: XCUIApplication) {
        tap(app.tabBars.buttons["Today"], in: app)
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 10))
    }

    /// Run 6 closed the weigh-in time with a tap on "dismiss popup" that
    /// landed on the Meals row, and the compact picker passed that tap on,
    /// turning meal reminders on. The time opens in a popover now, and a tap
    /// outside it only closes it.
    func testClosingATimeLeavesTheRowUnderTheTapAlone() async throws {
        let (app, _) = try await signedIn(reminders: ["weighIn": true], times: ["weighIn": "07:00"], prefix: "notify-close")
        openReminders(app)
        let switches = ["weighIn", "meals", "workouts", "sleep"].map { app.switches["reminders.\($0)"] }
        let before = switches.map { $0.value as? String }
        XCTAssertEqual(before, ["1", "0", "0", "0"])
        tap(app.buttons["reminders.weighIn.time"], in: app)
        let wheels = app.pickerWheels.firstMatch
        XCTAssertTrue(wheels.waitForExistence(timeout: 5), app.debugDescription)
        capture(app, "reminders-time-open")
        // As the tester's driver closed it; else on the Weigh-in row, above the popover.
        let outside = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "dismiss popup")).firstMatch
        if outside.exists && outside.isHittable {
            outside.tap()
        } else {
            let row = switches[0].frame
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: row.minX + 30, dy: row.midY)).tap()
        }
        XCTAssertTrue(wheels.waitForNonExistence(timeout: 5), "The tap closed the time\n\(app.debugDescription)")
        XCTAssertEqual(switches.map { $0.value as? String }, before, "and changed nothing else")
        XCTAssertEqual((app.buttons["reminders.weighIn.time"].value as? String)?.hasPrefix("7:00"), true, "The time is as it was")
    }

    /// A 7:30 AM weigh-in reminder from Profile: open Reminders, turn it on by
    /// its title (asking iOS the first time), turn the minutes to 30, close the
    /// picker. It's saved and scheduled with no other step, then listed in words.
    func testAWeighInReminderAtSevenThirtyFromProfile() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "notify-reminders", units: "imperial")
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        tap(app.buttons["Profile"], in: app)
        capture(app, "reminders-profile")
        var actions = 0
        tap(app.buttons["profile.reminders"], in: app); actions += 1
        let weighIn = app.switches["reminders.weighIn"]
        XCTAssertTrue(weighIn.waitForExistence(timeout: 15))
        XCTAssertEqual(weighIn.value as? String, "0")
        capture(app, "reminders-off")
        // The title turns it on, as the switch does.
        app.staticTexts["Weigh-in"].tap(); actions += 1
        if springboard.alerts.firstMatch.waitForExistence(timeout: 5) { springboard.alerts.buttons["Allow"].tap(); actions += 1 }
        XCTAssertEqual(weighIn.value as? String, "1")
        let time = app.buttons["reminders.weighIn.time"]
        XCTAssertTrue(time.waitForExistence(timeout: 5), app.debugDescription)
        time.tap(); actions += 1
        let minutes = app.pickerWheels.element(boundBy: 1)
        XCTAssertTrue(minutes.waitForExistence(timeout: 5), app.debugDescription)
        minutes.adjust(toPickerWheelValue: "30"); actions += 1
        capture(app, "reminders-picker")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap(); actions += 1
        XCTAssertLessThanOrEqual(actions, 6, "Five, plus Allow the first time")

        let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Weigh-in · every day at 7:30")).firstMatch
        reveal(line, in: app)
        XCTAssertTrue(line.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(app.switches["reminders.device"].value as? String, "1", "Turning one on delivers it here")
        capture(app, "reminders-weigh-in-scheduled")
        var saved: [String: Any] = [:]
        for _ in 0..<20 {
            let current = try await request("GET", "/api/preferences", token: person.token)
            saved = try XCTUnwrap(current["values"] as? [String: Any])
            if (saved["reminderTimes"] as? [String: Any])?["weighIn"] as? String == "07:30" { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertEqual((saved["reminders"] as? [String: Any])?["weighIn"] as? Bool, true)
        XCTAssertEqual((saved["reminderTimes"] as? [String: Any])?["weighIn"] as? String, "07:30", "Saved as before, for other clients")

        // Profile says what's on; its details row opens a sheet of the same name.
        tap(app.navigationBars.buttons["Profile"], in: app)
        let row = app.buttons["profile.reminders"]
        XCTAssertTrue((row.value as? String ?? "").hasPrefix("Weigh-in · every day at 7:30"), row.debugDescription)
        tap(app.buttons["profile.details"], in: app)
        XCTAssertTrue(app.navigationBars["Your details"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["profile.details"].label, "Your details")
        // Its workout days turn on from their names too.
        tap(app.buttons["Training preferences"], in: app)
        let monday = app.switches["preferences.day.monday"]
        reveal(monday, in: app)
        let before = monday.value as? String
        app.staticTexts["Monday"].tap()
        XCTAssertNotEqual(monday.value as? String, before)
        capture(app, "reminders-details-sheet")
    }

    func testLogUsualBreakfastFromTheMealReminder() async throws {
        let (app, _) = try await signedIn(reminders: ["meals": true], times: ["meals": [now]], prefix: "notify-meal")
        waitForHistory(app)
        XCTAssertFalse(todayEntries(app).firstMatch.exists, "Nothing logged today yet")
        capture(app, "notify-before-today")
        // Reminders shows the account's meal reminder, with a weigh-in beside it.
        openReminders(app)
        XCTAssertEqual(app.switches["reminders.meals"].value as? String, "1", app.debugDescription)
        XCTAssertEqual(app.switches["reminders.weighIn"].value as? String, "0")
        capture(app, "notify-reminders")
        deliverReminders(app, capturing: "notify-preferences-delivery")

        // Two taps from the banner: hold it, then Log usual breakfast.
        let reminder = notification("Press and hold to log your usual")
        capture(springboard, "notify-meal-banner")
        reminder.press(forDuration: 1.2)
        let logUsual = springboard.buttons["Log usual breakfast"]
        XCTAssertTrue(logUsual.waitForExistence(timeout: 8), springboard.debugDescription)
        XCTAssertTrue(springboard.buttons["Repeat yesterday's breakfast"].exists)
        XCTAssertTrue(springboard.buttons["Search"].exists)
        capture(springboard, "notify-meal-actions")
        logUsual.tap()

        let confirmation = notification("to Breakfast.", timeout: 30)
        capture(springboard, "notify-meal-logged")
        let food = try XCTUnwrap(["Greek yogurt, plain", "Blueberries"].first { confirmation.label.contains("Logged \($0), ") },
                                 "Logged a usual breakfast food: \(confirmation.label)")

        app.activate()
        closeReminders(app)
        let entry = todayEntries(app).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(entry.label.hasPrefix(food), entry.label)
        XCTAssertEqual(todayEntries(app).count, 1)
        capture(app, "notify-after-today")
    }

    func testLogWeightTypedIntoTheWeighInReminder() async throws {
        // The weigh-in reminder is added to the saved preferences in the app (a debug-only hook), so this
        // runs against a fixture whose API predates it; api.preferences.test.js covers the API storing it.
        let values = #"{"reminders":{"weighIn":true},"reminderTimes":{"weighIn":"07:00"}}"#
        let (app, token) = try await signedIn(reminders: [:], times: [:], prefix: "notify-weight",
                                              environment: ["EXERLY_TEST_REMINDER_VALUES": values])
        capture(app, "notify-weight-before-today")
        deliverReminders(app, capturing: "notify-weight-preferences")

        // Two taps: hold the reminder, which opens its only button's field
        // straight away, type, then Log.
        let reminder = notification("Press and hold to type today's weight in lb.")
        capture(springboard, "notify-weight-banner")
        reminder.press(forDuration: 1.2)
        let logWeight = springboard.buttons["Log weight"]
        if logWeight.waitForExistence(timeout: 2) { logWeight.tap() }
        let field = springboard.descendants(matching: .any).matching(NSPredicate(format: "placeholderValue == %@", "Weight")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), springboard.debugDescription)
        field.typeText("181.4")
        capture(springboard, "notify-weight-typed")
        springboard.buttons["Log"].tap()

        let confirmation = notification("Logged 181.4 lb.", timeout: 30)
        XCTAssertTrue(confirmation.exists)
        capture(springboard, "notify-weight-logged")

        app.activate()
        closeReminders(app)
        // A new weigh-in starts from the last reading: the one typed in the notification.
        tap(app.buttons["today.weighIn"], in: app)
        let value = app.buttons["weighIn.value"]
        XCTAssertTrue(value.waitForExistence(timeout: 10))
        XCTAssertTrue(value.label.contains("181.4 pounds is a placeholder"), value.label)
        capture(app, "notify-weight-after")
        tap(app.buttons["weighIn.cancel"], in: app)
        let synced = try await waitForWeighIn(token: token) { ($0["weight"] as? [String: Any])?["value"] as? Double == 181.4 }
        XCTAssertEqual((synced?["weight"] as? [String: Any])?["unit"] as? String, "lb")
    }

    /// A food logged before is offered as the Log a food shortcut, so choosing
    /// it logs the remembered portion; a saved food never logged opens its
    /// portion sheet.
    func testSpotlightLogsAUsualFoodAndOpensANewOnesPortion() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "notify-spotlight", units: "imperial")
        try await seedWeek(token: person.token)
        let cottage = SeedFood(name: "Cottage cheese, low fat", per100g: ["energy": 72, "protein": 12.4, "carbohydrate": 2.7, "fat": 1])
        _ = try await request("PUT", "/v1/documents/saved_food/\(cottage.id)", body: ["base_revision": 0, "payload": [
            "id": cottage.id, "name": cottage.name, "source": "custom", "per100g": cottage.per100g,
            "servings": [["name": "cup", "grams": 226]], "favorite": false, "createdAt": "2026-10-01T12:00:00.000Z",
        ]], token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        waitForHistory(app)
        // Indexing follows the account's foods as they sync.
        Thread.sleep(forTimeInterval: 3)
        XCUIDevice.shared.press(.home)
        // Spotlight runs in its own process: pull down on the Home Screen, or tap its Search.
        let spotlight = XCUIApplication(bundleIdentifier: "com.apple.Spotlight")
        let field = spotlight.textFields["SpotlightSearchField"]
        springboard.swipeDown()
        if !field.waitForExistence(timeout: 5) { springboard.otherElements["spotlight-pill"].firstMatch.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 8), spotlight.debugDescription)

        field.typeText("greek yogurt")
        let usual = spotlight.cells.matching(NSPredicate(format: "label CONTAINS %@", "Greek yogurt, plain")).firstMatch
        XCTAssertTrue(usual.waitForExistence(timeout: 45), spotlight.debugDescription)
        capture(spotlight, "notify-spotlight-usual")
        usual.tap()
        // Spotlight says what was logged in a panel tests can't query (Today shows
        // the entry below); its Done sits near the top of the screen.
        Thread.sleep(forTimeInterval: 3)
        capture(spotlight, "notify-spotlight-usual-logged")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        // That tap can close Spotlight itself rather than its panel; open it again if so.
        let clear = spotlight.buttons["Clear text"]
        if clear.waitForExistence(timeout: 3) {
            clear.tap()
        } else {
            springboard.swipeDown()
            if !field.waitForExistence(timeout: 5) { springboard.otherElements["spotlight-pill"].firstMatch.tap() }
            XCTAssertTrue(field.waitForExistence(timeout: 8), spotlight.debugDescription)
            if clear.exists { clear.tap() }
        }
        field.typeText("cottage cheese")
        let saved = spotlight.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "Cottage cheese, low fat")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 45), spotlight.debugDescription)
        capture(spotlight, "notify-spotlight-saved")
        saved.tap()
        XCTAssertTrue(app.navigationBars["Log food"].waitForExistence(timeout: 15), app.debugDescription)
        capture(app, "notify-spotlight-portion")
        tap(app.buttons["nutrition.saveEntry"], in: app)

        let entries = todayEntries(app)
        let cottageEntry = entries.matching(NSPredicate(format: "label BEGINSWITH %@", "Cottage cheese, low fat")).firstMatch
        XCTAssertTrue(cottageEntry.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(entries.matching(NSPredicate(format: "label BEGINSWITH %@", "Greek yogurt, plain")).firstMatch.exists)
        capture(app, "notify-spotlight-after")
    }
}
