import Foundation
import UIKit
import ExerlyCore
import Combine

/// App composition: the account determines which Core store a screen can open.
@MainActor
final class TrainingWorkspace: ObservableObject {
    let identity = UUID()
    let accountID: String
    let url: URL
    let store: TrainingStore
    let programs: ProgramStore
    let gyms: GymStore
    let provenance: ProvenanceStore
    /// What was imported from Apple Health, by whom, and what's become of it.
    let healthImports: HealthImportStore
    let nutrition: NutritionStore
    /// Barcodes this account resolved, scanned, or scanned offline.
    let barcodes: BarcodeLibrary
    let agent: AgentStore
    /// What two devices changed at once, kept for review.
    let conflicts: SyncConflictStore
    let entryChecks: TrainingEntryChecks
    private let persistence: SQLiteTrainingPersistence
    @Published private(set) var sync: ExerlyCore.SyncEngine?
    @Published private(set) var nutritionSetupError: String?
    private var accountAPI: AccountAPI?
    private var checkedLegacyTargets = false
    private var adoptingLegacyTargets = false
    let unreadableCount: Int

    enum AccessError: Error { case missingAccount }

    /// `stored`, read off the main actor (`open`), saves reading and decoding
    /// the history here; without it the stores read it themselves.
    init(accountID: String, root: URL? = nil, api: AccountAPI? = nil, stored: StoredAccount? = nil) throws {
        self.accountID = accountID
        url = try Self.storageURL(accountID: accountID, root: root)
        persistence = try SQLiteTrainingPersistence(url: url)
        if let stored {
            store = try TrainingStore(persistence: persistence, loaded: stored.training)
            nutrition = NutritionStore(persistence: persistence, loaded: stored.nutrition)
        } else {
            store = try TrainingStore(persistence: persistence)
            nutrition = try NutritionStore(persistence: persistence)
        }
        programs = try ProgramStore(persistence: persistence, training: store)
        gyms = try GymStore(persistence: persistence)
        provenance = try ProvenanceStore(persistence: persistence)
        healthImports = try HealthImportStore(persistence: persistence)
        barcodes = BarcodeLibrary(persistence: persistence)
        agent = try AgentStore(persistence: persistence, hosts: [store, programs, nutrition, gyms])
        conflicts = SyncConflictStore(state: persistence, hosts: [store, programs, nutrition, gyms, agent],
                                      deviceName: UIDevice.current.model)
        conflicts.effects = ScanConflictEffects(library: barcodes, store: nutrition)
        entryChecks = TrainingEntryChecks(training: store, agent: agent, accountID: accountID)
        // The background read's unreadable rows are noted with persistence by the training store.
        unreadableCount = persistence.unreadableRows.count
        if let api { resumeSync(api: api) }
    }

    /// Opens an account with its sessions and food history read and decoded
    /// off the main actor; only the stores' small documents and publishing
    /// them happen on it (PARITY B03). `read` is replaced only by tests.
    static func open(accountID: String, root: URL? = nil, api: AccountAPI?,
                     read: @escaping @Sendable (URL) throws -> StoredAccount? = StoredAccount.read) async throws -> TrainingWorkspace {
        let url = try storageURL(accountID: accountID, root: root)
        let stored = try await Task.detached(priority: .userInitiated) { try read(url) }.value
        return try TrainingWorkspace(accountID: accountID, root: root, api: api, stored: stored)
    }

    private static func storageURL(accountID: String, root: URL?) throws -> URL {
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AccessError.missingAccount }
        let canonical = try SQLiteTrainingPersistence.defaultURL(accountID: accountID)
        guard let testRoot = try root ?? testStorageRoot() else { return canonical }
        return testRoot.appendingPathComponent(accountID, isDirectory: true).appendingPathComponent(canonical.lastPathComponent)
    }

    func resumeSync(api: AccountAPI) {
        guard api.accountID == accountID, !persistence.isClosed else { return }
        accountAPI = api
        // A new build compares every document once; after that, only those written since.
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        sync = ExerlyCore.SyncEngine(hosts: [store, programs, nutrition, gyms, agent, provenance, healthImports], state: persistence, api: api,
                                     conflicts: conflicts, appVersion: build)
    }

    func synchronize() async {
        // Core exposes the durable state to the UI; cancellation is expected at
        // account changes and when the scene moves to the background.
        guard !persistence.isClosed, !Task.isCancelled else { return }
        await entryChecks.refresh()
        do {
            try await sync?.sync()
            guard !persistence.isClosed, !Task.isCancelled else { return }
            if !checkedLegacyTargets, !adoptingLegacyTargets, let accountAPI {
                adoptingLegacyTargets = true
                defer { adoptingLegacyTargets = false }
                if nutrition.plans.isEmpty {
                    _ = try await accountAPI.adoptLegacyTargets()
                    guard !persistence.isClosed, !Task.isCancelled else { return }
                    try await sync?.sync()
                }
                checkedLegacyTargets = true
                nutritionSetupError = nil
            }
        } catch {
            if !checkedLegacyTargets, nutrition.plans.isEmpty, !persistence.isClosed {
                nutritionSetupError = "Your nutrition targets could not load. Pull down to retry."
            }
        }
        guard !persistence.isClosed, !Task.isCancelled else { return }
        if await entryChecks.refresh() { try? await sync?.sync() }
        // Scans made offline resolve once the server answers again.
        if let accountAPI, !barcodes.waiting.isEmpty, !persistence.isClosed {
            await barcodes.resolveWaiting(fetch: BarcodeLibrary.fetch(accountAPI))
        }
    }

    /// The active program's next workout. With `unit`, every recommended load
    /// is in that unit, on a weight the equipment allows.
    func nextWorkout(bodyweight: Mass?, unit: MassUnit? = nil) -> WorkoutPlan? {
        let plan = programs.nextWorkout(bodyweight: bodyweight, increments: gyms.increments(for:))
        guard let unit else { return plan }
        return plan?.expressed(in: unit, library: store.library, increments: gyms.increments(for:))
    }

    /// The latest weigh-in, used for bodyweight exercises without asking.
    var latestBodyweight: Mass? { nutrition.weights.last?.weight }

    /// Starts the next workout of the active program, with the latest
    /// weigh-in. Returns false when the program has nothing left to do.
    @discardableResult
    func startNextWorkout(timeZone: TimeZone, unit: MassUnit? = nil) throws -> Bool {
        guard let plan = nextWorkout(bodyweight: latestBodyweight, unit: unit) else { return false }
        try store.startSession(from: plan, bodyweight: latestBodyweight, timeZone: timeZone)
        return true
    }

    /// Each program slot's target for the cycle a session was planned from,
    /// by slot ID. Empty for a workout started without a program.
    func slotTargets(for session: WorkoutSession) -> [UUID: SlotTarget] {
        guard let reference = session.program, let program = programs.program(reference.programID) else { return [:] }
        var targets: [UUID: SlotTarget] = [:]
        for day in program.days {
            for slot in day.slots { targets[slot.id] = program.target(for: slot, cycle: reference.cycle) }
        }
        return targets
    }

    func close() async {
        accountAPI = nil
        entryChecks.stop()
        await sync?.shutdown()
        persistence.close()
    }

    func export(server: Data?, pending: [AccountExport.PendingRow] = [], context: AccountExport.Context? = nil) throws -> Data {
        try AccountExport.merging(server: server, hosts: documentHosts, state: persistence, pending: pending, context: context)
    }

    /// Saves imports as one unit across this account's stores, and undoes them.
    var importer: HistoryImporter { importer(measurements: nil) }

    /// The importer, saving body measurements to `measurements` alongside.
    func importer(measurements: ImportedMeasurementStore?) -> HistoryImporter {
        HistoryImporter(hosts: documentHosts, persistence: persistence, measurements: measurements)
    }

    /// Every store whose records are documents: what imports write and exports hold,
    /// Health's import records among them, with their owners and generations.
    var documentHosts: [DocumentHost] { [store, programs, nutrition, gyms, agent, provenance, healthImports] }

    func supportsChanges(in proposal: Proposal) -> Bool {
        let kinds = store.documentKinds + programs.documentKinds + nutrition.documentKinds + gyms.documentKinds
        return proposal.changes.allSatisfy { kinds.contains($0.kind) }
    }

    static func deleteStorage(accountID: String, root: URL? = nil) throws {
        _ = try SQLiteTrainingPersistence.defaultURL(accountID: accountID)
        if let root = try root ?? testStorageRoot() {
            let directory = root.appendingPathComponent(accountID, isDirectory: true)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        } else { try SQLiteTrainingPersistence.deleteDatabase(accountID: accountID) }
        TrainingEntryChecks.removePreference(accountID: accountID)
    }

    private static func testStorageRoot() throws -> URL? {
        #if DEBUG
        if let id = ProcessInfo.processInfo.environment["EXERLY_TEST_STORE_ID"], UUID(uuidString: id) != nil {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
            return base.appendingPathComponent("SimulatorTests/\(id)/Training", isDirectory: true)
        }
        #endif
        return nil
    }
}

enum TrainingInput {
    // Input syntax belongs to the editor. Core still decides whether a set is loggable.
    static func number(_ text: String, locale: Locale = .current) -> Double? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = input.replacingOccurrences(of: locale.decimalSeparator ?? ".", with: ".")
        guard normalized.range(of: #"^[0-9]+(?:\.[0-9]*)?$"#, options: .regularExpression) != nil,
              let value = Double(normalized), value.isFinite else { return nil }
        return value
    }

    static func reps(_ text: String) -> Int? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(input)
    }
}

enum TrainingFormat {
    static func number(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...3)))
    }

    /// A load to the nearest 0.1, without trailing zeros: "140", "132.3".
    static func load(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...1)).rounded(rule: .toNearestOrAwayFromZero))
    }

    static func mass(_ mass: Mass, unit: MassUnit) -> String {
        "\(load(mass.value(in: unit))) \(unit == .kilograms ? "kg" : "lb")"
    }

    static func set(_ set: PerformedSet, unit: MassUnit) -> String {
        let values = set.efforts.map { effort in
            var parts: [String] = []
            if let load = effort.load { parts.append(mass(load, unit: unit)) }
            if let reps = effort.reps { parts.append("\(reps) reps") }
            if let duration = effort.duration { parts.append("\(number(duration)) s") }
            if let distance = effort.distance { parts.append("\(number(distance)) m") }
            return parts.isEmpty ? "Enter values" : parts.joined(separator: " × ")
        }.joined(separator: " → ")
        return values
    }

    static func kind(_ kind: SetKind) -> String {
        switch kind {
        case .standard: "Working"
        case .warmUp: "Warm-up"
        case .drop: "Drop"
        case .myo: "Myo"
        case .failure: "To failure"
        }
    }

    /// The letter shown in place of the set number, for sets that aren't working sets.
    static func badge(_ kind: SetKind) -> String? {
        switch kind {
        case .standard: nil
        case .warmUp: "W"
        case .drop: "D"
        case .myo: "M"
        case .failure: "F"
        }
    }

    static func unitSymbol(_ unit: MassUnit) -> String { unit == .kilograms ? "kg" : "lb" }

    /// "3 × 5–8 · 2 RIR", or "3 sets" when the exercise doesn't count reps.
    static func compactTarget(_ target: SlotTarget, exercise: ExerlyCore.Exercise?) -> String {
        guard exercise?.metric.tracksReps == true else { return target.sets == 1 ? "1 set" : "\(target.sets) sets" }
        let reps = target.minReps == target.maxReps ? "\(target.minReps)" : "\(target.minReps)–\(target.maxReps)"
        return "\(target.sets) × \(reps) · \(number(target.rir)) RIR"
    }

    /// A set's values in a few characters, for the Previous column: "155 × 8",
    /// "BW × 9", "+10 × 8", "45 s", "400 m".
    static func compact(_ set: PerformedSet, metric: TrackingMetric, unit: MassUnit) -> String {
        let effort = set.primary
        let load = effort.load.map { self.load($0.value(in: unit)) }
        let text: String
        switch metric {
        case .weightReps: text = "\(load ?? "–") × \(effort.reps.map(String.init) ?? "–")"
        case .bodyweightReps: text = "\(load.map { "+" + $0 } ?? "BW") × \(effort.reps.map(String.init) ?? "–")"
        case .assistedReps: text = "\(load.map { "−" + $0 } ?? "BW") × \(effort.reps.map(String.init) ?? "–")"
        case .duration: text = effort.duration.map { "\(number($0)) s" } ?? "–"
        case .weightDuration: text = "\(load ?? "–") · \(effort.duration.map { "\(number($0)) s" } ?? "–")"
        case .distanceDuration: text = effort.distance.map { "\(number($0)) m" } ?? effort.duration.map { "\(number($0)) s" } ?? "–"
        case .weightDistance: text = "\(load ?? "–") · \(effort.distance.map { "\(number($0)) m" } ?? "–")"
        }
        return set.efforts.count > 1 ? text + " +\(set.efforts.count - 1)" : text
    }

    /// "4,520 lb" of volume.
    static func volume(_ tonnage: Tonnage, unit: MassUnit) -> String {
        "\(tonnage.total(in: unit).formatted(.number.precision(.fractionLength(0)))) \(unitSymbol(unit))"
    }

    /// "52 min" or "1 h 5 min".
    static func minutes(_ seconds: Double) -> String {
        let total = max(1, Int((seconds / 60).rounded()))
        return total < 60 ? "\(total) min" : "\(total / 60) h\(total % 60 == 0 ? "" : " \(total % 60) min")"
    }

    /// A planned session's name, "Program: Day", as the day with the program
    /// beneath it, so the title fits a narrow bar. Other names stay whole.
    static func title(of session: WorkoutSession) -> (name: String, program: String?) {
        title(session.name, planned: session.program != nil)
    }

    static func title(_ name: String, planned: Bool) -> (name: String, program: String?) {
        guard planned, let range = name.range(of: ": ") else { return (name, nil) }
        let program = String(name[..<range.lowerBound])
        let day = String(name[range.upperBound...])
        return day.isEmpty ? (name, nil) : (day, program)
    }

    /// A name for a workout started without a plan, from the time of day.
    static func emptyWorkoutName(at date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        switch calendar.component(.hour, from: date) {
        case 4..<12: return "Morning workout"
        case 12..<17: return "Afternoon workout"
        default: return "Evening workout"
        }
    }

    /// What a set of this exercise records, in words.
    static func logged(_ metric: TrackingMetric) -> String {
        switch metric {
        case .weightReps: "Weight and reps"
        case .bodyweightReps: "Reps, with any added weight"
        case .assistedReps: "Reps, with any assistance"
        case .duration: "Time"
        case .weightDuration: "Weight and time"
        case .distanceDuration: "Distance and time"
        case .weightDistance: "Weight and distance"
        }
    }

    static func sides(_ laterality: Laterality) -> String {
        switch laterality {
        case .bilateral: "Both sides together"
        case .unilateral: "One side at a time, logged as separate sets"
        case .alternating: "Alternating sides within a set"
        }
    }

    static func words(_ raw: String) -> String {
        raw.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
    }

    static func date(_ session: WorkoutSession) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = session.timeZone
        return formatter.string(from: session.startedAt)
    }

    /// "Through today", "Through yesterday" or "Through Tue, Oct 6".
    static func through(_ date: LocalDate, today: LocalDate) -> String {
        let day = BodyFormat.day(date, today: today)
        return "Through \(date >= today.adding(days: -1) ? day.lowercased() : day)"
    }

    /// "Logged in Pacific Time" for a workout saved in another time zone
    /// than the account's; nil when they match.
    static func zoneNote(_ zone: TimeZone, account: TimeZone) -> String? {
        let name = zone.localizedName(for: .generic, locale: .current) ?? zone.identifier
        guard zone.identifier != account.identifier, name != account.localizedName(for: .generic, locale: .current) else { return nil }
        return "Logged in \(name)"
    }

    static func error(_ error: Error) -> String {
        if case TrainingStore.StoreError.edit(.incomplete) = error {
            return "Enter the required values before completing this set."
        }
        return "The change could not be saved. Your last saved workout is still on this device. Try again."
    }
}
