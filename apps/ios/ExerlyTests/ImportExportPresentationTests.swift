import ExerlyCore
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
                                                hosts: [mine.store, mine.programs, mine.nutrition, mine.gyms, mine.agent])
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
        XCTAssertEqual((json["imports"] as? [[String: Any]])?.first?["source"] as? String, "strong")
        let sets = try XCTUnwrap(try ExportFiles.tables(export).first { $0.name == "sets" })
        XCTAssertEqual(sets.rows.count, 3, "A header and two sets")

        let undone = try reopened.importer.undo(record.id)
        XCTAssertEqual(undone, .init(undone: 2, kept: 0))
        XCTAssertTrue(reopened.store.history.sessions.isEmpty)
        XCTAssertTrue(try TrainingWorkspace(accountID: "import-mine", root: root).store.history.sessions.isEmpty, "Undone on disk too")
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
