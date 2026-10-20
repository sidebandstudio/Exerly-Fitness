import Foundation

/// The full export, including what this device hasn't synced yet. The
/// server's export (`AccountAPI.exportAccount()`) holds what reached the
/// server; this overlays the device's newer documents, so a workout logged
/// offline is never left out.
@MainActor
public enum AccountExport {
    /// An entry the legacy app holds that the server doesn't have yet: a food
    /// log, water, weight, measurement, diary day, activity or sleep entry.
    public struct PendingRow: Sendable, Hashable {
        /// The server export's table, such as "food" or "weights".
        public var table: String
        /// The entry's client ID, or its date for a once-a-day entry.
        public var clientID: String
        public var serverID: String?
        /// The row as the device holds it, a JSON object; nil when it was deleted here.
        public var row: Data?

        public init(table: String, clientID: String, serverID: String?, row: Data?) {
            self.table = table
            self.clientID = clientID
            self.serverID = serverID
            self.row = row
        }
    }

    /// The server export with this device's unsynced documents merged into its
    /// `documents` rows, and the legacy app's `pending` entries into their
    /// tables. Each added or replaced row carries `"pending_sync": true`;
    /// anything deleted on this device but not yet on the server is left out.
    /// With no server export (offline), the result holds this device's data
    /// only, and says so in `note`. `context` records the account's time zone
    /// and units, and `imports` where imported documents came from.
    public static func merging(server: Data?, hosts: [DocumentHost], state: SyncStateStore,
                               pending: [PendingRow] = [], context: Context? = nil, imports: [ImportRecord] = [],
                               now: Date = Date()) throws -> Data {
        var export: [String: Any]
        if let server {
            guard let parsed = try JSONSerialization.jsonObject(with: server) as? [String: Any] else {
                throw DocumentError(message: "The server export isn't a JSON object")
            }
            export = parsed
        } else {
            export = [
                "exported_at": ISOMilliseconds.format(now.millisecondsSince1970),
                "version": 3,
                "source": "device",
                "note": "Exported on this device while offline: training, proposals, the audit log and entries waiting to sync only. "
                    + "Account details and data kept only on the server are not included.",
            ]
        }
        let bases = Dictionary(try state.syncBases().map { ("\($0.kind)/\($0.id)", $0) }, uniquingKeysWith: { a, _ in a })
        var rows = (export["documents"] as? [[String: Any]]) ?? []
        func index(_ kind: String, _ id: String) -> Int? {
            rows.firstIndex { $0["kind"] as? String == kind && $0["document_id"] as? String == id }
        }
        var seen = Set<String>()
        for host in hosts {
            for kind in host.documentKinds {
                for id in host.documentIDs(kind: kind) {
                    seen.insert("\(kind)/\(id)")
                    guard let local = try host.payload(kind: kind, id: id) else { continue }
                    let base = bases["\(kind)/\(id)"]
                    let synced = base?.payload == local
                    if synced && server != nil { continue }
                    var row: [String: Any] = [
                        "kind": kind, "document_id": id, "revision": base?.revision ?? 0,
                        "payload": try JSONSerialization.jsonObject(with: local), "deleted_at": NSNull(),
                    ]
                    if !synced { row["pending_sync"] = true }
                    if let existing = index(kind, id) {
                        rows[existing] = rows[existing].merging(row) { _, new in new }
                    } else {
                        rows.append(row)
                    }
                }
            }
        }
        // Deleted here, not yet on the server: the person no longer has it.
        rows.removeAll { row in
            guard let kind = row["kind"] as? String, let id = row["document_id"] as? String,
                  hosts.contains(where: { $0.documentKinds.contains(kind) }), !seen.contains("\(kind)/\(id)")
            else { return false }
            return bases["\(kind)/\(id)"]?.payload != nil
        }
        export["documents"] = rows
        for entry in pending {
            var table = (export[entry.table] as? [[String: Any]]) ?? []
            let existing = table.firstIndex { row in
                row["client_id"] as? String == entry.clientID || row["entry_date"] as? String == entry.clientID
                    || (entry.serverID != nil && (row["id"] as? String ?? (row["id"] as? NSNumber)?.stringValue) == entry.serverID)
            }
            if let data = entry.row {
                guard var row = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw DocumentError(message: "A pending \(entry.table) row isn't a JSON object")
                }
                row["pending_sync"] = true
                if let existing {
                    table[existing] = table[existing].merging(row) { _, new in new }
                } else {
                    table.append(row)
                }
            } else if let existing {
                table.remove(at: existing)
            }
            export[entry.table] = table
        }
        if let context {
            export["context"] = ["time_zone": context.timeZone.identifier, "mass_unit": context.unit.rawValue,
                                 "instants": "UTC, ISO 8601", "dates": "local dates in time_zone"]
        }
        if !imports.isEmpty {
            export["imports"] = imports.map { record -> [String: Any] in
                var row: [String: Any] = [
                    "id": record.id.uuidString, "source": record.source.rawValue, "files": record.files,
                    "imported_at": ISOMilliseconds.format(record.importedAt.millisecondsSince1970), "time_zone": record.timeZoneID,
                    "documents": record.changes.filter { $0.after != nil }.map { "\($0.kind)/\($0.id)" },
                ]
                if let undone = record.undoneAt { row["undone_at"] = ISOMilliseconds.format(undone.millisecondsSince1970) }
                return row
            }
        }
        return try JSONSerialization.data(withJSONObject: export, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// The account's settings that say how to read the export's numbers and dates.
    public struct Context: Sendable, Hashable {
        public var timeZone: TimeZone
        public var unit: MassUnit

        public init(timeZone: TimeZone, unit: MassUnit) {
            self.timeZone = timeZone
            self.unit = unit
        }
    }
}
