import XCTest

/// The workout's Live Activity: requested when a workout starts, updated as
/// sets and rest change, and ended when the workout is finished or discarded.
/// The app's debug readout reports what ActivityKit holds.
final class LiveActivityUITests: ExerlyUITestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    func testTheWorkoutIsALiveActivityUntilItIsFinishedOrDiscarded() async throws {
        let app = try await signedInWithWeek(prefix: "live-activity")
        let activity = readout(app)
        XCTAssertTrue(activity.waitForExistence(timeout: 10))
        XCTAssertEqual(activity.value as? String, "none")

        tap(app.buttons["today.startWorkout"], in: app)
        XCTAssertTrue(app.buttons["training.finish"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait(activity, for: "active Pull 0/3"), "Requested when the workout starts: \(activity.value ?? "")")
        tap(app.buttons["Complete set 1, Deadlift"], in: app)
        XCTAssertTrue(wait(activity, for: "active Pull 1/3 resting"), "Updated with the set and rest: \(activity.value ?? "")")
        tap(app.buttons["Add 15 seconds of rest"], in: app)
        tap(app.buttons["Skip rest"], in: app)
        XCTAssertTrue(wait(activity, for: "active Pull 1/3"), "Rest skipped: \(activity.value ?? "")")

        // The activity and the Next workout widget link to Train, wherever the app was.
        tap(app.buttons["Today"], in: app)
        XCTAssertTrue(app.scrollViews["today.screen"].waitForExistence(timeout: 10))
        XCUIDevice.shared.system.open(URL(string: "exerly://train")!)
        XCTAssertTrue(app.buttons["training.finish"].waitForExistence(timeout: 10), "exerly://train opens the workout")

        tap(app.buttons["training.finish"], in: app)
        tap(app.buttons["Save workout"], in: app)
        XCTAssertTrue(wait(activity, for: "none"), "Ended with the workout: \(activity.value ?? "")")
        tap(app.buttons["training.summaryDone"], in: app)

        startNamedWorkout("Mobility", in: app)
        XCTAssertTrue(wait(activity, for: "active Mobility 0/0"), "\(activity.value ?? "")")
        tap(app.buttons["training.menu"], in: app)
        tap(app.buttons["Discard workout"], in: app)
        tap(app.buttons["Discard workout"].firstMatch, in: app)
        XCTAssertTrue(wait(activity, for: "none"), "Ended when discarded: \(activity.value ?? "")")
    }

    /// Opt-in: the Live Activity on the Lock Screen and in the Dynamic Island,
    /// and its Complete set button run from the Lock Screen.
    func testLiveActivityCapture() async throws {
        guard ProcessInfo.processInfo.environment["EXERLY_DESIGN_CAPTURE"] == "1" else {
            throw XCTSkip("Opt-in visual review of the Live Activity")
        }
        let app = try await signedInWithWeek(prefix: "live-capture")
        let activity = readout(app)
        tap(app.buttons["today.startWorkout"], in: app)
        XCTAssertTrue(app.buttons["training.finish"].waitForExistence(timeout: 10))
        tap(app.buttons["Complete set 1, Deadlift"], in: app)
        XCTAssertTrue(wait(activity, for: "active Pull 1/3 resting"))

        lockAndWake()
        captureScreen("live-01-lock-rest")
        unlock()
        XCUIDevice.shared.press(.home)
        pause(2)
        captureScreen("live-02-island-compact-rest")
        expandIsland()
        captureScreen("live-03-island-expanded-rest")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()

        app.activate()
        tap(app.buttons["Skip rest"], in: app)
        XCTAssertTrue(wait(activity, for: "active Pull 1/3"))
        XCUIDevice.shared.press(.home)
        pause(2)
        captureScreen("live-04-island-compact")
        expandIsland()
        captureScreen("live-05-island-expanded")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()

        lockAndWake()
        captureScreen("live-06-lock-next")
        // The Lock Screen's button logs the next set in the app's process.
        let complete = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Complete set 2, Deadlift")).firstMatch
        if complete.waitForExistence(timeout: 5) {
            complete.tap()
            pause(3)
            captureScreen("live-07-lock-after-complete")
        } else {
            XCTFail("No Complete set button on the Lock Screen: \(springboard.debugDescription)")
        }
        unlock()
        app.activate()
        XCTAssertTrue(app.buttons["Reopen set 2, Deadlift"].waitForExistence(timeout: 10), "The Lock Screen's button logged set 2")
        XCTAssertTrue(wait(activity, for: "active Pull 2/3 resting"), "\(activity.value ?? "")")
    }

    /// Opt-in, as it locks the simulator: rest that ends while the app is
    /// suspended still leaves the next set one tap away on the Lock Screen.
    func testTheNextSetLogsFromTheLockScreenAfterRestEnds() async throws {
        guard ProcessInfo.processInfo.environment["EXERLY_DESIGN_CAPTURE"] == "1" else {
            throw XCTSkip("Opt-in check on the Lock Screen")
        }
        let app = try await signedInWithWeek(prefix: "live-rest-end")
        let activity = readout(app)
        tap(app.buttons["today.startWorkout"], in: app)
        XCTAssertTrue(app.buttons["training.finish"].waitForExistence(timeout: 10))
        tap(app.buttons["Complete set 1, Deadlift"], in: app)
        XCTAssertTrue(wait(activity, for: "active Pull 1/3 resting"))
        // Three minutes of rest after a deadlift, cut to under a minute so it ends while locked.
        let remaining = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Rest, ")).firstMatch
        func secondsLeft() -> Int {
            Int((remaining.label.split(separator: " ").dropFirst().first).map(String.init) ?? "") ?? 0
        }
        while secondsLeft() > 50 { tap(app.buttons["Remove 15 seconds of rest"], in: app) }
        let left = secondsLeft()
        XCTAssertGreaterThan(left, 20, "Rest must still be running at the lock")
        lockAndWake()
        XCTAssertTrue(springboard.buttons["Skip rest"].waitForExistence(timeout: 5), "Resting on the Lock Screen")
        pause(Double(left) + 5)
        // Waking the screen again is how a person looks after resting.
        lockAndWake()
        captureScreen("live-08-lock-rest-over")
        let redrawn = !springboard.buttons["Skip rest"].exists
        add(XCTAttachment(string: "Rest UI \(redrawn ? "cleared" : "still shown at 0:00") after rest ended without the app"))
        let log = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Complete set 2, Deadlift")).firstMatch
        XCTAssertTrue(log.waitForExistence(timeout: 5), "The next set can be logged after rest: \(springboard.debugDescription)")
        log.tap()
        pause(3)
        captureScreen("live-09-lock-logged-after-rest")
        XCTAssertTrue(springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Complete set 3, Deadlift")).firstMatch
                        .waitForExistence(timeout: 10), "The activity moved on to set 3")
        unlock()
        app.activate()
        XCTAssertTrue(app.buttons["Reopen set 2, Deadlift"].waitForExistence(timeout: 10), "Set 2 was logged from the Lock Screen")
    }

    // MARK: Helpers

    private func readout(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["debug.liveActivity"]
    }

    /// ActivityKit's updates reach the readout seconds later on a loaded machine,
    /// such as six simulators sharing it.
    private func wait(_ element: XCUIElement, for value: String, timeout: TimeInterval = 30) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Waits for the system UI to settle; XCTest has nothing to wait on there.
    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Locks the simulator, then wakes it to the Lock Screen.
    private func lockAndWake() {
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        pause(1.5)
        XCUIDevice.shared.press(.home)
        pause(2.5)
        // iOS asks, at first and again later, whether to keep showing Exerly's Live Activities.
        let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "Always Allow"])).firstMatch
        if allow.exists {
            allow.tap()
            pause(1)
        }
    }

    /// Swipes up from the bottom edge; the simulator has no passcode.
    private func unlock() {
        let bottom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995))
        bottom.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func expandIsland() {
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.028)).press(forDuration: 1.2)
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// The whole screen, system UI included.
    private func captureScreen(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["EXERLY_SCREEN_DIR"], !directory.isEmpty {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: url.appendingPathComponent(name + ".png"))
        }
    }
}
