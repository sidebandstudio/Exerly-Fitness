import Foundation

/// Durable storage for training data. Every `TrainingStore` change is written
/// through before the call returns, so a crash loses nothing.
@MainActor
public protocol TrainingPersistence: AnyObject {
    /// Every stored session, finished or not, in any order.
    func loadSessions() throws -> [WorkoutSession]
    func loadCustomExercises() throws -> [Exercise]
    /// Inserts or replaces by ID.
    func save(_ session: WorkoutSession) throws
    func deleteSession(_ id: UUID) throws
    /// Inserts or replaces by ID.
    func save(_ exercise: Exercise) throws
    /// Small values such as settings and the running rest timer.
    func loadValue(forKey key: String) throws -> Data?
    /// Stores a value, or removes it when nil.
    func saveValue(_ value: Data?, forKey key: String) throws
    /// Runs several writes as one unit: all of them persist, or none.
    func performAtomically(_ body: () throws -> Void) throws
    /// Runs `action` once the outermost transaction commits, at once when no
    /// transaction is open, and never if it rolls back. Stores publish their
    /// in-memory state through it, so a write nested in a caller's transaction
    /// shows only once that transaction is saved.
    func afterCommit(_ action: @escaping () -> Void)
}

/// Keeps everything in memory. For previews, tests and the app agent's stubs.
@MainActor
public final class InMemoryTrainingPersistence: TrainingPersistence {
    public private(set) var sessions: [UUID: WorkoutSession] = [:]
    public private(set) var customExercises: [ExerciseID: Exercise] = [:]
    public private(set) var values: [String: Data] = [:]
    var bases: [String: SyncBase] = [:]
    var documents: [String: [String: Data]] = [:]

    public init(sessions: [WorkoutSession] = [], customExercises: [Exercise] = []) {
        for session in sessions { self.sessions[session.id] = session }
        for exercise in customExercises { self.customExercises[exercise.id] = exercise }
    }

    public func loadSessions() throws -> [WorkoutSession] { Array(sessions.values) }
    public func loadCustomExercises() throws -> [Exercise] {
        customExercises.values.sorted { $0.id < $1.id }
    }
    public func save(_ session: WorkoutSession) throws { sessions[session.id] = session }
    public func deleteSession(_ id: UUID) throws { sessions[id] = nil }
    public func save(_ exercise: Exercise) throws { customExercises[exercise.id] = exercise }
    public func loadValue(forKey key: String) throws -> Data? { values[key] }
    public func saveValue(_ value: Data?, forKey key: String) throws { values[key] = value }

    private var depth = 0
    private var committed: [(depth: Int, action: () -> Void)] = []

    public func performAtomically(_ body: () throws -> Void) throws {
        let snapshot = (sessions, customExercises, values, bases, documents)
        depth += 1
        let level = depth
        do {
            try body()
        } catch {
            (sessions, customExercises, values, bases, documents) = snapshot
            committed.removeAll { $0.depth >= level }
            depth -= 1
            throw error
        }
        depth -= 1
        if depth == 0 {
            let actions = committed
            committed = []
            actions.forEach { $0.action() }
        }
    }

    public func afterCommit(_ action: @escaping () -> Void) {
        if depth == 0 { action() } else { committed.append((depth, action)) }
    }
}

extension InMemoryTrainingPersistence: DocumentPersistence {
    public func loadDocuments(kind: String) throws -> [Data] {
        (documents[kind] ?? [:]).sorted { $0.key < $1.key }.map(\.value)
    }

    public func saveDocument(kind: String, id: String, payload: Data) throws { documents[kind, default: [:]][id] = payload }
    public func deleteDocument(kind: String, id: String) throws { documents[kind]?[id] = nil }
}
