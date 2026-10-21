import ExerlyCore
import Foundation
import HealthKit

// Food, workouts and weigh-ins other apps saved to Health, imported only after
// a preview says what would be added, what's already in Exerly, and what
// source priority sets aside. After that, new ones are read as the screen
// opens. Weigh-ins then go through the Read weigh-ins switch (HealthSync).

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

/// What changed in Health since an anchor.
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
        let added = result.addedSamples.filter { !Self.isExerly($0) }.map { food in
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
        return HealthChanges(added: added, deleted: result.deletedObjects.map(\.uuid), anchor: try Self.archive(result.newAnchor))
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

/// The history switches and their preview for the open account. Kept per
/// server and account.
@MainActor
final class HealthHistoryModel: ObservableObject {
    struct Pending: Identifiable {
        var kind: HealthHistoryKind
        var preview: HealthHistoryPreview
        var foods: [HealthFoodReading] = []
        var workouts: [HealthWorkoutReading] = []
        var anchor: Data?
        var id: String { kind.rawValue }
    }

    /// Food and workouts; weigh-ins are HealthSync's switch.
    @Published private(set) var enabled: Set<HealthHistoryKind>
    @Published private(set) var requesting: HealthHistoryKind?
    @Published var pending: Pending?
    @Published private(set) var messages: [HealthHistoryKind: String] = [:]
    /// What the last import added, in words.
    @Published private(set) var lastImport: [HealthHistoryKind: String] = [:]

    private let client: HealthHistoryClient
    private let defaults: UserDefaults
    private let key: String
    private let timeZone: TimeZone
    private let workspace: @MainActor () -> TrainingWorkspace?
    private let enableWeights: @MainActor () async -> Void
    private let saveActivity: @MainActor (ActivityRequest) throws -> Void

    init(accountID: String, timeZone: TimeZone = .current, client: HealthHistoryClient = HealthKitHistoryClient.shared,
         namespace: String = APIClient.shared.storageNamespace, defaults: UserDefaults = .standard,
         workspace: @escaping @MainActor () -> TrainingWorkspace? = { HealthSync.shared.workspace },
         enableWeights: @escaping @MainActor () async -> Void = { await HealthSync.shared.setEnabled(.readWeights, true) },
         saveActivity: @escaping @MainActor (ActivityRequest) throws -> Void = { _ = try SyncEngine.shared.saveActivity($0) }) {
        key = "healthHistory.\(namespace).\(accountID)"
        self.client = client
        self.defaults = defaults
        self.timeZone = timeZone
        self.workspace = workspace
        self.enableWeights = enableWeights
        self.saveActivity = saveActivity
        let saved = accountID.isEmpty ? [] : defaults.stringArray(forKey: key + ".enabled") ?? []
        enabled = Set(saved.compactMap(HealthHistoryKind.init(rawValue:)))
    }

    var isAvailable: Bool { client.isAvailable }

    /// Asks Health for the kind, reads all of it, and shows what importing
    /// would do. Nothing is saved until `confirm`.
    func begin(_ kind: HealthHistoryKind) async {
        messages[kind] = nil
        guard client.isAvailable else {
            messages[kind] = "Apple Health isn't available on this device."
            return
        }
        guard let workspace = workspace() else { return }
        requesting = kind
        defer { if requesting == kind { requesting = nil } }
        do {
            try await client.requestAccess(kind)
            var pending = Pending(kind: kind, preview: HealthHistoryPreview())
            switch kind {
            case .weights:
                pending.preview = HealthHistory.weights(try await client.weights(), existing: Set(workspace.nutrition.weights.map(\.id)),
                                                        timeZone: timeZone)
            case .foods:
                let changes = try await client.foods(after: nil)
                (pending.preview, pending.foods) = HealthHistory.foods(changes.added, existing: Set(workspace.nutrition.entries.map(\.id)),
                                                                        timeZone: timeZone)
                pending.anchor = changes.anchor
            case .workouts:
                let changes = try await client.workouts(after: nil)
                (pending.preview, pending.workouts) = HealthHistory.workouts(changes.added, existing: importedWorkouts, timeZone: timeZone)
                pending.anchor = changes.anchor
            }
            guard requesting == kind, self.workspace() === workspace else { return }
            self.pending = pending
        } catch {
            messages[kind] = "Health couldn't be read. Try again."
        }
    }

    /// Imports what the preview showed, and turns the kind on.
    func confirm() async {
        guard let pending, let workspace = workspace() else { return }
        self.pending = nil
        do {
            switch pending.kind {
            case .weights:
                await enableWeights()
            case .foods:
                try workspace.nutrition.importHealthFoods(pending.foods, timeZone: timeZone)
            case .workouts:
                try save(pending.workouts)
            }
        } catch {
            messages[pending.kind] = "Nothing was imported. Try again."
            return
        }
        lastImport[pending.kind] = "Added \(pending.kind.count(pending.preview.adding))."
        guard pending.kind != .weights else { return }
        defaults.set(pending.anchor, forKey: key + ".anchor." + pending.kind.rawValue)
        enabled.insert(pending.kind)
        saveEnabled()
    }

    func cancel() { pending = nil }

    func turnOff(_ kind: HealthHistoryKind) {
        enabled.remove(kind)
        defaults.removeObject(forKey: key + ".anchor." + kind.rawValue)
        saveEnabled()
    }

    /// Reads what's new for the switches that are on, with the same source
    /// priority, and nothing for those that are off.
    func refresh() async {
        guard client.isAvailable, let workspace = workspace() else { return }
        for kind in [HealthHistoryKind.foods, .workouts] where enabled.contains(kind) {
            let anchorKey = key + ".anchor." + kind.rawValue
            do {
                switch kind {
                case .foods:
                    let changes = try await client.foods(after: defaults.data(forKey: anchorKey))
                    let adding = HealthHistory.foods(changes.added, existing: Set(workspace.nutrition.entries.map(\.id)), timeZone: timeZone).adding
                    try workspace.nutrition.importHealthFoods(adding, deleted: changes.deleted, timeZone: timeZone)
                    defaults.set(changes.anchor, forKey: anchorKey)
                case .workouts:
                    let changes = try await client.workouts(after: defaults.data(forKey: anchorKey))
                    try save(HealthHistory.workouts(changes.added, existing: importedWorkouts, timeZone: timeZone).adding)
                    defaults.set(changes.anchor, forKey: anchorKey)
                case .weights: break
                }
            } catch {
                messages[kind] = "Health couldn't be read. Exerly will try again."
            }
        }
    }

    /// Workouts become activities, each once.
    private func save(_ workouts: [HealthWorkoutReading]) throws {
        var imported = importedWorkouts
        defer { defaults.set(imported.map(\.uuidString), forKey: key + ".workouts") }
        for workout in workouts where !imported.contains(workout.id) {
            let minutes = min(1440, max(0.1, (workout.minutes * 10).rounded() / 10))
            try saveActivity(ActivityRequest(type: workout.activity, duration: minutes, calories: workout.kilocalories.map { $0.rounded() },
                                             intensity: nil, entryDate: LocalDate(workout.start, in: workout.timeZone ?? timeZone).description,
                                             category: "health"))
            imported.insert(workout.id)
        }
    }

    private var importedWorkouts: Set<UUID> {
        Set((defaults.stringArray(forKey: key + ".workouts") ?? []).compactMap(UUID.init(uuidString:)))
    }

    private func saveEnabled() { defaults.set(HealthHistoryKind.allCases.filter(enabled.contains).map(\.rawValue), forKey: key + ".enabled") }
}
