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

    /// The bedtime reminder's button puts it off without opening Exerly, and
    /// it comes back. (Tests bring it back after the reminder delay instead of
    /// 15 minutes.) Not checked here: the Lock Screen, whose notification
    /// buttons XCTest can't open in the simulator (the button needs no unlock;
    /// see ReminderActionsTests), and a terminated Exerly, which the system
    /// relaunches without the test's isolated account.
    func testTheBedtimeReminderComesBackWithoutOpeningExerly() async throws {
        let (app, _) = try await signedIn(reminders: ["sleep": true], times: ["sleep": now], prefix: "notify-sleep")
        waitForHistory(app)
        deliverReminders(app)
        let reminder = notification("Time to start your bedtime routine.", timeout: 60)
        capture(springboard, "notify-sleep-banner")
        reminder.press(forDuration: 1.2)
        let later = springboard.buttons["Remind me in 15 minutes"]
        XCTAssertTrue(later.waitForExistence(timeout: 8), springboard.debugDescription)
        capture(springboard, "notify-sleep-actions")
        later.tap()
        XCTAssertTrue(later.waitForNonExistence(timeout: 10))
        XCTAssertNotEqual(app.state, .runningForeground, "Nothing opened")
        let again = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Time to start your bedtime routine."))
        let back = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"), object: again)
        XCTAssertEqual(XCTWaiter().wait(for: [back], timeout: 60), .completed, "It comes back")
        capture(springboard, "notify-sleep-again")
    }

    /// A food logged before is offered in Spotlight. As Log a food's top hit
    /// it logs the remembered portion in place, with Undo in the answer; as
    /// its own result it opens Today on its confirmation, with Undo. Spotlight
    /// chooses which it shows. A saved food never logged opens its portion
    /// sheet from its own result.
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
        let spotlight = XCUIApplication(bundleIdentifier: "com.apple.Spotlight")
        search(spotlight, for: "greek yogurt")
        let yogurtEntry = todayEntries(app).matching(NSPredicate(format: "label BEGINSWITH %@", "Greek yogurt, plain")).firstMatch
        let yogurt = result(spotlight, "Greek yogurt, plain")
        capture(spotlight, "notify-spotlight-usual")
        yogurt.cell.tap()
        if yogurt.isShortcut {
            // Log a food runs in place: Exerly stays closed, and the answer's Undo
            // takes the entry back. SpringBoard hosts the answer.
            let undo = springboard.buttons["Undo"].firstMatch
            XCTAssertTrue(undo.waitForExistence(timeout: 15), springboard.debugDescription)
            XCTAssertNotEqual(app.state, .runningForeground, "Nothing opened")
            capture(springboard, "notify-spotlight-snippet")
            // The answer is the system's remote view: XCTest finds its Undo but may report it
            // not hittable, at the snippet's own coordinates. Undo itself is unit-tested.
            let undone = springboard.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Taken back")).firstMatch
            let tookBack = undo.isHittable
            if tookBack {
                undo.tap()
                XCTAssertTrue(undone.waitForExistence(timeout: 10), springboard.debugDescription)
                capture(springboard, "notify-spotlight-snippet-undone")
            }
            springboard.buttons["Done"].firstMatch.tap()
            app.activate()
            XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 15))
            XCTAssertEqual(yogurtEntry.waitForExistence(timeout: 5), !tookBack, "Logged once, in place, unless taken back")
            // Today's confirmation of the same food, the one its own Spotlight result opens on, at every text size.
            let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Log Greek yogurt, plain")).firstMatch
            if chip.waitForExistence(timeout: 10) {
                tap(chip, in: app)
                let confirmation = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Logged Greek yogurt, plain")).firstMatch
                XCTAssertTrue(confirmation.waitForExistence(timeout: 5), app.debugDescription)
                capture(app, "today-logged-confirmation")
                app.buttons["today.undo"].tap()
                XCTAssertTrue(yogurtEntry.waitForNonExistence(timeout: 10))
            }
        } else {
            // The food's own result logs its usual portion and opens Today in front on its confirmation, whose Undo takes it back.
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "Today opens")
            XCTAssertTrue(yogurtEntry.waitForExistence(timeout: 15), app.debugDescription)
            let confirmation = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Logged Greek yogurt, plain")).firstMatch
            XCTAssertTrue(confirmation.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(app.navigationBars["Log food"].exists, "No portion sheet for a usual food")
            capture(app, "notify-spotlight-usual-logged")
            app.buttons["today.undo"].tap()
            XCTAssertTrue(yogurtEntry.waitForNonExistence(timeout: 10), "Undo takes back the entry Spotlight logged")
        }
        search(spotlight, for: "cottage cheese")
        let saved = result(spotlight, "Cottage cheese, low fat")
        capture(spotlight, "notify-spotlight-saved")
        saved.cell.tap()
        if saved.isShortcut {
            // A saved food logs its first serving in place.
            XCTAssertTrue(springboard.buttons["Undo"].firstMatch.waitForExistence(timeout: 15), springboard.debugDescription)
            springboard.buttons["Done"].firstMatch.tap()
            app.activate()
        } else {
            XCTAssertTrue(app.navigationBars["Log food"].waitForExistence(timeout: 15), app.debugDescription)
            capture(app, "notify-spotlight-portion")
            tap(app.buttons["nutrition.saveEntry"], in: app)
        }

        let entries = todayEntries(app)
        let cottageEntry = entries.matching(NSPredicate(format: "label BEGINSWITH %@", "Cottage cheese, low fat")).firstMatch
        XCTAssertTrue(cottageEntry.waitForExistence(timeout: 10), app.debugDescription)
        capture(app, "notify-spotlight-after")
        // When Spotlight ran the Log a food shortcut itself, its answer stays up until closed.
        XCUIDevice.shared.press(.home)
        let done = springboard.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 2) { done.tap() }
    }

    /// Signing out takes the account's foods out of Spotlight, so the next
    /// person on the phone doesn't see them.
    func testSigningOutTakesTheirFoodsOutOfSpotlight() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "notify-spotlight-out", units: "imperial")
        try await seedWeek(token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        waitForHistory(app)
        Thread.sleep(forTimeInterval: 3)
        let spotlight = XCUIApplication(bundleIdentifier: "com.apple.Spotlight")
        let yogurt = spotlight.cells.matching(NSPredicate(format: "label CONTAINS %@", "Greek yogurt, plain")).firstMatch
        search(spotlight, for: "greek yogurt")
        XCTAssertTrue(yogurt.waitForExistence(timeout: 45), "Their food is in Spotlight while they're signed in")

        app.activate()
        tap(app.buttons["Profile"], in: app)
        tap(app.buttons["profile.logout"], in: app)
        XCTAssertTrue(app.buttons["profile.logout"].waitForNonExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 3)
        search(spotlight, for: "greek yogurt")
        // Spotlight showed it within seconds above; it stays gone for longer than that.
        XCTAssertFalse(yogurt.waitForExistence(timeout: 20), spotlight.debugDescription)
        capture(spotlight, "notify-spotlight-signed-out")
    }

    /// Opens Spotlight from the Home Screen and searches. Spotlight runs in
    /// its own process and opens slowly on a small phone, so typing waits for
    /// its field and is checked, and an earlier search is cleared first.
    /// A food's result in Spotlight: Log a food's top hit ("Food, …"), which
    /// runs in place, or the food's own, which opens Exerly. Spotlight chooses.
    private func result(_ spotlight: XCUIApplication, _ name: String) -> (cell: XCUIElement, isShortcut: Bool) {
        let shortcut = spotlight.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "Food, \(name)")).firstMatch
        let own = spotlight.cells.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        let deadline = Date().addingTimeInterval(45)
        while !shortcut.exists && !own.exists && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertTrue(shortcut.exists || own.exists, spotlight.debugDescription)
        return shortcut.exists ? (shortcut, true) : (own, false)
    }

    private func search(_ spotlight: XCUIApplication, for text: String) {
        let field = spotlight.textFields["SpotlightSearchField"]
        let inFront = XCTNSPredicateExpectation(predicate: NSPredicate(format: "state == %d", XCUIApplication.State.runningForeground.rawValue),
                                                object: spotlight)
        for _ in 0..<3 {
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 1.5)
            springboard.swipeDown()
            // Its elements can only be asked for once it's in front.
            if XCTWaiter().wait(for: [inFront], timeout: 15) == .completed, field.waitForExistence(timeout: 5) { break }
        }
        XCTAssertTrue(spotlight.state == .runningForeground && field.exists, "Spotlight didn't open")
        for _ in 0..<3 {
            let clear = spotlight.buttons["Clear text"]
            if clear.exists { clear.tap() }
            field.tap()
            field.typeText(text)
            let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: field)
            if XCTWaiter().wait(for: [typed], timeout: 3) == .completed { return }
        }
        XCTFail("Spotlight didn't take the search \(text): \(field.value ?? "")")
    }
}
