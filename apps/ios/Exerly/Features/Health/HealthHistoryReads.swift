import ExerlyCore
import Foundation
import HealthKit

// Food, workouts and weigh-ins other apps saved to Health, imported only after
// a preview says what would be added, what's already in Exerly, and what
// source priority sets aside. After that, Health's changes are read from an
// anchor as the screen opens: new records, and the ones Health deleted. A
// record missing from a read is never taken out for it, as a read Health
// revoked looks the same as one with no data; Check everything again lists
// those, for the person to choose. Weigh-ins then go through the Read
// weigh-ins switch (HealthSync), with the readings reviewed.

enum HealthHistoryKind: String, CaseIterable, Identifiable {
    case weights, foods, workouts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weights: "Weigh-ins from Health"
        case .foods: "Read food from other apps"
        case .workouts: "Read workouts from other apps"
        }
    }

    var purpose: String {
        switch self {
        case .weights: ""
        case .foods: "Meals another app saved to Health are added to your diary after you review them. They aren't written back."
        case .workouts: "Runs, rides and other workouts from your watch or another app are added to your activity after you review them."
        }
    }

    /// "412 weigh-ins".
    func count(_ count: Int) -> String {
        let (one, many) = switch self {
        case .weights: ("weigh-in", "weigh-ins")
        case .foods: ("food", "foods")
        case .workouts: ("workout", "workouts")
        }
        return "\(count.formatted()) \(count == 1 ? one : many)"
    }
}

/// What changed in Health since an anchor: everything, with no deletions,
/// from none.
struct HealthChanges<Reading> {
    var added: [Reading] = []
    var deleted: [UUID] = []
    var anchor: Data?
}

protocol HealthHistoryClient: AnyObject, Sendable {
    var isAvailable: Bool { get }
    func requestAccess(_ kind: HealthHistoryKind) async throws
    func foods(after anchor: Data?) async throws -> HealthChanges<HealthFoodReading>
    func workouts(after anchor: Data?) async throws -> HealthChanges<HealthWorkoutReading>
    /// Every weigh-in another source saved, with its source's name.
    func weights() async throws -> [(weight: HealthWeight, source: String)]
}

final class HealthKitHistoryClient: HealthHistoryClient, @unchecked Sendable {
    static let shared = HealthKitHistoryClient()
    private let store = HKHealthStore()

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAccess(_ kind: HealthHistoryKind) async throws {
        #if DEBUG
        // The weigh-in switch's request, which seeds synthetic scale readings
        // for UI tests, so the preview shows them and Health asks once.
        if kind == .weights, HealthDebugSeed.spec != nil {
            try await HealthKitService.shared.requestAccess(.readWeights)
            await HealthDebugSeed.seedIfRequested(HealthKitService.shared, timeZone: .current)
            return
        }
        #endif
        let read: Set<HKObjectType> = switch kind {
        case .weights: [HKQuantityType(.bodyMass), HKQuantityType(.bodyFatPercentage)]
        case .foods: Set(HealthKitService.dietaryTypes)
        case .workouts: [HKObjectType.workoutType(), HKQuantityType(.activeEnergyBurned)]
        }
        try await store.requestAuthorization(toShare: [], read: read)
    }

    /// Exerly's own, from the phone or the watch, never come back as another app's.
    private static func isExerly(_ sample: HKSample) -> Bool {
        #if DEBUG
        // UI tests' synthetic readings stand in for another app's.
        if sample.metadata?[HealthDebugSeed.markerKey] != nil { return false }
        #endif
        return HealthMetadata.isFromExerly(sample.metadata) || sample.sourceRevision.source.bundleIdentifier.hasPrefix("com.exerly.")
    }

    private static func zone(_ sample: HKSample) -> TimeZone? {
        (sample.metadata?[HKMetadataKeyTimeZone] as? String).flatMap(TimeZone.init(identifier:))
    }

    private static func archive(_ anchor: HKQueryAnchor) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }

    private static func unarchive(_ data: Data?) -> HKQueryAnchor? {
        data.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) }
    }

    func foods(after anchor: Data?) async throws -> HealthChanges<HealthFoodReading> {
        let result = try await HKAnchoredObjectQueryDescriptor(predicates: [.correlation(type: HKCorrelationType(.food))],
                                                               anchor: Self.unarchive(anchor)).result(for: store)
        return HealthChanges(added: result.addedSamples.filter { !Self.isExerly($0) }.map(Self.food),
                             deleted: result.deletedObjects.map(\.uuid), anchor: try Self.archive(result.newAnchor))
    }

    private static func food(_ food: HKCorrelation) -> HealthFoodReading {
        var nutrients = NutrientAmounts()
        for nutrient in Nutrient.healthWritable {
            guard let identifier = nutrient.healthType else { continue }
            let samples = food.objects(for: HKQuantityType(HKQuantityTypeIdentifier(rawValue: identifier))).compactMap { $0 as? HKQuantitySample }
            guard !samples.isEmpty else { continue }
            nutrients[nutrient] = samples.reduce(0) { $0 + $1.quantity.doubleValue(for: HealthKitService.unit(nutrient.healthUnit)) }
        }
        return HealthFoodReading(id: food.uuid, at: food.startDate, name: food.metadata?[HKMetadataKeyFoodType] as? String,
                                 nutrients: nutrients, source: food.sourceRevision.source.bundleIdentifier,
                                 sourceName: food.sourceRevision.source.name, timeZone: zone(food))
    }

    func workouts(after anchor: Data?) async throws -> HealthChanges<HealthWorkoutReading> {
        let result = try await HKAnchoredObjectQueryDescriptor(predicates: [.workout()], anchor: Self.unarchive(anchor)).result(for: store)
        let added = result.addedSamples.filter { !Self.isExerly($0) }.map { workout in
            HealthWorkoutReading(id: workout.uuid, start: workout.startDate, end: workout.endDate,
                                 activity: Self.name(workout.workoutActivityType),
                                 kilocalories: workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?
                                     .doubleValue(for: .kilocalorie()),
                                 source: workout.sourceRevision.source.bundleIdentifier, sourceName: workout.sourceRevision.source.name,
                                 timeZone: Self.zone(workout))
        }
        return HealthChanges(added: added, deleted: result.deletedObjects.map(\.uuid), anchor: try Self.archive(result.newAnchor))
    }

    func weights() async throws -> [(weight: HealthWeight, source: String)] {
        let samples = try await HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(.bodyMass))],
                                                        sortDescriptors: [SortDescriptor(\.startDate)]).result(for: store)
        return samples.filter { !Self.isExerly($0) }.map {
            (HealthWeight(id: $0.uuid, at: $0.startDate, kilograms: $0.quantity.doubleValue(for: .gramUnit(with: .kilo)),
                          timeZone: Self.zone($0)), $0.sourceRevision.source.name)
        }
    }

    /// The kinds people log most, in words; others are "Workout".
    static func name(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: "Running"
        case .walking: "Walking"
        case .hiking: "Hiking"
        case .cycling: "Cycling"
        case .swimming: "Swimming"
        case .rowing: "Rowing"
        case .elliptical: "Elliptical"
        case .stairClimbing: "Stair climbing"
        case .yoga: "Yoga"
        case .pilates: "Pilates"
        case .highIntensityIntervalTraining: "HIIT"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "Strength training"
        case .coreTraining: "Core training"
        case .dance: "Dance"
        case .soccer: "Soccer"
        case .basketball: "Basketball"
        case .tennis: "Tennis"
        default: "Workout"
        }
    }
}

/// Where imported workouts are kept: the account's activity log.
@MainActor
protocol HealthActivityStore: AnyObject {
    /// The days the activity log takes, today last.
    var days: ClosedRange<LocalDate> { get }
    /// Which of these activities this phone has for the account, each true
    /// if it was deleted.
    func activityStates(_ ids: Set<String>) -> [String: Bool]
    /// An activity's fingerprint as it's saved now, nil when it isn't.
    func activityFingerprint(_ clientID: String) -> String?
    /// Reads the account's activities on these days. False when the account
    /// couldn't be reached.
    func readActivities(_ days: ClosedRange<LocalDate>) async -> Bool
    func saveImportedActivity(_ request: ActivityRequest, clientID: String) throws
    func deleteImportedActivity(clientID: String) throws
}

/// This install of Exerly, as Health imports name their owner. Kept in the
/// app's defaults, so a reinstall is a new install whose imports start as
/// another's until it adopts them.
enum HealthImportInstall {
    static let key = "healthImport.install"

    static func id(_ defaults: UserDefaults = .standard) -> String {
        if let id = defaults.string(forKey: key) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: key)
        return id
    }
}

/// Workout changes written down before they're made. The activity log and
/// the account's records are separate stores, so each change to the log is
/// recorded with the record it leaves, and a crash between the two is
/// finished when Exerly next opens, instead of leaving an activity with no
/// record, or a deleted one recorded as imported.
struct HealthWorkoutWork: Codable {
    struct Activity: Codable {
        var type: String
        var minutes: Double
        var calories: Double?
        var day: String
    }

    enum Step: Codable {
        case save(Activity)
        /// Only while the activity's fingerprint is still this one, and its
        /// record still belongs to the install and generation it was listed for.
        case delete(expecting: String, owner: String, generation: Int)
        case none
    }

    struct Item: Codable {
        var step: Step
        /// The activity the step changes, kept apart from the record, as a
        /// removed record is kept without it.
        var target: String
        /// The record as the step leaves it; a save's fingerprint is the
        /// activity's once it's made.
        var record: HealthImport
    }

    var items: [Item]
    var anchor: Data?
    /// Turns reading workouts on, as confirming a preview does.
    var turnOn: Bool
    /// Where the account's Health switches and anchors are kept in defaults
    /// (`HealthHistoryModel`), so the work can be finished without it.
    var key: String
    /// Removals the read listed for the person, added to those waiting.
    var queued: [HealthChangeQueue.Entry] = []
    /// A full read's: its "No longer in Health" replaces the last one's.
    var fullRead = false
    /// The waiting changes applied, which leave the list made or dropped.
    var processed: [UUID] = []

    /// Finishes work a crash or a failure left written down, as the account
    /// opens (`AppAccountWorkspace`) or the Health screen reads. The work was
    /// read with the account's history, off the main actor; its changes are
    /// made here, on the main actor, where both stores are written.
    @MainActor
    static func recover(_ workspace: TrainingWorkspace, activities: HealthActivityStore, defaults: UserDefaults) throws {
        guard let data = try workspace.healthImports.pendingWork() else { return }
        try ExerlyJSON.decoder.decode(Self.self, from: data).finish(imports: workspace.healthImports, activities: activities, defaults: defaults)
    }

    /// Makes each change to the activity log that isn't made yet, so running
    /// it again after a crash repeats nothing; then saves the records and the
    /// list of changes and clears the work in one transaction, and moves
    /// Health's anchor on.
    @MainActor
    func finish(imports: HealthImportStore, activities store: HealthActivityStore, defaults: UserDefaults) throws {
        var records: [HealthImport] = []
        for item in items {
            var record = item.record
            let deleted = store.activityStates([item.target])[item.target]
            switch item.step {
            case .save(let activity):
                if deleted == nil {
                    try store.saveImportedActivity(ActivityRequest(type: activity.type, duration: activity.minutes, calories: activity.calories,
                                                                   intensity: nil, entryDate: activity.day, category: "health"),
                                                   clientID: item.target)
                }
                guard let print = store.activityFingerprint(item.target) else { continue }
                record.fingerprint = print
            case let .delete(expecting, owner, generation):
                // Adopted elsewhere since it was listed: no longer this install's to take out.
                if let current = imports.records[record.id], current.owner != owner || current.generation != generation { continue }
                // Changed since it was listed: theirs, and its record stays as it was.
                if deleted == false {
                    guard store.activityFingerprint(item.target) == expecting else { continue }
                    try store.deleteImportedActivity(clientID: item.target)
                }
            case .none:
                break
            }
            records.append(record)
        }
        var queue = imports.queue.removing(Set(processed))
        if !queued.isEmpty || fullRead { queue = queue.adding(queued, replacingMissing: fullRead ? .workout : nil) }
        try imports.save(records, finishingWork: true, queue: queue == imports.queue ? nil : queue)
        // Applying changes reads nothing, and leaves where reading stopped as it was.
        if let anchor { defaults.set(anchor, forKey: key + ".anchor." + HealthHistoryKind.workouts.rawValue) }
        if turnOn {
            let on = Set(defaults.stringArray(forKey: key + ".enabled") ?? []).union([HealthHistoryKind.workouts.rawValue])
            defaults.set(HealthHistoryKind.allCases.map(\.rawValue).filter(on.contains), forKey: key + ".enabled")
        }
    }
}

/// The changes from Health that would still do something: their record
/// still imported, and its entry or activity still there as it was listed.
/// Today's row and the card both show these, so neither shows what's been
/// applied on another phone or changed since.
@MainActor
enum HealthChangeList {
    static func actionable(_ workspace: TrainingWorkspace, activities: HealthActivityStore) -> [HealthChangeQueue.Entry] {
        let imports = workspace.healthImports, listed = imports.queue.entries
        guard !listed.isEmpty else { return [] }
        let entries = listed.contains { $0.kind == .food }
            ? Dictionary(workspace.nutrition.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) : [:]
        return listed.filter { change in
            guard let record = imports.records[change.id], change.stillFor(record) else { return false }
            switch change.kind {
            case .food:
                return UUID(uuidString: change.target).flatMap { entries[$0] }.map { HealthImport.fingerprint($0) == change.fingerprint } ?? false
            case .workout:
                return activities.activityStates([change.target])[change.target] == false && activities.activityFingerprint(change.target) == change.fingerprint
            }
        }
    }

    /// Leaves only those still to do in the account's list.
    static func prune(_ workspace: TrainingWorkspace, activities: HealthActivityStore) throws {
        guard !workspace.healthImports.queue.isEmpty else { return }
        try workspace.healthImports.prune(keeping: actionable(workspace, activities: activities))
    }
}

/// The history switches and their preview for the open account. Kept per
/// server and account. Everything read is bound to the account it was read
/// for, and to the switch: turning it off, or another account opening,
/// while Health is read saves nothing.
@MainActor
final class HealthHistoryModel: ObservableObject {
    struct Pending: Identifiable {
        var kind: HealthHistoryKind
        var preview: HealthHistoryPreview
        var foods: HealthImportPlan<HealthFoodReading>?
        var workouts: HealthImportPlan<HealthWorkoutReading>?
        /// What was read, to claim entries with no record, and to plan again as it's confirmed.
        var readings: [UUID: HealthFoodReading] = [:]
        var workoutReadings: [UUID: HealthWorkoutReading] = [:]
        var deleted: [UUID] = []
        var full = false
        /// Workouts read while the account couldn't be reached, which add nothing.
        var unreached = false
        /// The weigh-ins shown, which are all that may be imported.
        var weights: Set<UUID> = []
        var anchor: Data?
        var generation = 0
        /// Their choice for what a full read found on another iPhone: off unless they turn it on.
        var adopt = false
        /// Why this preview was shown again, or what waits.
        var note: String?
        /// Checking everything again, with the switch already on.
        var isCheck = false
        var id: String { kind.rawValue }
    }

    /// Food and workouts; weigh-ins are HealthSync's switch.
    @Published private(set) var enabled: Set<HealthHistoryKind>
    @Published private(set) var requesting: HealthHistoryKind?
    @Published var pending: Pending?
    @Published private(set) var messages: [HealthHistoryKind: String] = [:]
    /// What the last import changed, in words.
    @Published private(set) var lastImport: [HealthHistoryKind: String] = [:]
    /// Applying the account's changes from Health, and what the last apply did.
    @Published private(set) var applying = false
    @Published private(set) var changesMessage: String?

    private let accountID: String
    private let install: String
    private let client: HealthHistoryClient
    private let defaults: UserDefaults
    private let key: String
    private let timeZone: TimeZone
    private let workspace: @MainActor () -> TrainingWorkspace?
    private let isCurrent: @MainActor (String) -> Bool
    private let enableWeights: @MainActor (Set<UUID>) async -> Bool
    private let activities: @MainActor () -> HealthActivityStore
    /// Bumped as a switch turns off, so a read already under way saves nothing.
    private var generation: [HealthHistoryKind: Int] = [:]

    /// `enableWeights` turns Read weigh-ins on with the readings reviewed,
    /// and is false when Health has others, which need a new preview.
    init(accountID: String, timeZone: TimeZone = .current, client: HealthHistoryClient = HealthKitHistoryClient.shared,
         namespace: String = APIClient.shared.storageNamespace, defaults: UserDefaults = .standard, install: String? = nil,
         workspace: @escaping @MainActor () -> TrainingWorkspace? = { HealthSync.shared.workspace },
         isCurrent: @escaping @MainActor (String) -> Bool = { SyncEngine.shared.isConfigured(for: $0) },
         enableWeights: @escaping @MainActor (Set<UUID>) async -> Bool = { await HealthSync.shared.enableReadingWeights(reviewed: $0) },
         activities: @escaping @MainActor () -> HealthActivityStore = { SyncEngine.shared }) {
        self.accountID = accountID
        self.install = install ?? HealthImportInstall.id(defaults)
        key = "healthHistory.\(namespace).\(accountID)"
        self.client = client
        self.defaults = defaults
        self.timeZone = timeZone
        self.workspace = workspace
        self.isCurrent = isCurrent
        self.enableWeights = enableWeights
        self.activities = activities
        let saved = accountID.isEmpty ? [] : defaults.stringArray(forKey: key + ".enabled") ?? []
        enabled = Set(saved.compactMap(HealthHistoryKind.init(rawValue:)))
    }

    var isAvailable: Bool { client.isAvailable }

    /// Asks Health for the kind and shows what importing would do: what's
    /// changed since the last read when there was one, else everything.
    /// Nothing is saved until `confirm`.
    func begin(_ kind: HealthHistoryKind, note: String? = nil) async {
        await preview(kind, full: kind == .weights || anchor(kind) == nil, note: note)
    }

    /// Reads everything Health has of the kind again, for a preview that also
    /// lists what's no longer in Health, and what this iPhone could keep as
    /// its own imports.
    func checkEverythingAgain(_ kind: HealthHistoryKind) async {
        await preview(kind, full: true, note: nil)
    }

    private func preview(_ kind: HealthHistoryKind, full: Bool, note: String?) async {
        messages[kind] = nil
        guard client.isAvailable else {
            messages[kind] = "Apple Health isn't available on this device."
            return
        }
        guard let workspace = open() else { return }
        requesting = kind
        defer { if requesting == kind { requesting = nil } }
        let started = generation[kind, default: 0]
        do {
            try recover(workspace)
            try await client.requestAccess(kind)
            guard owns(workspace), generation[kind, default: 0] == started else { return }
            guard var pending = try await read(kind, full: full, in: workspace, generation: started), requesting == kind else { return }
            pending.note = note ?? pending.note
            pending.isCheck = full && enabled.contains(kind)
            self.pending = pending
        } catch {
            guard owns(workspace) else { return }
            messages[kind] = "Health couldn't be read. Try again."
        }
    }

    /// Imports what the preview showed, with their choice, and turns the kind
    /// on. What Health deleted, or no longer has, waits in Changes from Health.
    func confirm(adopt: Bool = false) async {
        guard var pending, let workspace = open() else { return }
        pending.adopt = adopt
        self.pending = nil
        if pending.kind == .weights {
            let matched = await enableWeights(pending.weights)
            guard owns(workspace) else { return }
            guard matched else {
                await begin(.weights, note: "Health has changed since this opened. Check what's here now.")
                return
            }
            lastImport[.weights] = "Added \(HealthHistoryKind.weights.count(pending.preview.adding))."
            return
        }
        guard generation[pending.kind, default: 0] == pending.generation else { return }
        do {
            try await workspace.healthImports.serially { [self] in
                switch try await apply(pending, in: workspace, turningOn: true) {
                case .applied:
                    lastImport[pending.kind] = Self.summary(pending)
                    enabled.insert(pending.kind)
                    saveEnabled()
                case .stale: break
                case .revised(var revised):
                    revised.note = "Exerly changed while this was open. Here's what importing does now."
                    self.pending = revised
                }
            }
        } catch {
            messages[pending.kind] = "Nothing was imported. Try again."
        }
    }

    func cancel() { pending = nil }

    /// Stops reading the kind, and drops any read under way. The anchor
    /// stays, so turning it on again catches up with Health's deletions.
    func turnOff(_ kind: HealthHistoryKind) {
        generation[kind, default: 0] += 1
        enabled.remove(kind)
        saveEnabled()
    }

    /// Reads what changed in Health for the switches that are on, and
    /// nothing for those that are off.
    func refresh() async {
        if let workspace = open() {
            do {
                try recover(workspace)
                try HealthChangeList.prune(workspace, activities: activities())
            } catch {
                messages[.workouts] = "Workouts from Health couldn't be saved. Exerly will try again."
                return
            }
        }
        guard client.isAvailable else { return }
        for kind in [HealthHistoryKind.foods, .workouts] where enabled.contains(kind) {
            guard let workspace = open() else { return }
            let started = generation[kind, default: 0]
            do {
                // One at a time with Apply changes: a deletion read meanwhile is listed after it, never lost.
                try await workspace.healthImports.serially { [self] in
                    guard let pending = try await read(kind, full: false, in: workspace, generation: started) else { return }
                    // Changed since it was read: what Health's changes mean now, once.
                    var outcome = try await apply(pending, in: workspace)
                    if case .revised(let revised) = outcome { outcome = try await apply(revised, in: workspace) }
                    if case .applied = outcome { messages[kind] = pending.note }
                }
            } catch {
                guard owns(workspace) else { return }
                messages[kind] = "Health couldn't be read. Exerly will try again."
            }
        }
    }

    // MARK: Reading and saving

    /// The account's open data, if it's this model's account.
    private func open() -> TrainingWorkspace? {
        guard let workspace = workspace(), owns(workspace) else { return nil }
        return workspace
    }

    /// Still this account, with the same data open, and still wanted.
    private func owns(_ workspace: TrainingWorkspace) -> Bool {
        !accountID.isEmpty && !Task.isCancelled && workspace.accountID == accountID && self.workspace() === workspace && isCurrent(accountID)
    }

    /// Still this account, and the switch wasn't turned off since `started`.
    private func current(_ kind: HealthHistoryKind, _ workspace: TrainingWorkspace, since started: Int) -> Bool {
        owns(workspace) && generation[kind, default: 0] == started
    }

    private func anchor(_ kind: HealthHistoryKind) -> Data? { defaults.data(forKey: key + ".anchor." + kind.rawValue) }

    /// Health's changes of a kind, or everything, planned against the
    /// account's records. Nil when the account changed or the switch was
    /// turned off while Health was read.
    private func read(_ kind: HealthHistoryKind, full: Bool, in workspace: TrainingWorkspace, generation started: Int) async throws -> Pending? {
        var pending = Pending(kind: kind, preview: HealthHistoryPreview(), generation: started)
        switch kind {
        case .weights:
            let readings = try await client.weights()
            guard current(kind, workspace, since: started) else { return nil }
            pending.preview = HealthHistory.weights(readings, existing: Set(workspace.nutrition.weights.map(\.id)), timeZone: timeZone)
            pending.weights = Set(readings.map(\.weight.id))
        case .foods:
            let changes = try await client.foods(after: full ? nil : anchor(kind))
            guard current(kind, workspace, since: started) else { return nil }
            let plan = foodPlan(changes, full: full, in: workspace)
            (pending.preview, pending.foods, pending.anchor) = (plan.preview, plan, changes.anchor)
            pending.readings = Dictionary(changes.added.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            (pending.deleted, pending.full) = (changes.deleted, full)
        case .workouts:
            let changes = try await client.workouts(after: full ? nil : anchor(kind))
            guard current(kind, workspace, since: started) else { return nil }
            var plan = workoutPlan(changes, full: full, in: workspace)
            var keepAnchor = false
            // Before adding any, the account's own on those days, which a phone just installed may not
            // have yet; and the days of imports whose activity this phone hasn't read.
            let records = workspace.healthImports.records(.workout).filter { $0.state != .removed }
            let states = activities().activityStates(Set(records.map(\.target)))
            let days = plan.adding.map { LocalDate($0.start, in: $0.timeZone ?? timeZone) } + records.filter { states[$0.target] == nil }.map(\.day)
            if let first = days.min(), let last = days.max() {
                let reached = await activities().readActivities(first...last)
                guard current(kind, workspace, since: started) else { return nil }
                plan = workoutPlan(changes, full: full, in: workspace)
                if !reached {
                    // Unsure what the account has, add none, nor set aside anything for them:
                    // the next read, from the same anchor and online, will.
                    Self.holdAdditions(&plan)
                    pending.note = "Workouts from Health will be added once Exerly can reach your account."
                    keepAnchor = true
                }
            }
            (pending.preview, pending.workouts) = (plan.preview, plan)
            pending.anchor = keepAnchor ? anchor(kind) : changes.anchor
            pending.workoutReadings = Dictionary(changes.added.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            (pending.deleted, pending.full, pending.unreached) = (changes.deleted, full, keepAnchor)
        }
        return pending
    }

    private static func holdAdditions(_ plan: inout HealthImportPlan<HealthWorkoutReading>) {
        (plan.preview.adding, plan.adding) = (0, [])
    }

    /// The plan made again from what was read, against the account as it is
    /// now, as another phone's imports may have arrived by sync since.
    private func planAgain(_ pending: Pending, in workspace: TrainingWorkspace) -> Pending {
        var revised = pending
        if pending.foods != nil {
            let changes = HealthChanges(added: Array(pending.readings.values), deleted: pending.deleted, anchor: pending.anchor)
            let plan = foodPlan(changes, full: pending.full, in: workspace)
            (revised.preview, revised.foods) = (plan.preview, plan)
        }
        if pending.workouts != nil {
            let changes = HealthChanges(added: Array(pending.workoutReadings.values), deleted: pending.deleted, anchor: pending.anchor)
            var plan = workoutPlan(changes, full: pending.full, in: workspace)
            if pending.unreached { Self.holdAdditions(&plan) }
            (revised.preview, revised.workouts) = (plan.preview, plan)
        }
        revised.adopt = false
        return revised
    }

    /// Whether two plans make the same changes.
    private static func same<T>(_ a: HealthImportPlan<T>?, _ b: HealthImportPlan<T>?, id: (T) -> UUID) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return Set(a.adding.map(id)) == Set(b.adding.map(id)) && a.removing == b.removing
            && a.missing == b.missing && a.adoptable == b.adoptable
    }

    private func foodPlan(_ changes: HealthChanges<HealthFoodReading>, full: Bool, in workspace: TrainingWorkspace) -> HealthImportPlan<HealthFoodReading> {
        var records = workspace.healthImports.records(.food)
        if !full {
            // Only the days Health's changes touch: a screen opening with nothing new does no work.
            let deleted = Set(changes.deleted)
            let days = Set(changes.added.map { HealthHistory.item($0, timeZone: timeZone).day } + records.filter { deleted.contains($0.id) }.map(\.day))
            // Removed ones are tombstones with no day, kept so their samples are never imported again.
            records = records.filter { $0.state == .removed || days.contains($0.day) }
        }
        let entries = Dictionary(workspace.nutrition.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var live = Set<UUID>(), changed = Set<UUID>()
        for record in records {
            guard let id = UUID(uuidString: record.target), let entry = entries[id] else { continue }
            live.insert(record.id)
            if HealthImport.fingerprint(entry) != record.fingerprint { changed.insert(record.id) }
        }
        let known = Set(records.map(\.id))
        let untracked = Set(changes.added.map(\.id).filter { entries[$0] != nil && !known.contains($0) })
        return HealthHistory.plan(added: changes.added, deleted: Set(changes.deleted), full: full, records: records, install: install,
                                  live: live, changed: changed, untracked: untracked, grouping: .day) {
            HealthHistory.item($0, timeZone: timeZone)
        }
    }

    private func workoutPlan(_ changes: HealthChanges<HealthWorkoutReading>, full: Bool,
                             in workspace: TrainingWorkspace) -> HealthImportPlan<HealthWorkoutReading> {
        let store = activities()
        var records = workspace.healthImports.records(.workout)
        if !full {
            // Only the times Health's changes touch, a day either side for runs of overlaps.
            let deleted = Set(changes.deleted)
            let spans = changes.added.map { ($0.start, $0.end) } + records.filter { deleted.contains($0.id) }.map { ($0.start, $0.end) }
            if let start = spans.map(\.0).min(), let end = spans.map(\.1).max() {
                records = records.filter {
                    $0.state == .removed || ($0.end >= start.addingTimeInterval(-86400) && $0.start <= end.addingTimeInterval(86400))
                }
            } else {
                records = records.filter { $0.state == .removed }
            }
        }
        let derived = Dictionary(changes.added.map { (HealthHistory.activityID(for: $0.id, accountID: accountID), $0.id) },
                                 uniquingKeysWith: { first, _ in first })
        let states = store.activityStates(Set(records.map(\.target)).union(derived.keys))
        var live = Set<UUID>(), changed = Set<UUID>()
        for record in records where states[record.target] == false {
            live.insert(record.id)
            if store.activityFingerprint(record.target) != record.fingerprint { changed.insert(record.id) }
        }
        let known = Set(records.map(\.id))
        // An activity already in the account with no record: synced before its record, or deleted there. Never added again.
        let untracked = Set(derived.filter { states[$0.key] != nil && !known.contains($0.value) }.values)
        return HealthHistory.plan(added: changes.added, deleted: Set(changes.deleted), full: full, records: records, install: install,
                                  live: live, changed: changed, untracked: untracked, grouping: .overlap, within: store.days) {
            HealthHistory.item($0, timeZone: timeZone)
        }
    }

    enum Outcome {
        case applied
        /// The account changed, or the switch was turned off first.
        case stale
        /// Nothing was changed: the account changed since the plan was made, and this is the plan now.
        case revised(Pending)
    }

    /// Adds what a read found, notes sources set aside on what was imported
    /// first, and lists in Changes from Health what Health deleted, or a full
    /// read no longer finds, of this install's imports; a full read's replace
    /// the last one's. Nothing is taken out here, and the anchor moves on
    /// once they're recorded. Run `serially`.
    private func apply(_ pending: Pending, in workspace: TrainingWorkspace, turningOn: Bool = false) async throws -> Outcome {
        let kind = pending.kind
        guard current(kind, workspace, since: pending.generation) else { return .stale }
        try recover(workspace)
        let imports = workspace.healthImports
        func listed<T>(_ plan: HealthImportPlan<T>) -> [HealthChangeQueue.Entry] {
            plan.removing.compactMap { imports.records[$0].map { HealthChangeQueue.Entry($0, reason: .deleted) } }
                + plan.missing.compactMap { imports.records[$0].map { HealthChangeQueue.Entry($0, reason: .missing) } }
        }
        if let plan = pending.foods {
            let now = planAgain(pending, in: workspace)
            guard Self.same(now.foods, plan, id: \.id) else { return .revised(now) }
            var changes = HealthFoodChanges()
            (changes.adding, changes.alsoIn) = (plan.adding, plan.alsoIn)
            if pending.adopt {
                changes.adopting = plan.adoptable.filter { imports.records[$0] != nil }
                changes.claiming = plan.adoptable.compactMap { imports.records[$0] == nil ? pending.readings[$0] : nil }
            }
            let removals = listed(plan)
            if !removals.isEmpty || pending.full {
                changes.queue = imports.queue.adding(removals, replacingMissing: pending.full ? .food : nil)
            }
            try imports.apply(changes, to: workspace.nutrition, install: install, timeZone: timeZone)
            defaults.set(pending.anchor, forKey: key + ".anchor." + kind.rawValue)
        }
        if let plan = pending.workouts {
            let now = planAgain(pending, in: workspace)
            guard Self.same(now.workouts, plan, id: \.id) else { return .revised(now) }
            try perform(workoutWork(plan, imports: imports, adopting: pending.adopt ? pending.workoutReadings : nil, queued: listed(plan),
                                    fullRead: pending.full, anchor: pending.anchor, turningOn: turningOn), imports: imports)
        }
        return .applied
    }

    /// What Changes from Health shows now: those still to do.
    func changeEntries() -> [HealthChangeQueue.Entry] {
        guard let workspace = open() else { return [] }
        return HealthChangeList.actionable(workspace, activities: activities())
    }

    /// Applies exactly the changes shown, on this device, one at a time with
    /// reading Health. Each is checked again as it's made: still imported,
    /// and its entry or activity still as it was listed. Those that pass are
    /// taken out and become this install's, a generation on; the rest are
    /// dropped. Exactly these leave the list.
    func applyChanges() async {
        guard let workspace = open(), !applying else { return }
        applying = true
        defer { applying = false }
        changesMessage = nil
        let shown = changeEntries()
        guard !shown.isEmpty else { return }
        do {
            try await workspace.healthImports.serially { [self] in
                guard owns(workspace) else { return }
                try recover(workspace)
                let imports = workspace.healthImports
                try imports.applyRemovals(shown, to: workspace.nutrition, install: install)
                let workouts = shown.filter { $0.kind == .workout }
                if !workouts.isEmpty { try perform(removalWork(workouts, imports: imports), imports: imports) }
                try HealthChangeList.prune(workspace, activities: activities())
            }
        } catch {
            guard owns(workspace) else { return }
            changesMessage = "The changes couldn't all be applied. Try again."
        }
    }

    /// Keeps everything in Exerly as it is: exactly the changes shown are dismissed.
    func keepEverything() {
        guard let workspace = open() else { return }
        do {
            try workspace.healthImports.keep(Set(changeEntries().map(\.id)))
            changesMessage = nil
        } catch {
            changesMessage = "That couldn't be saved. Try again."
        }
    }

    /// What each change shown does, in words, oldest day first.
    func changeRows() -> [HealthChangeRow] {
        guard let workspace = open() else { return [] }
        let imports = workspace.healthImports
        let shown = HealthChangeList.actionable(workspace, activities: activities())
        guard !shown.isEmpty else { return [] }
        let entries = Dictionary(workspace.nutrition.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = shown.compactMap { change -> (LocalDate, HealthChangeRow)? in
            guard let record = imports.records[change.id] else { return nil }
            let why = change.reason == .deleted ? "Deleted in Health" : "No longer in Health"
            let title = change.kind == .food
                ? UUID(uuidString: change.target).flatMap { entries[$0] }?.food.name ?? "Food from \(record.sourceName)"
                : "Workout from \(record.sourceName)"
            let what = change.kind == .food ? "takes it out of your diary" : "takes it out of your activity"
            return (record.day, HealthChangeRow(id: change.id, title: "\(title), \(Self.day(record.day))", detail: "\(why): \(what)."))
        }
        return rows.sorted { ($0.0, $0.1.title) < ($1.0, $1.1.title) }.map(\.1)
    }

    private static func day(_ day: LocalDate) -> String {
        NutritionFormat.pickerDate(day, timeZone: .current).formatted(.dateTime.day().month(.abbreviated))
    }

    /// Workouts read from Health: new ones, adoptions, and sources set aside
    /// noted on what was imported first. Nothing is taken out. Nothing is
    /// changed yet: `perform` writes it down, then makes it.
    private func workoutWork(_ plan: HealthImportPlan<HealthWorkoutReading>, imports: HealthImportStore,
                             adopting readings: [UUID: HealthWorkoutReading]?, queued: [HealthChangeQueue.Entry], fullRead: Bool,
                             anchor: Data?, turningOn: Bool) -> HealthWorkoutWork {
        let store = activities()
        let now = Date()
        var items: [HealthWorkoutWork.Item] = []
        for workout in plan.adding where imports.records[workout.id] == nil {
            let clientID = HealthHistory.activityID(for: workout.id, accountID: accountID)
            let activity = HealthWorkoutWork.Activity(type: workout.activity, minutes: min(1440, max(0.1, (workout.minutes * 10).rounded() / 10)),
                                                      calories: workout.kilocalories.map { min(20000, max(0, $0.rounded())) },
                                                      day: LocalDate(workout.start, in: workout.timeZone ?? timeZone).description)
            items.append(.init(step: .save(activity), target: clientID,
                               record: HealthImport(workout: workout, clientID: clientID, fingerprint: "", owner: install, timeZone: timeZone, now: now)))
        }
        var adopted = Set<UUID>()
        if let readings {
            for id in plan.adoptable {
                if var record = imports.records[id] {
                    record.adopt(by: install, at: now)
                    adopted.insert(id)
                    items.append(.init(step: .none, target: record.target, record: record))
                } else if let workout = readings[id] {
                    let clientID = HealthHistory.activityID(for: id, accountID: accountID)
                    guard let print = store.activityFingerprint(clientID) else { continue }
                    items.append(.init(step: .none, target: clientID, record: HealthImport(workout: workout, clientID: clientID, fingerprint: print,
                                                                                         owner: install, generation: 1, timeZone: timeZone, now: now)))
                }
            }
        }
        for record in imports.noting(plan.alsoIn, except: adopted, now: now) {
            items.append(.init(step: .none, target: record.target, record: record))
        }
        return HealthWorkoutWork(items: items, anchor: anchor, turnOn: turningOn, key: key, queued: queued, fullRead: fullRead)
    }

    /// Takes out the workouts of the changes they apply: each, if its record
    /// is still the import it was listed for (owner, generation and all),
    /// becomes this install's, a generation on, and its activity goes if
    /// it's still as it was listed.
    private func removalWork(_ changes: [HealthChangeQueue.Entry], imports: HealthImportStore) -> HealthWorkoutWork {
        let now = Date()
        var items: [HealthWorkoutWork.Item] = []
        for change in changes {
            guard var record = imports.records[change.id], record.kind == .workout, change.stillFor(record) else { continue }
            let target = record.target
            record.adopt(by: install, at: now)
            record.state = .removed
            items.append(.init(step: .delete(expecting: change.fingerprint, owner: change.owner, generation: change.generation), target: target,
                               record: record))
        }
        return HealthWorkoutWork(items: items, anchor: nil, turnOn: false, key: key, processed: changes.map(\.id))
    }

    /// Writes the work down in the account's store before anything else, so
    /// it outlasts a crash, then makes it. Health's anchor moves on only after.
    private func perform(_ work: HealthWorkoutWork, imports: HealthImportStore) throws {
        try imports.recordWork(ExerlyJSON.canonical(work))
        try finish(work, imports: imports)
    }

    /// Finishes work left written down by a crash or a failure, before anything else is read or saved.
    private func recover(_ workspace: TrainingWorkspace) throws {
        guard let data = try workspace.healthImports.pendingWork() else { return }
        try finish(ExerlyJSON.decoder.decode(HealthWorkoutWork.self, from: data), imports: workspace.healthImports)
    }

    private func finish(_ work: HealthWorkoutWork, imports: HealthImportStore) throws {
        try work.finish(imports: imports, activities: activities(), defaults: defaults)
        if work.turnOn { enabled.insert(.workouts) }
    }

    /// "Added 3 foods. 1 set aside, as its day was already imported." from a confirmed preview.
    private static func summary(_ pending: Pending) -> String {
        let preview = pending.preview
        var parts = ["Added \(pending.kind.count(preview.adding))."]
        if preview.leftOut > 0 { parts.append("\(pending.kind.count(preview.leftOut)) from other sources set aside.") }
        let waiting = preview.removing + preview.missing
        if waiting > 0 { parts.append(waiting == 1 ? "1 change waits in Changes from Health." : "\(waiting) changes wait in Changes from Health.") }
        return parts.joined(separator: " ")
    }

    private func saveEnabled() { defaults.set(HealthHistoryKind.allCases.filter(enabled.contains).map(\.rawValue), forKey: key + ".enabled") }
}

extension SyncEngine: HealthActivityStore {
    var days: ClosedRange<LocalDate> {
        let last = LocalDate(today.rawValue) ?? LocalDate(Date(), in: .current)
        return last.adding(days: -3650)...last
    }

    func readActivities(_ days: ClosedRange<LocalDate>) async -> Bool {
        await refreshActivities(from: days.lowerBound.description, to: days.upperBound.description)
    }

    func saveImportedActivity(_ request: ActivityRequest, clientID: String) throws { try saveActivity(request, clientID: clientID) }

    func deleteImportedActivity(clientID: String) throws { try deleteActivity(clientID: clientID) }

}
