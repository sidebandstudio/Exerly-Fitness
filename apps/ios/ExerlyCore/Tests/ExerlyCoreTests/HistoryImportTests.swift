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

    func plan(_ text: String, name: String = "export.csv", options: HistoryImportReader.Options, hosts: [DocumentHost],
              records: [ImportRecord] = []) throws -> HistoryImportPlan {
        let files = [(name: name, data: Data(text.utf8))]
        let parsed = try HistoryImportReader.read(files, options: options, library: library, now: Fixture.instant())
        return try HistoryImportReader.plan(parsed, files: [name], options: options, hosts: hosts, records: records)
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
        #expect(preview.exercises.first { $0.name == "Dumbbell Bench Press" }?.sets == 3, "The mini-sets are part of the myo set")
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
        #expect(first.units.first == "Weights read in lb: the file doesn't name a unit")
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

    @Test func aDocumentThatArrivedAfterThePreviewMakesItReadAgain() throws {
        let (_, nutrition, training, importer) = try stores()
        let preview = try plan(Self.strong, options: .init(timeZone: Fixture.utc, unit: .kilograms), hosts: [training, nutrition])
        // The same workout synced from another device in the meantime, with a note.
        var synced = try ExerlyJSON.decoder.decode(WorkoutSession.self, from: preview.writes[0].after!)
        synced.notes = "From the other phone"
        try training.importSessions([synced])
        #expect(throws: HistoryImporter.ImportError.stale) { try importer.commit(preview) }
        #expect(training.history.sessions.count == 1, "Nothing saved from the stale preview")
        let again = try plan(Self.strong, options: .init(timeZone: Fixture.utc, unit: .kilograms), hosts: [training, nutrition])
        let record = try importer.commit(again)
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
        let first = try Account()
        try first.importer.commit(try plan(Self.strong, options: .init(timeZone: Fixture.newYork, unit: .kilograms), hosts: first.hosts))
        let toast = Food(name: "=Synthetic, \"toast\"", per100g: NutrientAmounts([.energy: 250, .protein: 9]))
        try first.nutrition.log(toast, grams: 60, on: LocalDate("2026-10-02")!, meal: "Breakfast", at: Fixture.instant())
        try first.nutrition.logWeight(.kg(80.4), bodyFat: 18, at: Fixture.instant(), timeZone: Fixture.newYork)
        try first.nutrition.setStatus(.fasting, on: LocalDate("2026-10-04")!)
        let exported = try first.export()

        let second = try Account()
        let restore = try second.restore(exported)
        #expect(restore.source == .exerly && restore.lines.map(\.new) == [2, 1, 1, 1, 1], "\(restore.lines)")
        #expect(restore.lost.contains("The export was made offline, so it holds what that device had."))
        try second.importer.commit(restore)
        let again = try second.export()

        // The whole export is the same: every document with its kind, ID, revision, payload
        // and sync state, the time zone and units, and the provenance of the imported workouts.
        // Only exported_at could differ (the time each was made); this test's clock is fixed.
        // A restore into an account on a server also gives the server's older tables new row
        // IDs and times; api.portability.test.js checks those.
        func json(_ data: Data) throws -> [String: Any] {
            var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["exported_at"] = nil
            return object
        }
        #expect(NSDictionary(dictionary: try json(exported)).isEqual(to: try json(again)))
        #expect(try ExerlyExportFile(again).documents.count == 6, "Two workouts, a food, a weigh-in, a day and provenance")
        #expect((try json(again)["context"] as? [String: String])?["time_zone"] == "America/New_York")
        // Where the workouts came from comes along, apart from the device's Undo records.
        let upper = try #require(second.training.history.sessions.first)
        #expect(second.provenance.origin(kind: "workout_session", id: upper.id.uuidString)?.source == .strong)
        #expect(try second.importer.records().map(\.source) == [.exerly], "Undo records stay on the device that imported")
        // So are the CSV files and the workbook made from them.
        #expect(try ExportFiles.csvFiles(exported) == ExportFiles.csvFiles(again))
        // Restoring the same export again adds nothing.
        #expect(try second.restore(exported).isEmpty)
    }

    // MARK: Corrected workouts

    /// The same Hevy account exported again after the push day was renamed and
    /// its end time corrected, with a new legs day.
    static let hevyCorrected = WorkoutImportTests.hevy
        .replacingOccurrences(of: #""Push day","5 Oct 2026, 18:00","5 Oct 2026, 19:05""#,
                              with: #""Push day (heavy)","5 Oct 2026, 18:00","5 Oct 2026, 19:20""#)
        + #"""
        "Legs","9 Oct 2026, 07:00","9 Oct 2026, 08:00","","Squat (Barbell)",,"",0,"normal",140,5,,,8

        """#

    @Test func aWorkoutCorrectedInHevyIsUpdatedNotAddedAgain() throws {
        let (_, nutrition, training, importer) = try stores()
        let hosts: [DocumentHost] = [training, nutrition]
        let options = HistoryImportReader.Options(timeZone: Fixture.newYork, unit: .kilograms)
        try importer.commit(try plan(WorkoutImportTests.hevy, options: options, hosts: hosts))
        let benchSets = training.history.sets(of: "barbell-bench-press").count

        let corrected = try plan(Self.hevyCorrected, options: options, hosts: hosts, records: try importer.records())
        #expect(corrected.lines.first == ImportLine(key: "workouts", title: "Workouts", new: 1, existing: 1, updated: 1))
        let record = try importer.commit(corrected)
        #expect(training.history.sessions.map(\.name) == ["Push day (heavy)", "Pull day", "Legs"])
        #expect(training.history.sets(of: "barbell-bench-press").count == benchSets, "No set is added twice")
        let push = try #require(training.history.sessions.first)
        #expect(push.endedAt == Date(timeIntervalSince1970: 1_791_237_600 + 80 * 60))

        // Undo puts the first import's version back.
        try importer.undo(record.id)
        #expect(training.history.sessions.map(\.name) == ["Push day", "Pull day"])
    }

    @Test func aStrongWorkoutRenamedWithANewDurationIsUpdated() throws {
        let (_, nutrition, training, importer) = try stores()
        let options = HistoryImportReader.Options(timeZone: Fixture.newYork, unit: .pounds, leftOut: ["Synthetic Landmine Twist"])
        try importer.commit(try plan(Self.strong, options: options, hosts: [training, nutrition]))
        let renamed = Self.strong.replacingOccurrences(of: "Synthetic Upper,1h 5m", with: "Synthetic Upper Body,1h 20m")
        let corrected = try plan(renamed, options: options, hosts: [training, nutrition], records: try importer.records())
        #expect(corrected.lines.first == ImportLine(key: "workouts", title: "Workouts", new: 0, existing: 1, updated: 1))
        try importer.commit(corrected)
        let upper = try #require(training.history.sessions.first)
        #expect(training.history.sessions.count == 2 && upper.name == "Synthetic Upper Body")
        #expect(upper.endedAt == upper.startedAt.addingTimeInterval(80 * 60))
    }

    @Test func aWorkoutChangedInExerlyIsKeptWhenTheFileChangesItToo() throws {
        let (persistence, nutrition, training, importer) = try stores()
        let hosts: [DocumentHost] = [training, nutrition]
        let options = HistoryImportReader.Options(timeZone: Fixture.newYork, unit: .kilograms)
        try importer.commit(try plan(WorkoutImportTests.hevy, options: options, hosts: hosts))
        var push = try #require(training.history.sessions.first)
        push.notes = "Edited in Exerly"
        try persistence.performAtomically {
            try training.prepareWrite(kind: "workout_session", id: push.id.uuidString, payload: ExerlyJSON.canonical(push))()
        }
        let corrected = try plan(Self.hevyCorrected, options: options, hosts: hosts, records: try importer.records())
        #expect(corrected.lines.first == ImportLine(key: "workouts", title: "Workouts", new: 1, existing: 2))
        #expect(corrected.lost.contains("1 workout you changed in Exerly since the last import is kept as it is."))
        try importer.commit(corrected)
        #expect(training.history.sessions.map(\.notes).first == "Edited in Exerly")
        #expect(training.history.sessions.count == 3)
    }

    // MARK: A daily total and the foods that replace it

    /// MacroFactor's Quick Export: Oct 1 as one daily total of 2000 kcal.
    static let quickExport: [(name: String, rows: [[TestCell]])] = [
        ("Calories & Macros", [[.s("Date"), .s("Calories (kcal)"), .s("Protein (g)")], [.date(46296), .n(2000), .n(140)]]),
    ]
    let october1 = LocalDate("2026-10-01")!

    func macroFactorPlan(_ sheets: [(name: String, rows: [[TestCell]])], hosts: [DocumentHost]) throws -> HistoryImportPlan {
        let options = HistoryImportReader.Options(timeZone: Fixture.newYork, unit: .kilograms)
        let parsed = try HistoryImportReader.read([("MacroFactor.xlsx", try XLSXBuilder(sheets).data())], options: options,
                                                  library: library, now: Fixture.instant())
        return try HistoryImportReader.plan(parsed, files: ["MacroFactor.xlsx"], options: options, hosts: hosts)
    }

    /// Changes an entry as a sync from another device would.
    func edit(_ entry: FoodEntry, grams: Double, in nutrition: NutritionStore, _ persistence: InMemoryTrainingPersistence) throws {
        var changed = entry
        changed.grams = grams
        try persistence.performAtomically {
            try nutrition.prepareWrite(kind: "food_entry", id: entry.id.uuidString, payload: ExerlyJSON.canonical(changed))()
        }
    }

    @Test func aPreviewMadeStaleBySyncIsRebuiltNotSavedOverTheChange() throws {
        let (persistence, nutrition, training, importer) = try stores()
        let hosts: [DocumentHost] = [training, nutrition]
        try importer.commit(try macroFactorPlan(Self.quickExport, hosts: hosts))
        let granular = try macroFactorPlan(MacroFactorFixture.sheets, hosts: hosts)
        #expect(granular.writes.contains { $0.after == nil && $0.group == "food/2026-10-01" }, "The food log replaces Oct 1's total")
        // Another device changes Oct 1's total before this preview is imported.
        let total = try #require(nutrition.entries(on: october1).first { $0.food.name == MacroFactorExport.dayTotalName })
        try edit(total, grams: 110, in: nutrition, persistence)
        let documents = persistence.documents
        #expect(throws: HistoryImporter.ImportError.stale) { try importer.commit(granular) }
        #expect(persistence.documents == documents, "Nothing saved from the stale preview")
        // Read again, the import replaces the changed total too, so Oct 1 counts once.
        try importer.commit(try macroFactorPlan(MacroFactorFixture.sheets, hosts: hosts))
        #expect(!nutrition.entries(on: october1).contains { $0.food.name == MacroFactorExport.dayTotalName })
        #expect(close(nutrition.summary(on: october1).totals.energy, 738))
    }

    @Test func undoNeverBringsBackATotalBesideFoodsThatReplacedIt() throws {
        let (persistence, nutrition, training, importer) = try stores()
        let hosts: [DocumentHost] = [training, nutrition]
        try importer.commit(try macroFactorPlan(Self.quickExport, hosts: hosts))
        let granular = try importer.commit(try macroFactorPlan(MacroFactorFixture.sheets, hosts: hosts))
        #expect(close(nutrition.summary(on: october1).totals.energy, 738))
        // One of Oct 1's imported foods is corrected in Exerly.
        let oats = try #require(nutrition.entries(on: october1).first { $0.food.name != MacroFactorExport.dayTotalName })
        try edit(oats, grams: oats.grams * 2, in: nutrition, persistence)
        let corrected = nutrition.summary(on: october1).totals.energy

        let undone = try importer.undo(granular.id)
        #expect(undone.keptGroups == ["food/2026-10-01"])
        #expect(!nutrition.entries(on: october1).contains { $0.food.name == MacroFactorExport.dayTotalName },
                "Oct 1 stays as imported, with the correction, and without its old total")
        #expect(close(nutrition.summary(on: october1).totals.energy, corrected))
        #expect(nutrition.entries.allSatisfy { $0.date == october1 }, "Other days are undone")
    }

    // MARK: Body measurements

    /// The app's measurement log, as `ImportedMeasurementStore` sees it.
    @MainActor
    final class FakeMeasurements: ImportedMeasurementStore {
        var saved: [String: ImportedMeasurement] = [:]
        var failing = false

        func existing(_ clientIDs: [String]) -> Set<String> { Set(clientIDs.filter { saved[$0] != nil }) }

        func add(_ measurements: [ImportedMeasurement]) throws {
            if failing { throw DocumentError(message: "Synthetic: the measurement log can't be written") }
            for measurement in measurements { saved[measurement.clientID] = measurement }
        }

        func remove(_ measurements: [ImportedMeasurement]) throws -> (removed: Int, kept: Int) {
            var removed = 0, kept = 0
            for measurement in measurements {
                if saved[measurement.clientID] == measurement {
                    saved[measurement.clientID] = nil
                    removed += 1
                } else if saved[measurement.clientID] != nil {
                    kept += 1
                }
            }
            return (removed, kept)
        }
    }

    /// MacroFactor's Body Metrics sheet, as docs/MACROFACTOR.md records its sites.
    static let bodyMetrics: [(name: String, rows: [[TestCell]])] = [
        ("Body Metrics", [[.s("Date"), .s("Waist (cm)"), .s("Left Bicep (in)"), .s("Abdomen (cm)"), .s("Visual Body Fat Assessment (%)")],
                          [.date(46296), .n(82.5), .n(14), .n(90), .n(18)],
                          [.date(46303), .n(81.8), .empty, .empty, .empty]]),
    ]

    /// Hevy's measurement_data.csv: one row a day with `_cm` sites.
    /// Format: https://github.com/200ok-ch/hevy_measurements_visualizer and
    /// https://thetaperapp.com/articles/how-to-export-hevy-data/ (Export Measurements).
    static let hevyMeasurements = #"""
    "date","weight_kg","fat_percent","neck_cm","shoulder_cm","chest_cm","left_bicep_cm","right_bicep_cm","abdomen_cm","waist_cm"
    "1 Oct 2026, 07:00",80.2,18.5,38,118,102,35.5,35.0,88,84
    "8 Oct 2026, 07:00",,17.9,,,,,,,83.2

    """#

    /// Strong's measurement export, one file a measurement. Format:
    /// https://thetaperapp.com/articles/how-to-export-strong-data/ (Export Measurements).
    static let strongWaist = "Date,Measurement Type,Value,Unit,Source\n2026-10-01 07:00:00,Waist,33.0,in,Strong\n"
    static let strongWeight = "Date,Measurement Type,Value,Unit,Source\n2026-10-01 07:00:00,Weight,176.4,lbs,Strong\n"
    static let strongBodyFat = "Date,Measurement Type,Value,Unit,Source\n2026-10-01 07:00:00,Body Fat,18.0,%,Strong\n"

    @Test func macroFactorBodyMetricsJoinTheMeasurementsAsOneUnitAndUndo() throws {
        let (persistence, nutrition, training, _) = try stores()
        let store = FakeMeasurements()
        let importer = HistoryImporter(hosts: [training, nutrition], persistence: persistence, measurements: store, now: { Fixture.instant() })
        let options = HistoryImportReader.Options(timeZone: Fixture.newYork, unit: .kilograms)
        let parsed = try HistoryImportReader.read([("MacroFactor.xlsx", try XLSXBuilder(MacroFactorFixture.sheets + Self.bodyMetrics).data())],
                                                  options: options, library: library, now: Fixture.instant())
        let preview = try HistoryImportReader.plan(parsed, files: ["MacroFactor.xlsx"], options: options, hosts: [training, nutrition],
                                                   measurements: store)
        #expect(preview.lines.first { $0.key == "measurements" } == ImportLine(key: "measurements", title: "Body measurements", new: 4))
        #expect(preview.lost.contains { $0.contains("Abdomen") }, "\(preview.lost)")
        let bicep = try #require(preview.measurements.first { $0.site == .leftBicep })
        #expect(abs(bicep.value - 35.56) < 0.001, "14 in")
        #expect(preview.measurements.contains { $0.site == .bodyFat && $0.value == 18 })

        // The measurement log fails: nothing is saved anywhere.
        store.failing = true
        #expect(throws: DocumentError.self) { try importer.commit(preview) }
        let records = try importer.records()
        #expect(nutrition.entries.isEmpty && store.saved.isEmpty && records.isEmpty)

        store.failing = false
        let record = try importer.commit(preview)
        #expect(store.saved.count == 4 && record.measurements?.count == 4 && nutrition.weights.count == 4)
        let again = try HistoryImportReader.plan(parsed, files: ["MacroFactor.xlsx"], options: options, hosts: [training, nutrition],
                                                 records: try importer.records(), measurements: store)
        #expect(again.measurements.isEmpty && again.lines.first { $0.key == "measurements" }?.existing == 4)

        // A waist corrected in Exerly is kept by Undo; the rest go.
        let waist = try #require(store.saved.values.first { $0.site == .waist && $0.date == october1 })
        store.saved[waist.clientID]?.value = 83
        let undone = try importer.undo(record.id)
        #expect(store.saved.map(\.value.value) == [83] && undone.kept == 1)
        #expect(nutrition.weights.isEmpty)
    }

    @Test func hevyMeasurementsGiveWeighInsWithBodyFatAndSites() throws {
        let (persistence, nutrition, training, _) = try stores()
        let store = FakeMeasurements()
        let importer = HistoryImporter(hosts: [training, nutrition], persistence: persistence, measurements: store, now: { Fixture.instant() })
        #expect(HistoryImportReader.detect(Data(Self.hevyMeasurements.utf8)) == .hevy)
        let options = HistoryImportReader.Options(timeZone: Fixture.newYork, unit: .pounds)
        let parsed = try HistoryImportReader.read([("measurement_data.csv", Data(Self.hevyMeasurements.utf8))], options: options, library: library)
        let preview = try HistoryImportReader.plan(parsed, files: ["measurement_data.csv"], options: options, hosts: [training, nutrition],
                                                   measurements: store)
        #expect(preview.source == .hevy)
        #expect(preview.lines.map(\.key) == ["weights", "measurements"])
        #expect(preview.measurements.map(\.site).sorted { $0.rawValue < $1.rawValue }
                == [.bodyFat, .chest, .leftBicep, .neck, .rightBicep, .shoulders, .waist, .waist], "Body fat alone on Oct 8")
        #expect(preview.lost == ["abdomen_cm: 1 value of a measurement Exerly doesn't keep"])
        try importer.commit(preview)
        let weight = try #require(nutrition.weights.first)
        #expect(weight.weight == .kg(80.2) && weight.bodyFat == 18.5 && weight.source == .hevy && weight.date == october1)
    }

    @Test func strongMeasurementFilesReadTheirOwnUnits() throws {
        let (_, nutrition, training, _) = try stores()
        let store = FakeMeasurements()
        let files = [Self.strongWaist, Self.strongWeight, Self.strongBodyFat].enumerated().map { ("strong_\($0.offset).csv", Data($0.element.utf8)) }
        #expect(files.allSatisfy { HistoryImportReader.detect($0.1) == .strong })
        let options = HistoryImportReader.Options(timeZone: Fixture.newYork, unit: .kilograms)
        let parsed = try HistoryImportReader.read(files, options: options, library: library)
        let preview = try HistoryImportReader.plan(parsed, files: files.map(\.0), options: options, hosts: [training, nutrition],
                                                   measurements: store)
        let waist = try #require(preview.measurements.first { $0.site == .waist })
        #expect(abs(waist.value - 83.82) < 0.001 && preview.measurements.contains { $0.site == .bodyFat && $0.value == 18 })
        let weight = try ExerlyJSON.decoder.decode(WeightEntry.self, from: try #require(preview.writes.first?.after))
        #expect(weight.weight == .lb(176.4) && weight.source == .strong)
    }

    /// Every store an account has, sharing one database, as the app's workspace does.
    @MainActor
    struct Account {
        let persistence: InMemoryTrainingPersistence
        let training: TrainingStore
        let nutrition: NutritionStore
        let programs: ProgramStore
        let gyms: GymStore
        let provenance: ProvenanceStore
        var hosts: [DocumentHost] { [training, programs, nutrition, gyms, provenance] }
        var importer: HistoryImporter { HistoryImporter(hosts: hosts, persistence: persistence, now: { Fixture.instant() }) }

        init() throws {
            persistence = InMemoryTrainingPersistence()
            training = try TrainingStore(persistence: persistence, now: { Fixture.instant() })
            nutrition = try NutritionStore(persistence: persistence, now: { Fixture.instant() })
            programs = try ProgramStore(persistence: persistence, training: training, now: { Fixture.instant() })
            gyms = try GymStore(persistence: persistence, now: { Fixture.instant() })
            provenance = try ProvenanceStore(persistence: persistence)
        }

        func export() throws -> Data {
            try AccountExport.merging(server: nil, hosts: hosts, state: persistence,
                                      context: .init(timeZone: Fixture.newYork, unit: .kilograms), now: Fixture.instant())
        }

        func restore(_ export: Data) throws -> HistoryImportPlan {
            let options = HistoryImportReader.Options(timeZone: Fixture.utc, unit: .kilograms)
            let parsed = try HistoryImportReader.read([("exerly-export.json", export)], options: options, library: training.library)
            return try HistoryImportReader.plan(parsed, files: ["exerly-export.json"], options: options, hosts: hosts)
        }
    }

    @Test func anExportWithCustomExercisesProgramsAndGymsRestoresAndUndoes() throws {
        let first = try Account()
        let zercher = Exercise(id: "custom-synthetic-zercher-squat", name: "Synthetic Zercher Squat", aliases: [], metric: .weightReps,
                               mechanics: .compound, region: .lower, muscles: [.quads: 1, .glutes: 1], equipment: [.barbell], support: [.rack])
        try first.training.addCustomExercise(zercher)
        try first.training.importSessions([Fixture.session([("custom-synthetic-zercher-squat", [Fixture.set(5, 100)])])])
        let program = Program(name: "Synthetic block", days: [
            ProgramDay(name: "A", slots: [ProgramSlot(exerciseID: "custom-synthetic-zercher-squat",
                                                      target: SlotTarget(sets: 3, minReps: 5, maxReps: 8, rir: 2))]),
        ], cycles: 3, deload: .last)
        try first.programs.save(program)
        try first.gyms.save(GymProfile(name: "Synthetic garage", equipment: [.barbell, .rack]))
        let export = try first.export()

        let second = try Account()
        let restore = try second.restore(export)
        #expect(restore.lines.map(\.key) == ["custom_exercise", "workout_session", "program", "gym_profile"])
        let record = try second.importer.commit(restore)
        #expect(second.training.library.exercise("custom-synthetic-zercher-squat")?.name == "Synthetic Zercher Squat")
        #expect(second.training.history.sessions.count == 1 && second.programs.programs.map(\.name) == ["Synthetic block"])
        #expect(second.gyms.gyms.map(\.name) == ["Synthetic garage"])
        let restored = try ExerlyExportFile(second.export()).documents.map(\.payload)
        let original = try ExerlyExportFile(export).documents.map(\.payload)
        #expect(Set(restored) == Set(original), "The same documents, byte for byte")

        // Undo removes the workout, program and gym. The custom exercise stays: exercises are never deleted.
        let undone = try second.importer.undo(record.id)
        #expect(undone.undone == 3 && undone.keptExercises == 1)
        #expect(second.training.history.sessions.isEmpty && second.programs.programs.isEmpty && second.gyms.gyms.isEmpty)
        #expect(second.training.library.exercise("custom-synthetic-zercher-squat") != nil)
    }

    /// An export as the server sends it: documents of every kind the phone
    /// keeps, and the server's older tables, one of them a single object.
    func serverExport(_ account: Account) throws -> Data {
        var export = try JSONSerialization.jsonObject(with: try account.export()) as? [String: Any] ?? [:]
        export["measurements"] = [["id": 7, "client_id": "synthetic-waist", "type": "waist", "value": 80.5, "unit": "cm",
                                   "entry_date": "2026-10-01", "source": "manual"]]
        export["water"] = [["id": 3, "entry_date": "2026-10-01", "amount_ml": 500]]
        export["sleep"] = [Any]()
        export["goals"] = ["calories": 2200, "protein": 150]
        export["account"] = ["name": "Synthetic", "email": "synthetic@exerly.test", "timezone": "America/New_York"]
        return try JSONSerialization.data(withJSONObject: export)
    }

    /// The server's import endpoints, answering as `POST /v1/import` and `/v1/import/undo` do.
    final class FakeServer: SessionTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [(path: String, body: Data?)] = []
        var reachable = true

        var requests: [(path: String, body: Data?)] { lock.withLock { sent } }

        func send(_ method: String, path: String, body: Data?, headers: [String: String], as accountID: String) async throws
            -> (status: Int, data: Data) {
            lock.withLock { sent.append((path, body)) }
            guard lock.withLock({ reachable }) else { throw URLError(.notConnectedToInternet) }
            switch path {
            case "/v1/import":
                let json: [String: Any] = ["imported": 0, "kept": 0, "skipped": [Any](), "ignored_tables": [Any](),
                                           "restored": [["table": "measurements", "id": "row-7", "revision": 1],
                                                        ["table": "water", "id": "row-3", "revision": 1]],
                                           "not_restored": [String: String]()]
                return (200, try JSONSerialization.data(withJSONObject: json))
            case "/v1/import/undo": return (200, Data(#"{"removed":2,"kept":0}"#.utf8))
            default: return (404, Data())
            }
        }
    }

    @Test func aRestoreSendsTheServersTablesThroughTheAccountAndIsBothOrNeither() async throws {
        let first = try Account()
        try first.importer.commit(try plan(Self.strong, options: .init(timeZone: Fixture.newYork, unit: .kilograms), hosts: first.hosts))
        let export = try serverExport(first)
        let second = try Account()
        let restore = try second.restore(export)
        #expect(restore.lines.filter { $0.key.hasPrefix("server/") }.map(\.key) == ["server/goals", "server/measurements", "server/water"])
        #expect(restore.lost.contains("Account details and settings stay with the account they came from."))
        let server = FakeServer()
        let api = AccountAPI(accountID: "synthetic-second", transport: server)

        // The account can't be reached: nothing is kept.
        server.reachable = false
        await #expect(throws: HistoryImporter.ImportError.self) { try await second.importer.commit(restore, api: api) }
        #expect(second.training.history.sessions.isEmpty && second.provenance.provenance.isEmpty)
        #expect(try second.importer.records().isEmpty)

        server.reachable = true
        let record = try await second.importer.commit(restore, api: api)
        #expect(second.training.history.sessions.count == 2)
        #expect(record.serverRows?.map(\.id) == ["row-7", "row-3"])
        let body = try #require(server.requests.last?.body)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(sent.keys) == ["exported_at", "version", "goals", "measurements", "water"], "Only the older tables go to the server")

        let undone = try await second.importer.undo(record.id, api: api)
        #expect(server.requests.last?.path == "/v1/import/undo")
        #expect(undone.undone == 2 + 3, "Two rows on the server; two workouts and their provenance here")
        #expect(second.training.history.sessions.isEmpty && second.provenance.provenance.isEmpty)
    }

    @Test func everyKindOfDocumentAndEveryServerTableHasACSVAndASheet() throws {
        let account = try Account()
        try account.training.addCustomExercise(Exercise(id: "custom-synthetic-press", name: "Synthetic Press", aliases: [], metric: .weightReps,
                                                        mechanics: .compound, region: .upper, muscles: [.chest: 1], equipment: [.barbell]))
        var session = Fixture.session([("custom-synthetic-press", [Fixture.set(5, 60)])])
        session.notes = "Synthetic session note"
        session.exercises[0].notes = "Synthetic exercise note"
        try account.training.importSessions([session])
        try account.programs.save(Program(name: "Synthetic block", days: [
            ProgramDay(name: "A", slots: [ProgramSlot(exerciseID: "deadlift", target: SlotTarget(sets: 3, minReps: 3, maxReps: 5, rir: 2))]),
        ], cycles: 2, deload: .last))
        try account.gyms.save(GymProfile(name: "Synthetic garage"))
        let oats = try account.nutrition.log(Food(name: "Synthetic oats", per100g: NutrientAmounts([.energy: 380])), grams: 80,
                                             on: LocalDate("2026-10-01")!, meal: "Breakfast", at: Fixture.instant())
        try account.nutrition.hideSuggestion(oats.food)
        let export = try serverExport(account)

        let json = try #require(try JSONSerialization.jsonObject(with: export) as? [String: Any])
        let kinds = Set(((json["documents"] as? [[String: Any]]) ?? []).compactMap { $0["kind"] as? String })
        #expect(kinds.isSuperset(of: ["custom_exercise", "workout_session", "program", "gym_profile", "food_entry", "hidden_suggestion"]))
        let tables = try ExportFiles.tables(export)
        let names = Set(tables.map(\.name))
        let text = tables.map { $0.rows.flatMap { $0 }.joined(separator: "\u{1F}") }.joined(separator: "\u{1E}")
        for row in (json["documents"] as? [[String: Any]]) ?? [] {
            let id = try #require(row["document_id"] as? String)
            #expect(text.contains(id), "\(row["kind"] ?? "") \(id) is in a table")
        }
        for table in ["measurements", "water", "goals", "account"] { #expect(names.contains(table), "\(table) has a table") }
        #expect(!names.contains("sleep"), "An empty table has no file")
        #expect(text.contains("synthetic-waist") && text.contains("2200"))
        #expect(text.contains("Synthetic session note") && text.contains("Synthetic exercise note"))

        let csv = Set(try ExportFiles.csvFiles(export).map(\.name))
        #expect(csv == Set(names.map { "\($0).csv" }))
        let sheets = try Spreadsheet.read(ExportFiles.workbook(tables), name: "export").sheets.map(\.name)
        #expect(Set(sheets) == names, "The workbook has the same tables")
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
