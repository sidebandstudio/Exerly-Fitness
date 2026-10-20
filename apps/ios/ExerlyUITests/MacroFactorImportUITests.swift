import XCTest

/// Importing a synthetic MacroFactor export: the preview, the import, the
/// history it adds on Today and in Progress → Body, and Undo. The file comes through the
/// screen's debug hook, since the system file picker runs outside the app.
@MainActor
final class MacroFactorImportUITests: ExerlyUITestCase {
    private var designCapture: Bool { ProcessInfo.processInfo.environment["EXERLY_DESIGN_CAPTURE"] == "1" }

    func testImportAddsFoodToTodayAndWeighInsToProgressThenUndoes() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "mf-import", units: "metric")
        try await deleteSetupWeight(token: person.token)
        let app = launch(export: SyntheticExport.workbook())
        signIn(app, email: person.email)
        openImport(app, source: "macroFactor")
        XCTAssertTrue(app.buttons["import.choose"].waitForExistence(timeout: 15))
        capture(app, "mf-01-start")
        if designCapture {
            app.swipeUp(velocity: .slow)
            capture(app, "mf-02-start-more")
            for _ in 0..<3 { app.swipeDown(velocity: .fast) }
        }

        tap(app.buttons["import.testFile"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["import.preview"].waitForExistence(timeout: 30), app.debugDescription)
        let weights = app.descendants(matching: .any)["import.count.weights"]
        XCTAssertTrue(weights.waitForExistence(timeout: 5))
        XCTAssertEqual(weights.value as? String, "10 to add")
        XCTAssertEqual(app.descendants(matching: .any)["import.count.entries"].value as? String, "3 to add")
        XCTAssertEqual(app.descendants(matching: .any)["import.count.workouts"].value as? String, "1 to add")
        capture(app, "mf-04-preview")
        let unmatched = app.buttons.matching(NSPredicate(format: "label == 'Synthetic Zercher Hop'")).firstMatch
        reveal(unmatched, in: app)
        XCTAssertTrue(unmatched.exists, "The unmatched exercise is listed to match")
        XCTAssertEqual(unmatched.value as? String, "No match. Choose one, 1 set")
        capture(app, "mf-05-exercises")
        let trend = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'works out your trend weight'")).firstMatch
        reveal(trend, in: app)
        XCTAssertTrue(trend.exists, "MacroFactor's trend weight is listed as not coming across")
        capture(app, "mf-06-losses")

        reveal(app.buttons["import.import"], in: app)
        tap(app.buttons["import.import"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["import.done"].waitForExistence(timeout: 60), app.debugDescription)
        capture(app, "mf-07-done")

        // The weigh-ins are in Progress → Body, and reach the account.
        tap(app.buttons["import.seeTrend"], in: app)
        let yesterday = Self.day(-1).date
        XCTAssertTrue(app.descendants(matching: .any)["body.weighIn.\(yesterday)"].waitForExistence(timeout: 30), app.debugDescription)
        try await Task.sleep(for: .seconds(1))
        capture(app, "mf-08-trend")
        let synced = try await waitForWeighIn(token: person.token) { $0["source"] as? String == "macroFactor" && $0["date"] as? String == yesterday }
        XCTAssertEqual((synced?["weight"] as? [String: Any])?["value"] as? Double, 71.8)

        // Today's imported food is on Today.
        tap(app.tabBars.buttons["Today"], in: app)
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 15))
        let oats = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'nutrition.entry.' AND label CONTAINS 'Synthetic Oats'"))
        XCTAssertTrue(oats.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        reveal(oats.firstMatch, in: app)
        capture(app, "mf-09-today")

        // Importing the same file again adds nothing.
        openImport(app, source: "macroFactor")
        tap(app.buttons["import.testFile"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["import.preview"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["import.import"].exists, "Nothing new to import")
        XCTAssertEqual(app.descendants(matching: .any)["import.count.weights"].value as? String, "0 to add, 10 already in Exerly")
        capture(app, "mf-10-again")

        // Undo from the hub removes what the import added, Today's food included.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let undo = app.buttons["import.record.0.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10), app.debugDescription)
        capture(app, "mf-11-hub-record")
        tap(undo, in: app)
        tap(app.alerts.buttons["Undo import"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["import.undoMessage"].waitForExistence(timeout: 20))
        capture(app, "mf-12-undone")
        tap(app.tabBars.buttons["Today"], in: app)
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 15))
        XCTAssertFalse(oats.firstMatch.waitForExistence(timeout: 3), "The imported food is gone")
    }

    /// Profile → Import & export → the source's screen, from wherever the app is.
    private func openImport(_ app: XCUIApplication, source: String) {
        tap(app.tabBars.buttons["Profile"], in: app)
        for _ in 0..<4 where !app.buttons["profile.importExport"].exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            _ = app.buttons["profile.importExport"].waitForExistence(timeout: 3)
        }
        reveal(app.buttons["profile.importExport"], in: app)
        tap(app.buttons["profile.importExport"], in: app)
        tap(app.buttons["import.source.\(source)"], in: app)
    }

    private func launch(export: Data) -> XCUIApplication {
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
        app.launchEnvironment["EXERLY_IMPORT_FILE"] = export.base64EncodedString()
        app.launchEnvironment["EXERLY_IMPORT_FILE_NAME"] = "MacroFactor export.xlsx"
        app.launch()
        return app
    }
}

/// A synthetic MacroFactor export dated around today, in New York. No real
/// person's data. Written as a minimal .xlsx: inline strings and numbers,
/// stored without compression. Sheets and headers follow MacroFactor's
/// export (https://help.macrofactorapp.com/en/articles/356-export-your-data)
/// as recorded in docs/MACROFACTOR.md.
@MainActor
private enum SyntheticExport {
    static func workbook() -> Data {
        let day = { (offset: Int) in ExerlyUITestCase.day(offset).date }
        var foodLog: [[Any]] = [["Date", "Time", "Food Name", "Serving Size", "Serving Qty", "Serving Weight (g)", "Calories (kcal)",
                                 "Protein (g)", "Carbs (g)", "Fat (g)", "Mystery Column"]]
        foodLog.append([day(0), "07:30 AM", "Synthetic Oats", "cup", 1, 80, 300, 10, 54, 5, "x"])
        foodLog.append([day(0), "12:30 PM", "Test Chicken Breast", "g", 150, 150, 248, 46.5, 0, 5.4])
        foodLog.append([day(-1), "7:00 PM", "Fixture Pasta", "cup", 2, 280, 440, 16, 86, 2.6])
        var totals: [[Any]] = [["Date", "Calories (kcal)", "Protein (g)", "Carbs (g)", "Fat (g)"]]
        for offset in 2...9 where offset != 5 { totals.append([day(-offset), 2100 + offset * 15, 150, 220, 70]) }
        var weights: [[Any]] = [["Date", "Weight (kg)", "Fat Percent"]]
        for offset in 1...10 { weights.append([day(-offset), (718 + Double(offset - 1)) / 10, offset % 3 == 0 ? 19.5 : ""]) }
        let workouts: [[Any]] = [
            ["Date", "Workout Duration", "Workout", "Exercise", "Set Type", "Weight (kg)", "Reps", "RIR"],
            [day(-1), 3000, "Push A", "Bench Press (Barbell)", "Warm-Up", 40, 10, ""],
            [day(-1), 3000, "Push A", "Bench Press (Barbell)", "Standard Set", 70, 8, 2],
            [day(-1), 3000, "Push A", "Bench Press (Barbell)", "Standard Set", 70, 7, 1],
            [day(-1), 3000, "Push A", "Synthetic Zercher Hop", "Standard Set", 40, 5, 2],
        ]
        let sheets: [(String, [[Any]])] = [
            ("Food Log", foodLog), ("Calories & Macros", totals), ("Scale Weight", weights), ("Workouts", workouts),
            ("Fasting", [["Date"], [day(-5)]]), ("Food Log Notes", [["Date", "Notes"], [day(-1), "Synthetic note: dinner out"]]),
            ("Weight Trend", [["Date", "Trend Weight (kg)"], [day(-1), 72.0]]),
        ]
        return xlsx(sheets)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func column(_ index: Int) -> String {
        index < 26 ? String(UnicodeScalar(65 + index)!) : column(index / 26 - 1) + column(index % 26)
    }

    private static func xlsx(_ sheets: [(String, [[Any]])]) -> Data {
        var files: [(String, String)] = []
        let list = sheets.enumerated().map { #"<sheet name="\#(escape($1.0))" sheetId="\#($0 + 1)" r:id="rId\#($0 + 1)"/>"# }.joined()
        files.append(("xl/workbook.xml", #"<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\#(list)</sheets></workbook>"#))
        let relationships = sheets.indices.map {
            #"<Relationship Id="rId\#($0 + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#($0 + 1).xml"/>"#
        }.joined()
        files.append(("xl/_rels/workbook.xml.rels", #"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#(relationships)</Relationships>"#))
        for (index, sheet) in sheets.enumerated() {
            var xml = #"<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>"#
            for (rowIndex, row) in sheet.1.enumerated() {
                xml += #"<row r="\#(rowIndex + 1)">"#
                for (columnIndex, value) in row.enumerated() {
                    let reference = "\(column(columnIndex))\(rowIndex + 1)"
                    switch value {
                    case let text as String where text.isEmpty: break
                    case let text as String: xml += #"<c r="\#(reference)" t="inlineStr"><is><t>\#(escape(text))</t></is></c>"#
                    case let number as Int: xml += #"<c r="\#(reference)"><v>\#(number)</v></c>"#
                    case let number as Double: xml += #"<c r="\#(reference)"><v>\#(number)</v></c>"#
                    default: break
                    }
                }
                xml += "</row>"
            }
            files.append(("xl/worksheets/sheet\(index + 1).xml", xml + "</sheetData></worksheet>"))
        }
        return zip(files.map { ($0.0, Array($0.1.utf8)) })
    }

    /// A ZIP archive of stored entries.
    private static func zip(_ files: [(String, [UInt8])]) -> Data {
        var output: [UInt8] = []
        var directory: [UInt8] = []
        func u16(_ value: Int, _ into: inout [UInt8]) { into += [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
        func u32(_ value: Int, _ into: inout [UInt8]) { u16(value & 0xFFFF, &into); u16(value >> 16 & 0xFFFF, &into) }
        for (name, bytes) in files {
            let crc = Int(crc32(bytes)), nameBytes = Array(name.utf8), offset = output.count
            u32(0x0403_4B50, &output); u16(20, &output); u16(0, &output); u16(0, &output); u16(0, &output); u16(0x21, &output)
            u32(crc, &output); u32(bytes.count, &output); u32(bytes.count, &output); u16(nameBytes.count, &output); u16(0, &output)
            output += nameBytes + bytes
            u32(0x0201_4B50, &directory); u16(20, &directory); u16(20, &directory); u16(0, &directory); u16(0, &directory)
            u16(0, &directory); u16(0x21, &directory); u32(crc, &directory); u32(bytes.count, &directory); u32(bytes.count, &directory)
            u16(nameBytes.count, &directory); u16(0, &directory); u16(0, &directory); u16(0, &directory); u16(0, &directory)
            u32(0, &directory); u32(offset, &directory); directory += nameBytes
        }
        let start = output.count
        output += directory
        u32(0x0605_4B50, &output); u16(0, &output); u16(0, &output); u16(files.count, &output); u16(files.count, &output)
        u32(directory.count, &output); u32(start, &output); u16(0, &output)
        return Data(output)
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
