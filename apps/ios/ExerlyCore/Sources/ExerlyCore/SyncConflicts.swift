import Foundation
import Observation

/// A device in a conflict: a random ID kept with the account's data on that
/// device, and its kind ("iPhone", "iPad"), never the name the person gave it.
public struct SyncDevice: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// Two devices changed one record before either saw the other's change, and
/// the changes don't combine: the same field changed differently, or one
/// side deleted what the other changed. Both versions are kept, and the
/// conflict syncs like a document, until the person picks one. Meanwhile
/// the record shows the version of the device that found the conflict, or
/// stays deleted. See docs/DECISIONS.md, 2026-10-21.
public struct SyncConflict: Codable, Hashable, Sendable, Identifiable {
    public enum Choice: String, Codable, Sendable, Hashable {
        /// The version of the device that found the conflict.
        case local
        /// The other device's version.
        case remote
        /// Both, as two records: offered for food entries and weigh-ins.
        case both
    }

    public struct Resolution: Codable, Hashable, Sendable {
        public var choice: Choice
        public var at: Date
        public var device: SyncDevice
    }

    public var id: UUID
    public var kind: String
    public var documentID: String
    /// The device that found it; `local` is its version.
    public var device: SyncDevice
    public var detectedAt: Date
    /// When the server took the other version, when it said.
    public var remoteAt: Date?
    /// The version both last agreed on.
    public var base: JSONValue?
    /// Nil: deleted on `device`.
    public var local: JSONValue?
    /// Nil: deleted on the other device.
    public var remote: JSONValue?
    /// The fields both changed differently; empty when one side deleted.
    public var fields: [String]
    public var resolution: Resolution?
    /// The latest change to this conflict, on any device: when two devices
    /// changed it at once, the later change stands.
    public var changedAt: Date

    public init(id: UUID = UUID(), kind: String, documentID: String, device: SyncDevice, detectedAt: Date, remoteAt: Date? = nil,
                base: JSONValue?, local: JSONValue?, remote: JSONValue?, fields: [String], resolution: Resolution? = nil,
                changedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.documentID = documentID
        self.device = device
        self.detectedAt = detectedAt
        self.remoteAt = remoteAt
        self.base = base
        self.local = local
        self.remote = remote
        self.fields = fields
        self.resolution = resolution
        self.changedAt = changedAt ?? detectedAt
    }

    public var isDeletion: Bool { local == nil || remote == nil }
    public var isResolved: Bool { resolution != nil }

    /// Kinds where keeping both versions means two records.
    static let twoRecordKinds: Set<String> = ["food_entry", "weight_entry"]

    /// What the person can choose, the version shown now first.
    public var choices: [Choice] {
        if isDeletion { return local == nil ? [.local, .remote] : [.remote, .local] }
        return Self.twoRecordKinds.contains(kind) ? [.local, .remote, .both] : [.local, .remote]
    }

    /// The version a choice keeps, nil for keeping it deleted. Both keeps
    /// the local version in place.
    public func version(_ choice: Choice) -> JSONValue? { choice == .remote ? remote : local }

    /// The other device's version as a new record, for keeping both.
    func copyOfRemote(id: UUID) -> DocumentWrite? {
        guard case .object(var fields)? = remote else { return nil }
        fields["id"] = .string(id.uuidString)
        return DocumentWrite(kind: kind, id: id.uuidString, payload: JSONValue.object(fields).canonicalData)
    }
}

/// A store with its own records about documents another host keeps, such
/// as the offline scans behind food entries, that resolving a conflict must
/// keep true.
@MainActor
public protocol ConflictSideEffects: AnyObject {
    /// The document now standing in for a deleted one, such as the entry a
    /// scan was logged again as.
    func replacement(kind: String, id: String) -> String?
    /// Brings back a deleted document as `payload`; `base` is the version
    /// both devices last agreed on. Returns how to undo it, or nil to leave
    /// it to the document's host. Called inside a transaction.
    func bringBack(kind: String, id: String, payload: Data, base: Data?) throws -> (() throws -> Void)?
}

/// The conflicts of one account, kept in its own store beside its data, so
/// they survive a relaunch and never mix with another account's. Sync finds
/// them and keeps them in step across devices; the person resolves them here.
@MainActor
@Observable
public final class SyncConflictStore {
    public static let kind = syncConflictKind

    /// Newest first, resolved ones included.
    public private(set) var conflicts: [SyncConflict] = []
    public let device: SyncDevice
    /// The conflict Undo would reopen: the last one resolved here, this session.
    public private(set) var undoable: SyncConflict.ID?
    /// Keeps other stores' records true when a resolution writes a document.
    @ObservationIgnored public var effects: ConflictSideEffects?

    @ObservationIgnored private let state: SyncStateStore
    @ObservationIgnored private let hosts: [DocumentHost]
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var undoStep: (() throws -> Void)?

    public var unresolved: [SyncConflict] { conflicts.filter { !$0.isResolved } }

    public init(state: SyncStateStore, hosts: [DocumentHost], deviceName: String = "iPhone", now: @escaping () -> Date = Date.init) {
        self.state = state
        self.hosts = hosts
        self.now = now
        device = SyncDevice(id: (try? state.syncDeviceID()) ?? UUID(), name: deviceName)
        conflicts = ((try? state.syncConflicts()) ?? [])
            .compactMap { try? ExerlyJSON.decoder.decode(SyncConflict.self, from: $0) }
            .sorted(by: Self.order)
    }

    private static func order(_ a: SyncConflict, _ b: SyncConflict) -> Bool {
        (a.detectedAt, a.id.uuidString) > (b.detectedAt, b.id.uuidString)
    }

    public func conflict(_ id: SyncConflict.ID) -> SyncConflict? { conflicts.first { $0.id == id } }

    /// The open conflict about a document, if any.
    public func open(kind: String, id: String) -> SyncConflict? {
        conflicts.first { !$0.isResolved && $0.kind == kind && $0.documentID == id }
    }

    private func host(for kind: String) -> DocumentHost? { hosts.first { $0.documentKinds.contains(kind) } }

    // MARK: Finding

    /// The conflict sync found about a document: a new one, or the open one
    /// brought up to date with both sides' latest versions.
    func found(kind: String, id: String, base: Data?, local: Data?, remote: Data?, fields: [String],
               remoteAt: Date?) throws -> SyncConflict {
        let json = { (data: Data?) in try data.map(JSONValue.init(data:)) }
        let at = now()
        var conflict = open(kind: kind, id: id) ?? SyncConflict(
            id: UUID(), kind: kind, documentID: id, device: device, detectedAt: at, base: nil, local: nil, remote: nil,
            fields: [], changedAt: at
        )
        let earlier = conflict.isDeletion ? [] : conflict.fields
        conflict.device = device
        conflict.detectedAt = at
        conflict.changedAt = at
        conflict.remoteAt = remoteAt
        conflict.base = try json(base)
        conflict.local = try json(local)
        conflict.remote = try json(remote)
        conflict.fields = conflict.isDeletion ? [] : Array(Set(earlier + fields)).sorted()
        return conflict
    }

    /// Persists a conflict inside the caller's transaction; publish after it commits.
    func stage(_ conflict: SyncConflict) throws -> () -> Void {
        try prepareWrite(kind: Self.kind, id: conflict.id.uuidString, payload: ExerlyJSON.canonical(conflict))
    }

    // MARK: Resolving

    public enum ResolveError: Error, Equatable {
        case notOpen
        case notOffered(SyncConflict.Choice)
    }

    /// Applies the person's choice and marks the conflict resolved, in one
    /// transaction. A field conflict sets the conflicting fields to the
    /// chosen version's, keeping every other change; keeping both adds the
    /// other device's version as a second record. A deletion conflict keeps
    /// the record deleted or brings the chosen version back, through
    /// `effects` when another store keeps records about it.
    public func resolve(_ id: SyncConflict.ID, _ choice: SyncConflict.Choice) throws {
        guard let conflict = conflict(id), !conflict.isResolved else { throw ResolveError.notOpen }
        guard conflict.choices.contains(choice) else { throw ResolveError.notOffered(choice) }
        guard let host = host(for: conflict.kind) else { throw DocumentError(message: "Unknown kind \(conflict.kind)") }
        let documentID = conflict.documentID
        let current = try host.payload(kind: conflict.kind, id: documentID)
        var writes: [DocumentWrite] = []
        var undoEffect: (() throws -> Void)?
        var before: [DocumentWrite] = []
        var publishes: [() -> Void] = []
        var resolved = conflict
        resolved.resolution = SyncConflict.Resolution(choice: choice, at: now(), device: device)
        resolved.changedAt = now()
        try state.performAtomically {
            if conflict.isDeletion {
                if let kept = conflict.version(choice)?.canonicalData {
                    undoEffect = try effects?.bringBack(kind: conflict.kind, id: documentID, payload: kept,
                                                        base: conflict.base?.canonicalData)
                    if undoEffect == nil { writes = [DocumentWrite(kind: conflict.kind, id: documentID, payload: kept)] }
                } else if current != nil {
                    writes = [DocumentWrite(kind: conflict.kind, id: documentID, payload: nil)]
                }
            } else if let current, let chosen = conflict.version(choice) {
                let merged = try host.merge(kind: conflict.kind, base: conflict.base?.canonicalData, local: current,
                                            remote: chosen.canonicalData, preferring: .remote).merged
                if merged != current { writes.append(DocumentWrite(kind: conflict.kind, id: documentID, payload: merged)) }
                if choice == .both, let copy = conflict.copyOfRemote(id: UUID()) { writes.append(copy) }
            }
            for write in writes {
                if let payload = write.payload { try host.validate(kind: write.kind, id: write.id, payload: payload) }
                before.append(DocumentWrite(kind: write.kind, id: write.id, payload: try host.payload(kind: write.kind, id: write.id)))
                publishes.append(try host.prepareWrite(kind: write.kind, id: write.id, payload: write.payload))
            }
            publishes.append(try stage(resolved))
        }
        publishes.forEach { $0() }
        undoStep = { [self] in
            var reopened = resolved
            reopened.resolution = nil
            reopened.changedAt = now()
            var publishes: [() -> Void] = []
            try state.performAtomically {
                try undoEffect?()
                for write in before.reversed() {
                    publishes.append(try host.prepareWrite(kind: write.kind, id: write.id, payload: write.payload))
                }
                publishes.append(try stage(reopened))
            }
            publishes.forEach { $0() }
        }
        undoable = id
    }

    /// Reopens the last conflict resolved here and puts its records back.
    public func undo() throws {
        guard let undoStep else { return }
        try undoStep()
        self.undoStep = nil
        undoable = nil
    }

    /// The document now standing in for a deleted one, when another store knows.
    public func replacement(for conflict: SyncConflict) -> String? {
        effects?.replacement(kind: conflict.kind, id: conflict.documentID)
    }
}

extension SyncConflictStore: DocumentHost {
    public var documentKinds: [String] { [Self.kind] }

    public func documentIDs(kind: String) -> [String] { kind == Self.kind ? conflicts.map(\.id.uuidString) : [] }

    public func payload(kind: String, id: String) throws -> Data? {
        guard kind == Self.kind else { return nil }
        return try conflicts.first { $0.id.uuidString == id }.map(ExerlyJSON.canonical)
    }

    public func canonicalize(kind: String, payload: Data) throws -> Data {
        guard kind == Self.kind else { throw DocumentError(message: "Unknown kind \(kind)") }
        return try ExerlyJSON.canonical(ExerlyJSON.decoder.decode(SyncConflict.self, from: payload))
    }

    public func validate(kind: String, id: String, payload: Data) throws {
        let conflict = try ExerlyJSON.decoder.decode(SyncConflict.self, from: canonicalize(kind: kind, payload: payload))
        guard conflict.id.uuidString == id else { throw DocumentError(message: "The ID doesn't match") }
    }

    /// Changed on two devices at once, the later change stands: a
    /// resolution, an Undo, or a newer version found.
    public func merge(kind: String, base: Data?, local: Data, remote: Data) throws -> Data {
        let decoder = ExerlyJSON.decoder
        let mine = try decoder.decode(SyncConflict.self, from: local), theirs = try decoder.decode(SyncConflict.self, from: remote)
        return theirs.changedAt > mine.changedAt ? remote : local
    }

    public func merge(kind: String, base: Data?, local: Data, remote: Data, preferring prefer: Merge.Preference) throws -> MergeOutcome {
        MergeOutcome(merged: try merge(kind: kind, base: base, local: local, remote: remote), conflicts: [])
    }

    public func reviewsConflicts(kind: String) -> Bool { false }

    public func prepareWrite(kind: String, id: String, payload: Data?) throws -> () -> Void {
        guard kind == Self.kind else { throw DocumentError(message: "Unknown kind \(kind)") }
        guard let payload else {
            try state.saveSyncConflict(id: id, payload: nil)
            return { [self] in conflicts.removeAll { $0.id.uuidString == id } }
        }
        let conflict = try ExerlyJSON.decoder.decode(SyncConflict.self, from: payload)
        try state.saveSyncConflict(id: id, payload: ExerlyJSON.canonical(conflict))
        return { [self] in conflicts = (conflicts.filter { $0.id != conflict.id } + [conflict]).sorted(by: Self.order) }
    }
}

/// Keeps offline scans logged exactly once when a conflict brings back a
/// food entry that Undo removed. See `BarcodeLibrary.bringBack`.
@MainActor
public final class ScanConflictEffects: ConflictSideEffects {
    private let library: BarcodeLibrary
    private let store: NutritionStore

    public init(library: BarcodeLibrary, store: NutritionStore) {
        self.library = library
        self.store = store
    }

    public func replacement(kind: String, id: String) -> String? {
        guard kind == NutritionStore.entryKind, let entry = UUID(uuidString: id) else { return nil }
        return library.relog(of: entry, in: store)?.uuidString
    }

    public func bringBack(kind: String, id: String, payload: Data, base: Data?) throws -> (() throws -> Void)? {
        guard kind == NutritionStore.entryKind, let entry = UUID(uuidString: id) else { return nil }
        let decoder = ExerlyJSON.decoder
        return try library.bringBack(entry, as: decoder.decode(FoodEntry.self, from: payload),
                                     base: base.map { try decoder.decode(FoodEntry.self, from: $0) }, to: store)
    }
}
