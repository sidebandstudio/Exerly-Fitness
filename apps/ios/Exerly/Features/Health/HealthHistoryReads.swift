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
    /// These foods, those Health still has, to put one back.
    func foods(_ ids: Set<UUID>) async throws -> [HealthFoodReading]
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

    func foods(_ ids: Set<UUID>) async throws -> [HealthFoodReading] {
        guard !ids.isEmpty else { return [] }
        let samples = try await HKSampleQueryDescriptor(predicates: [.correlation(type: HKCorrelationType(.food),
                                                                                  predicate: HKQuery.predicateForObjects(with: ids))],
                                                        sortDescriptors: []).result(for: store)
        return samples.filter { !Self.isExerly($0) }.map(Self.food)
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
    /// Takes back Exerly's own deletion of an activity it imported.
    func restoreImportedActivity(clientID: String) throws
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
        /// Only while the activity's fingerprint is still this one.
        case delete(expecting: String)
        case restore
        case none
    }

    struct Item: Codable {
        var step: Step
        /// The record as the step leaves it; a save's or a restore's
        /// fingerprint is the activity's once it's made.
        var record: HealthImport
    }

    var items: [Item]
    var anchor: Data?
    /// Turns reading workouts on, as confirming a preview does.
    var turnOn: Bool
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
        /// Their choices for what a full read found: off unless they turn them on.
        var removeMissing = false
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
    private let pull: @MainActor (TrainingWorkspace) async -> Bool
    /// Bumped as a switch turns off, so a read already under way saves nothing.
    private var generation: [HealthHistoryKind: Int] = [:]

    /// `enableWeights` turns Read weigh-ins on with the readings reviewed,
    /// and is false when Health has others, which need a new preview.
    init(accountID: String, timeZone: TimeZone = .current, client: HealthHistoryClient = HealthKitHistoryClient.shared,
         namespace: String = APIClient.shared.storageNamespace, defaults: UserDefaults = .standard, install: String? = nil,
         workspace: @escaping @MainActor () -> TrainingWorkspace? = { HealthSync.shared.workspace },
         isCurrent: @escaping @MainActor (String) -> Bool = { SyncEngine.shared.isConfigured(for: $0) },
         enableWeights: @escaping @MainActor (Set<UUID>) async -> Bool = { await HealthSync.shared.enableReadingWeights(reviewed: $0) },
         activities: @escaping @MainActor () -> HealthActivityStore = { SyncEngine.shared },
         pull: @escaping @MainActor (TrainingWorkspace) async -> Bool = HealthHistoryModel.pullOwnership) {
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
        self.pull = pull
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

    /// Imports what the preview showed, with their choices, and turns the kind on.
    func confirm(removeMissing: Bool = false, adopt: Bool = false) async {
        guard var pending, let workspace = open() else { return }
        (pending.removeMissing, pending.adopt) = (removeMissing, adopt)
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
            switch try await apply(pending, in: workspace, turningOn: true) {
            case .applied: break
            case .stale: return
            case .held(let note):
                messages[pending.kind] = note
                return
            case .revised(var revised):
                revised.note = "Something in Exerly changed since this opened. This is what importing would do now."
                self.pending = revised
                return
            }
        } catch {
            messages[pending.kind] = "Nothing was imported. Try again."
            return
        }
        lastImport[pending.kind] = Self.summary(pending)
        enabled.insert(pending.kind)
        saveEnabled()
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
                guard let pending = try await read(kind, full: false, in: workspace, generation: started) else { continue }
                // Changed since it was read: what Health's changes mean now, once.
                var outcome = try await apply(pending, in: workspace)
                if case .revised(let revised) = outcome { outcome = try await apply(revised, in: workspace) }
                switch outcome {
                case .applied: messages[kind] = pending.note
                case .held(let note): messages[kind] = note
                case .stale, .revised: continue
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
        (plan.preview.adding, plan.adding, plan.preview.displacing, plan.displacing) = (0, [], 0, [])
    }

    /// The plan made again from what was read, against the account as it is
    /// now, so the whole day or time is checked as it's applied: an entry or
    /// activity changed since holds its group, and what was to replace it
    /// isn't added either.
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
        (revised.removeMissing, revised.adopt) = (false, false)
        return revised
    }

    /// Whether two plans make the same changes.
    private static func same<T>(_ a: HealthImportPlan<T>?, _ b: HealthImportPlan<T>?, id: (T) -> UUID) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return Set(a.adding.map(id)) == Set(b.adding.map(id)) && a.removing == b.removing && a.displacing == b.displacing
            && a.restoring == b.restoring && a.missing == b.missing && a.adoptable == b.adoptable
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
                                  live: live, changed: changed, untracked: untracked, grouping: .day) { HealthHistory.item($0, timeZone: timeZone) }
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
        /// Nothing was changed, for the reason given; Health's changes are read again next time.
        case held(String)
        /// Nothing was changed: the account changed since the plan was made, and this is the plan now.
        case revised(Pending)
    }

    /// The account's latest records from the server, so a phone that adopted
    /// imports since is their owner here too. False when it couldn't be reached.
    static func pullOwnership(_ workspace: TrainingWorkspace) async -> Bool {
        guard let sync = workspace.sync else { return true }
        do {
            try await sync.sync()
            return true
        } catch {
            return false
        }
    }

    /// Whether the plan takes anything out of Exerly or sets anything aside.
    private static func isDestructive(_ pending: Pending) -> Bool {
        let foods = pending.foods.map { !$0.removing.isEmpty || !$0.displacing.isEmpty || (pending.removeMissing && !$0.missing.isEmpty) }
        let workouts = pending.workouts.map {
            !$0.removing.isEmpty || !$0.displacing.isEmpty || (pending.removeMissing && !$0.missing.isEmpty)
        }
        return foods == true || workouts == true
    }

    /// Makes a plan's changes in the account it was read for, checking each
    /// again as it's saved. Anything it takes out waits for the account's
    /// latest records: only their owner at the latest generation does it.
    private func apply(_ pending: Pending, in workspace: TrainingWorkspace, turningOn: Bool = false) async throws -> Outcome {
        let kind = pending.kind
        guard current(kind, workspace, since: pending.generation) else { return .stale }
        try recover(workspace)
        if Self.isDestructive(pending) {
            let reached = await pull(workspace)
            guard current(kind, workspace, since: pending.generation) else { return .stale }
            guard reached else { return .held("Exerly will update this once it can reach your account.") }
        }
        let imports = workspace.healthImports
        if let plan = pending.foods {
            var changes = HealthFoodChanges()
            changes.adding = plan.adding
            changes.removing = plan.removing + (pending.removeMissing ? plan.missing : [])
            changes.displacing = plan.displacing
            if pending.adopt {
                changes.adopting = plan.adoptable.filter { imports.records[$0] != nil }
                changes.claiming = plan.adoptable.compactMap { imports.records[$0] == nil ? pending.readings[$0] : nil }
            }
            if !plan.restoring.isEmpty {
                changes.restoring = try await client.foods(Set(plan.restoring))
                guard current(kind, workspace, since: pending.generation) else { return .stale }
            }
            let now = planAgain(pending, in: workspace)
            guard Self.same(now.foods, plan, id: \.id) else { return .revised(now) }
            try imports.apply(changes, to: workspace.nutrition, install: install, timeZone: timeZone)
            defaults.set(pending.anchor, forKey: key + ".anchor." + kind.rawValue)
        }
        if let plan = pending.workouts {
            let now = planAgain(pending, in: workspace)
            guard Self.same(now.workouts, plan, id: \.id) else { return .revised(now) }
            try perform(workoutWork(plan, pending, imports: imports, turningOn: turningOn), imports: imports)
        }
        return .applied
    }

    /// Workouts' changes, each checked again as it's planned: only this
    /// install's records, and only activities still as they were imported.
    /// Nothing is changed yet: `perform` writes it down, then makes it.
    private func workoutWork(_ plan: HealthImportPlan<HealthWorkoutReading>, _ pending: Pending, imports: HealthImportStore,
                             turningOn: Bool) -> HealthWorkoutWork {
        let store = activities()
        let now = Date()
        var items: [HealthWorkoutWork.Item] = []
        let removals = HealthImport.outcomes(removing: plan.removing + (pending.removeMissing ? plan.missing : []), displacing: plan.displacing)
        for (id, state) in removals {
            guard var record = imports.records[id], record.owner == install, record.allows(state) else { continue }
            var step = HealthWorkoutWork.Step.none
            if record.state == .imported, store.activityStates([record.target])[record.target] == false {
                // Changed since it was imported: theirs now.
                guard store.activityFingerprint(record.target) == record.fingerprint else { continue }
                step = .delete(expecting: record.fingerprint)
            }
            record.state = state
            record.updatedAt = now
            items.append(.init(step: step, record: record))
        }
        for id in plan.restoring {
            guard var record = imports.records[id], record.owner == install, record.state == .displaced else { continue }
            record.state = .imported
            record.updatedAt = now
            items.append(.init(step: .restore, record: record))
        }
        for workout in plan.adding where imports.records[workout.id] == nil {
            let clientID = HealthHistory.activityID(for: workout.id, accountID: accountID)
            let activity = HealthWorkoutWork.Activity(type: workout.activity, minutes: min(1440, max(0.1, (workout.minutes * 10).rounded() / 10)),
                                                      calories: workout.kilocalories.map { min(20000, max(0, $0.rounded())) },
                                                      day: LocalDate(workout.start, in: workout.timeZone ?? timeZone).description)
            items.append(.init(step: .save(activity), record: HealthImport(workout: workout, clientID: clientID, fingerprint: "", owner: install,
                                                                           timeZone: timeZone, now: now)))
        }
        if pending.adopt {
            for id in plan.adoptable {
                if var record = imports.records[id] {
                    record.adopt(by: install, at: now)
                    items.append(.init(step: .none, record: record))
                } else if let workout = pending.workoutReadings[id] {
                    let clientID = HealthHistory.activityID(for: id, accountID: accountID)
                    guard let print = store.activityFingerprint(clientID) else { continue }
                    items.append(.init(step: .none, record: HealthImport(workout: workout, clientID: clientID, fingerprint: print, owner: install,
                                                                         generation: 1, timeZone: timeZone, now: now)))
                }
            }
        }
        return HealthWorkoutWork(items: items, anchor: pending.anchor, turnOn: turningOn)
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

    /// Makes each change to the activity log that isn't made yet, so running
    /// it again after a crash repeats nothing; then saves the records and
    /// clears the work in one transaction, and moves Health's anchor on.
    private func finish(_ work: HealthWorkoutWork, imports: HealthImportStore) throws {
        let store = activities()
        var records: [HealthImport] = []
        for item in work.items {
            var record = item.record
            let deleted = store.activityStates([record.target])[record.target]
            switch item.step {
            case .save(let activity):
                if deleted == nil {
                    try store.saveImportedActivity(ActivityRequest(type: activity.type, duration: activity.minutes, calories: activity.calories,
                                                                   intensity: nil, entryDate: activity.day, category: "health"),
                                                   clientID: record.target)
                }
                guard let print = store.activityFingerprint(record.target) else { continue }
                record.fingerprint = print
            case .delete(let expecting):
                // Changed since it was planned, as by a sync before a crash was finished: theirs now, its record as it was.
                if deleted == false {
                    guard store.activityFingerprint(record.target) == expecting else { continue }
                    try store.deleteImportedActivity(clientID: record.target)
                }
            case .restore:
                if deleted == true { try store.restoreImportedActivity(clientID: record.target) }
                record.fingerprint = store.activityFingerprint(record.target) ?? record.fingerprint
            case .none:
                break
            }
            records.append(record)
        }
        try imports.save(records, finishingWork: true)
        defaults.set(work.anchor, forKey: key + ".anchor." + HealthHistoryKind.workouts.rawValue)
        if work.turnOn {
            enabled.insert(.workouts)
            saveEnabled()
        }
    }

    /// "Added 3 foods. Took out 1 food." from a confirmed preview.
    private static func summary(_ pending: Pending) -> String {
        let preview = pending.preview
        var parts = ["Added \(pending.kind.count(preview.adding + preview.restoring))."]
        let out = preview.removing + preview.displacing + (pending.removeMissing ? preview.missing : 0)
        if out > 0 { parts.append("Took out \(pending.kind.count(out)).") }
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

    func restoreImportedActivity(clientID: String) throws { try undoActivityDeletion(entityID: clientID) }
}
