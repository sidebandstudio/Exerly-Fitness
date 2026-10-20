import XCTest

/// Scan barcode, end to end. The simulator has no camera, so each test turns
/// on the stand-in feed: the fixture API holds a synthetic code, the app
/// draws it and reads it through the same Vision decoder and two-read check
/// the camera uses. Posting a code counts as the scan, one action. Timings
/// and taps are recorded in docs/BARCODE.md.
@MainActor
final class BarcodeScannerUITests: ExerlyUITestCase {
    private var capturing: Bool { ProcessInfo.processInfo.environment["EXERLY_DESIGN_CAPTURE"] == "1" }
    static let oatBar = "0012345678905"
    static let cola = "0049000000443"
    static let juice = "0049000000450"
    /// Valid, and in no food database.
    static let unknown = "0099887766550"
    /// An in-store weighed label: item 12345, 512 embedded.
    static let deli = "2112345005126"

    private func launchScanner(prefix: String) async throws -> (XCUIApplication, (email: String, token: String)) {
        try await control([:])
        try await feed(nil)
        let person = try await createAccount(prefix: prefix)
        let app = launch(resetSession: true, environment: ["EXERLY_TEST_BARCODE_FEED": "1"])
        signIn(app, email: person.email)
        return (app, person)
    }

    /// What the stand-in camera sees next.
    private func feed(_ payload: String?) async throws {
        _ = try await request("POST", "/__test/barcode-feed", body: payload.map { ["payload": $0] } ?? [:])
    }

    /// Points the camera at a code: one action, as a scan is.
    private func scan(_ payload: String, in app: XCUIApplication) async throws {
        XCTAssertTrue(app.descendants(matching: .any)["nutrition.scannerReady"].waitForExistence(timeout: 10), "The camera is watching")
        try await feed(payload)
        tapCount += 1
    }

    private func openScanner(_ app: XCUIApplication) {
        tap(app.buttons["nutrition.scanBarcodeDirect"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["nutrition.scannerReady"].waitForExistence(timeout: 10))
    }

    /// Back from the scanner to Today: the scanner sits on food search, which closes.
    private func leaveScanner(_ app: XCUIApplication) {
        if app.buttons["nutrition.scanCancel"].exists {
            tap(app.buttons["nutrition.scanCancel"], in: app)
            tap(app.buttons["Discard"], in: app)
        } else {
            tap(app.navigationBars.buttons.element(boundBy: 0), in: app)
        }
        tap(app.buttons["nutrition.closePicker"], in: app)
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 10))
    }

    private var logAll: (XCUIApplication) -> XCUIElement { { $0.buttons["nutrition.scanLogAll"] } }

    private func entries(_ name: String, in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "nutrition.entry.", name))
    }

    // MARK: Speed

    /// Barcode to logged from the home screen: Scan, the scan, Log. Each
    /// step's wall-clock time is written out for docs/BARCODE.md.
    func testBarcodeToLoggedInThreeTapsWithEachStepTimed() async throws {
        let (app, _) = try await launchScanner(prefix: "scan-speed")
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 10))
        tapCount = 0
        let opened = Date()
        tap(app.buttons["nutrition.scanBarcodeDirect"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["nutrition.scannerReady"].waitForExistence(timeout: 10))
        let ready = Date()
        try await scan("ean13:\(Self.oatBar)", in: app)
        let scanned = Date()
        let log = logAll(app)
        XCTAssertTrue(log.waitForExistence(timeout: 10), "A found food lands on the plate at once")
        let onPlate = Date()
        XCTAssertTrue(log.label.contains("Log 1 food"), log.label)
        // Inside the app: open to watching, code shown to read, read to on the plate (ms).
        let inApp = app.staticTexts["nutrition.scanTimings"]
        let appTimings = inApp.waitForExistence(timeout: 2) ? inApp.label : "unavailable"
        XCTAssertTrue(app.buttons["nutrition.scanRow.off:\(Self.oatBar)"].exists)
        tap(log, in: app)
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 10))
        XCTAssertEqual(entries("Synthetic oat bar", in: app).count, 1)
        let logged = Date()
        XCTAssertEqual(tapCount, 3, "Scan, the scan, Log")
        let report = """
        TIMING|open to camera ready|\(Self.ms(ready, opened))
        TIMING|code shown to food on plate|\(Self.ms(onPlate, scanned))
        TIMING|Log to Today showing the entry|\(Self.ms(logged, onPlate))
        TIMING|open to logged|\(Self.ms(logged, opened))
        TIMING|taps|\(tapCount)
        TIMING|in app|\(appTimings)
        """
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "barcode-timing"
        attachment.lifetime = .keepAlways
        add(attachment)

        // A second scan of the same food is instant from this phone's cache.
        tapCount = 0
        let again = Date()
        openScanner(app)
        try await scan("ean13:\(Self.oatBar)", in: app)
        XCTAssertTrue(logAll(app).waitForExistence(timeout: 10))
        let cached = Date()
        tap(logAll(app), in: app)
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 10))
        XCTAssertEqual(entries("Synthetic oat bar", in: app).count, 2)
        print("TIMING|repeat scan, open to logged|\(Self.ms(Date(), again))\nTIMING|repeat scan, open to on plate|\(Self.ms(cached, again))")
    }

    private static func ms(_ end: Date, _ start: Date) -> Int { Int(end.timeIntervalSince(start) * 1000) }

    // MARK: Several in a row

    func testSeveralPacksInARowLandOnOnePlateAndLogTogether() async throws {
        let (app, _) = try await launchScanner(prefix: "scan-multi")
        openScanner(app)
        try await scan("ean13:\(Self.oatBar)", in: app)
        XCTAssertTrue(app.buttons["nutrition.scanRow.off:\(Self.oatBar)"].waitForExistence(timeout: 10))
        try await scan("upca:\(Self.cola.dropFirst())", in: app)
        XCTAssertTrue(app.buttons["nutrition.scanRow.off:\(Self.cola)"].waitForExistence(timeout: 10), "UPC-A finds the product filed as EAN-13")
        try await scan("ean13:\(Self.juice)", in: app)
        XCTAssertTrue(app.buttons["nutrition.scanRow.off:\(Self.juice)"].waitForExistence(timeout: 10))
        // The same bar again: one more of it, not a second row.
        try await scan("ean13:\(Self.oatBar)", in: app)
        let bar = app.buttons["nutrition.scanRow.off:\(Self.oatBar)"]
        XCTAssertTrue(app.staticTexts["nutrition.scanStatus"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor(bar, NSPredicate(format: "label CONTAINS %@", "2 ×")), "Two bars: \(bar.label)")
        XCTAssertTrue(logAll(app).label.contains("Log 3 foods"), logAll(app).label)
        if capturing { capture(app, "barcode-tray") }
        tap(app.buttons["nutrition.scanLess.off:\(Self.oatBar)"], in: app)
        XCTAssertTrue(waitFor(bar, NSPredicate(format: "NOT label CONTAINS %@", "2 ×")), bar.label)
        tap(app.buttons["nutrition.scanRemove.off:\(Self.cola)"], in: app)
        XCTAssertTrue(app.buttons["nutrition.scanRow.off:\(Self.cola)"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(logAll(app).label.contains("Log 2 foods"), logAll(app).label)
        tap(logAll(app), in: app)
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 10))
        XCTAssertEqual(entries("Synthetic oat bar", in: app).count, 1)
        XCTAssertEqual(entries("Synthetic apple juice", in: app).count, 1)
        XCTAssertEqual(entries("Synthetic cola", in: app).count, 0)
    }

    private func waitFor(_ element: XCUIElement, _ predicate: NSPredicate, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, predicate.evaluate(with: element) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    // MARK: Offline

    /// A code resolved once works offline, and Recent scans logs it again in one tap.
    func testARescanWorksOfflineAndHistoryRelogsInOneTap() async throws {
        let (app, _) = try await launchScanner(prefix: "scan-offline-cache")
        openScanner(app)
        try await scan("ean13:\(Self.oatBar)", in: app)
        tap(logAll(app), in: app)
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 10))

        try await control(["offline": true])
        openScanner(app)
        try await scan("upca:\(Self.oatBar.dropFirst())", in: app)
        XCTAssertTrue(app.buttons["nutrition.scanRow.off:\(Self.oatBar)"].waitForExistence(timeout: 5), "Found offline, from this phone")
        leaveScanner(app)

        tapCount = 0
        tap(app.buttons["nutrition.scanBarcodeDirect"], in: app)
        let relog = app.buttons["nutrition.scanRelog.\("0" + Self.oatBar)"]
        XCTAssertTrue(relog.waitForExistence(timeout: 5))
        if capturing { capture(app, "barcode-history") }
        tap(relog, in: app)
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 10))
        XCTAssertEqual(tapCount, 2, "Scan, then Log on the past scan")
        XCTAssertEqual(entries("Synthetic oat bar", in: app).count, 2)
        try await control([:])
    }

    /// A new code scanned offline is saved, says so, and is ready to log
    /// once the phone is back online, to the meal it was scanned for.
    func testANewCodeScannedOfflineIsSavedAndResolvesBackOnline() async throws {
        let (app, _) = try await launchScanner(prefix: "scan-offline-queue")
        try await control(["offline": true])
        openScanner(app)
        try await scan("ean13:\(Self.juice)", in: app)
        XCTAssertTrue(app.staticTexts["nutrition.barcodeQueued"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["nutrition.barcodeShown"].exists, "The code is shown")
        XCTAssertTrue(app.descendants(matching: .any)["nutrition.scanHistory.\("0" + Self.juice)"].exists, "It waits in Recent scans")
        if capturing { capture(app, "barcode-offline-queued") }
        leaveScanner(app)
        try await control([:])
        openScanner(app)
        XCTAssertTrue(app.staticTexts["nutrition.barcodeReady"].waitForExistence(timeout: 10), "Told it's ready")
        let relog = app.buttons["nutrition.scanRelog.\("0" + Self.juice)"]
        XCTAssertTrue(relog.waitForExistence(timeout: 5))
        XCTAssertTrue(relog.label.contains("Log"), relog.label)
        tap(relog, in: app)
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 10))
        XCTAssertEqual(entries("Synthetic apple juice", in: app).count, 1)
    }

    // MARK: Not found

    /// A miss is never a dead end: the code is shown with search, entry
    /// and the label, and a food entered for it is found by the next scan.
    func testAnUnknownCodeOffersSearchAndEntryAndRemembersWhatsEntered() async throws {
        let (app, _) = try await launchScanner(prefix: "scan-miss")
        openScanner(app)
        try await scan("ean13:\(Self.unknown)", in: app)
        XCTAssertTrue(app.staticTexts["nutrition.barcodeNotFound"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["nutrition.barcodeShown"].exists)
        XCTAssertTrue(app.buttons["nutrition.barcodeSearchByName"].exists)
        XCTAssertTrue(app.buttons["nutrition.barcodeScanLabel"].exists)
        if capturing { capture(app, "barcode-miss") }
        tap(app.buttons["nutrition.barcodeManualFood"], in: app)
        XCTAssertTrue(app.navigationBars["Food label"].waitForExistence(timeout: 5))
        replace(app.textFields["nutrition.foodName"], with: "Synthetic seed crackers", in: app)
        replace(app.textFields["nutrition.nutrient.energy"], with: "450", in: app)
        tap(app.buttons["nutrition.saveFood"], in: app)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "nutrition.scanRow.", "Synthetic seed crackers"))
        XCTAssertTrue(row.firstMatch.waitForExistence(timeout: 5), "The food entered joins the plate")
        tap(logAll(app), in: app)
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 10))
        // The next scan of that code finds it, offline too.
        try await control(["offline": true])
        openScanner(app)
        try await scan("ean13:\(Self.unknown)", in: app)
        XCTAssertTrue(row.firstMatch.waitForExistence(timeout: 5), "The code finds the food entered for it")
        try await control([:])
    }

    func testAnInStoreLabelIsExplainedNotLookedUp() async throws {
        try await control(["resetFoodDatabaseRequests": true])
        let (app, _) = try await launchScanner(prefix: "scan-deli")
        openScanner(app)
        try await scan("ean13:\(Self.deli)", in: app)
        XCTAssertTrue(app.staticTexts["nutrition.barcodeNotProduct"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["nutrition.barcodeSearchByName"].exists)
        let requests = try await request("GET", "/__test/food-database-requests")
        XCTAssertEqual((requests["requests"] as? [[String: Any]])?.filter { $0["type"] as? String == "barcode" }.count, 0)
    }

    // MARK: Capture

    func testBarcodeCapture() async throws {
        guard capturing else { throw XCTSkip("Opt-in visual review of Scan barcode") }
        let (app, _) = try await launchScanner(prefix: "design-scan")
        openScanner(app)
        try await scan("ean13:\(Self.oatBar)", in: app)
        XCTAssertTrue(logAll(app).waitForExistence(timeout: 10))
        capture(app, "barcode-scanner")
        try await scan("ean13:\(Self.juice)", in: app)
        XCTAssertTrue(app.buttons["nutrition.scanRow.off:\(Self.juice)"].waitForExistence(timeout: 10))
        try await scan("upca:\(Self.cola.dropFirst())", in: app)
        XCTAssertTrue(app.buttons["nutrition.scanRow.off:\(Self.cola)"].waitForExistence(timeout: 10))
        capture(app, "barcode-tray")
        tap(logAll(app), in: app)
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 10))
        try await control(["offline": true])
        openScanner(app)
        try await scan("ean13:7612345678900", in: app)
        XCTAssertTrue(app.staticTexts["nutrition.barcodeQueued"].waitForExistence(timeout: 10))
        capture(app, "barcode-offline-queued")
        try await control([:])
        try await scan("ean13:\(Self.unknown)", in: app)
        XCTAssertTrue(app.staticTexts["nutrition.barcodeNotFound"].waitForExistence(timeout: 10))
        capture(app, "barcode-miss")
        tap(app.buttons["nutrition.scanHistory"], in: app)
        XCTAssertTrue(app.navigationBars["Scan history"].waitForExistence(timeout: 5))
        capture(app, "barcode-history")
    }
}
