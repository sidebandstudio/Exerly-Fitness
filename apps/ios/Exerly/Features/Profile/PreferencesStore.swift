import ExerlyCore
import Foundation

struct PreferencesSnapshot: Codable {
    let schemaVersion: Int
    let accountID: String
    let revision: Int
    var values: [String: JSONValue]
    let user: UserDTO

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", accountID = "account_id"
        case revision, values, user
    }

    func value(_ key: String) -> JSONValue {
        let parts = key.split(separator: ".").map(String.init)
        if parts.count == 2, case .object(let group) = values[parts[0]] {
            return group[parts[1]] ?? .null
        }
        return values[key] ?? .null
    }

    var heightCM: Double? {
        if case .number(let value) = values["height"] { return value }
        return nil
    }
}

enum PreferenceFields {
    static let definitions: [(key: String, label: String)] = [
        ("name", "Name"), ("age", "Age"), ("gender", "Gender identity"),
        ("unitSystem", "Display units"), ("height", "Height"),
        ("activityLevel", "Usual activity level"), ("timezone", "Time zone"),
        ("dietaryStyle", "Diet preference"), ("allergies", "Allergies"),
        ("experienceLevel", "Training experience"), ("equipmentAccess", "Training location"),
        ("equipment", "Available equipment"),
        ("workoutDaysPerWeek", "Weekly workout goal"), ("workoutDays", "Workout days"),
        ("sleepGoalHours", "Sleep goal (hours)"),
        ("nutritionDisplay", "Today leads with"), ("waterGoalMl", "Daily water goal"),
        ("reminders.meals", "Meal reminders"), ("reminders.workouts", "Workout reminders"), ("reminders.sleep", "Sleep reminders"),
        ("reminders.weighIn", "Weigh-in reminders"),
        ("reminderTimes.meals", "Meal reminder times"), ("reminderTimes.workout", "Workout reminder time"),
        ("reminderTimes.sleep", "Sleep reminder time"), ("reminderTimes.weighIn", "Weigh-in reminder time")
    ]
    static let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    static let lists = ["allergies", "equipment", "workoutDays", "reminderTimes.meals"]
    static let numbers = ["age", "workoutDaysPerWeek", "sleepGoalHours", "waterGoalMl"]
    static func label(_ key: String) -> String { definitions.first { $0.key == key }?.label ?? key.capitalized }

    static func numberText(_ number: Double) -> String {
        number.formatted(.number.grouping(.never).precision(.fractionLength(0...8)))
    }
    static func heightText(_ cm: Double?, units: String) -> String {
        guard let cm else { return "" }
        // The draft keeps the exact centimeter value separately. Display
        // rounding must never become a change to the saved measurement.
        return (units == "imperial" ? cm / USUnits.centimetersPerInch : cm)
            .formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
    }
    static func text(_ value: JSONValue) -> String {
        switch value {
        case .null: return ""
        case .string(let value): return value
        case .number(let value): return numberText(value)
        case .bool(let value): return String(value)
        case .array(let values): return values.map(text).joined(separator: "\n")
        case .object(let value): return value.keys.sorted().map { "\($0): \(text(value[$0]!))" }.joined(separator: "; ")
        }
    }
    static func describe(_ value: JSONValue) -> String {
        if case .bool(let enabled) = value { return enabled ? "On" : "Off" }
        let description = text(value).replacingOccurrences(of: "\n", with: ", ")
        return description.isEmpty ? "Not set" : description
    }
    static func fields(_ snapshot: PreferencesSnapshot) -> [String: String] {
        var result = Dictionary(uniqueKeysWithValues: definitions.map { key, _ in
            (key, key.hasPrefix("reminders.") ? String(snapshot.value(key) == .bool(true)) : text(snapshot.value(key)))
        })
        result["height"] = heightText(snapshot.heightCM, units: result["unitSystem"] ?? "")
        return result
    }
    static func set(_ value: JSONValue, key: String, in values: inout [String: JSONValue]) {
        let parts = key.split(separator: ".").map(String.init)
        if parts.count == 2 {
            var group: [String: JSONValue] = [:]
            if case .object(let current) = values[parts[0]] { group = current }
            group[parts[1]] = value
            values[parts[0]] = .object(group)
        } else { values[key] = value }
    }
    static func changes(_ draft: PreferencesDraft) throws -> [String: JSONValue] {
        let before = fields(draft.base)
        var result: [String: JSONValue] = [:]
        for (key, label) in definitions {
            let raw = (draft.fields[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if key == "height" {
                if !raw.isEmpty && UserEnteredNumber.parse(raw) == nil { throw PreferencesError.message("Enter a valid height.") }
                if draft.heightCM != draft.base.heightCM { result[key] = draft.heightCM.map(JSONValue.number) ?? .null }
                continue
            }
            guard draft.fields[key] != before[key] else { continue }
            let value: JSONValue
            if numbers.contains(key) {
                if raw.isEmpty { value = .null } else if let number = UserEnteredNumber.parse(raw) { value = .number(number) } else { throw PreferencesError.message("Enter a valid number for \(label.lowercased()).") }
            } else if lists.contains(key) {
                var seen = Set<String>()
                value = .array(raw.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && seen.insert($0).inserted }.map(JSONValue.string))
            } else if key.hasPrefix("reminders.") { value = .bool(raw == "true") } else { value = raw.isEmpty ? .null : .string(raw) }
            set(value, key: key, in: &result)
        }
        return result
    }
}

struct PreferenceMutation: Codable {
    let baseRevision: Int
    let changes: [String: JSONValue]
    enum CodingKeys: String, CodingKey { case baseRevision = "base_revision", changes }
}
struct PendingPreferences: Codable {
    let id: String
    let body: PreferenceMutation
}
struct PreferencesDraft: Codable {
    let version: Int
    let accountID: String
    var base: PreferencesSnapshot
    var fields: [String: String]
    var heightCM: Double?
    var pending: PendingPreferences?
}
enum PreferencesError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}

protocol PreferencesDraftStorage {
    func read(_ key: String) throws -> Data?
    func write(_ data: Data, key: String) throws
}
struct DefaultsPreferencesStorage: PreferencesDraftStorage {
    let defaults: UserDefaults
    func read(_ key: String) throws -> Data? {
        guard let value = defaults.object(forKey: key) else { return nil }
        guard let data = value as? Data else { throw PreferencesError.message("Unreadable saved preferences") }
        return data
    }
    func write(_ data: Data, key: String) throws {
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else { throw PreferencesError.message("Preferences could not be saved on this device.") }
    }
}

@MainActor
final class PreferencesStore: ObservableObject {
    @Published private(set) var draft: PreferencesDraft?
    @Published private(set) var conflict: PreferencesSnapshot?
    @Published private(set) var accepted: PreferencesSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var isReadable = true
    @Published private(set) var error: String?
    @Published private(set) var message: String?
    let accountID: String
    let storageKey: String
    private let api: APIClient
    private let storage: any PreferencesDraftStorage
    private let ownerIsActive: () -> Bool
    private let onAccepted: (PreferencesSnapshot) -> Void
    private var isActive = true
    private var isOwned: Bool { isActive && ownerIsActive() }

    func activate() { isActive = true }
    func stop() { isActive = false }

    var isLocked: Bool { isSaving || draft?.pending != nil || !isReadable }
    var hasEdits: Bool { draft.map { $0.fields != PreferenceFields.fields($0.base) } ?? false }

    init(accountID: String, api: APIClient = .shared, defaults: UserDefaults = .standard,
         storage: (any PreferencesDraftStorage)? = nil,
         ownerIsActive: @escaping () -> Bool,
         onAccepted: @escaping (PreferencesSnapshot) -> Void = { _ in }) {
        self.accountID = accountID
        self.api = api
        self.storage = storage ?? DefaultsPreferencesStorage(defaults: defaults)
        self.ownerIsActive = ownerIsActive
        self.onAccepted = onAccepted
        storageKey = "preferences.draft.v1.\(api.storageNamespace).\(accountID)"
        do {
            if let data = try self.storage.read(storageKey) {
                var saved = try JSONDecoder().decode(PreferencesDraft.self, from: data)
                try validate(saved.base)
                // A draft saved before a field existed leaves that field as saved.
                for (key, value) in PreferenceFields.fields(saved.base) where saved.fields[key] == nil { saved.fields[key] = value }
                guard saved.version == 1, saved.accountID == accountID,
                      saved.heightCM == nil || saved.heightCM!.isFinite,
                      saved.pending == nil || (!saved.pending!.id.isEmpty && saved.pending!.body.baseRevision >= 0 && !saved.pending!.body.changes.isEmpty)
                else { throw PreferencesError.message("Unreadable saved preferences") }
                draft = saved
                message = "Your draft is saved on this iPhone. Review it before saving."
            }
        } catch {
            isReadable = false
            self.error = "Saved preferences could not be opened. Your draft has been kept. Keep the app installed and try again."
        }
    }
    private func validate(_ snapshot: PreferencesSnapshot) throws {
        guard snapshot.schemaVersion == 1, snapshot.accountID == accountID,
              snapshot.user.id == accountID, snapshot.revision >= 0 else {
            throw PreferencesError.message("The preferences response could not be read. Your draft is still here.")
        }
    }
    private func assertOwned() throws {
        try Task.checkCancellation()
        guard isOwned else { throw CancellationError() }
    }
    private func persist(_ next: PreferencesDraft) throws {
        try assertOwned()
        do { try storage.write(JSONEncoder().encode(next), key: storageKey) } catch {
            draft = next
            throw PreferencesError.message("This iPhone could not save your draft. Free some storage before sending it. Your open answers are kept.")
        }
        draft = next
    }
    private func fail(_ failure: Error) {
        guard isOwned, !(failure is CancellationError) else { return }
        error = failure.localizedDescription
    }
    private func adopt(_ snapshot: PreferencesSnapshot) throws {
        try assertOwned()
        try validate(snapshot)
        try persist(PreferencesDraft(version: 1, accountID: accountID, base: snapshot,
                                     fields: PreferenceFields.fields(snapshot), heightCM: snapshot.heightCM))
        accepted = snapshot
        conflict = nil
        error = nil
        message = "Preferences are up to date."
        onAccepted(snapshot)
    }
    func edit(_ key: String, value: String) {
        guard var next = draft, !isLocked, isOwned else { return }
        do {
            if key == "height" {
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { next.heightCM = nil } else if let number = UserEnteredNumber.parse(value) {
                    next.heightCM = next.fields["unitSystem"] == "imperial" ? USUnits.centimeters(feet: 0, inches: number) : number
                }
            }
            if key == "unitSystem" {
                let height = next.fields["height"] ?? ""
                guard height.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || UserEnteredNumber.parse(height) != nil else {
                    throw PreferencesError.message("Correct the height before changing display units.")
                }
                next.fields["height"] = PreferenceFields.heightText(next.heightCM, units: value)
            }
            next.fields[key] = value
            try persist(next)
            error = nil
            message = "Draft saved on this iPhone. Save preferences to apply it."
        } catch { fail(error) }
    }
    func load() async {
        guard !isLoading, !isSaving, isReadable, isOwned else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do { try await refresh() } catch { fail(error) }
    }
    /// Read saved answers for the training builder without resending a pending
    /// edit or replacing the person's unfinished preferences draft.
    func savedSnapshot() async throws -> PreferencesSnapshot { try await fetch() }
    private func fetch() async throws -> PreferencesSnapshot {
        let remote: PreferencesSnapshot = try await api.request("GET", path: "/api/preferences", expectedAccountID: accountID)
        try assertOwned()
        try validate(remote)
        return remote
    }
    private func refresh() async throws {
        if draft?.pending != nil { try await sendPending() }
        let remote = try await fetch()
        if let draft, hasEdits, remote.revision != draft.base.revision {
            conflict = remote
            error = nil
            message = "Preferences changed on another device. Review the differences."
        } else if !hasEdits { try adopt(remote) } else {
            accepted = remote
            onAccepted(remote)
            message = "Your draft is saved on this iPhone. Review it before saving."
        }
    }
    private func sendPending() async throws {
        guard var current = draft, let pending = current.pending else { return }
        try persist(current)
        do {
            let result: PreferencesSnapshot = try await api.request("PATCH", path: "/api/preferences", body: pending.body,
                                                                   operationID: pending.id, expectedAccountID: accountID)
            try adopt(result)
        } catch APIError.serverError(let status, let message) where status == 400 || status == 409 {
            current.pending = nil
            try persist(current)
            if status == 409 {
                conflict = try await fetch()
                self.message = "Preferences changed on another device. Review the differences."
                return
            }
            throw APIError.serverError(status, message)
        }
    }
    func save() async {
        guard !isLoading, !isSaving, isReadable, conflict == nil, isOwned, var current = draft else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            if current.pending == nil {
                let changes = try PreferenceFields.changes(current)
                guard !changes.isEmpty else { message = "No unsaved changes."; return }
                current.pending = PendingPreferences(id: UUID().uuidString,
                                                     body: PreferenceMutation(baseRevision: current.base.revision, changes: changes))
                try persist(current)
            }
            try await sendPending()
            if conflict == nil {
                // An idempotent replay may acknowledge an older revision.
                // Fetch the current account before announcing completion.
                try await refresh()
                if conflict == nil { message = "Preferences saved." }
            }
        } catch { fail(error) }
    }
    func resolve(useServer: Bool) async {
        guard let remote = conflict, var current = draft, !isSaving, !isLoading, isOwned else { return }
        do {
            if useServer { try adopt(remote); return }
            let changes = try PreferenceFields.changes(current)
            var merged = remote
            for (key, value) in changes {
                if case .object(let patch) = value {
                    var group: [String: JSONValue] = [:]
                    if case .object(let existing) = merged.values[key] { group = existing }
                    group.merge(patch) { _, new in new }
                    merged.values[key] = .object(group)
                } else { merged.values[key] = value }
            }
            current.base = remote
            current.fields = PreferenceFields.fields(merged)
            current.heightCM = merged.heightCM
            current.pending = nil
            try persist(current)
            conflict = nil
            error = nil
            await save()
        } catch { fail(error) }
    }
}
