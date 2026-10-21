import Foundation
import Observation

/// Proposals and the audit log. Agents file proposals; nothing changes until
/// the person accepts one, and every decision is recorded and can be undone.
@MainActor
@Observable
public final class AgentStore {
    public enum AgentError: Error, Equatable {
        case notFound
        case duplicate
        case invalid(String)
        /// A target changed since the proposal was made (or, for undo, since it was applied).
        case stale
        case alreadyDecided
        case notAccepted
    }

    /// A proposal's changes to one document, as field paths.
    public struct DocumentDiff: Sendable, Hashable {
        public var kind: String
        public var id: String
        public var fields: [FieldChange]
    }

    /// Newest first.
    public private(set) var proposals: [Proposal] = []
    /// Oldest first.
    public private(set) var auditLog: [AuditEvent] = []

    static let proposalKind = "proposal"
    static let auditKind = "audit_event"
    private static let person = AgentIdentity(kind: .builtIn, name: "You")

    @ObservationIgnored private let persistence: TrainingPersistence & DocumentPersistence
    @ObservationIgnored private let hosts: [DocumentHost]
    @ObservationIgnored private let now: () -> Date

    public init(persistence: TrainingPersistence & DocumentPersistence, hosts: [DocumentHost],
                now: @escaping () -> Date = Date.init) throws {
        self.persistence = persistence
        self.hosts = hosts
        self.now = { now().roundedToMilliseconds }
        proposals = try persistence.loadDocuments(kind: Self.proposalKind)
            .map { try ExerlyJSON.decoder.decode(Proposal.self, from: $0) }
            .sorted { $0.createdAt > $1.createdAt }
        auditLog = try persistence.loadDocuments(kind: Self.auditKind)
            .map { try ExerlyJSON.decoder.decode(AuditEvent.self, from: $0) }
            .sorted { $0.at < $1.at }
    }

    public func proposal(_ id: UUID) -> Proposal? { proposals.first { $0.id == id } }

    // MARK: Filing and deciding

    /// Records a new pending proposal after checking it is complete and every
    /// proposed document is valid. Changes nothing else.
    public func file(_ proposal: Proposal) throws {
        guard self.proposal(proposal.id) == nil else { throw AgentError.duplicate }
        try check(proposal)
        var filed = proposal
        filed.status = .pending
        filed.decidedAt = nil
        let event = AuditEvent(at: now(), action: .proposalFiled, actor: proposal.author, proposalID: proposal.id,
                               targets: proposal.changes.map { DataRef(kind: $0.kind, id: $0.id) })
        try commit(filed, event, stage: { [] })
    }

    /// Applies every change as one unit, only if each target still equals its
    /// `before`. Otherwise the proposal becomes stale and nothing is applied.
    /// A proposal that arrived by sync is checked here as strictly as one filed
    /// on this device.
    public func accept(_ id: UUID) throws {
        var proposal = try pending(id)
        try check(proposal)
        guard try matches(proposal.changes, \.before) else {
            proposal.status = .stale
            try commit(proposal, event(.proposalStale, proposal, actor: proposal.author), stage: { [] })
            throw AgentError.stale
        }
        proposal.status = .accepted
        proposal.decidedAt = now()
        try commit(proposal, event(.proposalAccepted, proposal, actor: Self.person)) {
            try proposal.changes.map { try self.host($0.kind).prepareWrite(kind: $0.kind, id: $0.id, payload: $0.after?.canonicalData) }
        }
    }

    public func reject(_ id: UUID) throws {
        var proposal = try pending(id)
        proposal.status = .rejected
        proposal.decidedAt = now()
        try commit(proposal, event(.proposalRejected, proposal, actor: Self.person), stage: { [] })
    }

    /// Restores every `before`, only if each target still equals its `after`.
    public func undo(_ id: UUID) throws {
        guard var proposal = self.proposal(id) else { throw AgentError.notFound }
        guard proposal.status == .accepted else { throw AgentError.notAccepted }
        try checkWrites(proposal.changes, \.before)
        guard try matches(proposal.changes, \.after) else { throw AgentError.stale }
        proposal.status = .undone
        proposal.decidedAt = now()
        try commit(proposal, event(.proposalUndone, proposal, actor: Self.person)) {
            try proposal.changes.map { try self.host($0.kind).prepareWrite(kind: $0.kind, id: $0.id, payload: $0.before?.canonicalData) }
        }
    }

    public func diff(_ id: UUID) -> [DocumentDiff] {
        (proposal(id)?.changes ?? []).map { DocumentDiff(kind: $0.kind, id: $0.id, fields: JSONValue.diff($0.before, $0.after)) }
    }

    // MARK: Private

    private func pending(_ id: UUID) throws -> Proposal {
        guard let proposal = proposal(id) else { throw AgentError.notFound }
        guard proposal.status == .pending else { throw AgentError.alreadyDecided }
        return proposal
    }

    private func host(_ kind: String) throws -> DocumentHost {
        guard let host = hosts.first(where: { $0.documentKinds.contains(kind) }) else {
            throw AgentError.invalid("No store holds \(kind) documents")
        }
        return host
    }

    private func check(_ proposal: Proposal) throws {
        let blank = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if blank(proposal.title) { throw AgentError.invalid("A proposal needs a title") }
        if blank(proposal.falsifier) { throw AgentError.invalid("A proposal needs a falsifier: what would show it is wrong") }
        if proposal.changes.isEmpty { throw AgentError.invalid("A proposal needs at least one change") }
        try checkWrites(proposal.changes, \.after)
    }

    /// Checks the writes one side of the changes would make, per host and as a
    /// batch, before anything is written. Each document may appear once.
    private func checkWrites(_ changes: [ProposedChange], _ side: KeyPath<ProposedChange, JSONValue?>) throws {
        var seen = Set<String>()
        var batches: [ObjectIdentifier: (host: DocumentHost, writes: [DocumentWrite])] = [:]
        for change in changes {
            guard seen.insert("\(change.kind)/\(change.id)").inserted else {
                throw AgentError.invalid("The proposal changes \(change.kind) \(change.id) more than once")
            }
            if change.before == nil && change.after == nil { throw AgentError.invalid("A change needs a before or an after") }
            let host = try host(change.kind)
            let write = DocumentWrite(kind: change.kind, id: change.id, payload: change[keyPath: side]?.canonicalData)
            batches[ObjectIdentifier(host), default: (host, [])].writes.append(write)
        }
        for (host, writes) in batches.values {
            do {
                try host.validate(batch: writes)
            } catch {
                let reason = (error as? DocumentError)?.message ?? "\(error)"
                throw AgentError.invalid("The proposed changes can't be applied: \(reason)")
            }
        }
    }

    /// Whether every target currently equals the given side of its change.
    private func matches(_ changes: [ProposedChange], _ side: KeyPath<ProposedChange, JSONValue?>) throws -> Bool {
        for change in changes {
            let current = try host(change.kind).payload(kind: change.kind, id: change.id)
            let expected = try change[keyPath: side].map { try host(change.kind).canonicalize(kind: change.kind, payload: $0.canonicalData) }
            if current != expected { return false }
        }
        return true
    }

    private func event(_ action: AuditEvent.Action, _ proposal: Proposal, actor: AgentIdentity) -> AuditEvent {
        AuditEvent(at: now(), action: action, actor: actor, proposalID: proposal.id,
                   targets: proposal.changes.map { DataRef(kind: $0.kind, id: $0.id) })
    }

    /// Saves the proposal, its audit event and any staged document writes as
    /// one unit, then publishes everything.
    private func commit(_ proposal: Proposal, _ event: AuditEvent, stage: () throws -> [() -> Void]) throws {
        var publish: [() -> Void] = []
        try persistence.performAtomically {
            publish = try stage()
            try persistence.saveDocument(kind: Self.proposalKind, id: proposal.id.uuidString, payload: ExerlyJSON.canonical(proposal))
            try persistence.saveDocument(kind: Self.auditKind, id: event.id.uuidString, payload: ExerlyJSON.canonical(event))
        }
        publish.forEach { $0() }
        proposals = ([proposal] + proposals.filter { $0.id != proposal.id }).sorted { $0.createdAt > $1.createdAt }
        auditLog.append(event)
    }
}

extension AgentStore: DocumentHost {
    public var documentKinds: [String] { [Self.proposalKind, Self.auditKind] }

    public func documentIDs(kind: String) -> [String] {
        kind == Self.proposalKind ? proposals.map(\.id.uuidString) : auditLog.map(\.id.uuidString)
    }

    public func payload(kind: String, id: String) throws -> Data? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        if kind == Self.proposalKind { return try proposal(uuid).map(ExerlyJSON.canonical) }
        return try auditLog.first { $0.id == uuid }.map(ExerlyJSON.canonical)
    }

    public func canonicalize(kind: String, payload: Data) throws -> Data {
        kind == Self.proposalKind
            ? try ExerlyJSON.canonical(ExerlyJSON.decoder.decode(Proposal.self, from: payload))
            : try ExerlyJSON.canonical(ExerlyJSON.decoder.decode(AuditEvent.self, from: payload))
    }

    public func validate(kind: String, id: String, payload: Data) throws {
        _ = try canonicalize(kind: kind, payload: payload)
    }

    /// A decision beats a pending copy; otherwise the usual field rule applies.
    /// Audit events never change, so the local copy stands.
    public func merge(kind: String, base: Data?, local: Data, remote: Data) throws -> Data {
        guard kind == Self.proposalKind else { return local }
        let decoder = ExerlyJSON.decoder
        let mine = try decoder.decode(Proposal.self, from: local)
        let theirs = try decoder.decode(Proposal.self, from: remote)
        if mine.status == .pending && theirs.status != .pending { return remote }
        if theirs.status == .pending && mine.status != .pending { return local }
        return try ExerlyJSON.canonical(Merge.value(try base.map { try decoder.decode(Proposal.self, from: $0) }, mine, theirs))
    }

    /// Proposals and audit events never need a review: the rule above decides.
    public func reviewsConflicts(kind: String) -> Bool { false }

    public func merge(kind: String, base: Data?, local: Data, remote: Data, preferring prefer: Merge.Preference) throws -> MergeOutcome {
        MergeOutcome(merged: try merge(kind: kind, base: base, local: local, remote: remote), conflicts: [])
    }

    public func prepareWrite(kind: String, id: String, payload: Data?) throws -> () -> Void {
        guard let uuid = UUID(uuidString: id) else { throw DocumentError(message: "Invalid ID") }
        guard let payload else {
            // Audit events are never deleted.
            guard kind == Self.proposalKind else { return {} }
            try persistence.deleteDocument(kind: kind, id: id)
            return { [self] in proposals.removeAll { $0.id == uuid } }
        }
        try persistence.saveDocument(kind: kind, id: id, payload: payload)
        if kind == Self.proposalKind {
            let proposal = try ExerlyJSON.decoder.decode(Proposal.self, from: payload)
            return { [self] in
                proposals = ([proposal] + proposals.filter { $0.id != uuid }).sorted { $0.createdAt > $1.createdAt }
            }
        }
        let event = try ExerlyJSON.decoder.decode(AuditEvent.self, from: payload)
        return { [self] in
            auditLog = (auditLog.filter { $0.id != uuid } + [event]).sorted { $0.at < $1.at }
        }
    }
}
