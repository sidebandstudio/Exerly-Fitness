import ExerlyCore
import Foundation
import Observation
import SwiftUI

/// One account's Health switches. Each switch keeps when it was turned on;
/// writing covers records from that day on.
struct HealthPreferences: Codable, Equatable {
    var enabledAt: [HealthCategory: Date] = [:]
    var promptDismissed = false
    var lastSync: Date?

    func isOn(_ category: HealthCategory) -> Bool { enabledAt[category] != nil }
}

/// What the last sync did, for the settings screen.
struct HealthSyncResult: Equatable {
    var read = 0
    var removedReadings = 0
    var written: [HealthRecordKind: Int] = [:]

    var isEmpty: Bool { read == 0 && removedReadings == 0 && written.values.allSatisfy { $0 == 0 } }

    mutating func add(_ other: HealthSyncResult) {
        read += other.read
        removedReadings += other.removedReadings
        written.merge(other.written, uniquingKeysWith: +)
    }

    var summary: String {
        var parts: [String] = []
        if read > 0 { parts.append(read == 1 ? "1 weigh-in from Health" : "\(read) weigh-ins from Health") }
        if removedReadings > 0 { parts.append("\(removedReadings) removed in Health") }
        for (kind, singular, plural) in [(HealthRecordKind.food, "food", "foods"), (.weight, "weigh-in", "weigh-ins"),
                                         (.workout, "workout", "workouts")] {
            if let count = written[kind], count > 0 { parts.append("\(count) \(count == 1 ? singular : plural) written") }
        }
        return parts.isEmpty ? "Everything is up to date." : parts.joined(separator: " · ")
    }
}

/// What Exerly keeps per account to sync with Health: which records it wrote,
/// and where it stopped reading.
struct HealthSyncState: Codable, Equatable {
    var ledger = HealthWriteLedger()
    /// HealthKit query anchors, archived, by sample type.
    var anchors: [String: Data] = [:]
    /// The weigh-in each body fat reading went with, by body fat sample ID.
    var bodyFatPairs: [String: String] = [:]
}

/// Keeps Exerly and Apple Health in step for the signed-in account. Reads
/// weigh-ins on launch, on foreground, when Health reports a change, and on
/// "Sync now"; writes food, weigh-ins and workouts shortly after they change.
/// Nothing is read or written unless its switch is on.
@MainActor
final class HealthSync: ObservableObject {
    static let shared = HealthSync(client: HealthKitService.shared)

    @Published private(set) var preferences = HealthPreferences()
    @Published private(set) var isSyncing = false
    @Published private(set) var requesting: HealthCategory?
    @Published private(set) var lastResult: HealthSyncResult?
    /// A problem with the last sync, in words.
    @Published private(set) var problem: String?
    /// Why a switch couldn't turn on, or why Health is refusing it.
    @Published private(set) var notices: [HealthCategory: String] = [:]
    @Published private(set) var accountID: String?

    let client: HealthStoreClient
    private let defaults: UserDefaults
    private let namespace: String
    private let writeDelay: Duration
    private(set) weak var workspace: TrainingWorkspace?
    private var timeZone = TimeZone.gmt
    private var state = HealthSyncState()
    private var foodRecords: [UUID: (entry: FoodEntry, record: HealthFoodRecord?)] = [:]
    private var foodFingerprints: [UUID: String] = [:]
    private var scheduled: Task<Void, Never>?
    private var scheduledGeneration = 0
    /// A write is waiting for its delay or still running.
    var hasPendingWrite: Bool { scheduled != nil }
    private var rerun: (reading: Bool, pending: Bool, asked: Bool) = (false, false, false)
    /// The weigh-ins a preview showed before Read weigh-ins was turned on.
    /// Its next read imports only these, or nothing when Health has others.
    private var reviewedWeights: Set<UUID>?

    static let writeCategories: [HealthCategory] = [.writeFood, .writeWeights, .writeWorkouts]
    static let observingKey = "health.observeWeights"

    init(client: HealthStoreClient, defaults: UserDefaults = .standard,
         namespace: String = APIClient.shared.storageNamespace, writeDelay: Duration = .seconds(1.5)) {
        self.client = client
        self.defaults = defaults
        self.namespace = namespace
        self.writeDelay = writeDelay
    }

    var isAvailable: Bool { client.isAvailable }
    var anyOn: Bool { !preferences.enabledAt.isEmpty }

    /// Whether an account writes workouts to Health, open or not.
    func writesWorkouts(accountID: String) -> Bool {
        (accountID == self.accountID ? preferences : loadPreferences(accountID)).isOn(.writeWorkouts)
    }

    // MARK: Account

    /// Follows the open account. Called on every launch and account change.
    func attach(_ workspace: TrainingWorkspace?, timeZone: TimeZone) {
        if let workspace, workspace === self.workspace {
            if timeZone != self.timeZone {
                self.timeZone = timeZone
                foodRecords = [:]
                foodFingerprints = [:]
            }
            return
        }
        scheduled?.cancel()
        scheduled = nil
        self.workspace = workspace
        self.timeZone = timeZone
        accountID = workspace?.accountID
        reviewedWeights = nil
        foodRecords = [:]
        foodFingerprints = [:]
        notices = [:]
        problem = nil
        lastResult = nil
        guard let workspace else {
            preferences = HealthPreferences()
            state = HealthSyncState()
            return
        }
        preferences = loadPreferences(workspace.accountID)
        state = loadState(workspace)
        observeChanges(workspace)
        if preferences.isOn(.readWeights) { startObserving() }
        if anyOn { Task { await sync() } }
    }

    /// Reads and writes when the app comes to the foreground.
    func foreground() {
        guard workspace != nil, anyOn else { return }
        Task { await sync() }
    }

    // MARK: Switches

    func setEnabled(_ category: HealthCategory, _ enabled: Bool) async {
        guard let workspace else { return }
        notices[category] = nil
        guard enabled else {
            turnOff(category)
            return
        }
        guard client.isAvailable else {
            notices[category] = "Apple Health isn't available on this device."
            return
        }
        requesting = category
        defer { if requesting == category { requesting = nil } }
        do {
            try await client.requestAccess(category)
        } catch {
            guard self.workspace === workspace else { return }
            notices[category] = "Health access couldn't open. Try again."
            return
        }
        guard self.workspace === workspace, requesting == category else { return }
        if category.recordKind != nil, client.writeAccess(category) != .allowed {
            notices[category] = Self.deniedNotice
            return
        }
        preferences.enabledAt[category] = Date()
        savePreferences()
        if category == .readWeights {
            startObserving()
            #if DEBUG
            // A preview already seeded the readings it showed.
            if reviewedWeights == nil { await HealthDebugSeed.seedIfRequested(client, timeZone: timeZone) }
            #endif
        }
        await sync()
    }

    /// Turns Read weigh-ins on after its preview, importing only the
    /// readings shown. False when Health had others, so nothing was imported
    /// and the switch stayed off for a preview of them.
    func enableReadingWeights(reviewed: Set<UUID>) async -> Bool {
        reviewedWeights = reviewed
        await setEnabled(.readWeights, true)
        if !preferences.isOn(.readWeights) { reviewedWeights = nil }
        return notices[.readWeights] != Self.reviewChangedNotice
    }

    private func turnOff(_ category: HealthCategory) {
        preferences.enabledAt[category] = nil
        savePreferences()
        if category == .readWeights {
            reviewedWeights = nil
            // Another account turning it on here registers again.
            defaults.set(false, forKey: Self.observingKey)
            client.stopObservingWeights()
        }
    }

    /// Leaves a switch request in flight without letting it turn the switch on.
    func cancelRequest() { requesting = nil }

    func dismissPrompt() {
        preferences.promptDismissed = true
        savePreferences()
    }

    static let deniedNotice = "Health doesn't allow this. Allow it in the Health app: your profile › Apps › Exerly."
    static let reviewChangedNotice = "Health has weigh-ins the preview didn't show. Turn this on to see them first."
    private struct ReviewChanged: Error {}

    // MARK: Syncing

    /// Reads weigh-ins, then writes whatever changed. One sync runs at a time;
    /// a request during one runs again after it. The summary keeps the last
    /// sync that changed something, unless the person asked: an automatic sync
    /// that finds nothing new doesn't hide what the last one did.
    func sync(reading: Bool = true, asked: Bool = false) async {
        if isSyncing {
            rerun = (rerun.reading || reading, true, rerun.asked || asked)
            return
        }
        guard anyOn else { return }
        isSyncing = true
        defer { isSyncing = false }
        var read = reading, show = asked
        var total = HealthSyncResult()
        var account = workspace
        // The account can change during a sync; the next round follows it.
        while let workspace {
            if workspace !== account {
                account = workspace
                total = HealthSyncResult()
            }
            rerun = (false, false, false)
            if let round = await perform(workspace, reading: read) {
                total.add(round)
                if show || !total.isEmpty { lastResult = total }
            }
            guard rerun.pending else { break }
            read = rerun.reading
            show = show || rerun.asked
        }
    }

    /// One round for one account, or nil when the account changed during it.
    private func perform(_ workspace: TrainingWorkspace, reading: Bool) async -> HealthSyncResult? {
        var result = HealthSyncResult()
        var failure: String?
        if reading, preferences.isOn(.readWeights) {
            do {
                let imported = try await importWeights(workspace)
                result.read = imported.added + imported.updated
                result.removedReadings = imported.removed
                // Send them to the account now, as screens do after a change,
                // so other devices see them; offline, they wait in the queue.
                if imported.added + imported.updated + imported.removed > 0 { Task { await workspace.synchronize() } }
            } catch is ReviewChanged {
                turnOff(.readWeights)
                notices[.readWeights] = Self.reviewChangedNotice
            } catch {
                failure = "Weigh-ins from Health couldn't be read. Exerly will try again."
            }
        }
        for category in Self.writeCategories where preferences.isOn(category) {
            guard self.workspace === workspace, let kind = category.recordKind else { return nil }
            guard client.writeAccess(category) == .allowed else {
                notices[category] = Self.deniedNotice
                continue
            }
            notices[category] = nil
            do {
                result.written[kind] = try await write(kind, since: preferences.enabledAt[category]!, workspace: workspace)
            } catch {
                failure = failure ?? "Some changes couldn't be saved to Health. Exerly will try again."
            }
        }
        guard self.workspace === workspace else { return nil }
        problem = failure
        if failure == nil {
            preferences.lastSync = Date()
            savePreferences()
        }
        return result
    }

    private func importWeights(_ workspace: TrainingWorkspace) async throws -> HealthWeightImport {
        let delta = try await client.weightChanges(massAnchor: state.anchors["bodyMass"], bodyFatAnchor: state.anchors["bodyFat"])
        guard self.workspace === workspace else { throw CancellationError() }
        if let reviewed = reviewedWeights {
            reviewedWeights = nil
            // Exerly's own, from the watch, aren't previewed.
            guard delta.addedMass.allSatisfy({ reviewed.contains($0.id) || $0.source?.hasPrefix("com.exerly.") == true }) else {
                throw ReviewChanged()
            }
        }
        let nutrition = workspace.nutrition
        // Weigh-ins whose body fat was deleted are paired again without it.
        let unpaired = Set(delta.deletedBodyFat.compactMap { state.bodyFatPairs[$0.uuidString] })
        var mass = delta.addedMass
        var bodyFat = delta.addedBodyFat
        let firstRead = state.anchors["bodyMass"] == nil && state.anchors["bodyFat"] == nil
        let instants = mass.map(\.at) + bodyFat.map(\.at) + nutrition.weights.filter { unpaired.contains($0.id.uuidString) }.map(\.at)
        // A first read already has every sample. Later, a new weight or body
        // fat reading can belong with one read before, so read around it again.
        if !firstRead, let span = HealthWeightPairing.span(around: instants) {
            let around = try await client.weights(in: span)
            guard self.workspace === workspace else { throw CancellationError() }
            let knownMass = Set(mass.map(\.id)), knownFat = Set(bodyFat.map(\.id))
            mass += around.mass.filter { !knownMass.contains($0.id) }
            bodyFat += around.bodyFat.filter { !knownFat.contains($0.id) }
        }
        let paired = HealthWeightPairing.pair(mass, bodyFat)
        let imported = try nutrition.importHealthWeights(paired.weights, deleted: delta.deletedMass, timeZone: timeZone)
        let repaired = Set(paired.weights.map(\.id.uuidString)).union(delta.deletedMass.map(\.uuidString))
        state.bodyFatPairs = state.bodyFatPairs.filter { !repaired.contains($0.value) }
        for id in delta.deletedBodyFat { state.bodyFatPairs[id.uuidString] = nil }
        for (fat, weight) in paired.bodyFat { state.bodyFatPairs[fat.uuidString] = weight.uuidString }
        state.anchors["bodyMass"] = delta.massAnchor
        state.anchors["bodyFat"] = delta.bodyFatAnchor
        saveState(workspace)
        return imported
    }

    /// Writes one kind's changes: removals first, then saves, recording each
    /// step as it succeeds so a retry repeats only what's left.
    private func write(_ kind: HealthRecordKind, since enabled: Date, workspace: TrainingWorkspace) async throws -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: enabled)
        switch kind {
        case .food:
            let records = foodRecords(workspace)
            let changes = state.ledger.changes(for: records, since: start) { record in
                if let known = foodFingerprints[record.id] { return known }
                let fingerprint = record.fingerprint
                foodFingerprints[record.id] = fingerprint
                return fingerprint
            }
            return try await apply(changes, workspace: workspace) { try await self.client.saveFood($0) }
        case .weight:
            let records = workspace.nutrition.weights.compactMap { HealthWeightRecord(entry: $0, timeZone: timeZone) }
            return try await apply(state.ledger.changes(for: records, since: start), workspace: workspace) {
                try await self.client.saveWeights($0)
            }
        case .workout:
            let records = workspace.store.history.sessions.compactMap(HealthWorkoutRecord.init(session:))
            var changes = state.ledger.changes(for: records, since: start)
            // The watch saved these itself, with heart rate and energy.
            let watched = changes.write.filter { WatchHealthWorkouts.contains($0.id, defaults: defaults) }
            if !watched.isEmpty {
                changes.write.removeAll { WatchHealthWorkouts.contains($0.id, defaults: defaults) }
                changes.remove.removeAll { id in watched.contains { $0.id == id } }
                state.ledger.wrote(watched)
                saveState(workspace)
            }
            return try await apply(changes, workspace: workspace, batch: 1) {
                try await self.client.saveWorkout($0[0])
            }
        }
    }

    private func apply<R: HealthRecord>(_ changes: HealthWriteChanges<R>, workspace: TrainingWorkspace, batch: Int = 50,
                                        save: ([R]) async throws -> Void) async throws -> Int {
        if !changes.remove.isEmpty {
            try await client.remove(R.kind, ids: changes.remove)
            guard self.workspace === workspace else { throw CancellationError() }
            state.ledger.removed(R.kind, changes.remove)
            saveState(workspace)
        }
        var written = 0
        for start in stride(from: 0, to: changes.write.count, by: batch) {
            let records = Array(changes.write[start..<min(start + batch, changes.write.count)])
            try await save(records)
            guard self.workspace === workspace else { throw CancellationError() }
            state.ledger.wrote(records)
            saveState(workspace)
            written += records.count
        }
        return written
    }

    /// Food records, rebuilt only for entries that changed since the last
    /// sync, so a long diary isn't encoded again after every change.
    private func foodRecords(_ workspace: TrainingWorkspace) -> [HealthFoodRecord] {
        var next: [UUID: (entry: FoodEntry, record: HealthFoodRecord?)] = [:]
        for entry in workspace.nutrition.entries {
            if let cached = foodRecords[entry.id], cached.entry == entry {
                next[entry.id] = cached
            } else {
                next[entry.id] = (entry, HealthFoodRecord(entry: entry, timeZone: timeZone))
                foodFingerprints[entry.id] = nil
            }
        }
        foodRecords = next
        return next.values.compactMap(\.record)
    }

    // MARK: Changes in Exerly

    private func observeChanges(_ workspace: TrainingWorkspace) {
        withObservationTracking {
            _ = workspace.nutrition.entries
            _ = workspace.nutrition.weights
            _ = workspace.store.history
        } onChange: { [weak self, weak workspace] in
            Task { @MainActor in
                guard let self, let workspace, self.workspace === workspace else { return }
                self.scheduleWrites()
                self.observeChanges(workspace)
            }
        }
    }

    /// Writes a moment after the last change, so a burst of edits is one write.
    private func scheduleWrites() {
        guard Self.writeCategories.contains(where: preferences.isOn) else { return }
        scheduled?.cancel()
        scheduledGeneration += 1
        let generation = scheduledGeneration
        scheduled = Task { [weak self, writeDelay] in
            try? await Task.sleep(for: writeDelay)
            guard !Task.isCancelled else { return }
            await self?.sync(reading: false)
            self?.finishScheduled(generation)
        }
    }

    private func finishScheduled(_ generation: Int) {
        if generation == scheduledGeneration { scheduled = nil }
    }

    // MARK: Health changes

    private func startObserving() {
        defaults.set(true, forKey: Self.observingKey)
        client.observeWeights { [weak self] in await self?.healthChanged() }
    }

    private func healthChanged() async {
        guard workspace != nil, preferences.isOn(.readWeights) else { return }
        await sync()
    }

    /// Registers for Health's weight updates as the app launches, as Health
    /// requires for background delivery. Without an open account the update is
    /// acknowledged, and read when the account opens.
    func registerAtLaunch() {
        guard defaults.bool(forKey: Self.observingKey), client.isAvailable else { return }
        client.observeWeights { [weak self] in await self?.healthChanged() }
    }

    // MARK: Storage

    private var preferenceKey: String? { accountID.map { "health.v1.\(namespace).\($0)" } }

    private func loadPreferences(_ accountID: String) -> HealthPreferences {
        guard let data = defaults.data(forKey: "health.v1.\(namespace).\(accountID)"),
              let saved = try? JSONDecoder().decode(HealthPreferences.self, from: data) else { return HealthPreferences() }
        return saved
    }

    private func savePreferences() {
        guard let preferenceKey, let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: preferenceKey)
    }

    static func stateURL(_ workspace: TrainingWorkspace) -> URL {
        workspace.url.deletingLastPathComponent().appendingPathComponent("health-sync.json")
    }

    private func loadState(_ workspace: TrainingWorkspace) -> HealthSyncState {
        guard let data = try? Data(contentsOf: Self.stateURL(workspace)),
              let saved = try? JSONDecoder().decode(HealthSyncState.self, from: data) else { return HealthSyncState() }
        return saved
    }

    /// Saved beside the account's database, so it's removed with the account.
    private func saveState(_ workspace: TrainingWorkspace) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.stateURL(workspace), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Attaches Health sync to the open account and reads again on foreground.
struct HealthSyncMount: ViewModifier {
    let workspace: TrainingWorkspace?
    let timeZone: String?
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task(id: "\(workspace?.identity.uuidString ?? "")-\(timeZone ?? "")") {
                HealthSync.shared.attach(workspace, timeZone: TimeZone(identifier: timeZone ?? "UTC") ?? .gmt)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { HealthSync.shared.foreground() }
            }
    }
}

extension View {
    /// Keeps Apple Health in step with the open account.
    func healthSync(_ workspace: TrainingWorkspace?, timeZone: String?) -> some View {
        modifier(HealthSyncMount(workspace: workspace, timeZone: timeZone))
    }
}
