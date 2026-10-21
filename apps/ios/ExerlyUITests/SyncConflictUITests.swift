import XCTest

/// Reviewing what two devices changed at once (PARITY I03 and N08): Today's
/// "Needs a look" row, both versions side by side, one-tap choices and Undo.
/// The conflicts are real records in the account's store, seeded through the
/// app's debug hook, since a UI test can't run a second device.
final class SyncConflictUITests: ExerlyUITestCase {
    func testReviewingAConflictKeepsTheChosenVersionAndUndoPutsItBack() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "sync-conflict", units: "metric")
        let app = launch(resetSession: true, environment: ["EXERLY_SYNC_CONFLICT_SEED": "1"])
        signIn(app, email: person.email)
        let row = app.buttons["today.conflicts"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(row.label, "Needs a look")
        XCTAssertEqual(row.value as? String, "2 changes to check")
        capture(app, "sync-01-today")

        tap(row, in: app)
        let food = app.staticTexts["Synthetic Greek yogurt"]
        XCTAssertTrue(food.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Both devices changed the amount."].exists)
        XCTAssertTrue(app.descendants(matching: .any)["This iPhone, 90 g, Showing now"].exists, "VoiceOver reads each version whole")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Another device, 60 g, "))
            .firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Deleted on this iPhone, changed on another device."].exists)
        capture(app, "sync-02-review")

        tap(app.buttons["Keep the other device's"], in: app)
        let undo = app.buttons["conflicts.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        let amount = app.staticTexts["Both devices changed the amount."]
        XCTAssertTrue(amount.waitForNonExistence(timeout: 5), "A resolved conflict leaves the list")
        XCTAssertTrue(app.descendants(matching: .any)["conflicts.resolved"].label.hasPrefix("Kept the other device's"))
        capture(app, "sync-03-resolved")
        tap(undo, in: app)
        XCTAssertTrue(amount.waitForExistence(timeout: 5), "Undo reopens it")

        tap(app.buttons["Keep the other device's"], in: app)
        reveal(app.buttons["Keep it deleted"], in: app)
        tap(app.buttons["Keep it deleted"], in: app)
        XCTAssertTrue(app.staticTexts["Nothing needs a look"].waitForExistence(timeout: 5))
        capture(app, "sync-04-done")

        tap(app.navigationBars.buttons.element(boundBy: 0), in: app)
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        let entry = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Synthetic Greek yogurt, 60 g"))
        reveal(entry.firstMatch, in: app)
        XCTAssertTrue(entry.firstMatch.exists, "Today shows the kept 60 g")
    }

    /// Opt-in screenshots of the review, as the capture script runs them
    /// in light and dark, at default and largest text.
    func testConflictReviewCapture() async throws {
        guard ProcessInfo.processInfo.environment["EXERLY_DESIGN_CAPTURE"] == "1" else {
            throw XCTSkip("Opt-in visual review of the conflict review")
        }
        try await control([:])
        let person = try await createAccount(prefix: "sync-capture", units: "metric")
        let app = launch(resetSession: true, environment: ["EXERLY_SYNC_CONFLICT_SEED": "1"])
        signIn(app, email: person.email)
        let row = app.buttons["today.conflicts"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        capture(app, "sync-capture-01-today")
        tap(row, in: app)
        XCTAssertTrue(app.staticTexts["Synthetic Greek yogurt"].waitForExistence(timeout: 10))
        capture(app, "sync-capture-02-review")
        app.swipeUp()
        capture(app, "sync-capture-03-review-more")
        app.swipeUp()
        capture(app, "sync-capture-04-review-end")
        reveal(app.buttons["Keep the other device's"], in: app)
        tap(app.buttons["Keep the other device's"], in: app)
        XCTAssertTrue(app.buttons["conflicts.undo"].waitForExistence(timeout: 5))
        capture(app, "sync-capture-05-saved")
    }
}
