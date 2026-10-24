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
        try database.executeScript("DROP TABLE sync_changes; DROP TABLE documents; DROP TABLE sync_bases; DROP TABLE settings; PRAGMA user_version = 1;")
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
        try database.executeScript("DROP TABLE sync_changes; ALTER TABLE sync_bases DROP COLUMN previous; PRAGMA user_version = 4;")
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

/// Review round 3, finding 1: a write and the record that sync must push it
/// are one unit, for every kind of write, with no transaction around them.
@MainActor
@Suite struct ChangeRecordTests {
    struct Crash: Error {}

    @Test(arguments: [false, true])
    func aWriteAndItsChangeRecordPersistTogetherOrNotAtAll(sqlite: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("exerly.sqlite")
        let memory = InMemoryTrainingPersistence()
        let disk: TrainingPersistence & DocumentPersistence & SyncStateStore = sqlite ? try SQLiteTrainingPersistence(url: url) : memory
        func crashing(_ on: Bool) {
            let hook: (() throws -> Void)? = on ? { throw Crash() } : nil
            if let store = disk as? SQLiteTrainingPersistence { store.beforeRecordingChange = hook } else { memory.beforeRecordingChange = hook }
        }
        try disk.trustChanges(token: "t")
        let session = Fixture.session([("barbell-bench-press", [Fixture.set(5, 100)])])
        let exercise = Exercise(id: "custom-synthetic-sled-push", name: "Synthetic Sled Push", aliases: [], metric: .weightReps,
                                mechanics: .compound, region: .lower, muscles: [.quads: 1], equipment: [.sled], support: [])
        let writes: [(name: String, write: () throws -> Void, exists: () throws -> Bool, ref: DocumentRef)] = [
            ("session", { try disk.save(session) }, { try disk.loadSessions().contains { $0.id == session.id } },
             DocumentRef(kind: TrainingStore.sessionKind, id: session.id.uuidString)),
            ("exercise", { try disk.save(exercise) }, { try disk.loadCustomExercises().contains { $0.id == exercise.id } },
             DocumentRef(kind: TrainingStore.exerciseKind, id: exercise.id.rawValue)),
            ("document", { try disk.saveDocument(kind: "food_entry", id: "A", payload: Data("{}".utf8)) },
             { try !disk.loadDocuments(kind: "food_entry").isEmpty }, DocumentRef(kind: "food_entry", id: "A")),
        ]
        for item in writes {
            crashing(true)
            #expect(throws: Crash.self) { try item.write() }
            #expect(try !item.exists() && disk.changedDocuments(token: "t")?.contains(item.ref) == false,
                    "\(item.name): a write survived without its change record")
            crashing(false)
            try item.write()
            #expect(try item.exists() && disk.changedDocuments(token: "t")?.contains(item.ref) == true)
            try disk.markUnchanged(kind: item.ref.kind, id: item.ref.id)
        }
        let deletions: [(name: String, delete: () throws -> Void, exists: () throws -> Bool, ref: DocumentRef)] = [
            ("session", { try disk.deleteSession(session.id) }, writes[0].exists, writes[0].ref),
            ("document", { try disk.deleteDocument(kind: "food_entry", id: "A") }, writes[2].exists, writes[2].ref),
        ]
        for item in deletions {
            crashing(true)
            #expect(throws: Crash.self) { try item.delete() }
            #expect(try item.exists(), "\(item.name): a deletion survived without its change record")
            crashing(false)
            try item.delete()
            #expect(try !item.exists() && disk.changedDocuments(token: "t")?.contains(item.ref) == true)
        }
    }
}

/// Review round 3, finding 4: two opens of an older file at once, as the app
/// and a background read can, both bring it up to date without an error.
@Suite struct RacingMigrationTests {
    @Test func twoOpensOfASchemaFourFileAtOnceBothSucceed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for round in 0..<20 {
            let url = directory.appendingPathComponent("race-\(round).sqlite")
            try SQLiteTrainingPersistence.migrate(url: url)
            let old = try SQLiteDatabase(url: url)
            try old.executeScript("DROP TABLE sync_changes; ALTER TABLE sync_bases DROP COLUMN previous; PRAGMA user_version = 4;")
            old.close()
            let failures = Failures()
            DispatchQueue.concurrentPerform(iterations: 2) { _ in
                do { try SQLiteTrainingPersistence.migrate(url: url) } catch { failures.add("\(error)") }
            }
            #expect(failures.all.isEmpty, "Round \(round): \(failures.all)")
            let migrated = try SQLiteDatabase(url: url)
            #expect(try SQLiteTrainingPersistence.schemaVersion(migrated) == SQLiteTrainingPersistence.currentSchemaVersion)
            migrated.close()
        }
    }

    final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var errors: [String] = []
        func add(_ error: String) { lock.withLock { errors.append(error) } }
        var all: [String] { lock.withLock { errors } }
    }
}

/// Review round 5: noting a background read's unreadable rows is linear,
/// and each row is noted once whatever the letter case of its ID.
@MainActor
@Suite struct NotedUnreadableRowTests {
    @Test func manyUnreadableRowsAreNotedOnceAndQuickly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = try SQLiteTrainingPersistence(url: directory.appendingPathComponent("exerly.sqlite"))
        let id = UUID().uuidString
        disk.noteUnreadable(["sessions/\(id.lowercased())", "sessions/\(id)"])
        #expect(disk.unreadableRows == ["sessions/\(id)"])
        // Four times the rows take about four times as long, not sixteen.
        func timed(_ count: Int) throws -> TimeInterval {
            let fresh = try SQLiteTrainingPersistence(url: directory.appendingPathComponent("\(count).sqlite"))
            let rows = (0..<count).map { _ in "sessions/\(UUID().uuidString)" }
            let started = Date()
            fresh.noteUnreadable(rows + rows)
            let took = Date().timeIntervalSince(started)
            #expect(fresh.unreadableRows.count == count)
            return took
        }
        let small = try timed(5_000), large = try timed(20_000)
        #expect(large / small < 8, "5,000 rows took \(small) s and 20,000 took \(large) s")
        let rows = (0..<3).map { _ in "sessions/\(UUID().uuidString)" }
        disk.noteUnreadable(rows)
        #expect(disk.isUnreadable(kind: TrainingStore.sessionKind, id: rows[0].replacingOccurrences(of: "sessions/", with: "")))
    }
}
