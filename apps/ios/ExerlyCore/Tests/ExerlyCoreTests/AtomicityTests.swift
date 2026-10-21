import Foundation
import Testing
@testable import ExerlyCore

/// Fails chosen writes, to check that a failed change leaves nothing behind.
@MainActor
final class FailingPersistence: TrainingPersistence {
    let inner = InMemoryTrainingPersistence()
    var failValues = false
    var failSessionDeletes = false
    struct Injected: Error {}

    func loadSessions() throws -> [WorkoutSession] { try inner.loadSessions() }
    func loadCustomExercises() throws -> [Exercise] { try inner.loadCustomExercises() }
    func save(_ session: WorkoutSession) throws { try inner.save(session) }
    func deleteSession(_ id: UUID) throws {
        if failSessionDeletes { throw Injected() }
        try inner.deleteSession(id)
    }
    func save(_ exercise: Exercise) throws { try inner.save(exercise) }
    func loadValue(forKey key: String) throws -> Data? { try inner.loadValue(forKey: key) }
    func saveValue(_ value: Data?, forKey key: String) throws {
        if failValues { throw Injected() }
        try inner.saveValue(value, forKey: key)
    }
    func performAtomically(_ body: () throws -> Void) throws { try inner.performAtomically(body) }
    func afterCommit(_ action: @escaping () -> Void) { inner.afterCommit(action) }
}

@MainActor
@Suite struct AtomicityTests {
    func prepared() throws -> (FailingPersistence, TrainingStore, UUID, UUID) {
        let persistence = FailingPersistence()
        let store = try TrainingStore(persistence: persistence, now: { Fixture.instant() })
        try store.startSession(name: "Atomic", bodyweight: nil)
        let squat = try store.addExercise("back-squat")
        var set = store.activeSession!.exercises[0].sets[0]
        set.primary = Effort(reps: 5, load: .kg(100))
        try store.updateSet(set, in: squat)
        // A second set to come, so completing the first starts its rest.
        try store.addSet(to: squat)
        return (persistence, store, squat, set.id)
    }

    @Test func completingASetIsAllOrNothing() throws {
        let (persistence, store, _, setID) = try prepared()
        let before = try #require(store.activeSession)
        persistence.failValues = true
        #expect(throws: FailingPersistence.Injected.self) { try store.completeSet(setID) }
        #expect(store.activeSession == before)
        #expect(store.restTimer == nil)
        #expect(try persistence.inner.loadSessions() == [before])
    }

    @Test func finishingIsAllOrNothing() throws {
        let (persistence, store, _, setID) = try prepared()
        try store.completeSet(setID)
        let before = try #require(store.activeSession)
        let timer = store.restTimer
        persistence.failValues = true
        #expect(throws: FailingPersistence.Injected.self) { try store.finishSession() }
        #expect(store.activeSession == before)
        #expect(store.restTimer == timer)
        #expect(store.history.sessions.isEmpty)
        #expect(try persistence.inner.loadSessions() == [before])
    }

    @Test func discardingIsAllOrNothing() throws {
        let (persistence, store, _, setID) = try prepared()
        try store.completeSet(setID)
        let before = try #require(store.activeSession)
        persistence.failValues = true
        #expect(throws: FailingPersistence.Injected.self) { try store.discardSession() }
        #expect(store.activeSession == before)
        #expect(try persistence.inner.loadSessions() == [before])

        persistence.failValues = false
        persistence.failSessionDeletes = true
        #expect(throws: FailingPersistence.Injected.self) { try store.discardSession() }
        #expect(store.activeSession == before)
        #expect(try persistence.inner.loadValue(forKey: "training.restTimer") != nil)
    }

    @Test func sqliteRollsBackAFailedUnit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("exerly-atomic-\(UUID().uuidString)/x.sqlite")
        let persistence = try SQLiteTrainingPersistence(url: url)
        let session = Fixture.session([("deadlift", [Fixture.set(3, 150)])])
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try persistence.performAtomically {
                try persistence.save(session)
                try persistence.saveValue(Data("x".utf8), forKey: "k")
                throw Boom()
            }
        }
        #expect(try persistence.loadSessions().isEmpty)
        #expect(try persistence.loadValue(forKey: "k") == nil)

        // A nested unit can fail alone; the outer one still commits.
        try persistence.performAtomically {
            try persistence.save(session)
            try? persistence.performAtomically {
                try persistence.saveValue(Data("inner".utf8), forKey: "k")
                throw Boom()
            }
        }
        #expect(try persistence.loadSessions() == [session])
        #expect(try persistence.loadValue(forKey: "k") == nil)
    }
}
