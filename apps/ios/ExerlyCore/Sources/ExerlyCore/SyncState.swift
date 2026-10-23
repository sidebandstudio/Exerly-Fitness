import Foundation

/// The last version of a document both this device and the server agreed on,
/// plus the key of a push that hasn't been acknowledged yet.
public struct SyncBase: Sendable, Hashable {
    public var kind: String
    public var id: String
    /// 0 until the server has acknowledged a version.
    public var revision: Int
    /// Canonical JSON of that version; nil for a tombstone or before the first push.
    public var payload: Data?
    /// Reused when the same content is pushed again after a lost response.
    public var pushKey: String?
    public var pushHash: String?
    /// For a tombstone, the version agreed on before it, so a record coming
    /// back merges against what both last had.
    public var previous: Data?
}

/// A version of a document from the server that this device couldn't read,
/// for example one written by a newer app or a faulty agent. Sync sets it aside
/// and carries on; a later readable version replaces it.
public struct RejectedDocument: Sendable, Hashable, Codable {
    public var kind: String
    public var id: String
    public var revision: Int
    /// Why it couldn't be read, for diagnostics rather than display.
    public var reason: String
    /// Its place in the change feed, so a later build can fetch it again.
    public var sequence: Int?
    /// The build that set it aside: another may read it.
    public var build: String?
}

/// Where the sync engine keeps bases and its cursor. Both training
/// persistence implementations provide it, in the same store as the data.
@MainActor
public protocol SyncStateStore: AnyObject {
    func syncBases() throws -> [SyncBase]
    func saveSyncBase(_ base: SyncBase) throws
    func removeSyncBase(kind: String, id: String) throws
    func syncCursor() throws -> Int
    func saveSyncCursor(_ cursor: Int) throws
    func rejectedDocuments() throws -> [RejectedDocument]
    func saveRejectedDocuments(_ documents: [RejectedDocument]) throws
    /// Runs several writes as one unit: all of them persist, or none.
    func performAtomically(_ body: () throws -> Void) throws
    /// Conflicts sync found, as canonical JSON, kept with the account's data.
    func syncConflicts() throws -> [Data]
    /// Saves a conflict, nil to remove it.
    func saveSyncConflict(id: String, payload: Data?) throws
    /// This device's ID in the conflicts it finds, made once per account.
    func syncDeviceID() throws -> UUID
    /// When this device first knew the server had each settled conflict, by
    /// conflict ID: the clock its removal waits on.
    func conflictAcknowledgements() throws -> [String: ConflictAcknowledgement]
    func saveConflictAcknowledgements(_ acknowledgements: [String: ConflictAcknowledgement]) throws
    /// Every document written since sync last found it matching its base,
    /// recorded with the write itself, or nil until `trustChanges(token:)`
    /// was called with this `token`: then sync compares every document.
    func changedDocuments(token: String) throws -> Set<DocumentRef>?
    /// Forgets every change recorded, before sync compares every document.
    func resetChanges() throws
    /// Every document has been compared since `resetChanges`: from now on
    /// the changes recorded are all there is to push, while `token` holds.
    func trustChanges(token: String) throws
    /// The document matches its base.
    func markUnchanged(kind: String, id: String) throws
    /// The document may differ from its base without a write here, such as
    /// one kept deleted when the server brought it back.
    func markChanged(kind: String, id: String) throws
    /// Stored here in a form this build can't read, such as a newer app's:
    /// missing from its store, yet not deleted.
    func isUnreadable(kind: String, id: String) -> Bool
}

/// A document by kind and ID.
public struct DocumentRef: Hashable, Sendable {
    public var kind: String
    public var id: String

    public init(kind: String, id: String) {
        self.kind = kind
        self.id = DocumentWrite.canonicalID(id)
    }
}

/// Stores that don't record changes: sync compares every document, as before.
extension SyncStateStore {
    public func changedDocuments(token: String) throws -> Set<DocumentRef>? { nil }
    public func resetChanges() throws {}
    public func trustChanges(token: String) throws {}
    public func markUnchanged(kind: String, id: String) throws {}
    public func markChanged(kind: String, id: String) throws {}
    public func isUnreadable(kind: String, id: String) -> Bool { false }
}

let changesTokenKey = "sync.changes.token"

private let cursorKey = "sync.cursor"
private let rejectedKey = "sync.rejected"
private let deviceKey = "sync.device"
private let acknowledgementsKey = "sync.conflicts.acknowledged.v2"

/// The settled version of a conflict the server took, by its `changedAt`, and when this device learned it.
public struct ConflictAcknowledgement: Codable, Hashable, Sendable {
    public var version: Date
    public var at: Date
}
let syncConflictKind = "sync_conflict"

extension SyncStateStore where Self: TrainingPersistence & DocumentPersistence {
    public func syncConflicts() throws -> [Data] { try loadDocuments(kind: syncConflictKind) }
    public func saveSyncConflict(id: String, payload: Data?) throws {
        if let payload { try saveDocument(kind: syncConflictKind, id: id, payload: payload) } else {
            try deleteDocument(kind: syncConflictKind, id: id)
        }
    }

    public func conflictAcknowledgements() throws -> [String: ConflictAcknowledgement] {
        try loadValue(forKey: acknowledgementsKey).map { try ExerlyJSON.decoder.decode([String: ConflictAcknowledgement].self, from: $0) } ?? [:]
    }

    public func saveConflictAcknowledgements(_ acknowledgements: [String: ConflictAcknowledgement]) throws {
        try saveValue(acknowledgements.isEmpty ? nil : ExerlyJSON.canonical(acknowledgements), forKey: acknowledgementsKey)
    }

    public func syncDeviceID() throws -> UUID {
        if let data = try loadValue(forKey: deviceKey), let id = String(bytes: data, encoding: .utf8).flatMap(UUID.init) { return id }
        let id = UUID()
        try saveValue(Data(id.uuidString.utf8), forKey: deviceKey)
        return id
    }
}

private func loadRejected(_ data: Data?) throws -> [RejectedDocument] {
    try data.map { try JSONDecoder().decode([RejectedDocument].self, from: $0) } ?? []
}

private func encodeRejected(_ documents: [RejectedDocument]) throws -> Data? {
    documents.isEmpty ? nil : try ExerlyJSON.canonical(documents)
}

extension InMemoryTrainingPersistence: SyncStateStore {
    public func changedDocuments(token: String) throws -> Set<DocumentRef>? {
        try loadValue(forKey: changesTokenKey) == Data(token.utf8) ? changed : nil
    }
    public func resetChanges() throws {
        changed = []
        try saveValue(nil, forKey: changesTokenKey)
    }
    public func trustChanges(token: String) throws { try saveValue(Data(token.utf8), forKey: changesTokenKey) }
    public func markUnchanged(kind: String, id: String) throws { changed.remove(DocumentRef(kind: kind, id: id)) }
    public func markChanged(kind: String, id: String) throws { changed.insert(DocumentRef(kind: kind, id: id)) }

    public func syncBases() throws -> [SyncBase] { Array(bases.values) }
    public func saveSyncBase(_ base: SyncBase) throws { bases["\(base.kind)/\(base.id)"] = base }
    public func removeSyncBase(kind: String, id: String) throws { bases["\(kind)/\(id)"] = nil }
    public func syncCursor() throws -> Int {
        try loadValue(forKey: cursorKey).flatMap { String(bytes: $0, encoding: .utf8).flatMap(Int.init) } ?? 0
    }
    public func saveSyncCursor(_ cursor: Int) throws { try saveValue(Data(String(cursor).utf8), forKey: cursorKey) }
    public func rejectedDocuments() throws -> [RejectedDocument] { try loadRejected(loadValue(forKey: rejectedKey)) }
    public func saveRejectedDocuments(_ documents: [RejectedDocument]) throws {
        try saveValue(encodeRejected(documents), forKey: rejectedKey)
    }
}

extension SQLiteTrainingPersistence: SyncStateStore {
    public func changedDocuments(token: String) throws -> Set<DocumentRef>? {
        guard try loadValue(forKey: changesTokenKey) == Data(token.utf8) else { return nil }
        return Set(try database.query("SELECT kind, id FROM sync_changes").compactMap { row in
            guard case .text(let kind) = row[0], case .text(let id) = row[1] else { return nil }
            return DocumentRef(kind: kind, id: id)
        })
    }

    public func resetChanges() throws {
        try performAtomically {
            try database.execute("DELETE FROM sync_changes")
            try saveValue(nil, forKey: changesTokenKey)
        }
    }

    public func trustChanges(token: String) throws { try saveValue(Data(token.utf8), forKey: changesTokenKey) }

    public func markUnchanged(kind: String, id: String) throws {
        try database.execute("DELETE FROM sync_changes WHERE kind = ? AND id = ?", kind, DocumentWrite.canonicalID(id))
    }

    public func markChanged(kind: String, id: String) throws { try recordChange(kind, id) }

    public func isUnreadable(kind: String, id: String) -> Bool {
        let table = switch kind {
        case TrainingStore.sessionKind: "sessions"
        case TrainingStore.exerciseKind: "custom_exercises"
        default: kind
        }
        return unreadableRows.contains("\(table)/\(DocumentWrite.canonicalID(id))")
    }

    public func syncBases() throws -> [SyncBase] {
        try database.query("SELECT kind, id, revision, payload, push_key, push_hash, previous FROM sync_bases").compactMap { row in
            guard case .text(let kind) = row[0], case .text(let id) = row[1], case .integer(let revision) = row[2] else {
                return nil
            }
            var base = SyncBase(kind: kind, id: id, revision: Int(revision))
            if case .blob(let payload) = row[3] { base.payload = payload }
            if case .text(let key) = row[4] { base.pushKey = key }
            if case .text(let hash) = row[5] { base.pushHash = hash }
            if case .blob(let previous) = row[6] { base.previous = previous }
            return base
        }
    }

    public func saveSyncBase(_ base: SyncBase) throws {
        try database.execute(
            """
            INSERT INTO sync_bases (kind, id, revision, payload, push_key, push_hash, previous) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (kind, id) DO UPDATE SET revision = excluded.revision, payload = excluded.payload,
                push_key = excluded.push_key, push_hash = excluded.push_hash, previous = excluded.previous
            """,
            base.kind, base.id, base.revision, base.payload, base.pushKey, base.pushHash, base.previous
        )
    }

    public func removeSyncBase(kind: String, id: String) throws {
        try database.execute("DELETE FROM sync_bases WHERE kind = ? AND id = ?", kind, id)
    }

    public func syncCursor() throws -> Int {
        try loadValue(forKey: cursorKey).flatMap { String(bytes: $0, encoding: .utf8).flatMap(Int.init) } ?? 0
    }

    public func saveSyncCursor(_ cursor: Int) throws { try saveValue(Data(String(cursor).utf8), forKey: cursorKey) }
    public func rejectedDocuments() throws -> [RejectedDocument] { try loadRejected(loadValue(forKey: rejectedKey)) }
    public func saveRejectedDocuments(_ documents: [RejectedDocument]) throws {
        try saveValue(encodeRejected(documents), forKey: rejectedKey)
    }
}
