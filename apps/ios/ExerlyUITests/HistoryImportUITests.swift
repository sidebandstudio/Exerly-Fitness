import XCTest

/// Importing a synthetic Strong export through the preview: the weight unit
/// the file doesn't give, an exercise left out, the import, its workouts, and
/// Undo. Also a file from another app, refused with a reason. The file comes
/// through the screen's debug hook, since the system file picker runs outside
/// the app.
@MainActor
final class HistoryImportUITests: ExerlyUITestCase {
    func testAStrongExportIsPreviewedImportedAndUndone() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "strong-import", units: "metric")
        let app = launch(file: StrongExport.csv(), name: "strong_workouts.csv")
        signIn(app, email: person.email)
        tap(app.tabBars.buttons["Profile"], in: app)
        reveal(app.buttons["profile.importExport"], in: app)
        tap(app.buttons["profile.importExport"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["import.noRecords"].waitForExistence(timeout: 10))
        capture(app, "hub-01-empty")
        tap(app.buttons["import.source.strong"], in: app)
        XCTAssertTrue(app.buttons["import.choose"].waitForExistence(timeout: 10))
        capture(app, "strong-01-start")

        tap(app.buttons["import.testFile"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["import.preview"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertEqual(app.descendants(matching: .any)["import.count.workouts"].value as? String, "2 to add")
        XCTAssertEqual(app.descendants(matching: .any)["import.count.sets"].value as? String, "4 to add",
                       "The landmine twist's set waits for a match")
        capture(app, "strong-02-preview")

        // Strong's weights have no unit: they were pounds.
        let pounds = app.buttons["Pounds"].firstMatch
        reveal(pounds, in: app)
        capture(app, "strong-03-units")
        tap(pounds, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["import.preview"].waitForExistence(timeout: 30))

        // The exercise Exerly has no match for is left out.
        let twist = app.buttons.matching(NSPredicate(format: "label == 'Synthetic Landmine Twist'")).firstMatch
        reveal(twist, in: app)
        XCTAssertEqual(twist.value as? String, "No match. Choose one, 1 set")
        tap(twist, in: app)
        XCTAssertTrue(app.buttons["import.chooser.leaveOut"].waitForExistence(timeout: 10))
        capture(app, "strong-04-chooser")
        tap(app.buttons["import.chooser.leaveOut"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["import.preview"].waitForExistence(timeout: 30))
        let leftOut = app.buttons.matching(NSPredicate(format: "label == 'Synthetic Landmine Twist'")).firstMatch
        reveal(leftOut, in: app)
        XCTAssertEqual(leftOut.value as? String, "Left out, 1 set")
        capture(app, "strong-05-exercises")
        let chosenOut = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'exercises you chose to leave out'")).firstMatch
        XCTAssertTrue(chosenOut.exists, "The loss list counts the set left out")
        let restTimer = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '1 rest timer'")).firstMatch
        reveal(restTimer, in: app)
        XCTAssertTrue(restTimer.exists, "The loss list names the rest timer")
        capture(app, "strong-06-losses")

        reveal(app.buttons["import.import"], in: app)
        tap(app.buttons["import.import"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["import.done"].waitForExistence(timeout: 60), app.debugDescription)
        capture(app, "strong-07-done")
        let synced = try await waitForSession(token: person.token, named: "Synthetic Upper")
        let bench = ((synced?["exercises"] as? [[String: Any]])?.first?["sets"] as? [[String: Any]])?.dropFirst().first
        let load = ((bench?["efforts"] as? [[String: Any]])?.first?["load"] as? [String: Any])
        XCTAssertEqual(load?["unit"] as? String, "lb", "Read in the unit chosen")
        XCTAssertEqual(load?["value"] as? Double, 185)

        tap(app.buttons["import.undo"], in: app)
        tap(app.alerts.buttons["Undo import"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["import.undone"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.descendants(matching: .any)["import.undoneDetail"].label,
                       "Import undone: 2 items removed or put back.")
        capture(app, "strong-08-undone")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.descendants(matching: .any)["import.record.0"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Undone"].exists)
        capture(app, "hub-02-undone")
    }

    func testAFileFromAnotherAppIsRefusedWithAReason() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "import-refused", units: "metric")
        let app = launch(file: Data("colour,shape\nred,round\n".utf8), name: "shapes.csv")
        signIn(app, email: person.email)
        tap(app.tabBars.buttons["Profile"], in: app)
        reveal(app.buttons["profile.importExport"], in: app)
        tap(app.buttons["profile.importExport"], in: app)
        tap(app.buttons["import.source.hevy"], in: app)
        tap(app.buttons["import.testFile"], in: app)
        let refused = app.descendants(matching: .any)["import.unreadable"]
        XCTAssertTrue(refused.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(refused.label.contains("shapes.csv isn't an export Exerly knows"), refused.label)
        XCTAssertTrue(app.buttons["import.choose"].exists, "Another file can be chosen")
        capture(app, "hevy-error")
    }

    /// Setup's last page offers to bring history, and Import & export opens
    /// once setup is finished. Then the export screen, from the same hub.
    func testSetupOffersToBringYourHistoryThenExportIsAtHand() async throws {
        try await control([:])
        let email = "bring-history-\(UUID().uuidString.prefix(8).lowercased())@exerly.test"
        _ = try await request("POST", "/signup", body: ["email": email, "password": "Simulator-Test-123!", "name": "Riley Example"])
        let app = launch(resetSession: true)
        tap(app.buttons["I already have an account"], in: app)
        replace(app.textFields["Email"], with: email, in: app)
        replace(app.secureTextFields["Password"], with: "Simulator-Test-123!", in: app)
        dismissKeyboard(app)
        tap(app.buttons["Log In"], in: app)
        XCTAssertTrue(app.textFields["Your name"].waitForExistence(timeout: 15))
        tap(app.buttons["Metric"], in: app)
        replace(app.textFields["Height, cm"], with: "172", in: app)
        dismissKeyboard(app)
        replace(app.textFields["Weight, kg"], with: "74.2", in: app)
        dismissKeyboard(app)
        tap(app.buttons["Female"], in: app)
        tap(app.buttons["Continue"], in: app)
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Maintain")).firstMatch, in: app)
        tap(app.buttons["Continue"], in: app)
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Moderately Active")).firstMatch, in: app)
        tap(app.buttons["setup.continueWeek"], in: app)
        tap(app.buttons["setup.workouts.3"], in: app)
        tap(app.buttons["setup.continueWeek"], in: app)
        XCTAssertTrue(app.buttons["Finish setup"].waitForExistence(timeout: 15))
        let bring = app.switches["setup.bringHistory"]
        reveal(bring, in: app)
        capture(app, "onboarding-01-offer")
        tap(bring, in: app)
        if bring.value as? String != "1" { bring.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        XCTAssertEqual(bring.value as? String, "1")
        capture(app, "onboarding-02-on")
        tap(app.buttons["Finish setup"], in: app)
        let hub = app.descendants(matching: .any)["import.noRecords"]
        XCTAssertTrue(hub.waitForExistence(timeout: 30), app.debugDescription)
        capture(app, "hub-00-after-setup")
        let export = app.buttons["import.export"]
        XCTAssertFalse(export.exists, "The sheet after setup is for importing")
        tap(app.buttons["Close"], in: app)

        tap(app.tabBars.buttons["Profile"], in: app)
        reveal(app.buttons["profile.importExport"], in: app)
        capture(app, "profile-entry")
        tap(app.buttons["profile.importExport"], in: app)
        reveal(export, in: app)
        tap(export, in: app)
        XCTAssertTrue(app.buttons["account.shareExport"].waitForExistence(timeout: 10))
        capture(app, "export-01")
        tap(app.buttons["account.shareExport"], in: app)
        XCTAssertTrue(app.buttons["Close"].firstMatch.waitForExistence(timeout: 20), "The share sheet opens with the zip")
        capture(app, "export-02-share")
    }

    /// The session the account's server has with this name, once it syncs.
    private func waitForSession(token: String, named name: String, timeout: Int = 40) async throws -> [String: Any]? {
        for _ in 0..<timeout {
            let exported = try await request("GET", "/api/export", token: token)
            let documents = exported["documents"] as? [[String: Any]] ?? []
            if let session = documents.lazy.filter({ $0["kind"] as? String == "workout_session" })
                .compactMap({ $0["payload"] as? [String: Any] }).first(where: { $0["name"] as? String == name }) {
                return session
            }
            try await Task.sleep(for: .seconds(1))
        }
        return nil
    }

    private func launch(file: Data, name: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        if let appearance = ProcessInfo.processInfo.environment["EXERLY_TEST_APPEARANCE"], ["light", "dark", "system"].contains(appearance) {
            app.launchArguments += ["-exerlyAppearance", appearance]
        }
        if ProcessInfo.processInfo.environment["EXERLY_TEST_LARGEST_TYPE"] == "1" {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launchEnvironment["EXERLY_API_BASE_URL"] = fixtureURL
        app.launchEnvironment["EXERLY_TEST_STORE_ID"] = UUID().uuidString
        app.launchEnvironment["EXERLY_IMPORT_FILE"] = file.base64EncodedString()
        app.launchEnvironment["EXERLY_IMPORT_FILE_NAME"] = name
        app.launch()
        return app
    }
}

/// A synthetic Strong export dated around today: one row per set, in the
/// layout whose Weight column has no unit. Format: Strong's help centre,
/// https://help.strongapp.io/article/235-export-workout-data, with the
/// columns listed at https://griptapp.com/help/export-workouts-from-strong.
/// No real person's data.
@MainActor
private enum StrongExport {
    static func csv() -> Data {
        let upper = ExerlyUITestCase.day(-3).date + " 18:30:00", legs = ExerlyUITestCase.day(-1).date + " 07:00:00"
        let rows = [
            "Date,Workout Name,Duration,Exercise Name,Set Order,Weight,Reps,Distance,Seconds,Notes,Workout Notes,RPE",
            "\(upper),Synthetic Upper,1h 5m,Bench Press (Barbell),W,95,10,,,,Synthetic session,",
            "\(upper),Synthetic Upper,1h 5m,Bench Press (Barbell),1,185,5,,,,Synthetic session,8",
            "\(upper),Synthetic Upper,1h 5m,Bench Press (Barbell),Rest Timer,,,,120,,Synthetic session,",
            "\(upper),Synthetic Upper,1h 5m,Bench Press (Barbell),2,185,5,,,,Synthetic session,9",
            "\(upper),Synthetic Upper,1h 5m,Synthetic Landmine Twist,1,45,12,,,,Synthetic session,",
            "\(legs),Synthetic Legs,45m,Squat (Barbell),1,225,5,,,,,",
        ]
        return Data((rows.joined(separator: "\n") + "\n").utf8)
    }
}
