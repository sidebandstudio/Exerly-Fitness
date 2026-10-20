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
                       "2 items removed or put back.")
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

    /// Each other source's start and preview, for visual review: Hevy,
    /// MacroFactor Workouts and an Exerly export.
    func testEachSourcesPreviewCapture() async throws {
        guard ProcessInfo.processInfo.environment["EXERLY_DESIGN_CAPTURE"] == "1" else { throw XCTSkip("Opt-in visual review") }
        try await control([:])
        let files: [(source: String, name: String, data: Data)] = [
            ("hevy", "workout_data.csv", OtherExports.hevy()),
            ("macroFactorWorkouts", "Workout Log.csv", OtherExports.macroFactorWorkouts()),
            ("exerly", "exerly-export.json", OtherExports.exerly()),
        ]
        for file in files {
            let person = try await createAccount(prefix: "preview-\(file.source.lowercased())", units: "imperial")
            let app = launch(file: file.data, name: file.name)
            signIn(app, email: person.email)
            tap(app.tabBars.buttons["Profile"], in: app)
            reveal(app.buttons["profile.importExport"], in: app)
            tap(app.buttons["profile.importExport"], in: app)
            tap(app.buttons["import.source.\(file.source)"], in: app)
            XCTAssertTrue(app.buttons["import.choose"].waitForExistence(timeout: 10))
            capture(app, "\(file.source)-01-start")
            tap(app.buttons["import.testFile"], in: app)
            XCTAssertTrue(app.descendants(matching: .any)["import.preview"].waitForExistence(timeout: 30), app.debugDescription)
            capture(app, "\(file.source)-02-preview")
            let losses = app.descendants(matching: .any)["import.losses"]
            reveal(losses, in: app)
            capture(app, "\(file.source)-03-losses")
            app.terminate()
        }
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

/// Synthetic exports from the other sources, dated around today. Formats:
/// Hevy, https://griptapp.com/help/export-workouts-from-hevy; MacroFactor
/// Workouts, https://help.macrofactorapp.com/en/articles/356-export-your-data
/// with the header of the public sample in
/// https://github.com/matanabudy/workout-data-sync/blob/main/examples/macrofactor_export.csv;
/// Exerly, docs/design/022-export-import.md. No real person's data.
@MainActor
private enum OtherExports {
    static func hevy() -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        let day = ExerlyUITestCase.day(-2).at
        let start = formatter.string(from: day.addingTimeInterval(11 * 3600)), end = formatter.string(from: day.addingTimeInterval(12 * 3600))
        let head = "\"title\",\"start_time\",\"end_time\",\"description\",\"exercise_title\",\"superset_id\",\"exercise_notes\",\"set_index\",\"set_type\",\"weight_lbs\",\"reps\",\"distance_miles\",\"duration_seconds\",\"rpe\""
        let rows = [
            "\"Synthetic Pull\",\"\(start)\",\"\(end)\",\"\",\"Bent Over Row (Barbell)\",,\"\",0,\"warmup\",95,10,,,",
            "\"Synthetic Pull\",\"\(start)\",\"\(end)\",\"\",\"Bent Over Row (Barbell)\",,\"\",1,\"normal\",155,8,,,8",
            "\"Synthetic Pull\",\"\(start)\",\"\(end)\",\"\",\"Face Pull (Cable)\",0,\"\",0,\"normal\",40,15,,,",
            "\"Synthetic Pull\",\"\(start)\",\"\(end)\",\"\",\"Hammer Curl (Dumbbell)\",0,\"\",0,\"dropset\",30,10,,,",
            "\"Synthetic Pull\",\"\(start)\",\"\(end)\",\"\",\"Synthetic Seal Row\",,\"\",0,\"normal\",60,12,,,",
        ]
        return Data(([head] + rows).joined(separator: "\n").utf8)
    }

    static func macroFactorWorkouts() -> Data {
        let date = ExerlyUITestCase.day(-1).date
        let rows = [
            #""Date","Workout Duration","Workout","Exercise","Exercise Base Weight (kg)","Set Type","Weight (kg)","Reps","RIR","Duration","Distance short (m)","Distance long (km)""#,
            #""\#(date)","3600","Synthetic Push","Dumbbell Bench Press",,"Warm-Up Set","20.0","10",,,,"#,
            #""\#(date)","3600","Synthetic Push","Dumbbell Bench Press",,"Standard Set","30.0","10","2",,,"#,
            #""\#(date)","3600","Synthetic Push","Dumbbell Bench Press",,"Myo Set","30.0","12","1",,,"#,
            #""\#(date)","3600","Synthetic Push","Dumbbell Bench Press",,"Mini-set","30.0","4","1",,,"#,
            #""\#(date)","3600","Synthetic Push","Dumbbell Lateral Raise",,"Standard Set","8.0","15","2",,,"#,
        ]
        return Data(rows.joined(separator: "\n").utf8)
    }

    static func exerly() -> Data {
        let days = (1...4).map { offset -> [String: Any] in
            let date = ExerlyUITestCase.day(-offset).date
            return ["kind": "nutrition_day", "document_id": date, "revision": 2, "deleted_at": NSNull(),
                    "payload": ["date": date, "status": offset == 3 ? "fasting" : "complete", "notes": offset == 1 ? "Synthetic note" : ""]]
        }
        let export: [String: Any] = ["exported_at": "2026-10-20T12:00:00.000Z", "version": 3, "account": ["name": "Synthetic"],
                                     "documents": days, "measurements": [["type": "waist", "value": 80]]]
        return (try? JSONSerialization.data(withJSONObject: export)) ?? Data()
    }
}
