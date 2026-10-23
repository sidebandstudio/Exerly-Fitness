import CryptoKit
import Foundation
import Observation

/// The document endpoints the sync engine needs. `AccountAPI` provides them,
/// bound to one account.
public protocol DocumentAPI: Sendable {
    func putDocument(kind: String, id: String, payload: Data, baseRevision: Int, idempotencyKey: String) async throws -> DocumentWriteResult
    func deleteDocument(kind: String, id: String, baseRevision: Int, idempotencyKey: String) async throws -> DocumentWriteResult
    func changes(after cursor: Int, limit: Int) async throws -> ChangePage
}

/// Keeps a TrainingStore and the server in step. See
/// docs/design/003-document-sync.md.
///
/// A document needs pushing when its canonical JSON differs from the base:
/// the last version the server acknowledged. Because that is derived rather
/// than flagged, a crash between saving and syncing can't lose a change.
/// Conflicts merge three ways, field by field, and are pushed again. When
/// both devices changed one field differently, or one deleted what the
/// other changed, the record keeps this device's version or stays deleted,
/// and both versions are kept in `conflicts` for the person to review. A
/// deleted record never comes back on its own.
///
/// Before an account is signed out, switched or deleted, call `shutdown()`.
/// It stops the current run and waits for it, after which the engine writes
/// nothing locally and sends nothing.
@MainActor
@Observable
public final class SyncEngine {
    public enum State: Equatable, Sendable {
        case idle
        case syncing
        /// The last attempt couldn't reach the server. Local data is intact.
        case offline
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var lastSyncedAt: Date?
    /// Server versions this device couldn't read, set aside so sync carries on.
    /// Loaded at the start of each sync.
    public private(set) var rejected: [RejectedDocument] = []
    /// What two devices changed at once, kept for review and synced like a document.
    public let conflicts: SyncConflictStore

    @ObservationIgnored private let hosts: [DocumentHost]
    @ObservationIgnored private let stateStore: SyncStateStore
    @ObservationIgnored private let api: DocumentAPI
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var running: Task<Void, Error>?
    @ObservationIgnored private(set) var isShutDown = false
    @ObservationIgnored private var bases: [String: SyncBase] = [:]

    private static let maxAttempts = 4
    /// Kinds a server deployed before them refuses, kept here until it takes them.
    private static let newerKinds: Set<String> = [SyncConflictStore.kind, NutritionStore.linkKind]

    /// `hosts` are synced in order, kind by kind, so a host's earlier kinds
    /// (custom exercises) arrive before the ones that use them (sessions).
    /// Conflicts sync last; pass the account's store of them to share it
    /// with the review screen, or one is made over `state`.
    public init(hosts: [DocumentHost], state: SyncStateStore, api: DocumentAPI, conflicts: SyncConflictStore? = nil,
                now: @escaping () -> Date = Date.init) {
        let conflicts = conflicts ?? SyncConflictStore(state: state, hosts: hosts, now: now)
        self.conflicts = conflicts
        self.hosts = hosts + [conflicts]
        stateStore = state
        self.api = api
        self.now = now
    }

    public convenience init(store: TrainingStore, state: SyncStateStore, api: DocumentAPI, now: @escaping () -> Date = Date.init) {
        self.init(hosts: [store], state: state, api: api, now: now)
    }

    /// Pulls, pushes, then pulls again. Overlapping calls share one run, and
    /// cancelling the call that started it cancels the run.
    public func sync() async throws {
        guard !isShutDown else { throw CancellationError() }
        if let running { return try await running.value }
        let task = Task { try await self.run() }
        running = task
        defer { running = nil }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            state = .idle
            lastSyncedAt = now()
        } catch {
            switch error {
            case is CancellationError, APIError.accountChanged: state = .idle
            case APIError.sessionExpired, APIError.notSignedIn: state = .failed("Sign in again to sync.")
            case APIError.accountDeleted: state = .failed("This account was deleted.")
            case APIError.server(_, let message): state = .failed(message)
            case APIError.invalidResponse: state = .failed("The server sent an unexpected response.")
            default: state = .offline
            }
            throw error
        }
    }

    /// Stops syncing for good: cancels the current run and returns once it has
    /// stopped. Call it before signing out, switching or deleting the account.
    public func shutdown() async {
        isShutDown = true
        guard let running else { return }
        running.cancel()
        _ = try? await running.value
    }

    /// Every local write checks this first. The engine runs on the main actor,
    /// so nothing can interleave between the check and the write.
    private func checkActive() throws {
        if isShutDown || Task.isCancelled { throw CancellationError() }
    }

    private var kindOrder: [String] { hosts.flatMap(\.documentKinds) }

    private func host(for kind: String) -> DocumentHost? {
        hosts.first { $0.documentKinds.contains(kind) }
    }

    private func run() async throws {
        state = .syncing
        let stored = try stateStore.syncBases()
        bases = Dictionary(stored.map { base in
            var canonical = base
            canonical.id = DocumentWrite.canonicalID(base.id)
            return (Self.key(canonical.kind, canonical.id), canonical)
        }, uniquingKeysWith: { a, b in a.revision >= b.revision ? a : b })
        // Bases an earlier version saved under a lowercase UUID are folded into one.
        let stale = stored.filter { $0.id != DocumentWrite.canonicalID($0.id) }
        if !stale.isEmpty {
            try checkActive()
            try stateStore.performAtomically {
                for base in stale {
                    try stateStore.removeSyncBase(kind: base.kind, id: base.id)
                    if let folded = bases[Self.key(base.kind, DocumentWrite.canonicalID(base.id))] { try stateStore.saveSyncBase(folded) }
                }
            }
        }
        rejected = try stateStore.rejectedDocuments()
        try await pull()
        if try await push() { try await pull() }
    }

    // MARK: Pull

    private func pull() async throws {
        var cursor = try stateStore.syncCursor()
        while true {
            let page = try await api.changes(after: cursor, limit: 500)
            try checkActive()
            for kind in kindOrder {
                for change in page.changes where change.kind == kind { try receive(change) }
            }
            cursor = page.cursor
            try stateStore.saveSyncCursor(cursor)
            if !page.hasMore { return }
        }
    }

    /// Applies a remote version, merging with unpushed local changes. Returns
    /// false when the version can't be read and was set aside.
    @discardableResult
    private func receive(_ incoming: RemoteDocument) throws -> Bool {
        try checkActive()
        var change = incoming
        change.id = DocumentWrite.canonicalID(incoming.id)
        guard let host = host(for: change.kind) else { return true }
        let key = Self.key(change.kind, change.id)
        let base = bases[key]
        if let base, change.revision <= base.revision { return true }
        let remote: Data?
        do {
            remote = try change.payload.map { try host.canonicalize(kind: change.kind, payload: $0) }
        } catch {
            try setAside(change, reason: "\(error)")
            return false
        }
        let local = try host.payload(kind: change.kind, id: change.id)
        let clean = base.map { local == $0.payload } ?? (local == nil)
        var write: Data??
        var found: (fields: [String], local: Data?, remote: Data?)?
        if clean, remote == nil, let local, host.keepsWhenDeletedElsewhere(kind: change.kind, id: change.id) {
            // Deleted there while in progress here, even unchanged since:
            // it stays, and the deletion waits for review.
            found = ([], local, nil)
        } else if clean {
            write = .some(remote)
        } else if !host.reviewsConflicts(kind: change.kind) {
            // The kind's own rule decides; a change beats a deletion.
            if let remote { write = .some(try local.map { try host.merge(kind: change.kind, base: base?.payload, local: $0, remote: remote) } ?? remote) }
        } else if let remote, let local {
            let outcome = try host.merge(kind: change.kind, base: base?.payload, local: local, remote: remote, preferring: .local)
            write = .some(outcome.merged)
            if !outcome.conflicts.isEmpty { found = (outcome.conflicts, local, remote) }
        } else if let remote {
            // Deleted here, changed there: it stays deleted, and the change
            // waits for review.
            if remote != base?.payload { found = ([], nil, remote) }
        } else if let local {
            // Changed here, deleted there: the deletion stands, and this
            // device's change waits for review. The workout in progress stays.
            if !host.keepsWhenDeletedElsewhere(kind: change.kind, id: change.id) { write = .some(nil) }
            found = ([], local, nil)
        }
        let conflict = try found.map {
            try conflicts.found(kind: change.kind, id: change.id, base: base?.payload, local: $0.local, remote: $0.remote,
                                fields: $0.fields, remoteAt: change.updatedAt)
        }
        // Back here after a deletion, it may be what another record now
        // stands in for, such as an entry whose scan was logged again. That
        // record keeps what it changed, and the other value waits for review.
        let isBack = local == nil && base != nil
        var writes = write.map { [DocumentWrite(kind: change.kind, id: change.id, payload: $0)] } ?? []
        var clashes: [SyncConflict] = []
        if case .some(let payload?) = write,
           let reconciled = try host.reconcile(kind: change.kind, id: change.id, payload: payload, isBack: isBack, preferring: .local,
                                               agreed: { [self] id in
               conflicts.agreed(kind: change.kind, id: id) ?? (id == change.id ? base?.payload ?? base?.previous : nil)
           }) {
            writes = try reconciled.writes.filter { try $0.payload != nil || host.payload(kind: $0.kind, id: $0.id) != nil }
            clashes = try reconciled.clashes.map {
                try conflicts.found(kind: $0.kind, id: $0.id, base: $0.base, local: $0.local, remote: $0.remote, fields: $0.fields,
                                    remoteAt: change.updatedAt)
            }
        }
        let newBase = SyncBase(kind: change.kind, id: change.id, revision: change.revision, payload: remote,
                               previous: remote == nil ? base?.payload ?? base?.previous : nil)
        let remaining = rejected.filter { $0.kind != change.kind || $0.id != change.id }
        var publishes: [() -> Void] = []
        var publishConflict: () -> Void = {}
        try stateStore.performAtomically {
            for write in writes { publishes.append(try host.prepareWrite(kind: write.kind, id: write.id, payload: write.payload)) }
            if isBack, writes.contains(where: { $0.id == change.id && $0.payload != nil }) {
                try conflicts.effects?.broughtBack(kind: change.kind, id: change.id)
            }
            let staged = try ([conflict].compactMap { $0 } + clashes).map { try conflicts.stage($0) }
            publishConflict = { staged.forEach { $0() } }
            try stateStore.saveSyncBase(newBase)
            if remaining != rejected { try stateStore.saveRejectedDocuments(remaining) }
        }
        publishes.forEach { $0() }
        publishConflict()
        bases[key] = newBase
        rejected = remaining
        return true
    }

    private func setAside(_ change: RemoteDocument, reason: String) throws {
        let entry = RejectedDocument(kind: change.kind, id: change.id, revision: change.revision, reason: String(reason.prefix(500)))
        let updated = rejected.filter { $0.kind != change.kind || $0.id != change.id } + [entry]
        try stateStore.saveRejectedDocuments(updated)
        rejected = updated
    }

    // MARK: Push

    /// Pushes every document that differs from its base. Returns whether anything was written.
    private func push() async throws -> Bool {
        let order = kindOrder
        var documents = Set<SyncBase>()
        for base in bases.values where base.payload != nil { documents.insert(SyncBase(kind: base.kind, id: base.id, revision: 0)) }
        for host in hosts {
            for kind in host.documentKinds {
                for id in host.documentIDs(kind: kind) { documents.insert(SyncBase(kind: kind, id: id, revision: 0)) }
            }
        }
        let ordered = documents.sorted {
            (order.firstIndex(of: $0.kind) ?? .max, $0.id) < (order.firstIndex(of: $1.kind) ?? .max, $1.id)
        }
        var wrote = false
        for document in ordered where host(for: document.kind) != nil {
            if try await pushDocument(document.kind, document.id) { wrote = true }
        }
        // Conflicts found while pushing go out in the same run.
        for id in conflicts.documentIDs(kind: SyncConflictStore.kind) where try await pushDocument(SyncConflictStore.kind, id) {
            wrote = true
        }
        return wrote
    }

    private func pushDocument(_ kind: String, _ id: String) async throws -> Bool {
        for _ in 0..<Self.maxAttempts {
            guard let host = host(for: kind) else { return false }
            let current = try host.payload(kind: kind, id: id)
            var base = bases[Self.key(kind, id)] ?? SyncBase(kind: kind, id: id, revision: 0)
            if current == base.payload || (current == nil && base.revision == 0) { return false }
            // One key per content and base revision: a lost response is
            // retried with the same key, a merged version gets a new one.
            let hash = SHA256.hash(data: current ?? Data()).map { String(format: "%02x", $0) }.joined() + "@\(base.revision)"
            if base.pushHash != hash || base.pushKey == nil {
                base.pushKey = UUID().uuidString
                base.pushHash = hash
                try saveBase(base)
            }
            let result: DocumentWriteResult
            do {
                if let current {
                    result = try await api.putDocument(kind: kind, id: id, payload: current, baseRevision: base.revision,
                                                       idempotencyKey: base.pushKey!)
                } else {
                    result = try await api.deleteDocument(kind: kind, id: id, baseRevision: base.revision,
                                                          idempotencyKey: base.pushKey!)
                }
            } catch APIError.server(status: 404, _) where current == nil {
                try checkActive()
                try stateStore.removeSyncBase(kind: kind, id: id)
                bases[Self.key(kind, id)] = nil
                return false
            } catch APIError.server(status: 400, _) where Self.newerKinds.contains(kind) {
                // A server from before this kind: keep it here and try next time.
                return false
            }
            switch result {
            case .applied(let revision):
                try saveBase(SyncBase(kind: kind, id: id, revision: revision, payload: current,
                                      previous: current == nil ? base.payload ?? base.previous : nil))
                return true
            case .conflict(let remote?):
                // An unreadable server version can't be merged; leave this document.
                if try !receive(remote) { return false }
            case .conflict(nil):
                // The server has no such document: start again from nothing.
                try saveBase(SyncBase(kind: kind, id: id, revision: 0))
            }
        }
        throw APIError.server(status: 409, message: "\(kind) \(id) kept changing during sync. Try again.")
    }

    // MARK: Bases

    private static func key(_ kind: String, _ id: String) -> String { "\(kind)/\(id)" }

    private func saveBase(_ base: SyncBase) throws {
        try checkActive()
        try stateStore.saveSyncBase(base)
        bases[Self.key(base.kind, base.id)] = base
    }
}
