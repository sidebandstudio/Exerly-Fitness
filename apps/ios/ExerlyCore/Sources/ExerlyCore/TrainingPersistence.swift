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
    /// Rows another connection read and couldn't decode, as `table/id`, so
    /// this one treats them as it would its own: kept, never deleted.
    func noteUnreadable(_ rows: [String])
}

extension TrainingPersistence {
    public func noteUnreadable(_ rows: [String]) {}
}

/// Keeps everything in memory. For previews, tests and the app agent's stubs.
@MainActor
public final class InMemoryTrainingPersistence: TrainingPersistence {
    public private(set) var sessions: [UUID: WorkoutSession] = [:]
    public private(set) var customExercises: [ExerciseID: Exercise] = [:]
    public private(set) var values: [String: Data] = [:]
    var bases: [String: SyncBase] = [:]
    var documents: [String: [String: Data]] = [:]
    /// Documents written since sync last found them matching their base.
    var changed: Set<DocumentRef> = []
    /// Tests: runs between a write and the record of its change, as a crash could.
    var beforeRecordingChange: (() throws -> Void)?

    private func recordChange(_ kind: String, _ id: String) throws {
        try beforeRecordingChange?()
        changed.insert(DocumentRef(kind: kind, id: id))
    }

    public init(sessions: [WorkoutSession] = [], customExercises: [Exercise] = []) {
        for session in sessions { self.sessions[session.id] = session }
        for exercise in customExercises { self.customExercises[exercise.id] = exercise }
    }

    public func loadSessions() throws -> [WorkoutSession] { Array(sessions.values) }
    public func loadCustomExercises() throws -> [Exercise] {
        customExercises.values.sorted { $0.id < $1.id }
    }
    // Each write and the record of its change are one unit, as on disk.
    public func save(_ session: WorkoutSession) throws {
        try performAtomically {
            sessions[session.id] = session
            try recordChange(TrainingStore.sessionKind, session.id.uuidString)
        }
    }
    public func deleteSession(_ id: UUID) throws {
        try performAtomically {
            sessions[id] = nil
            try recordChange(TrainingStore.sessionKind, id.uuidString)
        }
    }
    public func save(_ exercise: Exercise) throws {
        try performAtomically {
            customExercises[exercise.id] = exercise
            try recordChange(TrainingStore.exerciseKind, exercise.id.rawValue)
        }
    }
    public func loadValue(forKey key: String) throws -> Data? { values[key] }
    public func saveValue(_ value: Data?, forKey key: String) throws { values[key] = value }

    private var depth = 0
    private var committed: [() -> Void] = []

    public func performAtomically(_ body: () throws -> Void) throws {
        let snapshot = (sessions, customExercises, values, bases, documents, changed)
        depth += 1
        // A rollback drops only what this transaction added; a sibling
        // saved before it keeps its actions.
        let added = committed.count
        do {
            try body()
        } catch {
            (sessions, customExercises, values, bases, documents, changed) = snapshot
            committed.removeSubrange(added...)
            depth -= 1
            throw error
        }
        depth -= 1
        if depth == 0 {
            let actions = committed
            committed = []
            actions.forEach { $0() }
        }
    }

    public func afterCommit(_ action: @escaping () -> Void) {
        if depth == 0 { action() } else { committed.append(action) }
    }
}

extension InMemoryTrainingPersistence: DocumentPersistence {
    public func loadDocuments(kind: String) throws -> [Data] {
        (documents[kind] ?? [:]).sorted { $0.key < $1.key }.map(\.value)
    }

    public func saveDocument(kind: String, id: String, payload: Data) throws {
        try performAtomically {
            documents[kind, default: [:]][id] = payload
            try recordChange(kind, id)
        }
    }
    public func deleteDocument(kind: String, id: String) throws {
        try performAtomically {
            documents[kind]?[id] = nil
            try recordChange(kind, id)
        }
    }
}
