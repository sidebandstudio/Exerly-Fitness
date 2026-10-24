import ExerlyCore
import Foundation
import HealthKit

// Sleep, heart rate variability and resting heart rate, read from Health for
// recovery context. Each has its own switch and asks Health only for its own
// type. They're read when shown and never saved, written or sent anywhere.

extension RecoveryStatus.Signal {
    var title: String {
        switch self {
        case .sleep: "Read sleep"
        case .hrv: "Read heart rate variability"
        case .restingHeartRate: "Read resting heart rate"
        }
    }

    /// Why Exerly wants this, in one line.
    var purpose: String {
        switch self {
        case .sleep: "Time asleep each night, to show your recovery. It never changes your targets."
        case .hrv: "Overnight heart rate variability against your usual, to show your recovery."
        case .restingHeartRate: "Resting heart rate each day against your usual, to show your recovery."
        }
    }

    /// What's shown when Health has none, and what to check.
    var missing: String {
        let what = switch self {
        case .sleep: "No sleep in Health this week. Check that Exerly can read Sleep"
        case .hrv: "No heart rate variability in Health this week. Check that Exerly can read Heart Rate Variability"
        case .restingHeartRate: "No resting heart rate in Health this week. Check that Exerly can read Resting Heart Rate"
        }
        return what + " in Health: your profile › Apps › Exerly."
    }
}

/// What Health returned for the signals asked for.
struct HealthRecoverySamples: Equatable {
    var sleep: [HealthSleepReading] = []
    var hrv: [HealthHeartReading] = []
    var restingHeartRate: [HealthHeartReading] = []
}

/// The HealthKit calls for recovery. Tests replace it with a fake.
protocol HealthRecoveryClient: AnyObject, Sendable {
    var isAvailable: Bool { get }
    func requestAccess(_ signal: RecoveryStatus.Signal) async throws
    /// Reads only the signals given.
    func read(_ signals: Set<RecoveryStatus.Signal>, in span: DateInterval) async throws -> HealthRecoverySamples
}

final class HealthKitRecoveryClient: HealthRecoveryClient, @unchecked Sendable {
    static let shared = HealthKitRecoveryClient()
    private let store = HKHealthStore()

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    static func type(_ signal: RecoveryStatus.Signal) -> HKSampleType {
        switch signal {
        case .sleep: HKCategoryType(.sleepAnalysis)
        case .hrv: HKQuantityType(.heartRateVariabilitySDNN)
        case .restingHeartRate: HKQuantityType(.restingHeartRate)
        }
    }

    func requestAccess(_ signal: RecoveryStatus.Signal) async throws {
        var share: Set<HKSampleType> = []
        #if DEBUG
        // Seeding synthetic nights for UI tests needs to write them.
        if HealthDebugSeed.recovery { share.insert(Self.type(signal)) }
        #endif
        try await store.requestAuthorization(toShare: share, read: [Self.type(signal)])
        #if DEBUG
        if HealthDebugSeed.recovery { try? await seed(signal) }
        #endif
    }

    func read(_ signals: Set<RecoveryStatus.Signal>, in span: DateInterval) async throws -> HealthRecoverySamples {
        let predicate = HKQuery.predicateForSamples(withStart: span.start, end: span.end, options: [])
        var samples = HealthRecoverySamples()
        if signals.contains(.sleep) {
            let found = try await HKSampleQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
                                                          sortDescriptors: [SortDescriptor(\.startDate)]).result(for: store)
            samples.sleep = found.map { sample in
                let asleep = HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue).contains(sample.value)
                return HealthSleepReading(start: sample.startDate, end: sample.endDate, kind: asleep ? .asleep : .notAsleep,
                                          source: sample.sourceRevision.source.bundleIdentifier, timeZone: Self.zone(sample))
            }
        }
        func heart(_ identifier: HKQuantityTypeIdentifier, _ unit: HKUnit) async throws -> [HealthHeartReading] {
            try await HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(identifier), predicate: predicate)],
                                              sortDescriptors: [SortDescriptor(\.startDate)]).result(for: store)
                .map { HealthHeartReading(at: $0.startDate, value: $0.quantity.doubleValue(for: unit),
                                          source: $0.sourceRevision.source.bundleIdentifier, timeZone: Self.zone($0)) }
        }
        if signals.contains(.hrv) { samples.hrv = try await heart(.heartRateVariabilitySDNN, .secondUnit(with: .milli)) }
        if signals.contains(.restingHeartRate) {
            samples.restingHeartRate = try await heart(.restingHeartRate, .count().unitDivided(by: .minute()))
        }
        return samples
    }

    private static func zone(_ sample: HKSample) -> TimeZone? {
        (sample.metadata?[HKMetadataKeyTimeZone] as? String).flatMap(TimeZone.init(identifier:))
    }

    #if DEBUG
    /// Seven synthetic nights, written as another app would, after removing
    /// earlier ones. UI tests only.
    private func seed(_ signal: RecoveryStatus.Signal) async throws {
        let type = Self.type(signal)
        guard store.authorizationStatus(for: type) == .sharingAuthorized else { return }
        _ = try await store.deleteObjects(of: type, predicate: HKQuery.predicateForObjects(withMetadataKey: HealthDebugSeed.markerKey))
        let metadata: [String: Any] = [HealthDebugSeed.markerKey: true, HKMetadataKeyTimeZone: TimeZone.current.identifier]
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let objects: [HKObject] = (1...7).compactMap { night -> HKObject? in
            guard let morning = calendar.date(byAdding: .day, value: 1 - night, to: today) else { return nil }
            let wake = morning.addingTimeInterval(6.5 * 3600 + Double(night % 3) * 900)
            switch signal {
            case .sleep:
                return HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                        start: wake.addingTimeInterval(-(7 + Double(night % 4) * 0.25) * 3600), end: wake, metadata: metadata)
            case .hrv:
                return HKQuantitySample(type: HKQuantityType(.heartRateVariabilitySDNN),
                                        quantity: HKQuantity(unit: .secondUnit(with: .milli), doubleValue: 42 + Double(night % 4) * 3),
                                        start: wake.addingTimeInterval(-3600), end: wake.addingTimeInterval(-3600), metadata: metadata)
            case .restingHeartRate:
                return HKQuantitySample(type: HKQuantityType(.restingHeartRate),
                                        quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: 56 + Double(night % 3)),
                                        start: wake, end: wake, metadata: metadata)
            }
        }
        try await store.save(objects)
    }
    #endif
}

/// The recovery switches for the open account, and the last four weeks of
/// what they read. Kept per server and account.
@MainActor
final class HealthRecoveryModel: ObservableObject {
    static let days = 28

    @Published private(set) var enabled: Set<RecoveryStatus.Signal>
    @Published private(set) var requesting: RecoveryStatus.Signal?
    /// Oldest first, through today; nil before the first read.
    @Published private(set) var recovery: [RecoveryDay]?
    @Published private(set) var messages: [RecoveryStatus.Signal: String] = [:]

    private let accountID: String
    private let client: HealthRecoveryClient
    private let defaults: UserDefaults
    private let key: String
    private let timeZone: TimeZone
    private let now: () -> Date
    private let isCurrent: @MainActor (String) -> Bool
    private var generation = UUID()

    init(accountID: String, timeZone: TimeZone = .current, client: HealthRecoveryClient = HealthKitRecoveryClient.shared,
         namespace: String = APIClient.shared.storageNamespace, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         isCurrent: @escaping @MainActor (String) -> Bool = { SyncEngine.shared.isConfigured(for: $0) }) {
        self.accountID = accountID
        self.isCurrent = isCurrent
        key = "healthRecovery.\(namespace).\(accountID)"
        self.client = client
        self.defaults = defaults
        self.timeZone = timeZone
        self.now = now
        let saved = accountID.isEmpty ? [] : defaults.stringArray(forKey: key) ?? []
        enabled = Set(saved.compactMap(RecoveryStatus.Signal.init(rawValue:)))
    }

    var isAvailable: Bool { client.isAvailable }

    func setEnabled(_ signal: RecoveryStatus.Signal, _ on: Bool) async {
        messages[signal] = nil
        guard on else {
            enabled.remove(signal)
            save()
            await refresh()
            return
        }
        guard client.isAvailable else {
            messages[signal] = "Apple Health isn't available on this device."
            return
        }
        requesting = signal
        defer { if requesting == signal { requesting = nil } }
        do {
            try await client.requestAccess(signal)
        } catch {
            messages[signal] = "Health access couldn't open. Try again."
            return
        }
        // Another account may have opened while Health asked.
        guard requesting == signal, owned else { return }
        // Health never says whether reading was allowed; what it returns shows.
        enabled.insert(signal)
        save()
        await refresh()
    }

    /// Reads the switches that are on, and nothing else.
    func refresh() async {
        let operation = UUID()
        generation = operation
        guard !enabled.isEmpty, client.isAvailable else {
            recovery = enabled.isEmpty ? nil : recovery
            return
        }
        let today = LocalDate(now(), in: timeZone)
        let dates = (0..<Self.days).reversed().map { today.adding(days: -$0) }
        // From 6 PM the evening before the first night, when it can start.
        let start = NutritionFormat.pickerDate(dates[0], timeZone: timeZone).addingTimeInterval(-30 * 3600)
        let samples = (try? await client.read(enabled, in: DateInterval(start: start, end: max(start, now())))) ?? HealthRecoverySamples()
        guard generation == operation, owned else { return }
        recovery = HealthRecovery.days(dates, sleep: samples.sleep, hrv: samples.hrv, restingHeartRate: samples.restingHeartRate,
                                       timeZone: timeZone)
    }

    /// The latest value of a signal in the last week, and its day.
    func latest(_ signal: RecoveryStatus.Signal) -> (date: LocalDate, value: Double)? {
        guard let recovery else { return nil }
        for day in recovery.suffix(7).reversed() {
            if let value = Self.value(signal, day) { return (day.date, value) }
        }
        return nil
    }

    /// How many of the last seven days have a value.
    func coverage(_ signal: RecoveryStatus.Signal) -> Int {
        (recovery ?? []).suffix(7).filter { Self.value(signal, $0) != nil }.count
    }

    static func value(_ signal: RecoveryStatus.Signal, _ day: RecoveryDay) -> Double? {
        switch signal {
        case .sleep: day.sleepHours
        case .hrv: day.hrv
        case .restingHeartRate: day.restingHeartRate
        }
    }

    func cancelRequest() { requesting = nil }

    /// Still this account's, and still wanted.
    private var owned: Bool { !Task.isCancelled && isCurrent(accountID) }

    private func save() { defaults.set(RecoveryStatus.Signal.allCases.filter(enabled.contains).map(\.rawValue), forKey: key) }
}
