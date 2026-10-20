import Foundation

/// Stores whose entities sync and can be changed by proposals: the training
/// store, the agent store, and later nutrition and programs.
@MainActor
public protocol DocumentHost: AnyObject {
    /// The kinds this host owns, in the order they should sync.
    var documentKinds: [String] { get }
    func documentIDs(kind: String) -> [String]
    /// The current canonical payload, or nil when the document doesn't exist.
    func payload(kind: String, id: String) throws -> Data?
    /// Decodes and re-encodes a payload, throwing when it isn't a valid document of that kind.
    func canonicalize(kind: String, payload: Data) throws -> Data
    /// Stricter than `canonicalize`: what a proposal may write.
    func validate(kind: String, id: String, payload: Data) throws
    /// Checks several writes together, nil to delete, so one can depend on
    /// another (a session using a custom exercise created alongside it).
    func validate(batch: [DocumentWrite]) throws
    func merge(kind: String, base: Data?, local: Data, remote: Data) throws -> Data
    /// Persists a write, nil to delete, and returns the step that publishes it in
    /// memory. Call inside `performAtomically` and publish only after it commits.
    func prepareWrite(kind: String, id: String, payload: Data?) throws -> () -> Void
    /// `prepareWrite` for many documents of one kind, published in one step.
    /// Stores holding thousands of documents, such as an import's, override it.
    func prepareWrites(kind: String, _ writes: [DocumentWrite]) throws -> () -> Void
}

extension DocumentHost {
    public func prepareWrites(kind: String, _ writes: [DocumentWrite]) throws -> () -> Void {
        let steps = try writes.map { try prepareWrite(kind: kind, id: $0.id, payload: $0.payload) }
        return { steps.forEach { $0() } }
    }
}

/// Documents with no dedicated table: proposals and audit events.
@MainActor
public protocol DocumentPersistence: AnyObject {
    func loadDocuments(kind: String) throws -> [Data]
    func saveDocument(kind: String, id: String, payload: Data) throws
    func deleteDocument(kind: String, id: String) throws
}

public struct DocumentError: Error, Equatable {
    public let message: String
}

/// One write in a batch: a document's kind, ID and payload, nil to delete.
public struct DocumentWrite: Sendable, Hashable {
    public var kind: String
    public var id: String
    public var payload: Data?

    public init(kind: String, id: String, payload: Data?) {
        self.kind = kind
        self.id = id
        self.payload = payload
    }

    /// A UUID in the uppercase form `UUID.uuidString` gives, and any other ID as
    /// it is, so one document never goes by two IDs.
    static func canonicalID(_ id: String) -> String { UUID(uuidString: id)?.uuidString ?? id }
}

extension DocumentHost {
    public func validate(batch: [DocumentWrite]) throws {
        for write in batch {
            if let payload = write.payload { try validate(kind: write.kind, id: write.id, payload: payload) }
        }
    }
}

extension TrainingStore: DocumentHost {
    static let sessionKind = "workout_session"
    static let exerciseKind = "custom_exercise"

    public var documentKinds: [String] { [Self.exerciseKind, Self.sessionKind] }

    public func documentIDs(kind: String) -> [String] {
        switch kind {
        case Self.exerciseKind: library.exercises.filter(\.id.isCustom).map(\.id.rawValue)
        case Self.sessionKind: (history.sessions + (activeSession.map { [$0] } ?? [])).map(\.id.uuidString)
        default: []
        }
    }

    public func payload(kind: String, id: String) throws -> Data? {
        switch kind {
        case Self.sessionKind:
            return try UUID(uuidString: id).flatMap(session(withID:)).map(ExerlyJSON.canonical)
        case Self.exerciseKind:
            return try library.exercise(ExerciseID(id)).flatMap { $0.id.isCustom ? $0 : nil }.map(ExerlyJSON.canonical)
        default:
            return nil
        }
    }

    public func canonicalize(kind: String, payload: Data) throws -> Data {
        switch kind {
        case Self.sessionKind: try ExerlyJSON.canonical(ExerlyJSON.decoder.decode(WorkoutSession.self, from: payload))
        case Self.exerciseKind: try ExerlyJSON.canonical(ExerlyJSON.decoder.decode(Exercise.self, from: payload))
        default: throw DocumentError(message: "Unknown kind \(kind)")
        }
    }

    public func validate(kind: String, id: String, payload: Data) throws {
        try validate(batch: [DocumentWrite(kind: kind, id: id, payload: payload)])
    }

    /// Custom exercises first, so the batch's sessions are checked against a
    /// library that includes them. Custom exercises are never removed.
    public func validate(batch: [DocumentWrite]) throws {
        var library = self.library
        for write in batch where write.kind == Self.exerciseKind {
            guard let payload = write.payload else {
                throw DocumentError(message: "Custom exercises can't be removed; sessions may use them")
            }
            try validateExercise(id: write.id, payload: payload)
            library = try library.replacing(ExerlyJSON.decoder.decode(Exercise.self, from: payload))
        }
        for write in batch where write.kind != Self.exerciseKind {
            guard write.kind == Self.sessionKind else { throw DocumentError(message: "Unknown kind \(write.kind)") }
            guard let payload = write.payload else {
                guard UUID(uuidString: write.id) != nil else { throw DocumentError(message: "Invalid session ID") }
                continue
            }
            let session = try ExerlyJSON.decoder.decode(WorkoutSession.self, from: payload)
            guard session.id.uuidString == write.id else { throw DocumentError(message: "The session ID doesn't match") }
            try session.validate(library: library)
        }
    }

    private func validateExercise(id: String, payload: Data) throws {
        let exercise = try ExerlyJSON.decoder.decode(Exercise.self, from: payload)
        guard exercise.id.rawValue == id, exercise.id.isCustom, exercise.validationErrors.isEmpty else {
            throw DocumentError(message: "Not a valid custom exercise")
        }
    }

    public func merge(kind: String, base: Data?, local: Data, remote: Data) throws -> Data {
        let decoder = ExerlyJSON.decoder
        switch kind {
        case Self.sessionKind:
            return try ExerlyJSON.canonical(Merge.session(
                base: try base.map { try decoder.decode(WorkoutSession.self, from: $0) },
                local: try decoder.decode(WorkoutSession.self, from: local),
                remote: try decoder.decode(WorkoutSession.self, from: remote)
            ))
        default:
            return try ExerlyJSON.canonical(Merge.exerciseDefinition(
                base: try base.map { try decoder.decode(Exercise.self, from: $0) },
                local: try decoder.decode(Exercise.self, from: local),
                remote: try decoder.decode(Exercise.self, from: remote)
            ))
        }
    }

    public func prepareWrite(kind: String, id: String, payload: Data?) throws -> () -> Void {
        switch kind {
        case Self.sessionKind:
            guard let uuid = UUID(uuidString: id) else { throw DocumentError(message: "Invalid session ID") }
            if let payload {
                return try stageSession(ExerlyJSON.decoder.decode(WorkoutSession.self, from: payload))
            }
            return try stageSessionRemoval(uuid)
        case Self.exerciseKind:
            // Custom exercises are never removed; sessions may still use them.
            guard let payload else { return {} }
            return try stageExercise(ExerlyJSON.decoder.decode(Exercise.self, from: payload))
        default:
            throw DocumentError(message: "Unknown kind \(kind)")
        }
    }

    /// Finished sessions added or removed together rebuild the history once.
    /// Anything touching the workout in progress goes one by one.
    public func prepareWrites(kind: String, _ writes: [DocumentWrite]) throws -> () -> Void {
        let oneByOne = { [self] in
            let steps = try writes.map { try prepareWrite(kind: kind, id: $0.id, payload: $0.payload) }
            return { steps.forEach { $0() } }
        }
        // Custom exercises, and anything else that isn't a session, go one by one.
        guard kind == Self.sessionKind else { return try oneByOne() }
        let sessions = try writes.map { write -> (UUID, WorkoutSession?) in
            guard let id = UUID(uuidString: write.id) else { throw DocumentError(message: "Invalid session ID") }
            return (id, try write.payload.map { try ExerlyJSON.decoder.decode(WorkoutSession.self, from: $0) })
        }
        guard sessions.allSatisfy({ $0.1?.isFinished != false && $0.0 != activeSession?.id }) else { return try oneByOne() }
        return try stageFinishedSessions(sessions)
    }
}
