import XCTest

/// Screens behind code-blind run 6 on an iPhone SE, on the realistic seed:
/// floating bars over content, hiding a suggestion, the portion sheet's
/// footer, the reminder time picker, the weight figures, and the toasts.
/// Steps a build doesn't have are skipped, so the same walk captures before and after.
final class SmallPhoneCaptureUITests: ExerlyUITestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    func testTabsCapture() async throws {
        guard ProcessInfo.processInfo.environment["EXERLY_DESIGN_CAPTURE"] == "1" else { throw XCTSkip("Opt-in visual review") }
        let app = try await signedInWithRealisticHistory(prefix: "small-tabs")
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 1.5)
        capture(app, "01-today-top")
        writeTree(app, "01-today-top")
        reveal(app.otherElements["weightCard"], in: app)
        capture(app, "02-today-weight")
        if app.buttons["today.select"].exists {
            tap(app.buttons["today.select"], in: app)
            let entries = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "nutrition.entry."))
            for index in 0..<min(2, entries.count) where entries.element(boundBy: index).isHittable { entries.element(boundBy: index).tap() }
            capture(app, "03-today-selecting")
            for _ in 0..<6 { app.swipeUp() }
            capture(app, "04-today-selecting-end")
            if app.buttons["today.endSelection"].exists { app.buttons["today.endSelection"].tap() }
        }
        for _ in 0..<6 { app.swipeUp() }
        capture(app, "05-today-end")

        tap(app.tabBars.buttons["Train"], in: app)
        Thread.sleep(forTimeInterval: 1)
        capture(app, "06-train-top")
        for _ in 0..<4 { app.swipeUp() }
        capture(app, "07-train-end")

        tap(app.tabBars.buttons["Today"], in: app)
        Thread.sleep(forTimeInterval: 1)
        capture(app, "08-today-returned")

        tap(app.tabBars.buttons["Progress"], in: app)
        Thread.sleep(forTimeInterval: 1.5)
        capture(app, "09-progress-top")
        let chart = app.descendants(matching: .any)["body.chart"]
        if chart.waitForExistence(timeout: 5) {
            reveal(chart, in: app)
            app.swipeUp()
            capture(app, "10-progress-chart")
            app.swipeUp()
            capture(app, "11-progress-rate")
        }

        tap(app.tabBars.buttons["Profile"], in: app)
        Thread.sleep(forTimeInterval: 1)
        capture(app, "12-profile-top")
        tap(app.buttons["profile.reminders"], in: app)
        let weighIn = app.switches["reminders.weighIn"]
        XCTAssertTrue(weighIn.waitForExistence(timeout: 15))
        capture(app, "13-reminders")
        if weighIn.value as? String == "0" {
            weighIn.tap()
            if springboard.alerts.firstMatch.waitForExistence(timeout: 4) { springboard.alerts.buttons["Allow"].tap() }
        }
        Thread.sleep(forTimeInterval: 1.5)
        capture(app, "14-reminders-weigh-in-on")
        let meals = app.switches["reminders.meals"].value as? String
        let time = app.descendants(matching: .any)["reminders.weighIn.time"]
        if time.waitForExistence(timeout: 5) {
            time.tap()
            Thread.sleep(forTimeInterval: 1)
            capture(app, "15-time-picker")
            // What a tap outside the picker reaches: the screen's middle, as the tester's did.
            let dismiss = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "dismiss popup")).firstMatch
            if dismiss.exists && dismiss.isHittable { dismiss.tap() } else {
                let row = app.switches["reminders.meals"].frame
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: row.minX + 30, dy: row.midY)).tap()
            }
            Thread.sleep(forTimeInterval: 1)
            capture(app, "16-time-picker-dismissed")
            XCTAssertEqual(app.switches["reminders.meals"].value as? String, meals, "Dismissing the picker left Meals alone")
        }
        for _ in 0..<3 { app.swipeUp() }
        capture(app, "17-reminders-end")
    }

    func testFoodCapture() async throws {
        guard ProcessInfo.processInfo.environment["EXERLY_DESIGN_CAPTURE"] == "1" else { throw XCTSkip("Opt-in visual review") }
        let app = try await signedInWithRealisticHistory(prefix: "small-food")
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 20))
        tap(app.buttons["nutrition.addFood"], in: app)
        let recent = app.otherElements["nutrition.group.recent"]
        XCTAssertTrue(recent.waitForExistence(timeout: 10))
        dismissKeyboard(app)
        capture(app, "20-add-food")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND identifier BEGINSWITH %@", "Roasted potatoes,", "nutrition.food."))
            .firstMatch
        reveal(row, in: app)
        row.press(forDuration: 1.0)
        Thread.sleep(forTimeInterval: 1)
        capture(app, "21-recent-long-press")
        closeTopSheetOrMenu(app)
        reveal(row, in: app)
        row.swipeLeft()
        Thread.sleep(forTimeInterval: 1)
        capture(app, "22-recent-swipe-left")
        let hide = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "nutrition.swipeHide.")).firstMatch
        if hide.exists && hide.isHittable {
            hide.tap()
            Thread.sleep(forTimeInterval: 1)
            capture(app, "22b-hidden-toast")
            if app.buttons["nutrition.undoLog"].exists { app.buttons["nutrition.undoLog"].tap() }
        } else { closeTopSheetOrMenu(app) }

        reveal(row, in: app)
        row.tap()
        XCTAssertTrue(app.buttons["nutrition.saveEntry"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        capture(app, "23-log-sheet")
        writeTree(app, "23-log-sheet")
        let about = app.buttons["About this food"]
        if about.exists {
            // A tap on the element, wherever it is, as the tester's driver tapped.
            about.tap()
            Thread.sleep(forTimeInterval: 1)
            capture(app, "24-about-this-food-tapped")
        }
        if app.buttons["nutrition.entryMore"].exists {
            app.buttons["nutrition.entryMore"].tap()
            Thread.sleep(forTimeInterval: 1)
            capture(app, "24b-log-sheet-menu")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            Thread.sleep(forTimeInterval: 0.6)
        }
        if app.buttons["nutrition.cancelEntry"].exists { app.buttons["nutrition.cancelEntry"].tap() }
        if app.buttons["nutrition.closePicker"].waitForExistence(timeout: 3) { app.buttons["nutrition.closePicker"].tap() }

        // The search tab stays after logging and confirms each food; over the target, by how much.
        tap(app.tabBars.buttons["Log food"], in: app)
        XCTAssertTrue(recent.waitForExistence(timeout: 10))
        dismissKeyboard(app)
        let adds = recent.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "nutrition.quickLog."))
        for index in 0..<min(4, adds.count) {
            let add = adds.element(boundBy: index)
            reveal(add, in: app)
            if add.isHittable { add.tap(); Thread.sleep(forTimeInterval: 0.6) }
        }
        capture(app, "25-logged-toast")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        // Past the day's target, the confirmation says by how much.
        replace(field, with: "500 g olive oil", in: app)
        let oil = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "nutrition.quickLog.", "Log 500 g of Olive oil"))
            .firstMatch
        if oil.waitForExistence(timeout: 5) {
            tap(oil, in: app)
            Thread.sleep(forTimeInterval: 1)
            capture(app, "25b-logged-over-target")
        }
        for (name, query) in [("26-search-toast", "1 slice toast"), ("27-search-eggs", "2 eggs")] {
            replace(field, with: query, in: app)
            Thread.sleep(forTimeInterval: 2.5)
            capture(app, name)
        }
        tap(app.tabBars.buttons["Today"], in: app)
        Thread.sleep(forTimeInterval: 1)
        capture(app, "28-today-after-search-tab")
        tap(app.tabBars.buttons["Log food"], in: app)
        Thread.sleep(forTimeInterval: 1)
        capture(app, "29-search-tab-again")
    }

    func testGoalsAndWorkoutCapture() async throws {
        guard ProcessInfo.processInfo.environment["EXERLY_DESIGN_CAPTURE"] == "1" else { throw XCTSkip("Opt-in visual review") }
        let app = try await signedInWithRealisticHistory(prefix: "small-goals")
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 20))
        tap(app.tabBars.buttons["Profile"], in: app)
        tap(app.buttons["profile.nutrientGoals"], in: app)
        let fiber = app.buttons["goals.nutrient.fiber"]
        XCTAssertTrue(fiber.waitForExistence(timeout: 10))
        tap(fiber, in: app)
        Thread.sleep(forTimeInterval: 1)
        capture(app, "30-fiber-goal")
        writeTree(app, "30-fiber-goal")
        app.typeText("35")
        tap(app.buttons["goalEditor.save"], in: app)
        let pin = app.buttons["goals.pin.fiber"]
        if pin.waitForExistence(timeout: 5) { tap(pin, in: app) }
        tap(app.tabBars.buttons["Today"], in: app)
        Thread.sleep(forTimeInterval: 1)
        reveal(app.buttons["today.pinned.fiber"], in: app)
        capture(app, "31-today-fiber")

        tap(app.tabBars.buttons["Train"], in: app)
        let start = app.buttons["training.startToday"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        tap(start, in: app)
        XCTAssertTrue(app.buttons["training.finish"].waitForExistence(timeout: 10))
        let done = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "set.", ".1.done")).firstMatch
        if done.waitForExistence(timeout: 5) { tap(done, in: app) }
        Thread.sleep(forTimeInterval: 1)
        capture(app, "32-rest-bar")
        for _ in 0..<6 { app.swipeUp() }
        capture(app, "33-workout-end")
        tap(app.buttons["training.finish"], in: app)
        Thread.sleep(forTimeInterval: 1)
        capture(app, "34-finish-dialog")
        if app.buttons["Save workout"].exists { app.buttons["Save workout"].tap() }
        Thread.sleep(forTimeInterval: 1.5)
        capture(app, "35-workout-summary")
        writeTree(app, "35-workout-summary")
    }

    /// Closes a sheet or menu that a gesture opened, leaving the screen under it.
    private func closeTopSheetOrMenu(_ app: XCUIApplication) {
        if app.buttons["nutrition.cancelEntry"].exists { app.buttons["nutrition.cancelEntry"].tap() }
        else if app.buttons["Details"].exists {
            // A long-press menu, at the top at the largest sizes: a tap away from it closes it.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).tap()
        } else if app.collectionViews.firstMatch.exists || app.otherElements["PopoverDismissRegion"].exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
        } else { app.swipeRight() }
        Thread.sleep(forTimeInterval: 1)
    }

    /// The accessibility tree as XCTest sees it, beside the screenshot.
    private func writeTree(_ app: XCUIApplication, _ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["EXERLY_SCREEN_DIR"], !directory.isEmpty else { return }
        try? app.debugDescription.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".tree.txt"),
                                        atomically: true, encoding: .utf8)
    }
}
