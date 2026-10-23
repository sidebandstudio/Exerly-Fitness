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
    /// Like `merge`, also naming the fields both sides changed differently,
    /// which take `prefer`'s value. By default top-level fields merge; hosts
    /// whose documents have structure, or whose kinds never conflict, say so.
    func merge(kind: String, base: Data?, local: Data, remote: Data, preferring prefer: Merge.Preference) throws -> MergeOutcome
    /// Top-level fields that change together, such as an entry's grams,
    /// serving and quantity, named by their first: merges report a group as
    /// one field, and a resolution sets all of it.
    func fieldGroups(kind: String) -> [[String]]
    /// Whether a document this device changed stays when another device
    /// deleted it, such as the workout in progress. The conflict is still kept.
    func keepsWhenDeletedElsewhere(kind: String, id: String) -> Bool
    /// False for kinds whose own rule settles every clash, such as proposals:
    /// they keep the older behaviour, where a change beats a deletion, and
    /// raise no conflict.
    func reviewsConflicts(kind: String) -> Bool
    /// The document standing in for `id`, such as the entry an undone scan
    /// was logged again as: bringing `id` back changes that one instead.
    func replacement(kind: String, id: String) -> String?
    /// The writes that keep this host's records true when `payload` arrives
    /// for `id` or a resolution brings it back (`isBack`, gone here until
    /// now), or nil to write it as it is: an entry and the one logged again
    /// from its scan become one. `agreed` gives a document's version both
    /// devices last agreed on, when known. A field both changed differently
    /// takes `prefer`'s value: the document here (`local`) or `payload`.
    func reconcile(kind: String, id: String, payload: Data, isBack: Bool, preferring prefer: Merge.Preference,
                   agreed: (String) -> Data?) throws -> Reconciliation?
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

/// What `reconcile` writes, and the fields of a written document both sides
/// changed differently, which wait for review.
public struct Reconciliation: Sendable, Hashable {
    public struct Clash: Sendable, Hashable {
        public var kind: String
        public var id: String
        public var base: Data?
        /// As written.
        public var local: Data
        /// With the other side's values in `fields`.
        public var remote: Data
        public var fields: [String]
    }

    public var writes: [DocumentWrite]
    public var clashes: [Clash] = []
}

/// A merged document and the fields both sides changed differently.
public struct MergeOutcome: Sendable, Hashable {
    public var merged: Data
    /// Empty when the two sides combined cleanly.
    public var conflicts: [String]

    public init(merged: Data, conflicts: [String]) {
        self.merged = merged
        self.conflicts = conflicts
    }
}

extension DocumentHost {
    public func validate(batch: [DocumentWrite]) throws {
        for write in batch {
            if let payload = write.payload { try validate(kind: write.kind, id: write.id, payload: payload) }
        }
    }

    public func merge(kind: String, base: Data?, local: Data, remote: Data, preferring prefer: Merge.Preference) throws -> MergeOutcome {
        try fieldMerge(kind: kind, base: base, local: local, remote: remote, preferring: prefer)
    }

    public func keepsWhenDeletedElsewhere(kind: String, id: String) -> Bool { false }

    public func fieldGroups(kind: String) -> [[String]] { [] }

    public func replacement(kind: String, id: String) -> String? { nil }

    public func reconcile(kind: String, id: String, payload: Data, isBack: Bool, preferring prefer: Merge.Preference,
                          agreed: (String) -> Data?) throws -> Reconciliation? {
        nil
    }

    public func reviewsConflicts(kind: String) -> Bool { true }

    /// Merges a document's top-level fields, `groups` together. A result this
    /// host can't read keeps the preferred side whole, reported as "*".
    public func fieldMerge(kind: String, base: Data?, local: Data, remote: Data, groups: [[String]] = [],
                           preferring prefer: Merge.Preference) throws -> MergeOutcome {
        let result = Merge.fields(base: try base.map(JSONValue.init(data:)), local: try JSONValue(data: local),
                                  remote: try JSONValue(data: remote), groups: groups, preferring: prefer)
        if let merged = try? canonicalize(kind: kind, payload: result.merged.canonicalData) {
            return MergeOutcome(merged: merged, conflicts: result.conflicts)
        }
        return MergeOutcome(merged: prefer == .local ? local : remote, conflicts: ["*"])
    }
}

extension TrainingStore: DocumentHost {
    nonisolated static let sessionKind = "workout_session"
    nonisolated static let exerciseKind = "custom_exercise"

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

    /// Sessions merge set by set; a custom exercise as a whole value.
    public func merge(kind: String, base: Data?, local: Data, remote: Data, preferring prefer: Merge.Preference) throws -> MergeOutcome {
        guard kind == Self.sessionKind else {
            return try fieldMerge(kind: kind, base: base, local: local, remote: remote, preferring: prefer)
        }
        let decoder = ExerlyJSON.decoder
        let result = Merge.session(base: try base.map { try decoder.decode(WorkoutSession.self, from: $0) },
                                   local: try decoder.decode(WorkoutSession.self, from: local),
                                   remote: try decoder.decode(WorkoutSession.self, from: remote), preferring: prefer)
        return MergeOutcome(merged: try ExerlyJSON.canonical(result.merged), conflicts: result.conflicts)
    }

    /// The workout in progress isn't taken away mid-session.
    public func keepsWhenDeletedElsewhere(kind: String, id: String) -> Bool {
        kind == Self.sessionKind && activeSession?.id.uuidString == id
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
