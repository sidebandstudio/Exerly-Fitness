import Foundation
import Testing
@testable import ExerlyCore

@MainActor
@Suite struct SQLitePersistenceTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("exerlycore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var url: URL { directory.appendingPathComponent("exerly.sqlite") }

    func sampleSession(days: Double = 0) -> WorkoutSession {
        var drop = Fixture.set(8, 100, kind: .drop, rir: 0)
        drop.efforts.append(Effort(reps: 5, load: .lb(135)))
        var session = Fixture.session(days: days, zone: Fixture.newYork, [
            ("back-squat", [Fixture.set(5, 60, kind: .warmUp), Fixture.set(5, 100, rir: 2)]),
            ("barbell-bench-press", [drop]),
            ("plank", [PerformedSet(efforts: [Effort(duration: 62.5)], completedAt: Fixture.instant(minutes: 30))]),
        ])
        session.notes = "Synthetic session ✓"
        session.exercises[0].supersetID = UUID()
        session.exercises[1].supersetID = session.exercises[0].supersetID
        return session
    }

    @Test func roundTripsSessionsAndCustomExercisesAcrossReopening() throws {
        let session = sampleSession()
        let custom = Exercise(
            id: .custom(), name: "Zercher Squat", aliases: ["Zercher"], metric: .weightReps, mechanics: .compound,
            region: .lower, muscles: [.quads: 1, .glutes: 1, .midBack: 0.5], equipment: [.barbell], support: [.rack]
        )
        do {
            let store = try SQLiteTrainingPersistence(url: url)
            try store.save(session)
            try store.save(custom)
        }
        let reopened = try SQLiteTrainingPersistence(url: url)
        #expect(try reopened.loadSessions() == [session])
        #expect(try reopened.loadCustomExercises() == [custom])
        #expect(reopened.unreadableRows.isEmpty)
    }

    @Test func savingReplacesByIDAndDeleteRemoves() throws {
        let store = try SQLiteTrainingPersistence(url: url)
        var session = sampleSession()
        try store.save(session)
        session.name = "Renamed"
        session.endedAt = Fixture.instant(minutes: 90)
        try store.save(session)
        try store.save(sampleSession(days: 2))
        let loaded = try store.loadSessions()
        #expect(loaded.count == 2)
        #expect(loaded.first { $0.id == session.id }?.name == "Renamed")
        try store.deleteSession(session.id)
        #expect(try store.loadSessions().map(\.id) != [session.id])
        #expect(try store.loadSessions().count == 1)
        try store.deleteSession(UUID())
    }

    @Test func recordsTheSchemaVersionAndRefusesANewerOne() throws {
        do {
            let store = try SQLiteTrainingPersistence(url: url)
            #expect(try store.schemaVersion() == SQLiteTrainingPersistence.currentSchemaVersion)
        }
        let database = try SQLiteDatabase(url: url)
        try database.execute("PRAGMA user_version = \(SQLiteTrainingPersistence.currentSchemaVersion + 1)")
        #expect(throws: SQLiteTrainingPersistence.PersistenceError.self) { try SQLiteTrainingPersistence(url: url) }
    }

    @Test func upgradesAVersionOneFileWithoutLosingSessions() throws {
        let session = sampleSession()
        do {
            let store = try SQLiteTrainingPersistence(url: url)
            try store.save(session)
        }
        let database = try SQLiteDatabase(url: url)
        try database.executeScript("DROP TABLE documents; DROP TABLE sync_bases; DROP TABLE settings; PRAGMA user_version = 1;")
        let upgraded = try SQLiteTrainingPersistence(url: url)
        #expect(try upgraded.schemaVersion() == SQLiteTrainingPersistence.currentSchemaVersion)
        #expect(try upgraded.loadSessions() == [session])
        try upgraded.saveValue(Data("x".utf8), forKey: "k")
        #expect(try upgraded.loadValue(forKey: "k") == Data("x".utf8))
    }

    /// A version-four file gains the tombstone's agreed version, and keeps its bases.
    @Test func aTombstoneKeepsTheVersionAgreedOnBeforeIt() throws {
        do {
            let store = try SQLiteTrainingPersistence(url: url)
            try store.saveSyncBase(SyncBase(kind: "food_entry", id: "A", revision: 2, payload: Data("{}".utf8)))
        }
        let database = try SQLiteDatabase(url: url)
        try database.executeScript("ALTER TABLE sync_bases DROP COLUMN previous; PRAGMA user_version = 4;")
        let upgraded = try SQLiteTrainingPersistence(url: url)
        #expect(try upgraded.syncBases() == [SyncBase(kind: "food_entry", id: "A", revision: 2, payload: Data("{}".utf8))])
        let tombstone = SyncBase(kind: "food_entry", id: "A", revision: 3, previous: Data("{}".utf8))
        try upgraded.saveSyncBase(tombstone)
        #expect(try upgraded.syncBases() == [tombstone])
    }

    @Test func storesAndRemovesSmallValues() throws {
        let store = try SQLiteTrainingPersistence(url: url)
        #expect(try store.loadValue(forKey: "training.restTimer") == nil)
        try store.saveValue(Data("a".utf8), forKey: "training.restTimer")
        try store.saveValue(Data("b".utf8), forKey: "training.restTimer")
        #expect(try SQLiteTrainingPersistence(url: url).loadValue(forKey: "training.restTimer") == Data("b".utf8))
        try store.saveValue(nil, forKey: "training.restTimer")
        #expect(try store.loadValue(forKey: "training.restTimer") == nil)
    }

    @Test func reportsUnreadableRowsWithoutLosingTheRest() throws {
        let good = sampleSession()
        do {
            let store = try SQLiteTrainingPersistence(url: url)
            try store.save(good)
        }
        let database = try SQLiteDatabase(url: url)
        try database.execute(
            "INSERT INTO sessions (id, started_at, ended_at, payload, updated_at) VALUES (?, 0, NULL, ?, 0)",
            "broken-row", Data("{not json".utf8)
        )
        let store = try SQLiteTrainingPersistence(url: url)
        #expect(try store.loadSessions() == [good])
        #expect(store.unreadableRows == ["sessions/broken-row"])
    }

    @Test func drivesATrainingStoreAcrossARelaunch() throws {
        do {
            let store = try TrainingStore(persistence: SQLiteTrainingPersistence(url: url), now: { Fixture.instant() })
            try store.startSession(name: "Persisted", bodyweight: .kg(80))
            let squat = try store.addExercise("back-squat")
            var set = store.activeSession!.exercises[0].sets[0]
            set.primary = Effort(reps: 5, load: .kg(100))
            try store.updateSet(set, in: squat)
            try store.completeSet(set.id)
        }
        let relaunched = try TrainingStore(persistence: SQLiteTrainingPersistence(url: url), now: { Fixture.instant(minutes: 50) })
        #expect(relaunched.activeSession?.exercises[0].sets[0].isCompleted == true)
        try relaunched.finishSession()
        let again = try TrainingStore(persistence: SQLiteTrainingPersistence(url: url))
        #expect(again.activeSession == nil)
        #expect(again.history.sessions.count == 1)
        #expect(again.history.statistics(of: "back-squat")?.totalVolume == 500)
    }

    @Test func loadsAYearsOfHeavyTrainingQuickly() throws {
        let store = try SQLiteTrainingPersistence(url: url)
        let sets = (0..<25).map { _ in Fixture.set(8, 100, rir: 2) }
        try store.performAtomically {
            for day in 0..<1_000 {
                var session = Fixture.session(days: Double(day), [("back-squat", Array(sets[0..<9])),
                                                                  ("barbell-bench-press", Array(sets[9..<17])),
                                                                  ("barbell-row", Array(sets[17..<25]))])
                session.id = UUID()
                try store.save(session)
            }
        }
        let clock = ContinuousClock()
        var loaded: [WorkoutSession] = []
        let elapsed = try clock.measure { loaded = try SQLiteTrainingPersistence(url: url).loadSessions() }
        #expect(loaded.count == 1_000)
        #expect(elapsed < .seconds(2), "loading 1,000 sessions took \(elapsed)")
        let history = clock.measure { _ = TrainingHistory(sessions: loaded, library: Fixture.library) }
        #expect(history < .seconds(1), "indexing took \(history)")
    }
}
