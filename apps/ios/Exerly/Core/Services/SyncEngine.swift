import ExerlyCore
import Foundation
import SwiftData
import Network
import Combine

struct LegacyMeasurementImport {
    let recordID: PersistentIdentifier
    let type: String
    let value: Double
    let unit: String
    let timestamp: Date
    var day: CalendarDay

    init(_ record: Measurement, day: CalendarDay) {
        recordID = record.persistentModelID
        type = record.type; value = record.value; unit = record.unit
        timestamp = record.date; self.day = day
    }

    func matches(_ record: Measurement) -> Bool {
        recordID == record.persistentModelID && type == record.type && value == record.value
            && unit == record.unit && timestamp == record.date
    }
}

enum JSONValue: Codable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

@MainActor
final class SyncEngine: ObservableObject {
    static let shared = SyncEngine()
    @Published private(set) var pendingCount = 0
    @Published private(set) var attentionCount = 0
    @Published private(set) var isSyncing = false
    @Published private(set) var isOffline = false
    @Published private(set) var changeToken = 0
    @Published var error: String?
    /// When a sync last sent every queued change it could and pulled the server's.
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var accountID: String?
    @Published private(set) var calendar: AccountCalendar
    @Published private(set) var today: CalendarDay
    private var context: ModelContext?
    private let api: APIClient
    private let automaticallySync: Bool
    private let monitor = NWPathMonitor()
    private var retryTask: Task<Void, Never>?
    private var calendarTask: Task<Void, Never>?
    private let now: () -> Date

    init(api: APIClient = .shared, monitorNetwork: Bool = true, automaticallySync: Bool = true,
         observeClock: Bool = true, now: @escaping () -> Date = Date.init) {
        self.api = api
        self.automaticallySync = automaticallySync
        self.now = now
        let calendar = AccountCalendar(timeZoneIdentifier: nil)
        self.calendar = calendar
        self.today = calendar.today(now: now())
        if observeClock {
            calendarTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    self?.refreshCalendarDay()
                }
            }
        }
        if monitorNetwork {
            monitor.pathUpdateHandler = { [weak self] path in
                Task { @MainActor in
                    guard let self else { return }
                    self.isOffline = path.status != .satisfied
                    if path.status == .satisfied { await self.synchronize(force: true) }
                }
            }
            monitor.start(queue: DispatchQueue(label: "com.exerly.connectivity"))
        }
    }
    deinit { monitor.cancel(); retryTask?.cancel(); calendarTask?.cancel() }

    func refreshCalendarDay() {
        let day = calendar.today(now: now())
        if today != day { today = day }
    }

    func isConfigured(for id: String?) -> Bool {
        guard let id else { return false }
        return context != nil && accountID == "\(api.storageNamespace):\(id)"
    }
    private func serverAccountID(_ owner: String) -> String { String(owner.dropFirst(api.storageNamespace.count + 1)) }

    func configure(container: ModelContainer, accountID: String?, timeZone: String? = nil) {
        let calendar = AccountCalendar(timeZoneIdentifier: timeZone)
        if self.calendar != calendar { self.calendar = calendar }
        refreshCalendarDay()
        let accountID = accountID.map { "\(api.storageNamespace):\($0)" }
        guard context == nil || self.accountID != accountID else { return }
        retryTask?.cancel()
        self.accountID = accountID
        let context = ModelContext(container)
        context.autosaveEnabled = false
        self.context = context
        resetStatus()
        refreshCounts()
        if accountID != nil && automaticallySync { Task { await synchronize(force: true) } }
    }

    /// Another account starts with no error, offline state or sync time of
    /// the last one's; its first sync sets them.
    private func resetStatus() {
        error = nil
        isOffline = false
        lastSyncedAt = nil
    }

    enum PurgeError: Error { case notConfigured }

    /// Removes a deleted account's offline queue, synced copies, cached responses
    /// and checkpoint. If that account is the configured one, syncing it stops.
    func purge(accountID: String) throws {
        guard let context else { throw PurgeError.notConfigured }
        let owner = "\(api.storageNamespace):\(accountID)"
        if self.accountID == owner {
            retryTask?.cancel()
            self.accountID = nil
            resetStatus()
        }
        try context.delete(model: SyncedResource.self, where: #Predicate { $0.accountID == owner })
        try context.delete(model: PendingMutation.self, where: #Predicate { $0.accountID == owner })
        try context.delete(model: CachedAPIResponse.self, where: #Predicate { $0.accountID == owner })
        try context.delete(model: SyncCheckpoint.self, where: #Predicate { $0.accountID == owner })
        try context.save()
        refreshCounts()
    }

    /// The configured account's entries that haven't reached the server, for
    /// `AccountExport.merging(pending:)`, so an export made before they sync
    /// still holds them.
    func pendingExportRows() throws -> [AccountExport.PendingRow] {
        let tables = ["food": "food", "measurement": "measurements", "diary_day": "diary_days", "water": "water",
                      "weight": "weights", "activity": "activities", "sleep": "sleep"]
        return try ownedResources().compactMap { resource in
            guard resource.syncState == "pending" || resource.syncState == "attention",
                  let table = tables[resource.kind] else { return nil }
            return AccountExport.PendingRow(table: table, clientID: resource.entityID, serverID: resource.serverID,
                                            row: resource.tombstoned ? nil : resource.payload)
        }
    }

    private func ownedResources() throws -> [SyncedResource] {
        guard let accountID, let context else { return [] }
        return try context.fetch(FetchDescriptor<SyncedResource>(predicate: #Predicate { $0.accountID == accountID }))
    }
    private func operations() throws -> [PendingMutation] {
        guard let accountID, let context else { return [] }
        return try context.fetch(FetchDescriptor<PendingMutation>(predicate: #Predicate { $0.accountID == accountID }, sortBy: [SortDescriptor(\.createdAt)]))
    }
    func refreshCounts() {
        do {
            let queue = try operations()
            pendingCount = queue.filter { $0.state != "attention" }.count
            attentionCount = queue.filter { $0.state == "attention" }.count
        } catch { self.error = "Saved changes could not be read. Keep the app installed and try again." }
    }

    func read(_ path: String, cachedOnly: Bool = false) async throws -> Data {
        guard let accountID, let context else { throw APIError.unauthorized }
        let key = "\(accountID):\(path)"
        let cached = try context.fetch(FetchDescriptor<CachedAPIResponse>(predicate: #Predicate { $0.key == key })).first
        if cachedOnly {
            guard let cached else { throw APIError.unknown }
            return cached.payload
        }
        do {
            let document: JSONValue = try await api.request("GET", path: path, expectedAccountID: serverAccountID(accountID))
            guard self.accountID == accountID else { throw CancellationError() }
            let data = try JSONEncoder().encode(document)
            if let cached { cached.payload = data; cached.updatedAt = Date() }
            else { context.insert(CachedAPIResponse(accountID: accountID, path: path, payload: data)) }
            try context.save()
            isOffline = false
            return data
        } catch is CancellationError { throw CancellationError() }
        catch APIError.unauthorized { throw APIError.unauthorized }
        catch {
            guard self.accountID == accountID else { throw CancellationError() }
            if let apiError = error as? APIError, !apiError.permitsReadRetry {
                if case .decodingError = apiError {} else { throw error }
            }
            isOffline = true
            if let cached { return cached.payload }
            throw error
        }
    }

    @discardableResult
    func saveFood(_ request: FoodRequest, editing: FoodDTO? = nil) throws -> String {
        guard let accountID, let context else { throw APIError.unauthorized }
        let resources = try ownedResources()
        let old = resources.first { editing != nil && $0.kind == "food" && ($0.entityID == editing?.clientID || ($0.serverID != nil && $0.serverID == editing?.id)) }
        let entityID = old?.entityID ?? editing?.clientID ?? UUID().uuidString.lowercased()
        var body = try object(JSONEncoder().encode(request))
        body["client_id"] = entityID
        let data = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        let resource = old ?? SyncedResource(accountID: accountID, kind: "food", entityID: entityID, payload: data)
        let hasEarlierMutation = try operations().contains { $0.kind == "food" && $0.entityID == entityID }
        let endpoint = editing != nil ? "/api/food/{id}" : "/api/food"
        let operation = PendingMutation(accountID: accountID, entityID: entityID, kind: "food", method: editing != nil ? "PUT" : "POST", endpoint: endpoint, payload: data, baseRevision: hasEarlierMutation ? nil : editing?.revision)
        do {
            if old == nil { context.insert(resource); resource.serverID = editing?.id; resource.revision = editing?.revision ?? 0 }
            resource.payload = try foodSnapshot(body, entityID: entityID, serverID: resource.serverID, revision: resource.revision)
            resource.tombstoned = false
            resource.syncState = "pending"
            resource.updatedAt = Date()
            context.insert(operation)
            try context.save() // Both the entry and its operation commit together.
        } catch { context.rollback(); throw error }
        changeToken += 1
        refreshCounts()
        if automaticallySync { Task { await synchronize() } }
        return entityID
    }

    @discardableResult
    func saveMeasurement(_ request: BodyMeasurementRequest, editing: BodyMeasurementDTO? = nil, commit: Bool = true) throws -> String {
        guard let accountID, let context else { throw APIError.unauthorized }
        guard BodySite(rawValue: request.type) != nil,
              request.value.isFinite, request.value > 0, request.value <= (request.type == "body_fat" ? 100 : 1000),
              request.unit == (request.type == "body_fat" ? "%" : "cm") else {
            throw APIError.serverError(400, "Enter a valid measurement.")
        }
        let old = try ownedResources().first { $0.kind == "measurement" && $0.entityID == editing?.client_id }
        let entityID = old?.entityID ?? editing?.client_id ?? UUID().uuidString.lowercased()
        var body = try object(JSONEncoder().encode(request))
        body["client_id"] = entityID
        let payload = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        let resource = old ?? SyncedResource(accountID: accountID, kind: "measurement", entityID: entityID, payload: payload)
        let pending = try operations().contains { $0.kind == "measurement" && $0.entityID == entityID }
        let operation = PendingMutation(accountID: accountID, entityID: entityID, kind: "measurement",
            method: editing == nil ? "POST" : "PUT", endpoint: editing == nil ? "/api/measurements" : "/api/measurements/{id}",
            payload: payload, baseRevision: pending ? nil : editing?.revision)
        do {
            if old == nil {
                context.insert(resource)
                resource.serverID = editing?.id
                resource.revision = editing?.revision ?? 0
            }
            body["id"] = resource.serverID ?? entityID
            body["revision"] = resource.revision
            resource.payload = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
            resource.syncState = "pending"
            resource.updatedAt = Date()
            resource.tombstoned = false
            context.insert(operation)
            if commit { try context.save() }
        } catch { context.rollback(); throw error }
        if commit {
            changeToken += 1
            refreshCounts()
            if automaticallySync { Task { await synchronize() } }
        }
        return entityID
    }

    /// Saves new measurements as one change: all of them or, on any error, none.
    func saveMeasurements(_ requests: [BodyMeasurementRequest]) throws {
        guard let context else { throw APIError.unauthorized }
        do {
            for request in requests { try saveMeasurement(request, commit: false) }
            try context.save()
        } catch { context.rollback(); throw error }
        changeToken += 1
        refreshCounts()
        if automaticallySync { Task { await synchronize() } }
    }

    func importLegacyMeasurements(_ reviewed: [LegacyMeasurementImport]) throws {
        guard accountID != nil, let context, !reviewed.isEmpty, reviewed.count <= 500 else { throw APIError.unknown }
        let selected = Set(reviewed.map(\.recordID))
        guard selected.count == reviewed.count else { throw APIError.unknown }
        let records = try context.fetch(FetchDescriptor<Measurement>()).filter { selected.contains($0.persistentModelID) }
        guard records.count == selected.count,
              reviewed.allSatisfy({ item in records.contains(where: item.matches) }) else {
            throw APIError.serverError(409, "These saved measurements changed. Reopen the review before importing.")
        }
        guard reviewed.allSatisfy({ $0.day <= today && $0.day >= today.adding(days: -3650)! }) else {
            throw APIError.serverError(400, "Review the import dates. Choose today or a date within the past ten years in your account time zone.")
        }
        do {
            for item in reviewed {
                let old = records.first { $0.persistentModelID == item.recordID }!
                let unit = old.unit.lowercased()
                guard ["cm", "in", "%"].contains(unit) else {
                    throw APIError.serverError(400, "One selected measurement has an unsupported unit. Export it for review before importing.")
                }
                let value = unit == "in" ? old.value * 2.54 : old.value
                let body = BodyMeasurementRequest(type: old.type, value: value, unit: unit == "in" ? "cm" : unit,
                    entry_date: item.day.rawValue, source: "legacy_device_import")
                try saveMeasurement(body, commit: false)
                context.delete(old)
            }
            // Moving each legacy record and queuing its owned copy is one
            // durable transaction. A failed batch leaves every original intact.
            try context.save()
        } catch { context.rollback(); throw error }
        changeToken += 1
        refreshCounts()
        if automaticallySync { Task { await synchronize() } }
    }

    func measurements(from: String, to: String, cachedOnly: Bool = false) async throws -> [BodyMeasurementDTO] {
        guard let owner = accountID, let context else { throw APIError.unauthorized }
        var resources = try ownedResources()
        var offset = 0
        while true {
            let path = "/api/measurements?from=\(from)&to=\(to)&limit=500&offset=\(offset)"
            let page: BodyMeasurementPage
            do { page = try JSONDecoder().decode(BodyMeasurementPage.self, from: await read(path, cachedOnly: cachedOnly)) }
            catch {
                guard accountID == owner else { throw CancellationError() }
                if cachedOnly || ((error as? APIError)?.permitsReadRetry == true) {
                    if resources.contains(where: { $0.kind == "measurement" }) { break }
                }
                throw error
            }
            guard accountID == owner else { throw CancellationError() }
            let queue = try operations()
            for measurement in page.entries {
                let existing = resources.first { $0.kind == "measurement" && $0.entityID == measurement.client_id }
                if queue.contains(where: { $0.kind == "measurement" && $0.entityID == measurement.client_id }) { continue }
                if let existing, existing.revision > measurement.revision { continue }
                let payload = try JSONEncoder().encode(measurement)
                let resource = existing ?? SyncedResource(accountID: owner, kind: "measurement", entityID: measurement.client_id, payload: payload)
                if existing == nil { context.insert(resource); resources.append(resource) }
                resource.serverID = measurement.id
                resource.revision = measurement.revision
                resource.payload = payload
                resource.syncedPayload = payload
                resource.tombstoned = false
                resource.syncState = "synced"
            }
            try context.save()
            offset += page.entries.count
            if offset >= page.total || page.entries.isEmpty { break }
        }
        guard accountID == owner else { throw CancellationError() }
        return try resources.filter { $0.kind == "measurement" && !$0.tombstoned }.map { resource in
            var item = try JSONDecoder().decode(BodyMeasurementDTO.self, from: resource.payload)
            item.sync_state = resource.syncState
            return item
        }.filter { $0.entry_date >= from && $0.entry_date <= to }.sorted { $0.entry_date > $1.entry_date }
    }

    @discardableResult
    func saveActivity(_ request: ActivityRequest, editing: ActivityDTO? = nil) throws -> String {
        guard !request.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, request.type.utf16.count <= 120,
              request.duration.isFinite, (0.1...1440).contains(request.duration),
              (request.intensity?.utf16.count ?? 0) <= 32, (request.category?.utf16.count ?? 0) <= 48,
              request.calories.map({ $0.isFinite && (0...20000).contains($0) }) ?? true else {
            throw APIError.serverError(400, "Enter an activity, 0.1 to 1,440 minutes, and a valid calorie amount if known.")
        }
        var body = try object(JSONEncoder().encode(request))
        body["activity"] = request.type.trimmingCharacters(in: .whitespacesAndNewlines)
        body["entry_date"] = request.entryDate ?? today.rawValue
        return try saveLog(kind: "activity", body: body, entityID: editing?.clientID, serverID: editing?.id,
            revision: editing?.revision, createdAt: editing?.createdAt)
    }

    @discardableResult
    func saveSleep(_ request: SleepRequest, editing: SleepDTO? = nil) throws -> String {
        guard request.hours.isFinite, (0...24).contains(request.hours),
              (request.quality?.utf16.count ?? 0) <= 32,
              (request.bedtime?.utf16.count ?? 0) <= 16, (request.wakeTime?.utf16.count ?? 0) <= 16 else {
            throw APIError.serverError(400, "Enter a sleep duration from 0 to 24 hours and valid times.")
        }
        var body = try object(JSONEncoder().encode(request))
        body["entry_date"] = request.entryDate ?? today.rawValue
        body["wake_time"] = body.removeValue(forKey: "wakeTime")
        return try saveLog(kind: "sleep", body: body, entityID: editing?.clientID, serverID: editing?.id,
            revision: editing?.revision, createdAt: editing?.createdAt)
    }

    private func saveLog(kind: String, body: [String: Any], entityID: String?, serverID: String?, revision: Int?, createdAt: String?) throws -> String {
        guard let accountID, let context else { throw APIError.unauthorized }
        guard let value = body["entry_date"] as? String, let day = CalendarDay(rawValue: value),
              day <= today, day >= today.adding(days: -3650)! else {
            throw APIError.serverError(400, "Choose today or a date within the past ten years.")
        }
        let entityID = entityID ?? UUID().uuidString.lowercased()
        let existing = try ownedResources().first { $0.kind == kind && $0.entityID == entityID }
        if existing?.tombstoned == true { throw APIError.serverError(409, "This entry was deleted. Restore it before editing.") }
        var body = body
        body["client_id"] = entityID
        let data = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        let resource = existing ?? SyncedResource(accountID: accountID, kind: kind, entityID: entityID, payload: data)
        let hasEarlier = try operations().contains { $0.kind == kind && $0.entityID == entityID }
        let editing = revision != nil
        let path = try collectionPath(kind)
        let mutation = PendingMutation(accountID: accountID, entityID: entityID, kind: kind,
            method: editing ? "PUT" : "POST", endpoint: editing ? "\(path)/{id}" : path,
            payload: data, baseRevision: hasEarlier ? nil : revision)
        do {
            if existing == nil {
                context.insert(resource)
                resource.serverID = serverID; resource.revision = revision ?? 0
            }
            var snapshot = body
            snapshot["id"] = resource.serverID ?? entityID
            snapshot["revision"] = resource.revision
            snapshot["created_at"] = createdAt ?? Date().ISO8601Format()
            resource.payload = try JSONSerialization.data(withJSONObject: snapshot)
            resource.tombstoned = false; resource.syncState = "pending"; resource.updatedAt = Date()
            context.insert(mutation)
            try context.save()
        } catch { context.rollback(); throw error }
        changeToken += 1; refreshCounts()
        if automaticallySync { Task { await synchronize() } }
        return entityID
    }

    private func adoptLog(_ input: [String: Any], kind: String) throws {
        guard let accountID, let context, let id = string(input["id"] ?? input["_id"]) else { return }
        var row = input
        let entityID = row["client_id"] as? String ?? "legacy-\(id)"
        row["client_id"] = entityID; row["revision"] = row["revision"] ?? 1
        let existing = try ownedResources().first { $0.kind == kind && ($0.entityID == entityID || $0.serverID == id) }
        if try operations().contains(where: { $0.kind == kind && $0.entityID == (existing?.entityID ?? entityID) }) { return }
        let revision = row["revision"] as? Int ?? 1
        if let existing, existing.revision > revision { return }
        let data = try JSONSerialization.data(withJSONObject: row)
        let resource = existing ?? SyncedResource(accountID: accountID, kind: kind, entityID: entityID, payload: data)
        if existing == nil { context.insert(resource) }
        resource.payload = data; resource.syncedPayload = data; resource.serverID = id
        resource.revision = revision; resource.tombstoned = row["deleted_at"] is String; resource.syncState = "synced"
        try context.save()
    }

    private func logSnapshots(kind: String, from: String, to: String) throws -> [[String: Any]] {
        try ownedResources().filter { $0.kind == kind && !$0.tombstoned }.compactMap { resource in
            var row = try object(resource.payload)
            guard let day = row["entry_date"] as? String, day >= from, day <= to else { return nil }
            row["deleted_at"] = nil; row["sync_state"] = resource.syncState
            return row
        }.sorted { ($0["created_at"] as? String ?? "") > ($1["created_at"] as? String ?? "") }
    }

    func activityEntries(from: String, to: String, cachedOnly: Bool = false) async throws -> [ActivityDTO] {
        try await loadLogs(kind: "activity", from: from, to: to, cachedOnly: cachedOnly)
    }
    func sleepEntries(from: String, to: String, cachedOnly: Bool = false) async throws -> [SleepDTO] {
        try await loadLogs(kind: "sleep", from: from, to: to, cachedOnly: cachedOnly)
    }
    private func loadLogs<T: Decodable>(kind: String, from: String, to: String, cachedOnly: Bool) async throws -> [T] {
        guard let owner = accountID else { throw APIError.unauthorized }
        if !cachedOnly {
            let path = try collectionPath(kind)
            var page = 1
            do {
                while true {
                    let data = try await read("\(path)?from=\(from)&to=\(to)&include_deleted=true&limit=500&page=\(page)")
                    guard accountID == owner else { throw CancellationError() }
                    guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw APIError.unknown }
                    for row in rows { try adoptLog(row, kind: kind) }
                    if rows.count < 500 { break }
                    page += 1
                }
            } catch {
                guard accountID == owner else { throw CancellationError() }
                guard (error as? APIError)?.permitsReadRetry == true else { throw error }
                let saved = try ownedResources().contains { $0.kind == kind }
                if !saved { throw error }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: logSnapshots(kind: kind, from: from, to: to))
        return try JSONDecoder().decode([T].self, from: data)
    }
    @discardableResult
    func deleteActivity(_ item: ActivityDTO) throws -> String { try deleteLog(kind: "activity", entityID: item.clientID, revision: item.revision) }
    @discardableResult
    func deleteSleep(_ item: SleepDTO) throws -> String { try deleteLog(kind: "sleep", entityID: item.clientID, revision: item.revision) }
    private func deleteLog(kind: String, entityID: String?, revision: Int) throws -> String {
        guard let resource = try ownedResources().first(where: { $0.kind == kind && $0.entityID == entityID }) else { throw APIError.unknown }
        return try deleteResource(resource, baseRevision: revision)
    }
    func undoActivityDeletion(entityID: String) throws { try undoDeletion(kind: "activity", entityID: entityID) }
    func undoSleepDeletion(entityID: String) throws { try undoDeletion(kind: "sleep", entityID: entityID) }

    @discardableResult
    func deleteFood(_ food: FoodDTO) throws -> String {
        guard let resource = try ownedResources().first(where: { $0.kind == "food" && ($0.entityID == food.clientID || $0.serverID == food.id) }) else { throw APIError.unknown }
        return try deleteResource(resource)
    }
    @discardableResult
    func deleteMeasurement(_ measurement: BodyMeasurementDTO) throws -> String {
        guard let resource = try ownedResources().first(where: { $0.kind == "measurement" && $0.entityID == measurement.client_id }) else { throw APIError.unknown }
        return try deleteResource(resource)
    }
    private func deleteResource(_ resource: SyncedResource, baseRevision: Int? = nil) throws -> String {
        guard let accountID, let context else { throw APIError.unauthorized }
        let path = try collectionPath(resource.kind)
        let hasEarlierMutation = try operations().contains { $0.entityID == resource.entityID && $0.kind == resource.kind }
        let operation = PendingMutation(accountID: accountID, entityID: resource.entityID, kind: resource.kind, method: "DELETE", endpoint: "\(path)/{id}", payload: Data("{}".utf8), baseRevision: hasEarlierMutation ? nil : (baseRevision ?? resource.revision))
        do {
            resource.tombstoned = true
            resource.syncState = "pending"
            context.insert(operation)
            try context.save()
        } catch { context.rollback(); throw error }
        changeToken += 1
        refreshCounts()
        if automaticallySync { Task { await synchronize() } }
        return resource.entityID
    }

    func undoFoodDeletion(entityID: String) throws {
        try undoDeletion(kind: "food", entityID: entityID)
    }
    func undoMeasurementDeletion(entityID: String) throws {
        try undoDeletion(kind: "measurement", entityID: entityID)
    }
    private func undoDeletion(kind: String, entityID: String) throws {
        guard let accountID, let context,
              let resource = try ownedResources().first(where: { $0.kind == kind && $0.entityID == entityID }) else { throw APIError.unknown }
        let path = try collectionPath(kind)
        let queue = try operations().filter { $0.entityID == entityID && $0.kind == kind }
        do {
            if let deletion = queue.last, deletion.method == "DELETE", deletion.attempts == 0 {
                context.delete(deletion)
                resource.syncState = queue.count == 1 ? "synced" : "pending"
            } else {
                let operation = PendingMutation(accountID: accountID, entityID: entityID, kind: kind, method: "POST", endpoint: "\(path)/{id}/restore", payload: Data("{}".utf8), baseRevision: queue.isEmpty ? resource.revision : nil)
                context.insert(operation)
                resource.syncState = "pending"
            }
            resource.tombstoned = false
            try context.save()
        } catch { context.rollback(); throw error }
        changeToken += 1
        refreshCounts()
        if automaticallySync { Task { await synchronize(force: true) } }
    }

    enum ChangeIntent { case save, delete, restore }
    struct Issue: Identifiable {
        let id: String
        let name: String
        let message: String
        let local: FoodDTO?
        let serverID: String?
        let kind: String
        let measurement: BodyMeasurementDTO?
        let diaryDay: DiaryDayDTO?
        let water: WaterDayDTO?
        let weight: WeightDayDTO?
        let activity: ActivityDTO?
        let sleep: SleepDTO?
        let intent: ChangeIntent
    }
    func issues() throws -> [Issue] {
        let resources = try ownedResources()
        let queue = try operations()
        return queue.filter { $0.state == "attention" }.map { operation in
            let resource = resources.first { $0.entityID == operation.entityID && $0.kind == operation.kind }
            let food = resource.flatMap { $0.kind == "food" ? try? JSONDecoder().decode(FoodDTO.self, from: $0.payload) : nil }
            let measurement = resource.flatMap { $0.kind == "measurement" ? try? JSONDecoder().decode(BodyMeasurementDTO.self, from: $0.payload) : nil }
            let diaryDay = resource.flatMap { $0.kind == "diary_day" ? try? JSONDecoder().decode(DiaryDayDTO.self, from: $0.payload) : nil }
            let water = resource.flatMap { $0.kind == "water" ? try? JSONDecoder().decode(WaterDayDTO.self, from: $0.payload) : nil }
            let weight = resource.flatMap { $0.kind == "weight" ? try? JSONDecoder().decode(WeightDayDTO.self, from: $0.payload) : nil }
            let activity = resource.flatMap { $0.kind == "activity" ? try? JSONDecoder().decode(ActivityDTO.self, from: $0.payload) : nil }
            let sleep = resource.flatMap { $0.kind == "sleep" ? try? JSONDecoder().decode(SleepDTO.self, from: $0.payload) : nil }
            let latest = queue.last { $0.kind == operation.kind && $0.entityID == operation.entityID } ?? operation
            let intent: ChangeIntent = latest.method == "DELETE" ? .delete : latest.endpoint.hasSuffix("/restore") ? .restore : .save
            let name: String
            switch operation.kind {
            case "food": name = food?.name ?? "Food entry"
            case "activity": name = activity?.type ?? "Activity"
            case "sleep": name = "Sleep · \(sleep?.date ?? "")"
            case "measurement": name = measurement?.type.capitalized ?? "Measurement"
            case "diary_day": name = "Logging status · \(diaryDay?.entry_date ?? "")"
            case "water": name = "Water · \(water?.entry_date ?? "")"
            case "weight": name = "Weight · \(weight?.entry_date ?? "")"
            default: name = "Saved change"
            }
            return Issue(id: operation.operationID, name: name, message: operation.lastError ?? "Review this change.",
                local: food, serverID: resource?.serverID, kind: operation.kind, measurement: measurement,
                diaryDay: diaryDay, water: water, weight: weight, activity: activity, sleep: sleep, intent: intent)
        }
    }
    func serverVersion(for issue: Issue) async throws -> (FoodDTO?, Bool) {
        try await currentVersion(for: issue)
    }
    func serverMeasurementVersion(for issue: Issue) async throws -> (BodyMeasurementDTO?, Bool) {
        try await currentVersion(for: issue)
    }
    func serverDiaryDayVersion(for issue: Issue) async throws -> (DiaryDayDTO?, Bool) {
        try await currentVersion(for: issue)
    }
    func serverWaterVersion(for issue: Issue) async throws -> (WaterDayDTO?, Bool) {
        try await currentVersion(for: issue)
    }
    func serverWeightVersion(for issue: Issue) async throws -> (WeightDayDTO?, Bool) { try await currentVersion(for: issue) }
    func serverActivityVersion(for issue: Issue) async throws -> (ActivityDTO?, Bool) { try await currentVersion(for: issue) }
    func serverSleepVersion(for issue: Issue) async throws -> (SleepDTO?, Bool) { try await currentVersion(for: issue) }
    private func collectionPath(_ kind: String) throws -> String {
        switch kind {
        case "food": return "/api/food"
        case "measurement": return "/api/measurements"
        case "diary_day": return "/api/diary/day"
        case "water": return "/api/water"
        case "weight": return "/api/weight"
        case "activity": return "/api/activities"
        case "sleep": return "/api/sleep"
        default: throw APIError.unknown
        }
    }
    private func currentVersion<T: Decodable>(for issue: Issue) async throws -> (T?, Bool) {
        guard let owner = accountID else { throw APIError.unauthorized }
        let path = try collectionPath(issue.kind)
        let endpoint: String
        if let day = issue.diaryDay { endpoint = "\(path)?entry_date=\(day.entry_date)" }
        else if let water = issue.water { endpoint = "\(path)?entry_date=\(water.entry_date)" }
        else if let weight = issue.weight { endpoint = "\(path)/day?entry_date=\(weight.entry_date)" }
        else if let serverID = issue.serverID { endpoint = "\(path)/\(serverID)?include_deleted=true" }
        else { return (nil, false) }
        let value: JSONValue = try await api.request("GET", path: endpoint, expectedAccountID: serverAccountID(owner))
        guard accountID == owner else { throw CancellationError() }
        let data = try JSONEncoder().encode(value)
        return (try JSONDecoder().decode(T.self, from: data), try object(data)["deleted_at"] is String)
    }
    func resolveIssue(_ id: String, useServer: Bool, reviewedRevision: Int?) async throws {
        guard let accountID, let context,
              let operation = try operations().first(where: { $0.operationID == id }),
              let resource = try ownedResources().first(where: { $0.entityID == operation.entityID && $0.kind == operation.kind }) else { throw APIError.unknown }
        let queue = try operations().filter { $0.entityID == operation.entityID && $0.kind == operation.kind }
        let path = try collectionPath(operation.kind)
        var serverPayload: Data?
        if resource.kind == "water", !useServer {
            for pending in queue { pending.state = "pending"; pending.retryAt = nil }
            resource.syncState = "pending"
            try context.save()
            refreshCounts()
            if automaticallySync { await synchronize(force: true) }
            return
        }
        if useServer, resource.serverID != nil || ["diary_day", "water", "weight"].contains(resource.kind) {
            let endpoint = ["diary_day", "water", "weight"].contains(resource.kind) ? "\(path)\(resource.kind == "weight" ? "/day" : "")?entry_date=\(resource.entityID)" : "\(path)/\(resource.serverID!)?include_deleted=true"
            let value: JSONValue = try await api.request("GET", path: endpoint, expectedAccountID: serverAccountID(accountID))
            guard self.accountID == accountID else { throw CancellationError() }
            serverPayload = try JSONEncoder().encode(value)
        }
        do {
            if useServer {
                if let serverPayload {
                    resource.payload = serverPayload; resource.syncedPayload = serverPayload
                    let current = try object(serverPayload)
                    resource.tombstoned = current["deleted_at"] is String
                    resource.revision = current["revision"] as? Int ?? resource.revision
                    resource.syncState = "synced"
                } else { resource.tombstoned = true; resource.syncState = "discarded" }
            } else {
                guard let latest = queue.last else { throw APIError.unknown }
                var body = try object(latest.payload)
                body.removeValue(forKey: "base_revision")
                let replacement = PendingMutation(accountID: accountID, entityID: resource.entityID, kind: resource.kind,
                    method: resource.kind == "diary_day" || (resource.kind == "weight" && latest.method == "PUT") || (latest.method == "POST" && resource.serverID != nil && !latest.endpoint.hasSuffix("/restore")) ? "PUT" : resource.serverID == nil ? "POST" : latest.method,
                    endpoint: latest.endpoint.hasSuffix("/restore") ? "\(path)/{id}/restore" : resource.kind == "weight" && latest.method == "PUT" ? "\(path)/day" : resource.kind == "diary_day" || resource.serverID == nil ? path : "\(path)/{id}",
                    payload: try JSONSerialization.data(withJSONObject: body, options: .sortedKeys), baseRevision: reviewedRevision)
                context.insert(replacement)
                resource.syncState = "pending"
            }
            queue.forEach(context.delete)
            try context.save()
        } catch { context.rollback(); throw error }
        changeToken += 1
        refreshCounts()
        if automaticallySync { await synchronize(force: true) }
    }

    func weightDay(for date: CalendarDay, cachedOnly: Bool = false) async throws -> WeightDayDTO {
        guard let owner = accountID else { throw APIError.unauthorized }
        let day = date.rawValue
        do {
            let data = try await read("/api/weight/day?entry_date=\(day)", cachedOnly: cachedOnly)
            guard accountID == owner else { throw CancellationError() }
            try adoptWeight(try JSONDecoder().decode(WeightDayDTO.self, from: data))
        } catch {
            guard accountID == owner else { throw CancellationError() }
            if let apiError = error as? APIError, !apiError.permitsReadRetry && !cachedOnly { throw error }
            if let resource = try ownedResources().first(where: { $0.kind == "weight" && $0.entityID == day }) {
                return try weightSnapshot(resource)
            }
            if cachedOnly { return .initial(day) }
            throw error
        }
        guard let resource = try ownedResources().first(where: { $0.kind == "weight" && $0.entityID == day }) else { throw APIError.unknown }
        return try weightSnapshot(resource)
    }

    func weights(from: String, to: String, cachedOnly: Bool = false) async throws -> [WeightDayDTO] {
        guard let owner = accountID else { throw APIError.unauthorized }
        do {
            let data = try await read("/api/weight?from=\(from)&to=\(to)&include_deleted=true", cachedOnly: cachedOnly)
            guard accountID == owner else { throw CancellationError() }
            for row in try JSONDecoder().decode([WeightDayDTO].self, from: data) { try adoptWeight(row) }
        } catch {
            guard accountID == owner else { throw CancellationError() }
            if let apiError = error as? APIError, !apiError.permitsReadRetry && !cachedOnly { throw error }
            let hasWeights = try ownedResources().contains { $0.kind == "weight" }
            if !cachedOnly && !hasWeights { throw error }
        }
        return try ownedResources().filter { $0.kind == "weight" && !$0.tombstoned && $0.entityID >= from && $0.entityID <= to }
            .map(weightSnapshot).filter(\.exists).sorted { $0.entry_date > $1.entry_date }
    }

    private func adoptWeight(_ row: WeightDayDTO) throws {
        guard let accountID, let context else { throw APIError.unauthorized }
        if try operations().contains(where: { $0.kind == "weight" && $0.entityID == row.entry_date }) { return }
        let old = try ownedResources().first { $0.kind == "weight" && $0.entityID == row.entry_date }
        if let old, old.revision > row.revision { return }
        let data = try JSONEncoder().encode(row)
        let resource = old ?? SyncedResource(accountID: accountID, kind: "weight", entityID: row.entry_date, payload: data)
        if old == nil { context.insert(resource) }
        resource.payload = data; resource.syncedPayload = data
        resource.serverID = row.id; resource.revision = row.revision
        resource.tombstoned = row.deleted_at != nil
        resource.syncState = "synced"
        try context.save()
    }
    private func weightSnapshot(_ resource: SyncedResource) throws -> WeightDayDTO {
        var row = try JSONDecoder().decode(WeightDayDTO.self, from: resource.payload)
        row.sync_state = resource.syncState
        row.deleted_at = resource.tombstoned ? (row.deleted_at ?? "pending") : nil
        return row
    }

    func saveWeight(_ current: WeightDayDTO, kilograms: Double, note: String) throws {
        guard let accountID, let context else { throw APIError.unauthorized }
        guard kilograms.isFinite, (20...500).contains(kilograms), note.count <= 280 else {
            throw APIError.serverError(400, "Enter a weight from 20 to 500 kg and a note of 280 characters or fewer.")
        }
        guard current.deleted_at == nil else { throw APIError.serverError(409, "This reading was deleted. Restore it before editing.") }
        let day = current.entry_date
        let old = try ownedResources().first { $0.kind == "weight" && $0.entityID == day }
        var body: [String: Any] = ["entry_date": day, "weight_kg": (kilograms * 100).rounded() / 100, "source": "manual", "note": note]
        body["body_fat_pct"] = current.body_fat_pct
        let payload = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        let resource = old ?? SyncedResource(accountID: accountID, kind: "weight", entityID: day, payload: payload)
        let pending = try operations().contains { $0.kind == "weight" && $0.entityID == day }
        let operation = PendingMutation(accountID: accountID, entityID: day, kind: "weight", method: "PUT", endpoint: "/api/weight/day", payload: payload, baseRevision: pending ? nil : current.revision)
        do {
            if old == nil { context.insert(resource); resource.revision = current.revision; resource.serverID = current.id }
            body["revision"] = resource.revision; body["id"] = resource.serverID
            resource.payload = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
            resource.tombstoned = false; resource.syncState = "pending"; resource.updatedAt = Date()
            context.insert(operation)
            try context.save()
        } catch { context.rollback(); throw error }
        changeToken += 1
        refreshCounts()
        if automaticallySync { Task { await synchronize() } }
    }
    @discardableResult
    func deleteWeight(_ row: WeightDayDTO) throws -> String {
        guard let resource = try ownedResources().first(where: { $0.kind == "weight" && $0.entityID == row.entry_date }) else { throw APIError.unknown }
        return try deleteResource(resource, baseRevision: row.revision)
    }
    func undoWeightDeletion(entityID: String) throws { try undoDeletion(kind: "weight", entityID: entityID) }

    func addWater(_ current: WaterDayDTO, milliliters: Int) throws {
        guard let accountID, let context else { throw APIError.unauthorized }
        guard (1...5000).contains(milliliters) else { throw APIError.serverError(400, "Enter 1 to 5,000 ml.") }
        let day = current.entry_date
        let old = try ownedResources().first { $0.kind == "water" && $0.entityID == day }
        let snapshot = try old.map { try JSONDecoder().decode(WaterDayDTO.self, from: $0.payload) } ?? current
        let body: [String: Any] = ["entry_date": day, "deltaMl": milliliters]
        let payload = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        let resource = old ?? SyncedResource(accountID: accountID, kind: "water", entityID: day, payload: payload)
        do {
            if old == nil { context.insert(resource); resource.revision = current.revision }
            resource.payload = try JSONEncoder().encode(WaterDayDTO(entry_date: day, ml: snapshot.ml + milliliters, revision: resource.revision))
            resource.syncState = "pending"
            resource.updatedAt = Date()
            context.insert(PendingMutation(accountID: accountID, entityID: day, kind: "water", method: "POST", endpoint: "/api/water", payload: payload, baseRevision: nil))
            try context.save()
        } catch { context.rollback(); throw error }
        changeToken += 1
        refreshCounts()
        if automaticallySync { Task { await synchronize() } }
    }

    func saveDiaryDay(_ current: DiaryDayDTO, status: DiaryLoggingStatus, note: String) throws {
        guard let accountID, let context else { throw APIError.unauthorized }
        guard note.count <= 500 else { throw APIError.serverError(400, "Keep the note to 500 characters or fewer.") }
        let day = current.entry_date
        let old = try ownedResources().first { $0.kind == "diary_day" && $0.entityID == day }
        let body: [String: Any] = ["entry_date": day, "status": status.rawValue, "note": note]
        let data = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        let resource = old ?? SyncedResource(accountID: accountID, kind: "diary_day", entityID: day, payload: data)
        let hasEarlier = try operations().contains { $0.kind == "diary_day" && $0.entityID == day }
        let operation = PendingMutation(accountID: accountID, entityID: day, kind: "diary_day", method: "PUT", endpoint: "/api/diary/day", payload: data, baseRevision: hasEarlier ? nil : current.revision)
        do {
            if old == nil { context.insert(resource); resource.revision = current.revision }
            resource.payload = try JSONEncoder().encode(DiaryDayDTO(entry_date: day, status: status, note: note, revision: resource.revision))
            resource.syncState = "pending"
            resource.updatedAt = Date()
            context.insert(operation)
            try context.save()
        } catch { context.rollback(); throw error }
        changeToken += 1
        refreshCounts()
        if automaticallySync { Task { await synchronize() } }
    }

    func diary(for date: CalendarDay, cachedOnly: Bool = false) async throws -> DaySummaryDTO {
        guard let owner = accountID, let context else { throw APIError.unauthorized }
        let day = date.rawValue
        let data: Data
        do { data = try await read("/api/summary?entry_date=\(day)", cachedOnly: cachedOnly) }
        catch {
            guard accountID == owner else { throw CancellationError() }
            if error is CancellationError { throw error }
            guard cachedOnly || (error as? APIError)?.permitsReadRetry == true else { throw error }
            // A day not previously opened can still show its queued entries.
            // No saved target for this date means unavailable, never invented.
            data = try JSONSerialization.data(withJSONObject: [
                "date": day, "timezone": calendar.timeZoneIdentifier,
                "consumed": ["calories": 0, "protein": 0, "carbs": 0, "fat": 0, "fiber": 0, "sugar": 0],
                "burned": 0, "targets": [:], "remaining": [:], "meals": [:],
                "activities": [], "sleep": NSNull(), "water_ml": 0, "entry_count": 0,
            ])
        }
        guard accountID == owner else { throw CancellationError() }
        var summary = try object(data)
        let meals = summary["meals"] as? [String: [String: Any]] ?? [:]
        let serverEntries = meals.values.flatMap { $0["entries"] as? [[String: Any]] ?? [] }
        let queue = try operations()
        var resources = try ownedResources()
        let serverWater = summary["water"] as? [String: Any] ?? ["entry_date": day, "ml": summary["water_ml"] ?? 0, "revision": 0]
        let existingWater = resources.first { $0.kind == "water" && $0.entityID == day }
        let waterData = try JSONSerialization.data(withJSONObject: serverWater)
        let waterResource = existingWater ?? SyncedResource(accountID: owner, kind: "water", entityID: day, payload: waterData)
        if existingWater == nil { context.insert(waterResource); resources.append(waterResource) }
        if !queue.contains(where: { $0.kind == "water" && $0.entityID == day }), waterResource.revision <= (serverWater["revision"] as? Int ?? 0) {
            waterResource.payload = waterData; waterResource.syncedPayload = waterData
            waterResource.revision = serverWater["revision"] as? Int ?? 0
            waterResource.syncState = "synced"
        }
        var waterPayload = try object(waterResource.payload)
        waterPayload["sync_state"] = waterResource.syncState
        summary["water"] = waterPayload
        summary["water_ml"] = waterPayload["ml"]
        if var serverWeight = summary["weight"] as? [String: Any] {
            serverWeight["revision"] = serverWeight["revision"] ?? 1
            try adoptWeight(JSONDecoder().decode(WeightDayDTO.self, from: JSONSerialization.data(withJSONObject: serverWeight)))
        }
        if let weight = try ownedResources().first(where: { $0.kind == "weight" && $0.entityID == day }) {
            summary["weight"] = try weightSnapshot(weight).exists ? object(weight.payload) : NSNull()
        }
        for row in summary["activities"] as? [[String: Any]] ?? [] { try adoptLog(row, kind: "activity") }
        let serverSleep = summary["sleep_entries"] as? [[String: Any]] ?? (summary["sleep"] as? [String: Any]).map { [$0] } ?? []
        for row in serverSleep { try adoptLog(row, kind: "sleep") }
        let activities = try logSnapshots(kind: "activity", from: day, to: day)
        let sleep = try logSnapshots(kind: "sleep", from: day, to: day)
        summary["activities"] = activities
        summary["burned"] = Int(activities.reduce(0.0) { $0 + (($1["calories"] as? NSNumber)?.doubleValue ?? 0) }.rounded())
        summary["sleep_entries"] = sleep; summary["sleep"] = sleep.first ?? NSNull()
        summary["sleep_hours"] = sleep.reduce(0.0) { $0 + (($1["hours"] as? NSNumber)?.doubleValue ?? 0) }
        let serverDay = summary["diary_day"] as? [String: Any] ?? ["entry_date": day, "status": "in_progress", "revision": 0]
        let existingDay = resources.first { $0.kind == "diary_day" && $0.entityID == day }
        let pendingDay = queue.contains { $0.kind == "diary_day" && $0.entityID == day }
        let serverDayData = try JSONSerialization.data(withJSONObject: serverDay)
        let dayResource = existingDay ?? SyncedResource(accountID: owner, kind: "diary_day", entityID: day, payload: serverDayData)
        if existingDay == nil { context.insert(dayResource); resources.append(dayResource) }
        if !pendingDay, dayResource.revision <= (serverDay["revision"] as? Int ?? 0) {
            dayResource.payload = try JSONSerialization.data(withJSONObject: serverDay)
            dayResource.syncedPayload = dayResource.payload
            dayResource.revision = serverDay["revision"] as? Int ?? 0
            dayResource.syncState = "synced"
        }
        var dayPayload = try object(dayResource.payload)
        dayPayload["sync_state"] = dayResource.syncState
        summary["diary_day"] = dayPayload
        for entry in serverEntries {
            guard let serverID = string(entry["id"] ?? entry["_id"]) else { continue }
            let entityID = entry["client_id"] as? String ?? serverID
            let existing = resources.first { $0.kind == "food" && ($0.entityID == entityID || $0.serverID == serverID) }
            if queue.contains(where: { $0.kind == "food" && $0.entityID == (existing?.entityID ?? entityID) }) { continue }
            if let existing, existing.revision > (entry["revision"] as? Int ?? 1) { continue }
            let payload = try JSONSerialization.data(withJSONObject: entry)
            let resource = existing ?? SyncedResource(accountID: owner, kind: "food", entityID: entityID, payload: payload)
            if existing == nil { context.insert(resource); resources.append(resource) }
            resource.payload = payload; resource.syncedPayload = payload
            resource.serverID = serverID; resource.revision = entry["revision"] as? Int ?? 1
            resource.syncState = "synced"; resource.tombstoned = false
        }
        try context.save()
        let foodResources = resources.filter { $0.kind == "food" }
        var entries = serverEntries.filter { entry in
            !foodResources.contains { $0.serverID == string(entry["id"] ?? entry["_id"]) || $0.entityID == entry["client_id"] as? String }
        }
        for resource in foodResources where !resource.tombstoned {
            var item = try object(resource.payload)
            if (item["entry_date"] as? String) != day { continue }
            item["sync_state"] = resource.syncState
            entries.append(item)
        }
        let fields = ["calories", "protein", "carbs", "fat", "fiber", "sugar"]
        func totals(_ rows: [[String: Any]]) -> [String: Double] {
            Dictionary(uniqueKeysWithValues: fields.map { field in (field, rows.reduce(0) { $0 + (($1[field] as? NSNumber)?.doubleValue ?? 0) }) })
        }
        var updatedMeals: [String: Any] = [:]
        for meal in ["breakfast", "lunch", "dinner", "snack", "uncategorized"] {
            let rows = entries.filter { ($0["meal_type"] as? String ?? "uncategorized") == meal }
            updatedMeals[meal] = ["entries": rows, "totals": totals(rows)]
        }
        let consumed = totals(entries)
        summary["meals"] = updatedMeals
        summary["consumed"] = consumed
        summary["entry_count"] = entries.count + activities.count + sleep.count
        var remaining = summary["remaining"] as? [String: Any] ?? [:]
        let targets = summary["targets"] as? [String: Any] ?? [:]
        for (field, target) in [("calories", "calories"), ("protein", "protein_g"), ("carbs", "carbs_g"), ("fat", "fat_g")] {
            if let value = targets[target] as? NSNumber { remaining[target] = value.doubleValue - (consumed[field] ?? 0) }
        }
        summary["remaining"] = remaining
        return try JSONDecoder().decode(DaySummaryDTO.self, from: JSONSerialization.data(withJSONObject: summary))
    }

    func synchronize(force: Bool = false) async {
        guard !isSyncing, let owner = accountID, let context else { return }
        isSyncing = true
        defer {
            isSyncing = false
            refreshCounts()
            if automaticallySync && accountID != nil && accountID != owner { Task { await synchronize(force: true) } }
        }
        var sendFailed = false
        do {
            for operation in try operations() {
                guard accountID == owner else { return }
                let earlier = try operations().contains { $0.kind == operation.kind && $0.entityID == operation.entityID && $0.createdAt < operation.createdAt }
                if operation.state == "attention" || earlier { continue }
                if !force, let retryAt = operation.retryAt, retryAt > Date() { continue }
                guard let resource = try ownedResources().first(where: { $0.entityID == operation.entityID && $0.kind == operation.kind }) else { continue }
                // Resolve dependencies once, before the first send. A retry uses
                // the identical URL, revision, body and operation identity.
                if operation.attempts == 0 {
                    if operation.kind == "diary_day" || (operation.kind == "weight" && operation.method == "PUT") { operation.baseRevision = operation.baseRevision ?? resource.revision }
                    if operation.endpoint.contains("{id}") {
                        guard let serverID = resource.serverID else { continue }
                        operation.endpoint = operation.endpoint.replacingOccurrences(of: "{id}", with: serverID)
                        operation.baseRevision = operation.baseRevision ?? resource.revision
                    }
                    var body = try object(operation.payload)
                    if let revision = operation.baseRevision { body["base_revision"] = revision }
                    operation.payload = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
                }
                operation.state = "sending"
                operation.attempts += 1
                try context.save()
                do {
                    let response: JSONValue = try await api.request(operation.method, path: operation.endpoint, body: JSONDecoder().decode(JSONValue.self, from: operation.payload), operationID: operation.operationID, expectedAccountID: serverAccountID(owner))
                    guard accountID == owner else { return }
                    var value = try object(JSONEncoder().encode(response))
                    if operation.method == "DELETE", let deleted = value[operation.kind] as? [String: Any] { value = deleted }
                    let data = try JSONSerialization.data(withJSONObject: value)
                    resource.serverID = string(value["id"] ?? value["_id"])
                    resource.revision = value["revision"] as? Int ?? max(resource.revision, 1)
                    resource.syncedPayload = data
                    let remaining = try operations().filter { $0.operationID != operation.operationID && $0.kind == operation.kind && $0.entityID == operation.entityID }
                    if remaining.isEmpty {
                        resource.payload = data
                        resource.tombstoned = value["deleted_at"] is String
                        resource.syncState = "synced"
                    }
                    if operation.kind == "water", !remaining.isEmpty {
                        // Rebase the still-pending additions onto the acknowledged total.
                        // A replay may acknowledge an older revision; the next addition
                        // and subsequent feed read recover intervening device changes.
                        var projected = value
                        projected["ml"] = try remaining.reduce(value["ml"] as? Int ?? 0) { total, pending in
                            total + (try object(pending.payload)["deltaMl"] as? Int ?? 0)
                        }
                        resource.payload = try JSONSerialization.data(withJSONObject: projected)
                    }
                    context.delete(operation)
                    try context.save()
                    isOffline = false
                    changeToken += 1
                } catch is CancellationError { return }
                catch {
                    guard accountID == owner else { return }
                    operation.lastError = error.localizedDescription
                    if case APIError.serverError(let status, _) = error, (400..<500).contains(status), ![408, 429].contains(status) {
                        operation.state = "attention"
                        resource.syncState = "attention"
                    } else if case APIError.unauthorized = error {
                        operation.state = "pending"
                        try context.save()
                        return
                    } else {
                        operation.state = "pending"
                        isOffline = true
                        sendFailed = true
                        let delay = min(pow(2, Double(min(operation.attempts, 5))), 30)
                        operation.retryAt = Date().addingTimeInterval(delay)
                        retryTask?.cancel()
                        if automaticallySync { retryTask = Task { [weak self] in
                            try? await Task.sleep(for: .seconds(delay))
                            guard !Task.isCancelled else { return }
                            await self?.synchronize()
                        } }
                    }
                    try context.save()
                    changeToken += 1
                    // Keep dependent edits in order; do not skip past a failure.
                    break
                }
            }
            guard accountID == owner else { return }
            try await pullChanges(owner: owner, context: context)
            guard accountID == owner else { return }
            // The server answered, so an earlier failure is over. A change that
            // couldn't be sent this time keeps the app offline until it is.
            error = nil
            if !sendFailed {
                isOffline = false
                lastSyncedAt = now()
            }
        } catch {
            guard accountID == owner else { return }
            self.error = error.localizedDescription
            if (error as? APIError)?.permitsReadRetry == true { isOffline = true }
        }
    }

    private func pullChanges(owner: String, context: ModelContext) async throws {
        let savedCheckpoint = try context.fetch(FetchDescriptor<SyncCheckpoint>(predicate: #Predicate { $0.accountID == owner })).first
        let checkpoint = savedCheckpoint ?? SyncCheckpoint(accountID: owner)
        if savedCheckpoint == nil { context.insert(checkpoint) }
        var more = true
        while more {
            let response: JSONValue = try await api.request("GET", path: "/api/sync?after=\(checkpoint.cursor)", expectedAccountID: serverAccountID(owner))
            guard accountID == owner else { return }
            let json = try object(JSONEncoder().encode(response))
            let queue = try operations()
            var resources = try ownedResources()
            for change in json["changes"] as? [[String: Any]] ?? [] {
                guard let kind = change["kind"] as? String, let entityID = change["entity_id"] as? String,
                      let payload = change["payload"] as? [String: Any] else { continue }
                if queue.contains(where: { $0.entityID == entityID && $0.kind == kind }) {
                    // A feed event can identify a committed create whose response
                    // was lost. Its immutable pending payload/revision stays intact.
                    if let pending = resources.first(where: { $0.kind == kind && $0.entityID == entityID }), pending.serverID == nil {
                        pending.serverID = change["server_id"] as? String
                    }
                    continue
                }
                let data = try JSONSerialization.data(withJSONObject: payload)
                let existing = resources.first { $0.kind == kind && $0.entityID == entityID }
                let resource = existing ?? SyncedResource(accountID: owner, kind: kind, entityID: entityID, payload: data)
                if existing == nil { context.insert(resource); resources.append(resource) }
                guard (change["revision"] as? Int ?? 1) >= resource.revision else { continue }
                resource.payload = data; resource.syncedPayload = data
                resource.serverID = change["server_id"] as? String
                resource.revision = change["revision"] as? Int ?? 1
                resource.tombstoned = change["deleted"] as? Bool ?? false
                resource.syncState = "synced"
            }
            checkpoint.cursor = json["cursor"] as? Int ?? checkpoint.cursor
            more = json["has_more"] as? Bool ?? false
            try context.save()
            if !(json["changes"] as? [[String: Any]] ?? []).isEmpty { changeToken += 1 }
        }
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError.unknown }
        return result
    }
    private func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? Int { return String(value) }
        return nil
    }
    private func foodSnapshot(_ body: [String: Any], entityID: String, serverID: String?, revision: Int) throws -> Data {
        var entry = body
        let servings = (body["servings"] as? NSNumber)?.doubleValue ?? 1
        for field in ["calories", "protein", "carbs", "fat", "fiber", "sugar", "sodium", "saturated_fat"] {
            if let value = (body[field] as? NSNumber)?.doubleValue {
                entry[field] = field == "calories" ? (value * servings).rounded() : (value * servings * 100).rounded() / 100
            }
        }
        entry["id"] = serverID ?? entityID
        entry["client_id"] = entityID
        entry["revision"] = revision
        entry["meal_type"] = body["mealType"] ?? "snack"
        entry["serving_size"] = body["servingSize"]
        entry["nutrition_snapshot"] = body
        return try JSONSerialization.data(withJSONObject: entry)
    }
}
