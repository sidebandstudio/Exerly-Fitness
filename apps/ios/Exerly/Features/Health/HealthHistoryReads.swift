import ExerlyCore
import Foundation
import HealthKit

// Food, workouts and weigh-ins other apps saved to Health, imported only after
// a preview says what would be added, what's already in Exerly, and what
// source priority sets aside. After that, Health is read again as the screen
// opens, all of it, so a better source saved later, or a record deleted while
// reading was off, is caught up with. Weigh-ins then go through the Read
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

protocol HealthHistoryClient: AnyObject, Sendable {
    var isAvailable: Bool { get }
    func requestAccess(_ kind: HealthHistoryKind) async throws
    /// Every food another app saved, as Health has them now.
    func foods() async throws -> [HealthFoodReading]
    /// Every workout another app or device saved.
    func workouts() async throws -> [HealthWorkoutReading]
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

    func foods() async throws -> [HealthFoodReading] {
        let samples = try await HKSampleQueryDescriptor(predicates: [.correlation(type: HKCorrelationType(.food))],
                                                        sortDescriptors: [SortDescriptor(\.startDate)]).result(for: store)
        return samples.filter { !Self.isExerly($0) }.map { food in
            var nutrients = NutrientAmounts()
            for nutrient in Nutrient.healthWritable {
                guard let identifier = nutrient.healthType else { continue }
                let samples = food.objects(for: HKQuantityType(HKQuantityTypeIdentifier(rawValue: identifier))).compactMap { $0 as? HKQuantitySample }
                guard !samples.isEmpty else { continue }
                nutrients[nutrient] = samples.reduce(0) { $0 + $1.quantity.doubleValue(for: HealthKitService.unit(nutrient.healthUnit)) }
            }
            return HealthFoodReading(id: food.uuid, at: food.startDate, name: food.metadata?[HKMetadataKeyFoodType] as? String,
                                     nutrients: nutrients, source: food.sourceRevision.source.bundleIdentifier,
                                     sourceName: food.sourceRevision.source.name, timeZone: Self.zone(food))
        }
    }

    func workouts() async throws -> [HealthWorkoutReading] {
        let samples = try await HKSampleQueryDescriptor(predicates: [.workout()], sortDescriptors: [SortDescriptor(\.startDate)])
            .result(for: store)
        return samples.filter { !Self.isExerly($0) }.map { workout in
            HealthWorkoutReading(id: workout.uuid, start: workout.startDate, end: workout.endDate,
                                 activity: Self.name(workout.workoutActivityType),
                                 kilocalories: workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?
                                     .doubleValue(for: .kilocalorie()),
                                 source: workout.sourceRevision.source.bundleIdentifier, sourceName: workout.sourceRevision.source.name,
                                 timeZone: Self.zone(workout))
        }
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
    /// Reads the account's activities on these days, as after a reinstall.
    func readActivities(_ days: ClosedRange<LocalDate>) async
    func saveImportedActivity(_ request: ActivityRequest, clientID: String) throws
    func deleteImportedActivity(clientID: String) throws
}

/// The history switches and their preview for the open account. Kept per
/// server and account. Everything read is bound to the account it was read
/// for: when another account opens while Health is read, nothing is saved.
@MainActor
final class HealthHistoryModel: ObservableObject {
    struct Pending: Identifiable {
        var kind: HealthHistoryKind
        var preview: HealthHistoryPreview
        var foods: HealthHistoryPlan<HealthFoodReading>?
        var workouts: HealthHistoryPlan<HealthWorkoutReading>?
        /// The weigh-ins shown, which are all that may be imported.
        var weights: Set<UUID> = []
        /// Why this preview was shown again.
        var note: String?
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
    private let client: HealthHistoryClient
    private let defaults: UserDefaults
    private let key: String
    private let timeZone: TimeZone
    private let workspace: @MainActor () -> TrainingWorkspace?
    private let isCurrent: @MainActor (String) -> Bool
    private let enableWeights: @MainActor (Set<UUID>) async -> Bool
    private let activities: @MainActor () -> HealthActivityStore

    /// `enableWeights` turns Read weigh-ins on with the readings reviewed,
    /// and is false when Health has others, which need a new preview.
    init(accountID: String, timeZone: TimeZone = .current, client: HealthHistoryClient = HealthKitHistoryClient.shared,
         namespace: String = APIClient.shared.storageNamespace, defaults: UserDefaults = .standard,
         workspace: @escaping @MainActor () -> TrainingWorkspace? = { HealthSync.shared.workspace },
         isCurrent: @escaping @MainActor (String) -> Bool = { SyncEngine.shared.isConfigured(for: $0) },
         enableWeights: @escaping @MainActor (Set<UUID>) async -> Bool = { await HealthSync.shared.enableReadingWeights(reviewed: $0) },
         activities: @escaping @MainActor () -> HealthActivityStore = { SyncEngine.shared }) {
        self.accountID = accountID
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

    /// Asks Health for the kind, reads all of it, and shows what importing
    /// would do. Nothing is saved until `confirm`.
    func begin(_ kind: HealthHistoryKind, note: String? = nil) async {
        messages[kind] = nil
        guard client.isAvailable else {
            messages[kind] = "Apple Health isn't available on this device."
            return
        }
        guard let workspace = open() else { return }
        requesting = kind
        defer { if requesting == kind { requesting = nil } }
        do {
            try await client.requestAccess(kind)
            guard owns(workspace) else { return }
            guard var pending = try await plan(kind, in: workspace), requesting == kind else { return }
            pending.note = note
            self.pending = pending
        } catch {
            guard owns(workspace) else { return }
            messages[kind] = "Health couldn't be read. Try again."
        }
    }

    /// Imports what the preview showed, and turns the kind on.
    func confirm() async {
        guard let pending, let workspace = open() else { return }
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
        do {
            try apply(pending, in: workspace)
        } catch {
            messages[pending.kind] = "Nothing was imported. Try again."
            return
        }
        lastImport[pending.kind] = Self.summary(pending)
        enabled.insert(pending.kind)
        saveEnabled()
    }

    func cancel() { pending = nil }

    /// Stops reading the kind. What it imported stays, and is still tracked,
    /// so turning it on again catches up with deletions made meanwhile.
    func turnOff(_ kind: HealthHistoryKind) {
        enabled.remove(kind)
        saveEnabled()
    }

    /// Reads everything again for the switches that are on, with the same
    /// source priority, and nothing for those that are off.
    func refresh() async {
        guard client.isAvailable else { return }
        for kind in [HealthHistoryKind.foods, .workouts] where enabled.contains(kind) {
            guard let workspace = open() else { return }
            do {
                guard let pending = try await plan(kind, in: workspace) else { return }
                try apply(pending, in: workspace)
                messages[kind] = nil
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

    /// Everything Health has of a kind, planned against what's in Exerly. Nil
    /// when the account changed while Health was read.
    private func plan(_ kind: HealthHistoryKind, in workspace: TrainingWorkspace) async throws -> Pending? {
        var pending = Pending(kind: kind, preview: HealthHistoryPreview())
        switch kind {
        case .weights:
            let readings = try await client.weights()
            guard owns(workspace) else { return nil }
            pending.preview = HealthHistory.weights(readings, existing: Set(workspace.nutrition.weights.map(\.id)), timeZone: timeZone)
            pending.weights = Set(readings.map(\.weight.id))
        case .foods:
            let readings = try await client.foods()
            guard owns(workspace) else { return nil }
            let imported = workspace.nutrition.entries.filter { $0.food.foodID.hasPrefix(HealthHistory.foodIDPrefix) }
            let plan = HealthHistory.foods(readings, existing: Set(imported.map(\.id)), imported: tracked(.foods),
                                           locked: Set(imported.filter { $0.food.edited == true }.map(\.id)), timeZone: timeZone)
            (pending.preview, pending.foods) = (plan.preview, plan)
        case .workouts:
            let readings = try await client.workouts()
            guard owns(workspace) else { return nil }
            let store = activities()
            // Each workout's activity has an ID of its own, so one already in the account is found.
            var health: [String: UUID] = [:]
            for id in tracked(.workouts).union(readings.map(\.id)) { health[HealthHistory.activityID(for: id, accountID: accountID)] = id }
            func planned() -> HealthHistoryPlan<HealthWorkoutReading> {
                let states = store.activityStates(Set(health.keys))
                // One deleted in Exerly isn't added back.
                return HealthHistory.workouts(readings, existing: Set(states.filter { !$0.value }.keys.compactMap { health[$0] }),
                                              imported: tracked(.workouts).union(states.filter(\.value).keys.compactMap { health[$0] }),
                                              timeZone: timeZone, within: store.days)
            }
            var plan = planned()
            // Before adding any, the account's own on those days, which this phone may not have yet.
            let days = plan.adding.map { LocalDate($0.start, in: $0.timeZone ?? timeZone) }
            if let first = days.min(), let last = days.max() {
                await store.readActivities(first...last)
                guard owns(workspace) else { return nil }
                plan = planned()
            }
            (pending.preview, pending.workouts) = (plan.preview, plan)
        }
        return pending
    }

    /// Makes a plan's changes in the account it was read for, and records
    /// what's imported as each change is saved.
    private func apply(_ pending: Pending, in workspace: TrainingWorkspace) throws {
        guard owns(workspace) else { throw CancellationError() }
        if let plan = pending.foods {
            try workspace.nutrition.importHealthFoods(plan.adding, deleted: plan.removing, timeZone: timeZone)
            track(.foods, plan.imported)
        }
        if let plan = pending.workouts {
            let store = activities()
            var imported = plan.imported.union(plan.removing).subtracting(plan.adding.map(\.id))
            defer { track(.workouts, imported) }
            for id in plan.removing {
                try store.deleteImportedActivity(clientID: HealthHistory.activityID(for: id, accountID: accountID))
                imported.remove(id)
            }
            for workout in plan.adding {
                let minutes = min(1440, max(0.1, (workout.minutes * 10).rounded() / 10))
                try store.saveImportedActivity(ActivityRequest(type: workout.activity, duration: minutes,
                                                       calories: workout.kilocalories.map { min(20000, max(0, $0.rounded())) },
                                                       intensity: nil,
                                                       entryDate: LocalDate(workout.start, in: workout.timeZone ?? timeZone).description,
                                                       category: "health"),
                                       clientID: HealthHistory.activityID(for: workout.id, accountID: accountID))
                imported.insert(workout.id)
            }
        }
    }

    /// "Added 3 foods. Took out 1 food." from a confirmed preview.
    private static func summary(_ pending: Pending) -> String {
        var parts = ["Added \(pending.kind.count(pending.preview.adding))."]
        if pending.preview.removing > 0 { parts.append("Took out \(pending.kind.count(pending.preview.removing)).") }
        return parts.joined(separator: " ")
    }

    /// The Health IDs this install imported, still in Health or Exerly.
    private func tracked(_ kind: HealthHistoryKind) -> Set<UUID> {
        Set((defaults.stringArray(forKey: key + ".imported." + kind.rawValue) ?? []).compactMap(UUID.init(uuidString:)))
    }

    private func track(_ kind: HealthHistoryKind, _ ids: Set<UUID>) {
        defaults.set(ids.map(\.uuidString).sorted(), forKey: key + ".imported." + kind.rawValue)
    }

    private func saveEnabled() { defaults.set(HealthHistoryKind.allCases.filter(enabled.contains).map(\.rawValue), forKey: key + ".enabled") }
}

extension SyncEngine: HealthActivityStore {
    var days: ClosedRange<LocalDate> {
        let last = LocalDate(today.rawValue) ?? LocalDate(Date(), in: .current)
        return last.adding(days: -3650)...last
    }

    func readActivities(_ days: ClosedRange<LocalDate>) async {
        _ = try? await activityEntries(from: days.lowerBound.description, to: days.upperBound.description)
    }

    func saveImportedActivity(_ request: ActivityRequest, clientID: String) throws { try saveActivity(request, clientID: clientID) }

    func deleteImportedActivity(clientID: String) throws { try deleteActivity(clientID: clientID) }
}
