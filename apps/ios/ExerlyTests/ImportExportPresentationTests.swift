import ExerlyCore
import SwiftData
import XCTest
@testable import Exerly

/// Imports and exports through an account's real on-device database: one
/// unit across its stores, Undo, other accounts untouched, and the export's
/// time zone, units and provenance.
@MainActor
final class ImportExportPresentationTests: XCTestCase {
    /// A Strong export in its unitless layout (https://help.strongapp.io/article/235-export-workout-data). Synthetic.
    private let strong = """
    Date,Workout Name,Duration,Exercise Name,Set Order,Weight,Reps,Distance,Seconds,Notes,Workout Notes,RPE
    2026-10-01 18:30:00,Synthetic Upper,1h 5m,Bench Press (Barbell),1,185,5,,,,,8
    2026-10-03 07:00:00,Synthetic Legs,45m,Squat (Barbell),1,225,5,,,,,
    """

    func testAnImportSavesIntoItsAccountAndUndoesThere() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let mine = try TrainingWorkspace(accountID: "import-mine", root: root)
        let other = try TrainingWorkspace(accountID: "import-other", root: root)
        let options = HistoryImportReader.Options(timeZone: TimeZone(identifier: "America/New_York")!, unit: .pounds)
        let parsed = try HistoryImportReader.read([("strong.csv", Data(strong.utf8))], options: options, library: mine.store.library)
        let plan = try HistoryImportReader.plan(parsed, files: ["strong.csv"], options: options,
                                                hosts: mine.documentHosts)
        let record = try mine.importer.commit(plan)
        XCTAssertEqual(mine.store.history.sessions.map(\.name), ["Synthetic Upper", "Synthetic Legs"])
        XCTAssertTrue(other.store.history.sessions.isEmpty)
        XCTAssertTrue(try other.importer.records().isEmpty, "Another account never sees this import")

        // Reopened from disk, the import and its record are there.
        let reopened = try TrainingWorkspace(accountID: "import-mine", root: root)
        XCTAssertEqual(reopened.store.history.sessions.count, 2)
        XCTAssertEqual(try reopened.importer.records().map(\.id), [record.id])

        let export = try reopened.export(server: nil, context: .init(timeZone: TimeZone(identifier: "America/New_York")!, unit: .pounds))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: export) as? [String: Any])
        XCTAssertEqual((json["context"] as? [String: String])?["mass_unit"], "lb")
        let documents = try XCTUnwrap(json["documents"] as? [[String: Any]])
        let provenance = documents.first { $0["kind"] as? String == "import_provenance" }?["payload"] as? [String: Any]
        XCTAssertEqual(provenance?["source"] as? String, "strong", "Where the workouts came from is in the export")
        let sets = try XCTUnwrap(try ExportFiles.tables(export).first { $0.name == "sets" })
        XCTAssertEqual(sets.rows.count, 3, "A header and two sets")

        let undone = try reopened.importer.undo(record.id)
        XCTAssertEqual(undone, .init(undone: 2, kept: 0), "Two workouts; where they came from goes too, uncounted")
        XCTAssertTrue(reopened.provenance.provenance.isEmpty)
        XCTAssertTrue(reopened.store.history.sessions.isEmpty)
        XCTAssertTrue(try TrainingWorkspace(accountID: "import-mine", root: root).store.history.sessions.isEmpty, "Undone on disk too")
    }

    func testImportedMeasurementsSaveWithTheirIDsAndUndoKeepsACorrectedOne() throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "exerly.tests.\(UUID().uuidString)"))
        let api = APIClient(baseURL: "https://fixture.exerly.test", session: URLSession(configuration: config),
                            keychain: MemoryCredentials(), defaults: defaults)
        let container = try ModelContainer(for: Schema(versionedSchema: ExerlySchemaV3.self),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false, observeClock: false)
        engine.configure(container: container, accountID: "measurements-a", timeZone: "UTC")
        XCTAssertNil(ImportedMeasurementLog(sync: engine, accountID: "measurements-b"), "Never another account's log")
        let log = try XCTUnwrap(ImportedMeasurementLog(sync: engine, accountID: "measurements-a"))
        let date = try XCTUnwrap(LocalDate("2026-10-01"))
        let waist = ImportedMeasurement(site: .waist, value: 82.5, date: date, source: .macroFactor)
        let fat = ImportedMeasurement(site: .bodyFat, value: 18, date: date, source: .macroFactor)
        try log.add([waist, fat])
        XCTAssertEqual(log.states([waist.clientID, fat.clientID, "other"]), [waist.clientID: waist.state, fat.clientID: fat.state])
        let rows = try engine.pendingExportRows().filter { $0.table == "measurements" }
        XCTAssertEqual(Set(rows.map(\.clientID)), [waist.clientID, fat.clientID])
        let row = try XCTUnwrap(rows.first { $0.clientID == waist.clientID }?.row)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: row) as? [String: Any])
        XCTAssertEqual(json["source"] as? String, "imported")
        XCTAssertEqual(json["note"] as? String, "From MacroFactor")

        // A value corrected in the source app updates the log while it's as imported.
        var corrected = waist
        corrected.value = 83
        let change = ImportedMeasurementChange(measurement: corrected, from: 82.5)
        XCTAssertEqual(try log.update([change]).updated, 1)
        XCTAssertEqual(log.states([waist.clientID])[waist.clientID]?.value, 83)
        XCTAssertEqual(try log.update([change]).kept, 1, "No longer 82.5, so it's kept")

        let outcome = try log.remove([waist, fat])
        XCTAssertEqual(outcome.removed, 1)
        XCTAssertEqual(outcome.kept, 1, "The waist differs from what's in the log, so it's kept")
        XCTAssertEqual(log.states([waist.clientID, fat.clientID]).filter { !$0.value.deleted }.mapValues(\.value), [waist.clientID: 83])
    }

    /// A measurement log on an in-memory store, answering through `handler`.
    private func measurementLog(signedIn: Bool = false) throws -> (Exerly.SyncEngine, ImportedMeasurementLog) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "exerly.tests.\(UUID().uuidString)"))
        let credentials = MemoryCredentials()
        if signedIn { credentials.saveSession(token: "e30.eyJzdWIiOiJtZWFzdXJlbWVudHMtYSJ9.fixture", refreshToken: "fixture-refresh") }
        let api = APIClient(baseURL: "https://fixture.exerly.test", session: URLSession(configuration: config),
                            keychain: credentials, defaults: defaults)
        let container = try ModelContainer(for: Schema(versionedSchema: ExerlySchemaV3.self),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false, observeClock: false)
        engine.configure(container: container, accountID: "measurements-a", timeZone: "UTC")
        return (engine, try XCTUnwrap(ImportedMeasurementLog(sync: engine, accountID: "measurements-a")))
    }

    func testAnImportedMeasurementMovedToAnotherDayIsAnEditUndoAndCorrectionsKeep() async throws {
        let (engine, log) = try measurementLog()
        let waist = ImportedMeasurement(site: .waist, value: 82, date: try XCTUnwrap(LocalDate("2026-10-01")), source: .macroFactor)
        try log.add([waist])
        // Moved to Oct 2 in the measurement editor, 82 cm unchanged.
        let cached = try await engine.measurements(from: "2026-09-01", to: "2026-10-31", cachedOnly: true)
        let record = try XCTUnwrap(cached.first { $0.client_id == waist.clientID })
        try engine.saveMeasurement(BodyMeasurementRequest(type: record.type, value: record.value, unit: "cm", entry_date: "2026-10-02",
                                                          note: record.note, source: record.source ?? "manual"), editing: record)

        var corrected = waist
        corrected.value = 83
        XCTAssertEqual(try log.update([ImportedMeasurementChange(measurement: corrected, from: 82)]).kept, 1,
                       "A correction leaves the day it was moved to")
        let outcome = try log.remove([waist])
        XCTAssertEqual(outcome.removed, 0)
        XCTAssertEqual(outcome.kept, 1, "Undo keeps it: moving it was an edit")
        let state = try XCTUnwrap(log.states([waist.clientID])[waist.clientID])
        XCTAssertEqual([state.date, String(state.value)], ["2026-10-02", "82.0"])
        XCTAssertFalse(state.deleted)
        XCTAssertEqual(engine.pendingCount, 2, "Its creation and the edit; no deletion queued")
    }

    func testARemovalTakenBackOrImportedAgainIsRestoredNotCreatedTwice() async throws {
        let (engine, log) = try measurementLog(signedIn: true)
        let waist = ImportedMeasurement(site: .waist, value: 82, date: try XCTUnwrap(LocalDate("2026-10-01")), source: .macroFactor)
        var requests: [String] = []
        var revision = 0
        StubURLProtocol.handler = { request in
            let path = try XCTUnwrap(request.url?.path)
            if path == "/api/sync" { return (200, Data(#"{"changes":[],"cursor":0,"has_more":false}"#.utf8)) }
            let method = try XCTUnwrap(request.httpMethod)
            requests.append("\(method) \(path)")
            revision += 1
            var row: [String: Any] = ["id": "m1", "client_id": waist.clientID, "revision": revision, "type": "waist", "value": 82,
                                      "unit": "cm", "entry_date": "2026-10-01", "note": "From MacroFactor", "source": "imported"]
            row["deleted_at"] = method == "DELETE" ? "2026-10-21T00:00:00.000Z" : NSNull()
            if method == "PUT" { row["value"] = 83 }
            return (200, try JSONSerialization.data(withJSONObject: row))
        }
        try log.add([waist])
        await engine.synchronize(force: true)
        XCTAssertEqual(requests, ["POST /api/measurements"])

        // An Undo whose record couldn't be saved takes back a deletion never sent.
        XCTAssertEqual(try log.remove([waist]).removed, 1)
        try log.restore([waist])
        XCTAssertEqual(engine.pendingCount, 0, "The deletion is cancelled, not followed by a new measurement")
        await engine.synchronize(force: true)
        XCTAssertEqual(requests, ["POST /api/measurements"])

        // A deletion already sent is reversed with the server's restore.
        _ = try log.remove([waist])
        await engine.synchronize(force: true)
        try log.restore([waist])
        await engine.synchronize(force: true)
        XCTAssertEqual(Array(requests.dropFirst()), ["DELETE /api/measurements/m1", "POST /api/measurements/m1/restore"])

        // Undo, then the file imported again with a corrected value: restored, then changed.
        _ = try log.remove([waist])
        await engine.synchronize(force: true)
        var corrected = waist
        corrected.value = 83
        try log.add([corrected])
        await engine.synchronize(force: true)
        XCTAssertEqual(Array(requests.dropFirst(3)), ["DELETE /api/measurements/m1", "POST /api/measurements/m1/restore",
                                                      "PUT /api/measurements/m1"])
        XCTAssertEqual(engine.pendingCount, 0)
        XCTAssertEqual(log.states([waist.clientID])[waist.clientID]?.value, 83)
    }

    func testExportFilesAreWrittenForSharingAndRemovedAfter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try ExportShareFile(ExportFiles.File(name: "exerly-export-2026-10-20.zip", data: Data([1, 2, 3])), directory: directory)
        XCTAssertEqual(file.url.lastPathComponent, "exerly-export-2026-10-20.zip")
        XCTAssertEqual(try Data(contentsOf: file.url), Data([1, 2, 3]))
        file.remove()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testSetupsBringYourHistoryOpensImportOnceForThatAccount() {
        BringHistory.remember(accountID: "bring-a", true)
        XCTAssertFalse(BringHistory.isOn(accountID: "bring-b"))
        XCTAssertTrue(BringHistory.take(accountID: "bring-a"))
        XCTAssertFalse(BringHistory.take(accountID: "bring-a"), "Only once")
    }

    func testUndoNamesTheDaysItKeptWholeAndTheExercisesItKept() {
        let result = HistoryImporter.UndoResult(undone: 9, kept: 4, keptExercises: 1)
        var days = result
        days.keptGroups = ["food/2026-10-01"]
        XCTAssertEqual(ImportCopy.undone(days), "9 items removed or put back. Food on Oct 1 stays as imported, because you changed it since; "
                       + "the daily total it replaced isn't brought back beside it. 1 custom exercise stays in your library.")
    }

    func testUndoSaysWhatItKept() {
        XCTAssertEqual(ImportCopy.undone(.init(undone: 2, kept: 0)), "2 items removed or put back.")
        XCTAssertEqual(ImportCopy.undone(.init(undone: 1, kept: 1)),
                       "1 item removed or put back. 1 you changed since was kept.")
    }
}
