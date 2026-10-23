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
/// stays deleted. The versions never change once found: a later clash
/// about the same record is a conflict of its own, and only the resolution
/// changes, on any device. See docs/DECISIONS.md, 2026-10-21 and 2026-10-22.
public struct SyncConflict: Codable, Hashable, Sendable, Identifiable {
    public enum Choice: String, Codable, Sendable, Hashable {
        /// The version of the device that found the conflict.
        case local
        /// The other device's version.
        case remote
        /// Both, as two records: offered for food entries and weigh-ins.
        case both
        /// Neither: the record stays as it is on this device now, such as a
        /// workout whose clashing set was removed since.
        case current
    }

    public struct Resolution: Codable, Hashable, Sendable {
        public var choice: Choice
        public var at: Date
        public var device: SyncDevice
        /// Settled by sync, not the person: the record was deleted on every device since.
        public var automatic: Bool?
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
    /// When the resolution last changed, on any device: when two devices
    /// resolved it, or one undid it, at once, the later change stands.
    public var changedAt: Date
    /// Too large to sync even with only what clashed kept: it stays on
    /// the device that found it.
    public var tooLarge: Bool?

    public init(id: UUID = UUID(), kind: String, documentID: String, device: SyncDevice, detectedAt: Date, remoteAt: Date? = nil,
                base: JSONValue?, local: JSONValue?, remote: JSONValue?, fields: [String], resolution: Resolution? = nil,
                changedAt: Date? = nil, tooLarge: Bool? = nil) {
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
        self.tooLarge = tooLarge
    }

    /// Conflicts larger than this keep only what clashed. The API takes
    /// bodies up to 256 KB, and a conflict holds up to three versions.
    static let syncBudget = 200_000

    /// This conflict small enough to sync: versions of a large record keep
    /// only what a card and a choice need, its top-level values and each
    /// list item a clash names, whole, then the base goes; still too
    /// large, it's marked to stay here.
    func fitted() -> SyncConflict {
        let size = { (conflict: SyncConflict) in (try? ExerlyJSON.canonical(conflict).count) ?? .max }
        var fitted = self
        guard size(fitted) > Self.syncBudget else { return fitted }
        if !isDeletion {
            fitted.local = Self.trimmed(local, to: fields)
            fitted.remote = Self.trimmed(remote, to: fields)
            fitted.base = Self.trimmed(base, to: fields)
        }
        if size(fitted) > Self.syncBudget { fitted.base = nil }
        if size(fitted) > Self.syncBudget { fitted.tooLarge = true }
        return fitted
    }

    /// `version` with only its top-level values that aren't lists, and of
    /// each list the items `paths` name, whole; a list's order keeps every
    /// item's own values.
    static func trimmed(_ version: JSONValue?, to paths: [String]) -> JSONValue? {
        guard case .object(let fields)? = version else { return version }
        var kept = fields.filter { if case .array = $0.value { false } else { true } }
        for path in paths {
            let step = String(path.split(separator: ".").first ?? "")
            guard let open = step.firstIndex(of: "["), step.hasSuffix("]") else {
                kept[step] = fields[step]
                continue
            }
            let name = String(step[..<open]), id = String(step[step.index(after: open)..<step.index(before: step.endIndex)])
            guard case .array(let items)? = fields[name] else { continue }
            let have: [JSONValue] = if case .array(let have)? = kept[name] { have } else { [] }
            func key(_ item: JSONValue) -> String? { if case .object(let f) = item, case .string(let id)? = f["id"] { id } else { nil } }
            kept[name] = .array(items.compactMap { item in
                let held = have.first { key($0) == key(item) }
                if !id.isEmpty, key(item) == id { return item }
                if id.isEmpty, case .object(let f) = item, held == nil {
                    return .object(f.filter { if case .array = $0.value { false } else { true } })
                }
                return held
            })
        }
        return .object(kept)
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
/// as the offline scans behind food entries, that bringing a document back
/// must keep true.
@MainActor
public protocol ConflictSideEffects: AnyObject {
    /// Brings back a deleted document as `payload`. Returns how to undo it,
    /// or nil to leave it to the document's host. Called inside a transaction.
    func bringBack(kind: String, id: String, payload: Data) throws -> (() throws -> Void)?
    /// Another device brought a deleted document back; sync wrote it.
    /// Called inside the same transaction.
    func broughtBack(kind: String, id: String) throws
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
    /// Settled for the person in the last week, to say so in the review.
    public var settledForYou: [SyncConflict] {
        let since = now().addingTimeInterval(-Self.settledNotice)
        return conflicts.filter { $0.resolution?.automatic == true && $0.changedAt > since }
    }

    /// How long a settled conflict is kept, for devices that haven't synced
    /// since, before the device that settled it removes it everywhere. Any
    /// other device waits twice as long, so the one whose Undo could still
    /// reopen it decides, and a device that's gone for good holds nothing up.
    public static let keptAfterSettling: TimeInterval = 30 * 24 * 3600
    static let settledNotice: TimeInterval = 7 * 24 * 3600

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

    /// A new conflict sync found about a document. One already open about it
    /// stays as it is, so its versions still wait for a decision.
    func found(kind: String, id: String, base: Data?, local: Data?, remote: Data?, fields: [String],
               remoteAt: Date?) throws -> SyncConflict {
        let json = { (data: Data?) in try data.map(JSONValue.init(data:)) }
        let at = now()
        let local = try json(local), remote = try json(remote)
        return SyncConflict(kind: kind, documentID: id, device: device, detectedAt: at, remoteAt: remoteAt, base: try json(base),
                            local: local, remote: remote, fields: local == nil || remote == nil ? [] : Array(Set(fields)).sorted(),
                            changedAt: at).fitted()
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
    /// transaction. A field conflict sets only the conflicting fields to the
    /// chosen version's, so every other change, including one made since,
    /// stays; keeping both adds the other device's version as a second
    /// record. A deletion conflict keeps the record deleted or brings the
    /// chosen version back, through `effects` when another store keeps
    /// records about it.
    public func resolve(_ id: SyncConflict.ID, _ choice: SyncConflict.Choice) throws {
        guard let conflict = conflict(id), !conflict.isResolved else { throw ResolveError.notOpen }
        guard conflict.choices.contains(choice) || choice == .current else { throw ResolveError.notOffered(choice) }
        guard let host = host(for: conflict.kind) else { throw DocumentError(message: "Unknown kind \(conflict.kind)") }
        let kind = conflict.kind, documentID = conflict.documentID
        let current = try host.payload(kind: kind, id: documentID)
        var writes: [DocumentWrite] = []
        var undoEffect: (() throws -> Void)?
        var clashes: [SyncConflict] = []
        var before: [DocumentWrite] = []
        var after: [Data?] = []
        var publishes: [() -> Void] = []
        var resolved = conflict
        resolved.resolution = SyncConflict.Resolution(choice: choice, at: now(), device: device)
        resolved.changedAt = now()
        try state.performAtomically {
            if choice == .current {
                // As it is: nothing to write.
            } else if conflict.isDeletion {
                if current != nil, conflict.version(choice) != nil {
                    // Already back, perhaps changed since: it stays as it is.
                } else if let kept = conflict.version(choice)?.canonicalData {
                    // The person's choice stands; what it replaces waits for review.
                    if let reconciled = try host.reconcile(kind: kind, id: documentID, payload: kept, isBack: true, preferring: .remote,
                                                           agreed: { agreed(kind: kind, id: $0) }) {
                        writes = try reconciled.writes.filter { try $0.payload != nil || host.payload(kind: $0.kind, id: $0.id) != nil }
                        clashes = try reconciled.clashes.map {
                            try found(kind: $0.kind, id: $0.id, base: $0.base, local: $0.local, remote: $0.remote, fields: $0.fields,
                                      remoteAt: conflict.remoteAt)
                        }
                    } else {
                        undoEffect = try effects?.bringBack(kind: kind, id: documentID, payload: kept)
                        if undoEffect == nil { writes = [DocumentWrite(kind: kind, id: documentID, payload: kept)] }
                    }
                } else if current != nil {
                    writes = [DocumentWrite(kind: kind, id: documentID, payload: nil)]
                }
            } else if let current, let chosen = conflict.version(choice) {
                // A set removed since comes back with the chosen values.
                let merged = try host.canonicalize(kind: kind, payload: Merge.apply(
                    conflict.fields, from: chosen, to: JSONValue(data: current), groups: host.fieldGroups(kind: kind),
                    restoring: true).canonicalData)
                if merged != current { writes.append(DocumentWrite(kind: kind, id: documentID, payload: merged)) }
                if choice == .both, let copy = conflict.copyOfRemote(id: UUID()) { writes.append(copy) }
            }
            for write in writes {
                if let payload = write.payload { try host.validate(kind: write.kind, id: write.id, payload: payload) }
                before.append(DocumentWrite(kind: write.kind, id: write.id, payload: try host.payload(kind: write.kind, id: write.id)))
                after.append(try write.payload.map { try host.canonicalize(kind: write.kind, payload: $0) })
                publishes.append(try host.prepareWrite(kind: write.kind, id: write.id, payload: write.payload))
            }
            for clash in clashes { publishes.append(try stage(clash)) }
            publishes.append(try stage(resolved))
        }
        publishes.forEach { $0() }
        // What the effect wrote: its Undo runs only while the record is still that.
        let effectWrote = undoEffect == nil ? nil : try host.payload(kind: kind, id: documentID)
        undoStep = { [self] in
            var reopened = resolved
            reopened.resolution = nil
            reopened.changedAt = now()
            var publishes: [() -> Void] = []
            try state.performAtomically {
                // Changed since, it stays, with the scans it logs, as any
                // record changed since a resolution does.
                if let undoEffect, try host.payload(kind: kind, id: documentID) == effectWrote { try undoEffect() }
                var kept = Set<String>()
                for (write, written) in zip(before, after).reversed() {
                    let now = try host.payload(kind: write.kind, id: write.id)
                    var payload = write.payload
                    if now != written {
                        // Changed since: of a field conflict's record, only
                        // the fields the choice set and nobody changed since
                        // go back; anything else changed since stays.
                        guard !conflict.isDeletion, write.id == documentID, let earlier = write.payload, let now, let written else {
                            kept.insert(write.id)
                            continue
                        }
                        let undone = Merge.apply(conflict.fields, from: try JSONValue(data: earlier), to: try JSONValue(data: written),
                                                 groups: host.fieldGroups(kind: kind))
                        payload = try host.merge(kind: kind, base: written, local: now, remote: undone.canonicalData, preferring: .local).merged
                    }
                    publishes.append(try host.prepareWrite(kind: write.kind, id: write.id, payload: payload))
                }
                // The choice made them, and taken back they never were; but
                // one about a record that stays as the choice left it holds
                // the only copy of the other value, so it waits for a decision.
                for clash in clashes where !kept.contains(clash.documentID) {
                    publishes.append(try prepareWrite(kind: Self.kind, id: clash.id.uuidString, payload: nil))
                }
                publishes.append(try stage(reopened))
            }
            publishes.forEach { $0() }
        }
        undoable = id
    }

    // MARK: Tidying

    /// Settles each open field conflict whose record is now deleted on every
    /// device (`deletedEverywhere`): neither version is a live edit, and
    /// nothing is written but the resolution, which says sync settled it.
    /// Then removes conflicts settled more than `keptAfterSettling` ago
    /// here, or twice that elsewhere, once `synced` says that version
    /// reached the server, or at once when it never syncs; never the one
    /// Undo would reopen. Sync calls this.
    /// The server has `payload` for conflict `id`, pushed or pulled: a settled
    /// version starts the clock on its removal, if it hasn't started; one
    /// reopened stops it.
    func acknowledged(_ id: String, payload: Data?) throws {
        var acknowledgements = try state.conflictAcknowledgements()
        let settled = try payload.map { try ExerlyJSON.decoder.decode(SyncConflict.self, from: $0).isResolved } ?? false
        guard settled != (acknowledgements[id] != nil) else { return }
        acknowledgements[id] = settled ? now() : nil
        try state.saveConflictAcknowledgements(acknowledgements)
    }

    func tidy(deletedEverywhere: (String, String) -> Bool, synced: (SyncConflict) -> Bool) throws {
        let at = now()
        let acknowledgements = try state.conflictAcknowledgements()
        var settled: [SyncConflict] = []
        for conflict in unresolved where !conflict.isDeletion && deletedEverywhere(conflict.kind, conflict.documentID) {
            guard let host = host(for: conflict.kind), try host.payload(kind: conflict.kind, id: conflict.documentID) == nil else { continue }
            var done = conflict
            done.resolution = SyncConflict.Resolution(choice: .current, at: at, device: device, automatic: true)
            done.changedAt = at
            settled.append(done)
        }
        let expired = conflicts.filter { conflict in
            guard let resolution = conflict.resolution, conflict.id != undoable else { return false }
            let kept = Self.keptAfterSettling * (resolution.device.id == device.id ? 1 : 2)
            // From when the server took it: settled offline, it isn't removed as soon as it's sent.
            let tooLarge = conflict.tooLarge == true
            guard let since = tooLarge ? max(resolution.at, conflict.changedAt) : acknowledgements[conflict.id.uuidString],
                  at.timeIntervalSince(since) > kept else { return false }
            return tooLarge || synced(conflict)
        }
        guard !settled.isEmpty || !expired.isEmpty else { return }
        var publishes: [() -> Void] = []
        try state.performAtomically {
            for conflict in settled { publishes.append(try stage(conflict)) }
            for conflict in expired { publishes.append(try prepareWrite(kind: Self.kind, id: conflict.id.uuidString, payload: nil)) }
            if !expired.isEmpty {
                try state.saveConflictAcknowledgements(acknowledgements.filter { id, _ in !expired.contains { $0.id.uuidString == id } })
            }
        }
        publishes.forEach { $0() }
    }

    // MARK: Undo of a delete

    /// Undo of a delete: brings the record back as `payload`, the version
    /// deleted, with every change another device made since and this one
    /// pulled, kept until now in the deletion's conflicts, so the snapshot
    /// never overwrites them. Those conflicts are settled; a field both
    /// changed differently keeps this version and the other waits in a new
    /// conflict. A record already back, from another device, stays as it is.
    public func restore(kind: String, id: String, payload: Data) throws {
        guard let host = host(for: kind) else { throw DocumentError(message: "Unknown kind \(kind)") }
        guard try host.payload(kind: kind, id: id) == nil else { return }
        let open = unresolved.filter { $0.kind == kind && $0.documentID == id && $0.isDeletion }
        var restored = try host.canonicalize(kind: kind, payload: payload)
        var clashes: [SyncConflict] = []
        for conflict in open.reversed() {
            guard let other = (conflict.local ?? conflict.remote)?.canonicalData, other != restored else { continue }
            let base = conflict.base?.canonicalData
            let outcome = try host.merge(kind: kind, base: base, local: restored, remote: other, preferring: .local)
            if !outcome.conflicts.isEmpty {
                clashes.append(try found(kind: kind, id: id, base: base, local: restored, remote: other, fields: outcome.conflicts,
                                         remoteAt: conflict.remoteAt))
            }
            restored = outcome.merged
        }
        try host.validate(kind: kind, id: id, payload: restored)
        var publishes: [() -> Void] = []
        try state.performAtomically {
            publishes.append(try host.prepareWrite(kind: kind, id: id, payload: restored))
            for conflict in open {
                var settled = conflict
                settled.resolution = SyncConflict.Resolution(choice: conflict.local == nil ? .remote : .local, at: now(), device: device)
                settled.changedAt = now()
                publishes.append(try stage(settled))
            }
            for clash in clashes { publishes.append(try stage(clash)) }
        }
        publishes.forEach { $0() }
    }

    /// Undo of deleting a food entry.
    public func restore(_ entry: FoodEntry) throws {
        try restore(kind: NutritionStore.entryKind, id: entry.id.uuidString, payload: ExerlyJSON.canonical(entry))
    }

    /// Undo of deleting a workout.
    public func restore(_ session: WorkoutSession) throws {
        try restore(kind: TrainingStore.sessionKind, id: session.id.uuidString, payload: ExerlyJSON.canonical(session))
    }

    /// Reopens the last conflict resolved here and puts its records back.
    public func undo() throws {
        guard let undoStep else { return }
        try undoStep()
        self.undoStep = nil
        undoable = nil
    }

    /// The conflict in words on this device, beside the record as it is here now.
    public func summary(of conflict: SyncConflict, unit: MassUnit, timeZone: TimeZone, locale: Locale = .current) -> SyncConflictSummary {
        let now = try? host(for: conflict.kind)?.payload(kind: conflict.kind, id: conflict.documentID).map(JSONValue.init(data:))
        return conflict.summary(on: device, unit: unit, timeZone: timeZone, locale: locale, replaced: replacement(for: conflict) != nil,
                                current: .some(now))
    }

    /// The document now standing in for a deleted one, such as the entry an
    /// undone scan was logged again as.
    public func replacement(for conflict: SyncConflict) -> String? {
        host(for: conflict.kind)?.replacement(kind: conflict.kind, id: conflict.documentID)
    }

    /// The version both devices last agreed on of a document a conflict is
    /// about, from the latest such conflict.
    func agreed(kind: String, id: String) -> Data? {
        conflicts.first { $0.kind == kind && $0.documentID == id && $0.base != nil }?.base?.canonicalData
    }
}

extension SyncConflictStore: DocumentHost {
    public var documentKinds: [String] { [Self.kind] }

    /// A conflict too large to sync isn't offered to sync.
    public func documentIDs(kind: String) -> [String] {
        kind == Self.kind ? conflicts.filter { $0.tooLarge != true }.map(\.id.uuidString) : []
    }

    /// The server refused a conflict as too large: it stays here.
    func keepHere(_ id: String) throws {
        guard var conflict = conflicts.first(where: { $0.id.uuidString == id }), conflict.tooLarge != true else { return }
        conflict.tooLarge = true
        var publish: () -> Void = {}
        try state.performAtomically { publish = try stage(conflict) }
        publish()
    }

    /// None for a conflict too large to sync: sync leaves it here.
    public func payload(kind: String, id: String) throws -> Data? {
        guard kind == Self.kind else { return nil }
        return try conflicts.first { $0.id.uuidString == id && $0.tooLarge != true }.map(ExerlyJSON.canonical)
    }

    public func canonicalize(kind: String, payload: Data) throws -> Data {
        guard kind == Self.kind else { throw DocumentError(message: "Unknown kind \(kind)") }
        return try ExerlyJSON.canonical(ExerlyJSON.decoder.decode(SyncConflict.self, from: payload))
    }

    public func validate(kind: String, id: String, payload: Data) throws {
        let conflict = try ExerlyJSON.decoder.decode(SyncConflict.self, from: canonicalize(kind: kind, payload: payload))
        guard conflict.id.uuidString == id else { throw DocumentError(message: "The ID doesn't match") }
    }

    /// Resolved or undone on two devices at once, the later change stands.
    /// The versions are the ones found, the same on every device; only the
    /// resolution is taken from the other side.
    public func merge(kind: String, base: Data?, local: Data, remote: Data) throws -> Data {
        let decoder = ExerlyJSON.decoder
        var merged = try decoder.decode(SyncConflict.self, from: local)
        let theirs = try decoder.decode(SyncConflict.self, from: remote)
        guard theirs.changedAt > merged.changedAt else { return local }
        merged.resolution = theirs.resolution
        merged.changedAt = theirs.changedAt
        return try ExerlyJSON.canonical(merged)
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

/// Keeps offline scans logged exactly once when a conflict, here or on
/// another device, brings back a food entry that Undo removed. See
/// `BarcodeLibrary.bringBack`.
@MainActor
public final class ScanConflictEffects: ConflictSideEffects {
    private let library: BarcodeLibrary
    private let store: NutritionStore

    public init(library: BarcodeLibrary, store: NutritionStore) {
        self.library = library
        self.store = store
    }

    public func bringBack(kind: String, id: String, payload: Data) throws -> (() throws -> Void)? {
        guard kind == NutritionStore.entryKind, let entry = UUID(uuidString: id) else { return nil }
        return try library.bringBack(entry, as: ExerlyJSON.decoder.decode(FoodEntry.self, from: payload), to: store)
    }

    public func broughtBack(kind: String, id: String) throws {
        guard kind == NutritionStore.entryKind, let entry = UUID(uuidString: id) else { return }
        try library.broughtBack(entry, to: store)
    }
}
