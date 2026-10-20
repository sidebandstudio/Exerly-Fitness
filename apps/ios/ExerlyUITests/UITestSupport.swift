import XCTest

/// Shared fixture, launch and interaction helpers for Exerly's UI tests.
/// Subclass it; every helper drives the app the way a person would.
@MainActor
class ExerlyUITestCase: XCTestCase {
    var fixtureURL = ProcessInfo.processInfo.environment["EXERLY_UI_FIXTURE_URL"] ?? "http://127.0.0.1:39001"
    /// Taps delivered through `tap(_:in:)` since the test began. Reset it before
    /// a task to count that task's taps the way a person would make them.
    var tapCount = 0
    /// Drags `reveal(_:in:)` made to bring a control into view since the test
    /// began. A tap budget that holds only after scrolling says so.
    var scrollCount = 0

    // Let async test bodies finish or throw before XCTest starts the next test.
    // Aborting at an assertion can leave their fixture requests running.
    override func setUpWithError() throws {
        continueAfterFailure = true
        addUIInterruptionMonitor(withDescription: "Password saving") { alert in
            guard alert.label.contains("Save Password"), alert.buttons["Not Now"].exists else { return false }
            alert.buttons["Not Now"].tap()
            return true
        }
    }

    func seedNutritionEntry(token: String, name: String = "Synthetic pear", nutrients: [String: Double] = ["energy": 57, "sodium": 0], grams: Double = 123.25, unweighed: Bool = false) async throws -> (id: String, date: String, foodID: String) {
        let entryID = UUID().uuidString
        let foodID = unweighed ? "quick:\(entryID)" : UUID().uuidString
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: Date())
        let food: [String: Any] = ["id": foodID, "name": name, "source": "custom", "per100g": nutrients,
                                 "servings": [], "favorite": false, "createdAt": "2026-10-06T12:00:00.000Z"]
        if !unweighed {
            _ = try await request("PUT", "/v1/documents/saved_food/\(foodID)", body: ["base_revision": 0, "payload": food], token: token)
        }
        var snapshot: [String: Any] = ["foodID": foodID, "name": name, "source": "custom", "per100g": nutrients]
        if unweighed { snapshot["unweighed"] = true }
        let entry: [String: Any] = ["id": entryID, "date": date, "meal": "Dinner", "loggedAt": "2026-10-06T18:30:00.000Z",
                                  "food": snapshot, "grams": grams]
        _ = try await request("PUT", "/v1/documents/food_entry/\(entryID)", body: ["base_revision": 0, "payload": entry], token: token)
        return (entryID, date, foodID)
    }
    func seedProgram(name: String, activated: String? = nil, token: String) async throws -> (id: String, payload: [String: Any]) {
        let id = UUID().uuidString
        var payload: [String: Any] = ["id": id, "name": name, "cycles": 2, "deload": "none", "createdAt": "2026-10-01T12:00:00.000Z",
            "days": [["id": UUID().uuidString, "name": "Pull", "slots": [["id": UUID().uuidString, "exerciseID": "deadlift", "notes": "",
                "target": ["sets": 3, "minReps": 5, "maxReps": 8, "rir": 2, "kind": "standard"],
                "cycleTargets": [String: Any](), "expandRepRange": false, "weightMatch": true]]]]]
        if let activated { payload["activatedAt"] = activated }
        _ = try await request("PUT", "/v1/documents/program/\(id)", body: ["base_revision": 0, "payload": payload], token: token)
        return (id, payload)
    }
    func seedTrainingWorkout(name: String, loads: [Double], finished: Bool = true, daysAgo: Int = 0,
                                     exercises: [String] = ["deadlift"], token: String) async throws -> String {
        let id = UUID().uuidString
        let date = Date().addingTimeInterval(Double(-daysAgo * 86400) - 3600)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var payload: [String: Any] = [
            "id": id, "name": name, "notes": "", "startedAt": formatter.string(from: date), "timeZoneID": "America/New_York",
            "exercises": exercises.map { exercise -> [String: Any] in
                ["id": UUID().uuidString, "exerciseID": exercise, "notes": "", "sets": loads.enumerated().map { index, load -> [String: Any] in
                    ["id": UUID().uuidString, "kind": "standard", "completedAt": formatter.string(from: date.addingTimeInterval(Double(60 + index * 120))),
                     "efforts": [["reps": 5, "load": ["unit": "kg", "value": load]]]]
                }]
            }
        ]
        if finished { payload["endedAt"] = formatter.string(from: date.addingTimeInterval(1800)) }
        _ = try await request("PUT", "/v1/documents/workout_session/\(id)", body: ["base_revision": 0, "payload": payload], token: token)
        return id
    }
    func createAccount(prefix: String, units: String = "metric") async throws -> (email: String, token: String) {
        let email = "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())@exerly.test"
        let signup = try await request("POST", "/signup", body: ["email": email, "password": "Simulator-Test-123!", "name": "Morgan"])
        let token = try XCTUnwrap(signup["token"] as? String)
        _ = try await request("POST", "/api/onboarding/complete", body: [
            "name": "Morgan", "age": 34, "gender": "female", "sex": "female", "height": 167.5, "weight": 72.25,
            "goal": "maintain", "activityLevel": "light", "unitSystem": units, "timezone": "America/New_York"
        ], token: token)
        return (email, token)
    }
    func signIn(_ app: XCUIApplication, email: String) {
        tap(app.buttons["I already have an account"], in: app)
        replace(app.textFields["Email"], with: email, in: app)
        replace(app.secureTextFields["Password"], with: "Simulator-Test-123!", in: app)
        dismissKeyboard(app)
        tap(app.buttons["Log In"], in: app)
        // At the largest text on an iPhone 17 Pro the form scrolls as the
        // keyboard leaves and the tap can miss. Go on the keyboard submits too.
        let password = app.secureTextFields["Password"]
        if !app.navigationBars["Today"].waitForExistence(timeout: 10), password.exists {
            if !app.keyboards.firstMatch.exists {
                reveal(password, in: app)
                password.tap()
            }
            app.typeText("\n")
        }
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 20))
        settleAfterSignIn(app)
    }

    /// iOS 26 simulators offer to save the synthetic password a few seconds
    /// after sign-in, in a sheet that swallows taps on the tab bar. Wait for
    /// it and decline it, then return once the tabs take taps.
    func settleAfterSignIn(_ app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let sheet = app.sheets["Save Password?"]
            if sheet.exists {
                let notNow = sheet.buttons["Not Now"]
                if notNow.exists { notNow.tap() } else { sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.9)).tap() }
                Thread.sleep(forTimeInterval: 0.6)
                continue
            }
            if dismissPasswordPrompt(in: app) { continue }
            if app.tabBars.buttons["Today"].isHittable, Date() > deadline.addingTimeInterval(-5) { return }
            Thread.sleep(forTimeInterval: 0.4)
        }
    }
    /// `contentSize` names a text size, such as "UICTContentSizeCategoryXXXL", for that launch only.
    func launch(resetSession: Bool, legacyToken: String? = nil, accountControls: String? = nil,
                environment: [String: String] = [:], contentSize: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = resetSession ? ["--ui-testing"] : []
        if let appearance = ProcessInfo.processInfo.environment["EXERLY_TEST_APPEARANCE"],
           ["light", "dark", "system"].contains(appearance) {
            app.launchArguments += ["-exerlyAppearance", appearance]
        }
        if ProcessInfo.processInfo.environment["EXERLY_TEST_LARGEST_TYPE"] == "1" {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        if let contentSize { app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize] }
        app.launchEnvironment["EXERLY_API_BASE_URL"] = fixtureURL
        app.launchEnvironment["EXERLY_TEST_STORE_ID"] = UUID().uuidString
        app.launchEnvironment["EXERLY_TEST_LEGACY_TOKEN"] = legacyToken
        app.launchEnvironment["EXERLY_TEST_ACCOUNT_CONTROLS"] = accountControls
        app.launchEnvironment.merge(environment) { $1 }
        app.launch()
        return app
    }
    @discardableResult
    func dismissPasswordPrompt(in app: XCUIApplication) -> Bool {
        // Fresh iOS 26 simulators offer to save the synthetic account password.
        // The app's elements still exist behind that system sheet, but none are
        // hittable. Handle only this prompt, leaving permission dialogs testable.
        // On iOS 26 it is a sheet in the app, so SpringBoard isn't queried: that
        // cross-process query ran on every reveal step and slowed every test.
        let passwordSheet = app.sheets["Save Password?"]
        if passwordSheet.exists && passwordSheet.buttons["Not Now"].exists {
            passwordSheet.buttons["Not Now"].tap()
            return true
        }
        return false
    }
    func revealAbove(_ element: XCUIElement, in app: XCUIApplication) {
        // A full-app swipe starts inside the saved-account banner at large
        // text sizes on SE. Keep upward-list navigation in the visible list too.
        for _ in 0..<24 where !element.exists {
            let bar = frontNavigationBar(in: app)
            let home = app.tabBars.firstMatch
            let top = max(bar.exists ? bar.frame.maxY + 16 : 48, scrollViewport(in: app)?.minY ?? 0, sectionBarBottom(in: app) + 16)
            let bottom = min(home.exists && home.isHittable ? home.frame.minY - 18 : app.frame.height - 38, fixedFooterTop(in: app))
            let height = max(80, bottom - top)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: (top + height * 0.16) / app.frame.height))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: (top + height * 0.84) / app.frame.height))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
            scrollCount += 1
        }
        reveal(element, in: app)
    }
    func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        dismissPasswordPrompt(in: app)
        if !element.exists { _ = element.waitForExistence(timeout: 5) }
        func visibleFrame(_ item: XCUIElement) -> Bool {
            guard item.exists else { return false }
            let frame = item.frame
            return !frame.isEmpty && !frame.isNull && !frame.isInfinite && app.frame.intersects(frame)
        }
        // Virtualized rows and dismissing sheets can expose an accessibility
        // element before it has a usable frame. Asking isHittable then causes
        // XCTest to abort all subsequent event delivery for this test.
        if (app.keyboards.firstMatch.exists || app.buttons["exerly.keypadDone"].exists) &&
            (!visibleFrame(element) || !element.isHittable) &&
            (app.buttons["Done"].firstMatch.exists || app.buttons["Hide keyboard"].firstMatch.exists || app.buttons["exerly.keypadDone"].exists) {
            dismissKeyboard(app)
        }
        let missing = !element.exists
        // Where the element was before the last drag. A drag that starts on
        // a chart scrubs it instead of scrolling, and at the largest text the
        // trend chart fills the middle of Progress: drag in the margin then.
        var frameBeforeDrag: CGRect?
        for attempt in 0..<48 {
            // An element that never appeared after ten drags won't: let the
            // caller's assertion fail now instead of dragging for minutes.
            if missing, attempt >= 10, !element.exists { return }
            // The system can present the sheet after the diary first appears.
            dismissPasswordPrompt(in: app)
            let home = app.tabBars.firstMatch
            // Identify native tab controls by their container. iOS can expose
            // the tab's symbol as its element label, which made the old label
            // allowlist drag the content 48 times before tapping a visible tab.
            if visibleFrame(element) && element.isHittable,
               app.tabBars.buttons.allElementsBoundByAccessibilityElement.contains(where: { $0.exists && $0.frame == element.frame }) { return }
            // Persistent meal actions are outside the scrolling viewport.
            // Tap them directly when visible, while keeping other drags above them.
            if visibleFrame(element) && element.isHittable,
               persistentActionIDs.contains(element.identifier) { return }
            // Stacked sheets expose the diary's navigation bar as well as
            // their own. Find the control in any bar instead of assuming
            // the last accessibility node is the frontmost navigation bar.
            if visibleFrame(element) && element.isHittable,
               app.navigationBars.buttons.allElementsBoundByAccessibilityElement.contains(where: { $0.exists && $0.frame == element.frame }) { return }
            // Native search fields can belong to the navigation bar itself.
            // They are already visible above the scrolling content's top edge.
            if visibleFrame(element), element.elementType == .searchField, element.isHittable { return }
            // A keyboard or Exerly's keypad covers the content under it, and a
            // drag that starts on the system keyboard swipe-types into the
            // focused field. Keypad keys are what a person taps there.
            // Reading a missing element's identifier is a test failure, and
            // XCTest then stops delivering drags, so read it from a snapshot.
            let identifier = element.exists ? (try? element.snapshot())?.identifier ?? "" : ""
            let keypadKey = identifier.hasPrefix("exerly.keypad") || identifier.hasPrefix("training.keypad")
            let keyboardTop = keypadKey ? .infinity : self.keyboardTop(in: app)
            // Under a keyboard with a Done key, put the keyboard away, as a
            // person would, instead of scrolling content that can't move far enough.
            if keyboardTop.isFinite, visibleFrame(element), element.frame.midY > keyboardTop - 10,
               app.buttons["exerly.keypadDone"].exists || app.buttons["Done"].firstMatch.exists || app.buttons["Hide keyboard"].firstMatch.exists {
                dismissKeyboard(app)
                continue
            }
            let lowerEdge = min(visibleFrame(home) && home.isHittable ? home.frame.minY - 10 : app.frame.height - 30,
                                fixedFooterTop(in: app), keyboardTop - 10)
            let bar = frontNavigationBar(in: app)
            // The saved-account notice is outside the navigation stack. Its
            // Retry button is already visible above the bar; scrolling the
            // diary cannot move it into the list's bounds.
            if visibleFrame(element), element.isHittable, element.label == "Retry", bar.exists,
               element.frame.maxY < bar.frame.minY { return }
            if visibleFrame(element) && element.isHittable && bar.exists,
               element.frame.minY >= bar.frame.minY, element.frame.maxY <= bar.frame.maxY { return }
            // The compact date controls sit just below the navigation bar.
            // A 56-point exclusion zone made the helper scroll a fully visible
            // control repeatedly. Check its center below the actual bar.
            let upperEdge = max(bar.exists ? bar.frame.maxY + 12 : 40, sectionBarBottom(in: app) + 12)
            if visibleFrame(element) && element.frame.midY > upperEdge && element.frame.midY < lowerEdge && element.isHittable { return }
            // A full-screen swipe can jump from below the SE's tab bar to
            // above its navigation bar. Short drags avoid that oscillation.
            // Keep the gesture inside the scrolling area. A large-type account
            // notice or the fixed Progress choices can occupy its upper half.
            let viewport = scrollViewport(in: app)
            let top = max(upperEdge, viewport?.minY ?? upperEdge) + 8
            let bottom = min(lowerEdge, viewport?.maxY ?? lowerEdge) - 8
            let down = element.exists && element.frame.height > 0 && element.frame.midY < top
            let height = max(80, bottom - top)
            let distance = element.exists ? 0.16 : 0.34
            let low = top + height * (0.5 - distance)
            let high = top + height * (0.5 + distance)
            let frame = element.exists ? element.frame : nil
            let dx = frame != nil && frame == frameBeforeDrag ? 6 / app.frame.width : 0.5
            frameBeforeDrag = frame
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: (down ? low : high) / app.frame.height))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: (down ? high : low) / app.frame.height))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
            scrollCount += 1
        }
    }
    /// The bottom of Progress's section picker, a bar the tabs scroll under,
    /// or zero elsewhere. Content under it isn't tappable.
    func sectionBarBottom(in app: XCUIApplication) -> CGFloat {
        let sections = app.otherElements["progress.sections"]
        return sections.exists && sections.isHittable ? sections.frame.maxY : 0
    }
    /// The navigation bar a person sees on top: the last one that takes
    /// taps. Bars of screens under a sheet stay in the hierarchy.
    func frontNavigationBar(in app: XCUIApplication) -> XCUIElement {
        let bars = app.navigationBars.allElementsBoundByAccessibilityElement
        return bars.last(where: { $0.exists && $0.isHittable }) ?? bars.last ?? app.navigationBars.firstMatch
    }
    func fixedFooterTop(in app: XCUIApplication) -> CGFloat {
        // Stacked sheets can expose the scroll view underneath. Never start a
        // content drag inside the current sheet's persistent action buttons.
        persistentActionIDs.compactMap { identifier in
            let button = app.buttons[identifier]
            return button.exists && button.isHittable ? button.frame.minY - 12 : nil
        }.min() ?? app.frame.height
    }
    /// The portion sheet pins its Log button, and the live workout accessory
    /// floats above the tab bar on every other tab: content under either
    /// isn't tappable.
    var persistentActionIDs: [String] {
        // The live workout accessory sits above the tab bar on every other tab.
        ["nutrition.plateAddFoods", "nutrition.reviewPlate", "setup.continueWeek", "setup.finish",
         "planSetup.continue", "planSetup.accept", "gym.save", "nutrition.quick.save", "nutrition.saveEntry",
         "workout.accessory"]
    }
    func scrollViewport(in app: XCUIApplication) -> CGRect? {
        app.scrollViews.allElementsBoundByAccessibilityElement.compactMap { scroll in
            guard scroll.exists, !scroll.frame.isEmpty, !scroll.frame.isNull,
                  app.frame.intersects(scroll.frame), scroll.isHittable else { return nil }
            return scroll.frame.intersection(app.frame)
        }.max { $0.width * $0.height < $1.width * $1.height }
    }
    func tap(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app)
        XCTAssertTrue(element.exists || element.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(element.isHittable, app.debugDescription)
        element.tap()
        tapCount += 1
        // A fresh simulator may show the password sheet between the hittability
        // check and event delivery, swallowing a tab tap. Retry only that known
        // interruption, and only if the original control is still available.
        if dismissPasswordPrompt(in: app), element.exists, element.isHittable {
            element.tap()
        }
    }
    func replace(_ field: XCUIElement, with text: String, in app: XCUIApplication) {
        // XCTest can call a partly obscured SwiftUI field hittable while its
        // tap point falls in the keyboard toolbar. Reveal the whole field
        // before switching focus, as a person scrolling the editor would.
        // iOS 26 puts typing predictions between that toolbar and the keys,
        // so measure from the toolbar itself when there is one.
        let keys = keyboardTop(in: app)
        var covered = keys - 50
        let toolbar = app.toolbars.firstMatch
        if keys.isFinite, toolbar.exists, let bar = (try? toolbar.snapshot())?.frame, bar.maxY <= keys {
            covered = min(covered, bar.minY)
        }
        if field.exists, field.frame.maxY > covered {
            dismissKeyboard(app)
        }
        tap(field, in: app)
        // A sheet at a small detent grows when the keypad opens. Selecting
        // the text mid-animation can land on whatever slid under the old frame.
        waitUntilStill(field)
        // At the largest text the sign-in form scrolls as the keyboard opens,
        // and the tap can land beside the field: reveal it and tap again.
        if (field.value(forKey: "hasKeyboardFocus") as? Bool) == false {
            reveal(field, in: app)
            field.tap()
            waitUntilStill(field)
        }
        let existing = field.value as? String ?? ""
        // Tapping a populated field can put the caret at its start, including
        // UIKit numeric fields. Select the paragraph before deleting so a
        // replacement cannot silently prepend digits to the old value.
        if !existing.isEmpty && existing != field.placeholderValue {
            field.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        }
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count + 3) + text)
        if field.elementType == .textField {
            func matchesExpectedValue() -> Bool {
                guard let actual = field.value as? String else { return false }
                return actual == text || (text.isEmpty && actual == field.placeholderValue)
            }
            // Busy CI simulators can drop keystrokes or miss the selection.
            // Retry through the real editing menu and verify the final value.
            for _ in 0..<2 where !matchesExpectedValue() {
                field.press(forDuration: 1.1)
                let selectAll = app.menuItems["Select All"].firstMatch
                let selectAllButton = app.buttons["Select All"].firstMatch
                if selectAll.exists { selectAll.tap() }
                else if selectAllButton.exists { selectAllButton.tap() }
                else { field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap() }
                let count = (field.value as? String ?? "").count
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count + 3))
                for character in text { field.typeText(String(character)) }
            }
            XCTAssertTrue(matchesExpectedValue(), "Expected '\(text)', found '\(field.value as? String ?? "unavailable")'")
        }
    }
    /// The top of the system keyboard or Exerly's keypad, whichever is up.
    /// Each is read once: one animating away can exist for one query and be
    /// gone for the next, which fails the test. Checking existence first
    /// avoids the snapshot's retries when neither is up.
    func keyboardTop(in app: XCUIApplication) -> CGFloat {
        var top = CGFloat.infinity
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists, let frame = (try? keyboard.snapshot())?.frame { top = frame.minY }
        let keypadDone = app.buttons["exerly.keypadDone"]
        if keypadDone.exists, let frame = (try? keypadDone.snapshot())?.frame { top = min(top, frame.minY) }
        return top
    }
    /// Returns once an element reports the same frame twice in a row, or is gone.
    func waitUntilStill(_ element: XCUIElement, timeout: TimeInterval = 3) {
        var last = CGRect.null
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, let frame = (try? element.snapshot())?.frame, frame != last {
            last = frame
            Thread.sleep(forTimeInterval: 0.3)
        }
    }
    func dismissKeyboard(_ app: XCUIApplication) {
        if app.buttons["exerly.keypadDone"].firstMatch.exists { app.buttons["exerly.keypadDone"].firstMatch.tap() }
        else if app.buttons["Hide keyboard"].firstMatch.exists { app.buttons["Hide keyboard"].firstMatch.tap() }
        else if app.buttons["Done"].firstMatch.exists { app.buttons["Done"].firstMatch.tap() }
        else { app.swipeUp() }
    }
    func capture(_ app: XCUIApplication, _ name: String) {
        if name.hasPrefix("design") || name.hasPrefix("setup") || name.hasPrefix("guided-plan") || name.hasPrefix("gym") {
            Thread.sleep(forTimeInterval: 0.5)
        }
        if dismissPasswordPrompt(in: app) { Thread.sleep(forTimeInterval: 0.8) }
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // TEST_RUNNER_EXERLY_SCREEN_DIR writes each capture to that directory too.
        if let directory = ProcessInfo.processInfo.environment["EXERLY_SCREEN_DIR"], !directory.isEmpty {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: url.appendingPathComponent(name + ".png"))
        }
    }
    // MARK: Today

    /// The Today screen, whatever day it shows.
    func todayScreen(_ app: XCUIApplication) -> XCUIElement { app.scrollViews["today.screen"] }

    /// The day Today shows, as YYYY-MM-DD.
    func shownDay(_ app: XCUIApplication) -> String? {
        app.descendants(matching: .any)["diary.selected-day"].value as? String
    }

    /// Moves Today by whole days through the week strip, the way a person
    /// would: tap the day, or swipe to the previous week first.
    func shiftDay(_ days: Int, in app: XCUIApplication) {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let current = shownDay(app).flatMap(formatter.date(from:)) else { return XCTFail("No day shown") }
        let target = formatter.string(from: current.addingTimeInterval(Double(days) * 86_400))
        showDay(target, earlier: days < 0, in: app)
    }

    func showToday(in app: XCUIApplication) {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        // Dates as YYYY-MM-DD order the same as strings.
        showDay(today, earlier: today < (shownDay(app) ?? today), in: app)
    }

    /// Swipes the week strip, scrolled into view first, until the day shows,
    /// then taps it.
    private func showDay(_ day: String, earlier: Bool, in app: XCUIApplication) {
        let button = app.buttons["today.day.\(day)"]
        let strip = app.descendants(matching: .any)["diary.selected-day"]
        for _ in 0..<8 where !button.exists {
            reveal(strip, in: app)
            earlier ? strip.swipeRight() : strip.swipeLeft()
        }
        tap(button, in: app)
        XCTAssertEqual(shownDay(app), day)
    }

    /// Chooses a logging status from the day's status menu. A tap toggles
    /// complete; a long press opens every status.
    func setDayStatus(_ status: String, in app: XCUIApplication) {
        let control = app.buttons["nutrition.dayStatus"]
        reveal(control, in: app)
        control.press(forDuration: 1.0)
        tapCount += 1
        tap(app.buttons["nutrition.status.\(status)"], in: app)
    }

    /// Opens a meal's actions with a long press on its name.
    /// The "…" menu on a meal's header.
    func openMealActions(_ meal: String, in app: XCUIApplication) {
        tap(app.buttons["today.mealMenu.\(meal.lowercased())"], in: app)
    }

    /// The calorie target Today shows, read from the ring's spoken value. The
    /// ring appears once the plan has synced, which a busy machine can delay;
    /// a failed query would stop XCTest delivering any later events.
    func targetEnergy(_ app: XCUIApplication) -> Double? {
        let ring = app.descendants(matching: .any)["nutrition.targetEnergy"]
        guard ring.waitForExistence(timeout: 20) else { return nil }
        let value = ring.value as? String ?? ""
        guard let range = value.range(of: #"eaten of ([0-9,]+)"#, options: .regularExpression) else { return nil }
        let digits = value[range].filter(\.isNumber)
        return Double(String(digits))
    }

    /// Saved foods moved from a tab to Profile → Foods & recipes.
    func openFoodLibrary(_ app: XCUIApplication) {
        tap(app.buttons["Profile"], in: app)
        tap(app.buttons["profile.foods"], in: app)
    }

    func control(_ body: [String: Any]) async throws {
        _ = try await request("POST", "/__test/control", body: body)
    }
    func request(_ method: String, _ path: String, body: [String: Any]? = nil, token: String? = nil) async throws -> [String: Any] {
        let result = try await responseJSON(method, path, body: body, token: token)
        return try XCTUnwrap(result as? [String: Any])
    }
    func requestArray(_ method: String, _ path: String, token: String) async throws -> [[String: Any]] {
        let result = try await responseJSON(method, path, token: token)
        return try XCTUnwrap(result as? [[String: Any]])
    }
    func responseJSON(_ method: String, _ path: String, body: [String: Any]? = nil, token: String? = nil) async throws -> Any {
        var request = URLRequest(url: URL(string: fixtureURL + path)!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if path == "/mcp" { request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept") }
        request.setValue("isolated-simulator", forHTTPHeaderField: "X-Test-Fixture")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Timezone")
        if method != "GET" { request.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertTrue((200..<300).contains((response as! HTTPURLResponse).statusCode), String(data: data, encoding: .utf8) ?? "")
        return try JSONSerialization.jsonObject(with: data)
    }
}
