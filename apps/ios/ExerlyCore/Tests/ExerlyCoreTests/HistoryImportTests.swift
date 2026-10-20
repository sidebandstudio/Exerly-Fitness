import Foundation
import Testing
@testable import ExerlyCore

/// Importing history from each app through the preview, the one-unit save and
/// Undo, and the export's round trip. Every fixture is synthetic and follows
/// the app's publicly documented export format; none is anyone's real data.
@MainActor
@Suite struct HistoryImportTests {
    let library = ExerciseLibrary.bundled
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    // MARK: Fixtures

    /// MacroFactor Workouts' Workout Log (More → Data Export → Granular Export
    /// → Workout Log), one row per set. Format: MacroFactor's help centre,
    /// https://help.macrofactorapp.com/en/articles/356-export-your-data, and the
    /// header of the public sample in
    /// https://github.com/matanabudy/workout-data-sync/blob/main/examples/macrofactor_export.csv
    static let macroFactorWorkouts = #"""
    "Date","Workout Duration","Workout","Exercise","Exercise Base Weight (kg)","Set Type","Weight (kg)","Reps","RIR","Duration","Distance short (m)","Distance long (km)"
    "2026-10-05","3600","Synthetic Push","Dumbbell Bench Press",,"Warm-Up Set","20.0","10",,,,
    "2026-10-05","3600","Synthetic Push","Dumbbell Bench Press",,"Standard Set","30.0","10","2",,,
    "2026-10-05","3600","Synthetic Push","Dumbbell Bench Press",,"Myo Set","30.0","12","1",,,
    "2026-10-05","3600","Synthetic Push","Dumbbell Bench Press",,"Mini-set","30.0","4","1",,,
    "2026-10-05","3600","Synthetic Push","Dumbbell Bench Press",,"Mini-set","30.0","3","0",,,
    "2026-10-05","3600","Synthetic Push","Synthetic Neutral Grip Fly",,"Standard Set","15.0","15","3",,,
    "2026-10-07","1800","Synthetic Cardio","Running",,"Standard Set",,,,"1500",,"5"

    """#

    /// Strong's CSV (Settings → Export Strong Data), one row per set, in the
    /// older layout whose Weight column has no unit. Format: Strong's help
    /// centre, https://help.strongapp.io/article/235-export-workout-data, with
    /// the columns listed at https://griptapp.com/help/export-workouts-from-strong
    static let strong = #"""
    Date,Workout Name,Duration,Exercise Name,Set Order,Weight,Reps,Distance,Seconds,Notes,Workout Notes,RPE
    2026-10-01 18:30:00,Synthetic Upper,1h 5m,Bench Press (Barbell),W,95,10,,,,Synthetic session,
    2026-10-01 18:30:00,Synthetic Upper,1h 5m,Bench Press (Barbell),1,185,5,,,,Synthetic session,8
    2026-10-01 18:30:00,Synthetic Upper,1h 5m,Bench Press (Barbell),Rest Timer,,,,120,,Synthetic session,
    2026-10-01 18:30:00,Synthetic Upper,1h 5m,Bench Press (Barbell),2,185,5,,,,Synthetic session,9
    2026-10-01 18:30:00,Synthetic Upper,1h 5m,Synthetic Landmine Twist,1,45,12,,,,Synthetic session,
    2026-10-03 23:30:00,Synthetic Late Legs,45m,Squat (Barbell),1,225,5,,,,,

    """#

    /// Hevy's workout_data file (Profile → Settings → Export & Import Data →
    /// Export Workouts), here tab-separated with pound and mile columns.
    /// Format: https://griptapp.com/help/export-workouts-from-hevy and
    /// https://thetaperapp.com/articles/how-to-export-hevy-data/
    static let hevyTabs = [
        ["title", "start_time", "end_time", "description", "exercise_title", "superset_id", "exercise_notes", "set_index", "set_type",
         "weight_lbs", "reps", "distance_miles", "duration_seconds", "rpe"],
        ["Synthetic Pull", "6 Oct 2026, 07:00", "6 Oct 2026, 07:50", "", "Bent Over Row (Barbell)", "", "", "0", "normal", "135", "8", "", "", "8"],
        ["Synthetic Pull", "6 Oct 2026, 07:00", "6 Oct 2026, 07:50", "", "Running", "", "", "0", "normal", "", "", "2", "1200", ""],
    ].map { $0.joined(separator: "\t") }.joined(separator: "\n")

    func stores() throws -> (InMemoryTrainingPersistence, NutritionStore, TrainingStore, HistoryImporter) {
        let persistence = InMemoryTrainingPersistence()
        let nutrition = try NutritionStore(persistence: persistence, now: { Fixture.instant() })
        let training = try TrainingStore(persistence: persistence, now: { Fixture.instant() })
        return (persistence, nutrition, training, HistoryImporter(hosts: [training, nutrition], persistence: persistence, now: { Fixture.instant() }))
    }

    func plan(_ text: String, name: String = "export.csv", options: HistoryImportReader.Options, hosts: [DocumentHost]) throws -> HistoryImportPlan {
        let files = [(name: name, data: Data(text.utf8))]
        let parsed = try HistoryImportReader.read(files, options: options, library: library, now: Fixture.instant())
        return try HistoryImportReader.plan(parsed, files: [name], options: options, hosts: hosts)
    }

    // MARK: Detection

    @Test func eachAppsExportIsRecognisedByItsContents() {
        #expect(HistoryImportReader.detect(Data(Self.macroFactorWorkouts.utf8)) == .macroFactorWorkouts)
        #expect(HistoryImportReader.detect(Data(Self.strong.utf8)) == .strong)
        #expect(HistoryImportReader.detect(Data(Self.hevyTabs.utf8)) == .hevy)
        #expect(HistoryImportReader.detect(Data(WorkoutImportTests.hevy.utf8)) == .hevy)
        #expect(HistoryImportReader.detect(Data("Date,Food Name,Calories (kcal)\n".utf8)) == .macroFactor)
        #expect(HistoryImportReader.detect(Data([0x50, 0x4B, 0x03, 0x04])) == .macroFactor)
        #expect(HistoryImportReader.detect(Data(#"{"exported_at":"2026-10-20T00:00:00.000Z","documents":[]}"#.utf8)) == .exerly)
        #expect(HistoryImportReader.detect(Data("colour,shape\nred,round\n".utf8)) == nil)
        #expect(HistoryImportReader.detect(Data(#"{"name":"not an export"}"#.utf8)) == nil)
        #expect(throws: HistoryImportReader.ReadError.mixed([.hevy, .strong])) {
            try HistoryImportReader.read([("a.csv", Data(Self.strong.utf8)), ("b.csv", Data(Self.hevyTabs.utf8))],
                                         options: .init(timeZone: Fixture.utc, unit: .kilograms), library: library)
        }
    }

    // MARK: MacroFactor Workouts

    @Test func macroFactorWorkoutsPreviewsSetsMyoRepsAndWhatIsLeftOut() throws {
        let (_, nutrition, training, importer) = try stores()
        let options = HistoryImportReader.Options(timeZone: Fixture.newYork, unit: .pounds)
        let preview = try plan(Self.macroFactorWorkouts, options: options, hosts: [training, nutrition])
        #expect(preview.source == .macroFactorWorkouts)
        #expect(preview.lines.map(\.key) == ["workouts", "sets"])
        #expect(preview.lines.first { $0.key == "workouts" }?.new == 2)
        #expect(preview.dateRange == LocalDate("2026-10-05")!...LocalDate("2026-10-07")!)
        #expect(preview.exercisesInOrder.map(\.name) == ["Synthetic Neutral Grip Fly", "Dumbbell Bench Press", "Running"])
        #expect(preview.exercisesInOrder.first?.how == .unmatched && preview.exercisesInOrder.first?.sets == 1)
        #expect(preview.lost.contains { $0.contains("Exercise Base Weight") }, "\(preview.lost)")
        #expect(preview.lost.contains { $0.hasPrefix("1 set of 1 exercise Exerly has no match for") })
        #expect(preview.units.contains { $0.contains("America/New_York") })
        #expect(preview.writes.isEmpty == false && training.history.sessions.isEmpty, "Nothing is saved by a preview")

        // Mini-sets continue the myo set, as one set of three efforts.
        let mapped = try plan(Self.macroFactorWorkouts, options: .init(timeZone: Fixture.newYork, unit: .pounds,
                                                                        mapping: ["Synthetic Neutral Grip Fly": "dumbbell-fly"]),
                              hosts: [training, nutrition])
        #expect(mapped.exercises.allSatisfy { $0.how != .unmatched } && !mapped.lost.contains { $0.contains("no match") })
        let record = try importer.commit(mapped)
        let push = try #require(training.history.sessions.first)
        let bench = try #require(push.exercises.first)
        #expect(bench.exerciseID == "dumbbell-bench-press" && bench.sets.map(\.kind) == [.warmUp, .standard, .myo])
        #expect(bench.sets[2].efforts.map(\.reps) == [12, 4, 3] && bench.sets[2].efforts.allSatisfy { $0.load == .kg(30) })
        #expect(push.exercises[1].exerciseID == "dumbbell-fly")
        #expect(push.startedAt == Date(timeIntervalSince1970: 1_791_216_000), "Midday in New York on Oct 5")
        #expect(record.added == 2 && record.source == .macroFactorWorkouts)
    }

    // MARK: Strong

    @Test func strongImportsWithTheChosenUnitAMappingAndALeftOutExerciseThenUndoes() throws {
        let (persistence, nutrition, training, importer) = try stores()
        let hosts: [DocumentHost] = [training, nutrition]
        var options = HistoryImportReader.Options(timeZone: Fixture.newYork, unit: .pounds)
        let first = try plan(Self.strong, options: options, hosts: hosts)
        #expect(first.source == .strong && first.assumedWeightUnit == .pounds)
        #expect(first.units.first == "Weights in lb, assumed: the file doesn't say")
        #expect(first.lost.contains("1 rest timer. Exerly times rest itself during a workout."))
        #expect(first.approximated.contains("RPE becomes reps in reserve: RPE 8 is 2 reps in reserve."))
        #expect(first.exercisesInOrder.first == ExerciseMatch(name: "Synthetic Landmine Twist", sets: 1, exerciseID: nil, how: .unmatched))

        // The weights were kilograms after all, the twist is left out, and the squat is a front squat.
        options.unit = .kilograms
        options.leftOut = ["Synthetic Landmine Twist"]
        options.mapping = ["Squat (Barbell)": "front-squat"]
        let chosen = try plan(Self.strong, options: options, hosts: hosts)
        #expect(chosen.assumedWeightUnit == .kilograms)
        #expect(chosen.exercises.first { $0.name == "Synthetic Landmine Twist" }?.how == .leftOut)
        #expect(chosen.exercises.first { $0.name == "Squat (Barbell)" } == ExerciseMatch(name: "Squat (Barbell)", sets: 1,
                                                                                            exerciseID: "front-squat", how: .chosen))
        #expect(chosen.lines == [ImportLine(key: "workouts", title: "Workouts", new: 2), ImportLine(key: "exercises", title: "Exercises", new: 2),
                                 ImportLine(key: "sets", title: "Sets", new: 4)])
        let record = try importer.commit(chosen)
        #expect(training.history.sessions.count == 2)
        let upper = training.history.sessions[0]
        #expect(upper.exercises.map(\.exerciseID) == ["barbell-bench-press"])
        #expect(upper.exercises[0].sets.map(\.primary.load) == [.kg(95), .kg(185), .kg(185)])
        #expect(upper.exercises[0].sets.map(\.rir) == [nil, 2, 1])
        // 23:30 in New York is already the next day in UTC, but the workout's day is the 3rd.
        let late = training.history.sessions[1]
        #expect(late.localDate == LocalDate("2026-10-03") && late.timeZoneID == "America/New_York")
        #expect(late.startedAt == Date(timeIntervalSince1970: 1_791_084_600))
        #expect(try importer.records().map(\.id) == [record.id])

        // Again: nothing new, and saving it changes nothing.
        let again = try plan(Self.strong, options: options, hosts: hosts)
        #expect(again.isEmpty && again.lines.first == ImportLine(key: "workouts", title: "Workouts", new: 0, existing: 2))
        let sessions = persistence.sessions
        try importer.commit(again)
        #expect(persistence.sessions == sessions)

        // Undo removes exactly what the import added.
        let manual = Fixture.session(days: 2, [("deadlift", [Fixture.set(5, 140, at: Fixture.instant(days: 2))])])
        try training.importSessions([manual])
        let undo = try importer.undo(record.id)
        #expect(undo == .init(undone: 2, kept: 0))
        #expect(training.history.sessions.map(\.id) == [manual.id], "Only the workout logged in Exerly is left")
        #expect(try importer.records().first?.undoneAt != nil)
        #expect(throws: HistoryImporter.ImportError.alreadyUndone) { try importer.undo(record.id) }
        // And it can be imported again afterwards.
        let afterUndo = try plan(Self.strong, options: options, hosts: hosts)
        #expect(afterUndo.lines.first?.new == 2)
    }

    @Test func undoKeepsWhatWasEditedSinceTheImport() throws {
        let (persistence, nutrition, training, importer) = try stores()
        let options = HistoryImportReader.Options(timeZone: Fixture.utc, unit: .kilograms, leftOut: ["Synthetic Landmine Twist"])
        let record = try importer.commit(try plan(Self.strong, options: options, hosts: [training, nutrition]))
        var edited = training.history.sessions[0]
        edited.notes = "Edited in Exerly"
        try persistence.performAtomically { try training.prepareWrite(kind: "workout_session", id: edited.id.uuidString,
                                                                      payload: ExerlyJSON.canonical(edited))() }
        let undo = try importer.undo(record.id)
        #expect(undo == .init(undone: 1, kept: 1))
        #expect(training.history.sessions.map(\.notes) == ["Edited in Exerly"])
    }

    @Test func theTimeZoneReadsTheSameRowsAsDifferentInstants() throws {
        let (_, nutrition, training, _) = try stores()
        let newYork = try plan(Self.strong, options: .init(timeZone: Fixture.newYork, unit: .pounds), hosts: [training, nutrition])
        let japan = try plan(Self.strong, options: .init(timeZone: tokyo, unit: .pounds), hosts: [training, nutrition])
        let decode = { (plan: HistoryImportPlan) in try plan.writes.map { try ExerlyJSON.decoder.decode(WorkoutSession.self, from: $0.after!) } }
        let a = try decode(newYork), b = try decode(japan)
        #expect(a.map(\.localDate) == b.map(\.localDate), "The same calendar days")
        #expect(zip(a, b).allSatisfy { $0.startedAt.timeIntervalSince($1.startedAt) == 13 * 3600 })
        #expect(b.allSatisfy { $0.timeZoneID == "Asia/Tokyo" } && japan.units.last == "Times read in Asia/Tokyo: the file has no time zone")
    }

    // MARK: Hevy

    @Test func aTabSeparatedHevyExportReadsItsPoundAndMileColumns() throws {
        let (_, nutrition, training, importer) = try stores()
        let preview = try plan(Self.hevyTabs, name: "workout_data.tsv", options: .init(timeZone: Fixture.utc, unit: .kilograms),
                               hosts: [training, nutrition])
        #expect(preview.source == .hevy && preview.assumedWeightUnit == nil)
        #expect(preview.units.prefix(2) == ["Weights in lb, from the \u{201C}weight_lbs\u{201D} column",
                                            "Distances in miles, from the \u{201C}distance_miles\u{201D} column"])
        try importer.commit(preview)
        let session = try #require(training.history.sessions.first)
        #expect(session.exercises[0].sets[0].primary.load == .lb(135))
        #expect(abs((session.exercises[1].sets[0].primary.distance ?? 0) - 2 * 1609.344) < 0.001)
    }

    // MARK: One unit

    @Test func anImportThatCantAllBeSavedSavesNothing() throws {
        let persistence = InMemoryTrainingPersistence()
        let nutrition = try NutritionStore(persistence: persistence, now: { Fixture.instant() })
        let training = try TrainingStore(persistence: persistence, now: { Fixture.instant() })
        let importer = HistoryImporter(hosts: [training, nutrition], persistence: persistence)
        var broken = try plan(Self.strong, options: .init(timeZone: Fixture.utc, unit: .kilograms), hosts: [training, nutrition])
        broken.writes.append(PlannedWrite(kind: "weight_entry", id: UUID().uuidString, before: nil, after: Data(#"{"nonsense":true}"#.utf8)))
        #expect(throws: (any Error).self) { try importer.commit(broken) }
        #expect(training.history.sessions.isEmpty && persistence.sessions.isEmpty && nutrition.weights.isEmpty)
        #expect(try importer.records().isEmpty, "No record of an import that didn't happen")
    }

    @Test func aDocumentThatArrivedAfterThePreviewIsKept() throws {
        let (_, nutrition, training, importer) = try stores()
        let preview = try plan(Self.strong, options: .init(timeZone: Fixture.utc, unit: .kilograms), hosts: [training, nutrition])
        // The same workout synced from another device in the meantime, with a note.
        var synced = try ExerlyJSON.decoder.decode(WorkoutSession.self, from: preview.writes[0].after!)
        synced.notes = "From the other phone"
        try training.importSessions([synced])
        let record = try importer.commit(preview)
        #expect(record.added == 1 && training.history.session(synced.id)?.notes == "From the other phone")
    }

    @Test func importsBelongToTheirAccount() throws {
        let (_, nutrition, training, importer) = try stores()
        try importer.commit(try plan(Self.strong, options: .init(timeZone: Fixture.utc, unit: .kilograms), hosts: [training, nutrition]))
        let (_, otherNutrition, otherTraining, other) = try stores()
        #expect(try other.records().isEmpty && otherTraining.history.sessions.isEmpty && otherNutrition.entries.isEmpty)
        #expect(try importer.records().count == 1)
    }

    // MARK: MacroFactor nutrition

    @Test func aMacroFactorWorkbookPreviewsEveryKindAndUndoesExactly() throws {
        let (persistence, nutrition, training, importer) = try stores()
        let workbook = try XLSXBuilder(MacroFactorFixture.sheets).data()
        let options = HistoryImportReader.Options(timeZone: Fixture.newYork, unit: .kilograms)
        let parsed = try HistoryImportReader.read([("MacroFactor export.xlsx", workbook)], options: options, library: library,
                                                  now: Fixture.instant())
        let preview = try HistoryImportReader.plan(parsed, files: ["MacroFactor export.xlsx"], options: options, hosts: [training, nutrition])
        #expect(preview.source == .macroFactor)
        #expect(preview.lines.map(\.key) == ["entries", "dayTotals", "days", "weights", "foods", "plans", "workouts", "sets"])
        #expect(preview.lines.first { $0.key == "weights" }?.new == 4)
        #expect(preview.units.first == "Weigh-ins in kg, from the column headers")
        // A day Exerly already has, so Undo has something to put back.
        try nutrition.setStatus(.partial, on: LocalDate("2026-09-28")!)
        let before = persistence.documents
        let record = try importer.commit(preview)
        #expect(nutrition.entries.count == 8 && nutrition.weights.count == 4 && training.history.sessions.count == 2)
        #expect(record.changes.contains { $0.kind == "nutrition_day" && $0.before == nil })
        try importer.undo(record.id)
        var after = persistence.documents
        after[HistoryImporter.recordKind] = nil
        #expect(after.filter { !$0.value.isEmpty } == before.filter { !$0.value.isEmpty }, "Exactly as before the import")
        #expect(training.history.sessions.isEmpty && nutrition.entries.isEmpty && nutrition.day(LocalDate("2026-09-28")!).status == .partial)
    }

    // MARK: Export

    @Test func anExportRestoredIntoAFreshAccountExportsTheSameData() throws {
        // An account with imported workouts, logged food, a weigh-in, a day and targets.
        let (persistence, nutrition, training, importer) = try stores()
        try importer.commit(try plan(Self.strong, options: .init(timeZone: Fixture.newYork, unit: .kilograms), hosts: [training, nutrition]))
        let toast = Food(name: "=Synthetic, \"toast\"", per100g: NutrientAmounts([.energy: 250, .protein: 9]))
        try nutrition.log(toast, grams: 60, on: LocalDate("2026-10-02")!, meal: "Breakfast", at: Fixture.instant())
        try nutrition.logWeight(.kg(80.4), bodyFat: 18, at: Fixture.instant(), timeZone: Fixture.newYork)
        try nutrition.setStatus(.fasting, on: LocalDate("2026-10-04")!)
        let context = AccountExport.Context(timeZone: Fixture.newYork, unit: .kilograms)
        let first = try AccountExport.merging(server: nil, hosts: [training, nutrition], state: persistence, context: context,
                                              imports: try importer.records(), now: Fixture.instant())

        func documents(_ export: Data) throws -> [String: String] {
            let json = try #require(try JSONSerialization.jsonObject(with: export) as? [String: Any])
            let rows = try #require(json["documents"] as? [[String: Any]])
            return Dictionary(uniqueKeysWithValues: try rows.map { row in
                ("\(row["kind"]!)/\(row["document_id"]!)",
                 try #require(String(bytes: try JSONSerialization.data(withJSONObject: row["payload"]!, options: .sortedKeys), encoding: .utf8)))
            })
        }
        let (freshPersistence, freshNutrition, freshTraining, freshImporter) = try stores()
        let options = HistoryImportReader.Options(timeZone: Fixture.utc, unit: .pounds)
        let parsed = try HistoryImportReader.read([("exerly-export.json", first)], options: options, library: library)
        let restore = try HistoryImportReader.plan(parsed, files: ["exerly-export.json"], options: options,
                                                   hosts: [freshTraining, freshNutrition])
        #expect(restore.source == .exerly && restore.lines.map(\.new) == [2, 1, 1, 1])
        #expect(restore.lost.contains("The export was made offline, so it holds what that device had."))
        try freshImporter.commit(restore)
        let second = try AccountExport.merging(server: nil, hosts: [freshTraining, freshNutrition], state: freshPersistence, context: context,
                                               now: Fixture.instant())

        // The documents are identical: kind, ID and payload. Documented differences:
        // exported_at, revisions (a fresh account hasn't synced) and the imports list.
        #expect(try documents(first) == documents(second))
        #expect(try documents(first).count == 5, "Two workouts, a food, a weigh-in and a day")
        // So are the tables, the CSV files and the workbook made from them.
        #expect(try ExportFiles.csvFiles(first) == ExportFiles.csvFiles(second))
        let json = try #require(try JSONSerialization.jsonObject(with: second) as? [String: Any])
        #expect((json["context"] as? [String: String])?["time_zone"] == "America/New_York")
        #expect((json["context"] as? [String: String])?["mass_unit"] == "kg")
        let firstJSON = try #require(try JSONSerialization.jsonObject(with: first) as? [String: Any])
        #expect((firstJSON["imports"] as? [[String: Any]])?.first?["source"] as? String == "strong", "Provenance")
        // Restoring the same export again adds nothing.
        let again = try HistoryImportReader.plan(try HistoryImportReader.read([("exerly-export.json", first)], options: options, library: library),
                                                 files: [], options: options, hosts: [freshTraining, freshNutrition])
        #expect(again.isEmpty)
    }

    @Test func theCSVFilesKeepIDsUnitsUnknownsAndEscapeFormulas() throws {
        let (persistence, nutrition, training, _) = try stores()
        let toast = Food(name: "=Synthetic, \"toast\"", per100g: NutrientAmounts([.energy: 250, .protein: 9]))
        let entry = try nutrition.log(toast, grams: 60, on: LocalDate("2026-10-02")!, meal: "Breakfast", at: Fixture.instant())
        let weight = try nutrition.logWeight(.lb(177.2), at: Fixture.instant(), timeZone: Fixture.newYork)
        try training.importSessions([Fixture.session([("deadlift", [Fixture.set(5, 140)])])])
        let export = try AccountExport.merging(server: nil, hosts: [training, nutrition], state: persistence, now: Fixture.instant())
        let tables = Dictionary(uniqueKeysWithValues: try ExportFiles.tables(export).map { ($0.name, $0.rows) })
        #expect(Set(tables.keys) == ["food_entries", "weigh_ins", "sets"])
        let food = try #require(tables["food_entries"])
        let row = Dictionary(uniqueKeysWithValues: zip(food[0], food[1]))
        #expect(row["id"] == entry.id.uuidString && row["date"] == "2026-10-02" && row["grams"] == "60")
        #expect(row["energy_kcal"] == "150" && row["protein_g"] == "5.4" && row["sodium_mg"] == "", "Unknown is empty, never 0")
        let weighIn = try #require(tables["weigh_ins"])
        #expect(Dictionary(uniqueKeysWithValues: zip(weighIn[0], weighIn[1]))["unit"] == "lb")
        #expect(Dictionary(uniqueKeysWithValues: zip(weighIn[0], weighIn[1]))["id"] == weight.id.uuidString)
        let csvFile = try #require(try ExportFiles.csvFiles(export).first { $0.name == "food_entries.csv" })
        let csv = try #require(String(bytes: csvFile.data, encoding: .utf8))
        #expect(csv.contains(#""'=Synthetic, ""toast""""#), "Quoted, with the formula defused")
        #expect(csv.hasSuffix("\r\n"))

        // The workbook reads back with the same cells.
        let sheets = try Spreadsheet.read(ExportFiles.workbook(try ExportFiles.tables(export)), name: "export").sheets
        let sheet = try #require(sheets.first { $0.name == "food_entries" })
        #expect(sheet.rows.count == food.count)
        #expect(sheet.rows[1].cells.first == .text(entry.id.uuidString))
        let bundle = try ExportFiles.bundle(export, date: LocalDate("2026-10-20")!)
        #expect(bundle.name == "exerly-export-2026-10-20.zip")
        let text = String(bytes: bundle.data, encoding: .isoLatin1) ?? ""
        for name in ["exerly-export-2026-10-20.json", "csv/food_entries.csv", "exerly-export-2026-10-20.xlsx", "README.txt"] {
            #expect(text.contains(name), "\(name) is in the zip")
        }
        #expect(ExportFiles.crc32(Data("123456789".utf8)) == 0xCBF4_3926, "The standard CRC-32 check value")
    }
}
