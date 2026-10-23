import ExerlyCore
import HealthKit
import SwiftUI

extension HealthCategory {
    var title: String {
        switch self {
        case .readWeights: "Read weigh-ins from Health"
        case .readActivity: "Read activity"
        case .writeFood: "Write food to Health"
        case .writeWeights: "Write weigh-ins"
        case .writeWorkouts: "Write workouts"
        }
    }

    /// Why Exerly wants this, in one line.
    var purpose: String {
        switch self {
        case .readWeights:
            "Weight and body fat from your scale or another app become weigh-ins for your trend weight, saved to your Exerly account."
        case .readActivity: "Steps and active Calories, shown for context. They never change your targets."
        case .writeFood:
            "Calories, protein, carbs, fat and the nutrients Health tracks, for food you log from the day you turn this on. Edits and deletions follow."
        case .writeWeights: "Weigh-ins you enter in Exerly. Readings that came from Health aren't written back."
        case .writeWorkouts: "Each workout you finish, with when it started and how long it took."
        }
    }
}

/// Steps and active Calories for the Read activity switch. Its preference is
/// kept per server and account.
@MainActor
final class HealthReadModel: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isRequesting = false
    @Published private(set) var steps: Int?
    @Published private(set) var calories: Int?
    @Published private(set) var message: String?
    private let preferenceKey: String
    private let defaults: UserDefaults
    private let available: () -> Bool
    private let request: () async throws -> Void
    private let load: () async -> (steps: Int?, calories: Int?)
    private var generation = UUID()

    init(accountID: String, namespace: String = APIClient.shared.storageNamespace, defaults: UserDefaults = .standard,
         available: @escaping () -> Bool = { HKHealthStore.isHealthDataAvailable() },
         request: @escaping () async throws -> Void = { try await HealthKitService.shared.requestAccess(.readActivity) },
         load: @escaping () async -> (steps: Int?, calories: Int?) = {
             let today = await HealthKitService.shared.activity(on: LocalDate(Date(), in: .current), timeZone: .current)
             return (today.steps, today.activeKilocalories)
         }) {
        preferenceKey = Self.key(accountID: accountID, namespace: namespace)
        self.defaults = defaults
        self.available = available
        self.request = request
        self.load = load
        isEnabled = !accountID.isEmpty && defaults.bool(forKey: preferenceKey)
    }

    static func key(accountID: String, namespace: String = APIClient.shared.storageNamespace) -> String {
        "healthRead.\(namespace).\(accountID)"
    }

    func setEnabled(_ enabled: Bool) async {
        let operation = UUID()
        generation = operation
        message = nil
        steps = nil
        calories = nil
        if !enabled {
            isEnabled = false
            isRequesting = false
            defaults.set(false, forKey: preferenceKey)
            return
        }
        guard available() else {
            message = "Apple Health isn't available on this device."
            return
        }
        isRequesting = true
        defer { if generation == operation { isRequesting = false } }
        do {
            try await request()
            guard generation == operation, !Task.isCancelled else { return }
            // Completing the permission sheet does not prove that read access
            // was granted. Health deliberately does not reveal denied reads.
            isEnabled = true
            defaults.set(true, forKey: preferenceKey)
            await refresh()
        } catch {
            guard generation == operation, !Task.isCancelled else { return }
            isEnabled = false
            defaults.set(false, forKey: preferenceKey)
            message = "Health access couldn't open. Try again."
        }
    }

    func refresh() async {
        guard isEnabled, available() else { return }
        let operation = generation
        let values = await load()
        guard generation == operation, isEnabled, !Task.isCancelled else { return }
        // Nil means no samples are visible. Health does not reveal denied reads.
        steps = values.steps
        calories = values.calories
    }

    func close() { generation = UUID(); isRequesting = false }
}

/// Apple Health: one switch per kind of data, each with its purpose, the
/// last sync and Sync now.
struct HealthKitSettingsView: View {
    @StateObject private var activity: HealthReadModel
    @StateObject private var recovery: HealthRecoveryModel
    @StateObject private var history: HealthHistoryModel
    @ObservedObject private var sync = HealthSync.shared
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Sync now is reading history and recovery after HealthSync's part.
    @State private var refreshing = false

    init(accountID: String) {
        _activity = StateObject(wrappedValue: HealthReadModel(accountID: accountID))
        _recovery = StateObject(wrappedValue: HealthRecoveryModel(accountID: accountID))
        _history = StateObject(wrappedValue: HealthHistoryModel(accountID: accountID))
    }

    var body: some View {
        ExScreen {
            ExCard(accent: true) {
                HStack(alignment: .firstTextBaseline, spacing: ExSpacing.small) {
                    if !typeSize.isAccessibilitySize {
                        Image(systemName: "heart.text.square.fill").font(.exH3).foregroundStyle(Color.exAccent)
                            .accessibilityHidden(true)
                    }
                    Text("You choose what to share").font(.exH3).foregroundStyle(Color.exTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                }
                Text("Each switch asks Health only for its own data. Exerly never uses Health data for advertising, and writes nothing to Health while a switch is off.")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                if !sync.isAvailable {
                    Label("Apple Health isn't available on this device.", systemImage: "exclamationmark.triangle")
                        .font(.exCaption).foregroundStyle(Color.exWarning)
                }
            }
            section("Read from Health") {
                switchRow(.readWeights)
                divider
                historyRow(.foods)
                divider
                historyRow(.workouts)
                divider
                activityRow
            }
            section("Recovery from Health") {
                ForEach(RecoveryStatus.Signal.allCases, id: \.self) { signal in
                    if signal != .sleep { divider }
                    recoveryRow(signal)
                }
            }
            section("Write to Health") {
                switchRow(.writeFood)
                divider
                switchRow(.writeWeights)
                divider
                switchRow(.writeWorkouts)
            }
            status
            Text("Turning a switch off stops it from now on. What's already in Health stays there: review or delete it, or change Exerly's access, in the Health app under your profile › Apps › Exerly.")
                .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .navigationTitle("Apple Health").navigationBarTitleDisplayMode(.inline)
        .task {
            await activity.refresh()
            await recovery.refresh()
            await history.refresh()
        }
        .sheet(item: $history.pending) { pending in
            HealthImportPreviewSheet(pending: pending, onImport: { remove, adopt in
                Task { await history.confirm(removeMissing: remove, adopt: adopt) }
            }, onCancel: history.cancel)
        }
        .onDisappear {
            activity.close()
            recovery.cancelRequest()
            sync.cancelRequest()
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: ExSpacing.small) {
            ExEyebrow(title).accessibilityAddTraits(.isHeader)
            ExCard { content() }
        }
    }

    private var divider: some View { Divider().overlay(Color.exBorder.opacity(0.6)) }

    private func toggleLabel(_ category: HealthCategory) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(category.title).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
            Text(category.purpose).font(.exCaption).foregroundStyle(Color.exTextSecondary)
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func switchRow(_ category: HealthCategory) -> some View {
        VStack(alignment: .leading, spacing: ExSpacing.small) {
            Toggle(isOn: Binding(get: { sync.preferences.isOn(category) }, set: { enabled in
                Task {
                    // History is previewed before the switch reads it all.
                    if category == .readWeights, enabled { await history.begin(.weights) } else { await sync.setEnabled(category, enabled) }
                }
            })) {
                toggleLabel(category)
            }
            .tint(.exActionFill)
            .disabled(!sync.isAvailable || sync.requesting != nil || history.requesting != nil)
            .accessibilityIdentifier("health.\(category.rawValue)")
            if sync.requesting == category || (category == .readWeights && history.requesting == .weights) {
                ProgressView("Opening Health access…").font(.exCaption)
            }
            if category == .readWeights {
                historyNotes(.weights)
            }
            if let notice = sync.notices[category] {
                Label(notice, systemImage: "exclamationmark.triangle").font(.exCaption).foregroundStyle(Color.exWarning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("health.\(category.rawValue).notice")
            }
            if category == .readWeights, nothingReadYet {
                // Health never says whether reading was allowed, so say what to check.
                Text("No weigh-ins from Health yet. If your scale saves to Health, check that Exerly can read Weight in the Health app: your profile › Apps › Exerly.")
                    .font(.exCaption).foregroundStyle(Color.exTextMuted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var nothingReadYet: Bool {
        guard sync.preferences.isOn(.readWeights), sync.preferences.lastSync != nil, !sync.isSyncing,
              let weights = sync.workspace?.nutrition.weights else { return false }
        return !weights.contains { $0.source == .appleHealth }
    }

    private var activityRow: some View {
        VStack(alignment: .leading, spacing: ExSpacing.small) {
            Toggle(isOn: Binding(get: { activity.isEnabled }, set: { enabled in Task { await activity.setEnabled(enabled) } })) {
                toggleLabel(.readActivity)
            }
            .tint(.exActionFill).disabled(activity.isRequesting || !sync.isAvailable)
            .accessibilityIdentifier("health.readActivity")
            if activity.isRequesting { ProgressView("Opening Health access…").font(.exCaption) }
            if let message = activity.message {
                Label(message, systemImage: "exclamationmark.triangle").font(.exCaption).foregroundStyle(Color.exWarning)
            }
            if activity.isEnabled {
                VStack(alignment: .leading, spacing: ExSpacing.tight) {
                    Text("Available from Health").font(.exSmall.weight(.semibold)).foregroundStyle(Color.exTextSecondary)
                    activityValue("Steps today", value: activity.steps.map { $0.formatted() })
                    activityValue("Active Calories today", value: activity.calories.map { "\($0.formatted()) kcal" })
                    if activity.steps == nil || activity.calories == nil {
                        Text("No data can mean nothing is recorded or reading is off for Exerly in the Health app.")
                            .font(.exSmall).foregroundStyle(Color.exTextMuted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(ExSpacing.item)
                .background(Color.exSurface2, in: RoundedRectangle(cornerRadius: ExRadius.control, style: .continuous))
            }
        }
    }

    private func historyRow(_ kind: HealthHistoryKind) -> some View {
        VStack(alignment: .leading, spacing: ExSpacing.small) {
            Toggle(isOn: Binding(get: { history.enabled.contains(kind) }, set: { on in
                if on { Task { await history.begin(kind) } } else { history.turnOff(kind) }
            })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                    Text(kind.purpose).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }.fixedSize(horizontal: false, vertical: true)
            }
            .tint(.exActionFill)
            .disabled(!history.isAvailable || history.requesting != nil)
            .accessibilityIdentifier("health.history.\(kind.rawValue)")
            if history.requesting == kind { ProgressView("Reading Health…").font(.exCaption) }
            historyNotes(kind)
            if history.enabled.contains(kind) {
                // A deliberate full read: lists what's no longer in Health, and what this iPhone could keep as its own.
                Button("Check everything again") { Task { await history.checkEverythingAgain(kind) } }
                    .font(.exCaption.weight(.semibold)).foregroundStyle(Color.exPrimaryText)
                    .disabled(history.requesting != nil)
                    .accessibilityIdentifier("health.history.\(kind.rawValue).checkAgain")
            }
        }
    }

    @ViewBuilder private func historyNotes(_ kind: HealthHistoryKind) -> some View {
        if let message = history.messages[kind] {
            Label(message, systemImage: "exclamationmark.triangle").font(.exCaption).foregroundStyle(Color.exWarning)
        }
        if let added = history.lastImport[kind] {
            Text(added).font(.exCaption).foregroundStyle(Color.exTextSecondary).accessibilityIdentifier("health.history.\(kind.rawValue).added")
        }
    }

    private func recoveryRow(_ signal: RecoveryStatus.Signal) -> some View {
        VStack(alignment: .leading, spacing: ExSpacing.small) {
            Toggle(isOn: Binding(get: { recovery.enabled.contains(signal) },
                                 set: { on in Task { await recovery.setEnabled(signal, on) } })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(signal.title).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                    Text(signal.purpose).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }.fixedSize(horizontal: false, vertical: true)
            }
            .tint(.exActionFill)
            .disabled(!recovery.isAvailable || recovery.requesting != nil)
            .accessibilityIdentifier("health.recovery.\(signal.rawValue)")
            if recovery.requesting == signal { ProgressView("Opening Health access…").font(.exCaption) }
            if let message = recovery.messages[signal] {
                Label(message, systemImage: "exclamationmark.triangle").font(.exCaption).foregroundStyle(Color.exWarning)
            }
            if recovery.enabled.contains(signal), recovery.recovery != nil {
                VStack(alignment: .leading, spacing: ExSpacing.tight) {
                    if let latest = recovery.latest(signal) {
                        activityValue(Self.day(latest.date, signal: signal), value: Self.format(latest.value, signal))
                        Text("\(recovery.coverage(signal)) of the last 7 \(signal == .restingHeartRate ? "days" : "nights") recorded")
                            .font(.exSmall).foregroundStyle(Color.exTextMuted)
                    } else {
                        Text(signal.missing).font(.exSmall).foregroundStyle(Color.exTextMuted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(ExSpacing.item)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.exSurface2, in: RoundedRectangle(cornerRadius: ExRadius.control, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("health.recovery.\(signal.rawValue).value")
            }
        }
    }

    /// "Last night", "Thursday night"; for resting heart rate, "Today" or the weekday.
    private static func day(_ date: LocalDate, signal: RecoveryStatus.Signal) -> String {
        let today = LocalDate(Date(), in: .current)
        if signal == .restingHeartRate {
            if date == today { return "Today" }
            if date == today.adding(days: -1) { return "Yesterday" }
        } else if date == today {
            return "Last night"
        }
        let weekday = NutritionFormat.pickerDate(date, timeZone: .current).formatted(.dateTime.weekday(.wide))
        return signal == .restingHeartRate ? weekday : "\(weekday) night"
    }

    private static func format(_ value: Double, _ signal: RecoveryStatus.Signal) -> String {
        switch signal {
        case .sleep:
            let minutes = Int((value * 60).rounded())
            return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
        case .hrv: return "\(Int(value.rounded())) ms"
        case .restingHeartRate: return "\(Int(value.rounded())) bpm"
        }
    }

    private func activityValue(_ title: String, value: String?) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: ExSpacing.item))
        return layout {
            Text(title).font(.exCaption).foregroundStyle(Color.exTextPrimary)
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Text(value ?? "No data available").font(value == nil ? .exCaption : .exStatSmall)
                .foregroundStyle(value == nil ? Color.exTextMuted : Color.exTextPrimary).monospacedDigit()
        }.fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
    }

    private var status: some View {
        ExCard {
            VStack(alignment: .leading, spacing: ExSpacing.tight) {
                Text(lastSyncText).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                if let result = sync.lastResult {
                    Text(result.summary).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                        .accessibilityIdentifier("health.lastResult")
                } else if !sync.anyOn && history.enabled.isEmpty && recovery.enabled.isEmpty {
                    Text("Turn on a switch above to start.").font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("health.lastSync")
            if let problem = sync.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.exCaption).foregroundStyle(Color.exError)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Task { await syncNow() }
            } label: {
                HStack(spacing: ExSpacing.small) {
                    if sync.isSyncing || refreshing {
                        ProgressView().tint(Color.exPrimaryText)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath").accessibilityHidden(true)
                    }
                    Text(sync.isSyncing || refreshing ? "Syncing…" : "Sync now")
                }
            }
            .buttonStyle(ExActionStyle(secondary: true))
            .disabled(!(sync.anyOn || !history.enabled.isEmpty || !recovery.enabled.isEmpty) || sync.isSyncing || refreshing)
            .accessibilityIdentifier("health.syncNow")
            #if DEBUG
            HealthDebugProbe(sync: sync)
            #endif
        }
    }

    /// Every switch that's on: weigh-ins and writes, food and workouts
    /// from other apps, and recovery.
    private func syncNow() async {
        refreshing = true
        defer { refreshing = false }
        await sync.sync(asked: true)
        await history.refresh()
        await recovery.refresh()
    }

    private var lastSyncText: String {
        guard let date = sync.preferences.lastSync else { return "Not synced yet" }
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Last synced today at \(time)" }
        return "Last synced \(date.formatted(.dateTime.month(.abbreviated).day())) at \(time)"
    }
}
