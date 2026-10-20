import Charts
import ExerlyCore
import SwiftData
import SwiftUI

@MainActor
final class MeasurementsViewModel: ObservableObject {
    @Published private(set) var isLoading = false
    @Published var error: String?
    @Published private(set) var measurements: [BodyMeasurementDTO] = []
    private var generation = UUID()

    /// Body measurements stay on the daily-log sync for now; weigh-ins live in ExerlyCore.
    func load(today: CalendarDay) async {
        let generation = UUID()
        self.generation = generation
        isLoading = true
        error = nil
        let from = today.adding(days: -3650)!.rawValue
        let to = today.rawValue
        if let saved = try? await SyncEngine.shared.measurements(from: from, to: to, cachedOnly: true), self.generation == generation {
            measurements = saved
        }
        do {
            let values = try await SyncEngine.shared.measurements(from: from, to: to)
            guard self.generation == generation else { return }
            measurements = values
        } catch is CancellationError {
            // A newer load replaced this one.
        } catch {
            if self.generation == generation { self.error = error.localizedDescription }
        }
        if self.generation == generation { isLoading = false }
    }
}

/// What the weigh-in sheet opens on.
private enum WeighInRequest: Identifiable {
    case new
    case edit(WeightEntry)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let entry): entry.id.uuidString
        }
    }
}

/// Progress → Body: weight, the goal, measurements and expenditure, with the
/// sheets they open and Undo for a deleted weigh-in.
struct MeasurementsTab: View {
    let workspace: TrainingWorkspace?
    let unit: MassUnit
    let timeZone: TimeZone
    let openingError: String?
    @Query private var legacyMeasurements: [Measurement]
    @EnvironmentObject private var sync: SyncEngine
    @EnvironmentObject private var auth: AuthViewModel
    @StateObject private var viewModel = MeasurementsViewModel()
    @State private var logging = false
    @State private var actionError: String?
    @State private var showLegacyReview = false
    @State private var weighIn: WeighInRequest?
    @State private var goalEditor: TargetsEditorRequest?
    @State private var toast: BodyToast?

    struct BodyToast: Equatable {
        let id = UUID()
        let message: String
        /// A deleted weigh-in to bring back.
        var undo: WeightEntry?
    }

    init(initialDate: CalendarDay, workspace: TrainingWorkspace?, unit: MassUnit, timeZone: TimeZone, openingError: String? = nil) {
        self.workspace = workspace
        self.unit = unit
        self.timeZone = timeZone
        self.openingError = openingError
    }

    private var lengthUnit: LengthUnit { LengthUnit(unit) }

    var body: some View {
        let records = MeasurementRecords(viewModel.measurements)
        ScrollViewReader { proxy in ScrollView {
            VStack(alignment: .leading, spacing: ExSpacing.page) {
                if let actionError { Text(actionError).font(.exCaption).foregroundStyle(Color.exError) }
                if let workspace {
                    BodyWeightSection(workspace: workspace, unit: unit, timeZone: timeZone, onWeighIn: { weighIn = .new },
                                      onEdit: { weighIn = .edit($0) }, onDelete: delete, onDeleted: deleted,
                                      onEditGoal: { editGoal(workspace) },
                                      onAddGoalWeight: { editGoal(workspace, addsGoalWeight: true) },
                                      onShowWeighIns: { withAnimation(.snappy) { proxy.scrollTo(BodyWeightSectionID.weighIns, anchor: .top) } },
                                      measurements: { measurementsCard(records) })
                } else if let openingError {
                    ExCard { Text(openingError).font(.exBody).foregroundStyle(Color.exTextSecondary) }
                    measurementsCard(records)
                } else {
                    LoadingStateView(message: "Opening your weigh-ins…").frame(height: 160)
                }
                if !legacyMeasurements.isEmpty {
                    Text("Measurements from an older version are preserved on this device. They have not been assigned to this account.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    Button("Review older measurements") { showLegacyReview = true }.frame(minHeight: 44)
                }
                if sync.attentionCount > 0 {
                    NavigationLink("Review unsynced changes") { SavedChangesReviewView() }
                        .frame(minHeight: 44)
                }
            }
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, ExSpacing.page)
            .padding(.top, ExSpacing.small)
            .padding(.bottom, ExSpacing.major)
        }
        .exScrollEdges()
        .refreshable {
            await viewModel.load(today: sync.today)
            await workspace?.synchronize()
        } }
        .navigationDestination(for: BodySite.self) { site in
            MeasurementHistoryView(site: site, unit: lengthUnit, timeZone: timeZone, model: viewModel)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { logging = true } label: { Image(systemName: "plus") }
                    .frame(minWidth: 44, minHeight: 44).accessibilityLabel("Log measurements")
                    .accessibilityIdentifier("body.measurements.add")
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                TodayToast(message: toast.message, undo: toast.undo.map { entry in { undoDelete(entry) } },
                           undoIdentifier: "body.undoDelete")
                    .padding(.bottom, ExSpacing.small)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast.id) {
                        try? await Task.sleep(for: .seconds(UIAccessibility.isVoiceOverRunning ? 15 : 10))
                        withAnimation(.snappy) { if self.toast == toast { self.toast = nil } }
                    }
            }
        }
        .sheet(item: $weighIn) { request in
            if let workspace {
                switch request {
                case .new: WeighInSheet(workspace: workspace, unit: unit, timeZone: timeZone)
                case .edit(let entry):
                    WeighInSheet(workspace: workspace, unit: unit, timeZone: timeZone, editing: entry, onDeleted: deleted)
                }
            }
        }
        .sheet(isPresented: $logging) {
            MeasurementEntrySheet(latest: BodyMeasurements.latest(records.readings), unit: lengthUnit, today: sync.today) { count in
                show("\(count) \(count == 1 ? "measurement" : "measurements") saved")
                Task { await viewModel.load(today: sync.today) }
            }
        }
        .sheet(item: $goalEditor) { request in
            if let workspace {
                TargetsPlanEditor(workspace: workspace, unit: unit, timeZone: timeZone, request: request) { message, _ in show(message) }
            }
        }
        .sheet(isPresented: $showLegacyReview) { LegacyMeasurementReview() }
        .onChange(of: sync.changeToken) { _, _ in Task { await viewModel.load(today: sync.today) } }
        .task(id: "\(sync.today.rawValue)-\(sync.calendar.timeZoneIdentifier)") {
            await viewModel.load(today: sync.today)
        }
        .task(id: workspace?.identity) {
            if let workspace { await LegacyWeighIns.importIfNeeded(workspace, timeZone: timeZone) }
        }
    }

    private func measurementsCard(_ records: MeasurementRecords) -> some View {
        BodyMeasurementsCard(records: records, unit: lengthUnit, today: LocalDate(Date(), in: timeZone),
                             isLoading: viewModel.isLoading, error: viewModel.error) { logging = true }
    }

    private func show(_ message: String, undo: WeightEntry? = nil) {
        withAnimation(.snappy) { toast = BodyToast(message: message, undo: undo) }
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func editGoal(_ workspace: TrainingWorkspace, addsGoalWeight: Bool = false) {
        let today = LocalDate(Date(), in: timeZone)
        let kind: TargetsEditorRequest.Kind = workspace.nutrition.plan(on: today) == nil ? .setup : .edit
        goalEditor = .make(kind, store: workspace.nutrition, user: auth.currentUser, unit: unit, today: today)
        goalEditor?.addsGoalWeight = addsGoalWeight
    }

    private func deleted(_ entry: WeightEntry) {
        show("Weigh-in deleted", undo: entry)
    }

    private func delete(_ entry: WeightEntry) {
        guard let workspace else { return }
        do {
            try workspace.nutrition.deleteWeight(entry.id)
        } catch {
            actionError = BodyFormat.message(error)
            return
        }
        deleted(entry)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task {
            await LegacyWeighIns.forget(entry, accountID: workspace.accountID)
            await workspace.synchronize()
        }
    }

    /// Brings a deleted weigh-in back as a new one with the same reading and time.
    private func undoDelete(_ entry: WeightEntry) {
        guard let workspace else { return }
        do {
            try workspace.nutrition.logWeight(entry.weight, bodyFat: entry.bodyFat, at: entry.at, timeZone: timeZone)
            withAnimation(.snappy) { toast = nil }
            Task { await workspace.synchronize() }
        } catch { actionError = BodyFormat.message(error) }
    }
}

private struct LegacyMeasurementReview: View {
    @Query(sort: \Measurement.date, order: .reverse) private var records: [Measurement]
    @EnvironmentObject private var sync: SyncEngine
    @EnvironmentObject private var auth: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmedOwner = false
    @State private var selection: Set<PersistentIdentifier> = []
    @State private var reviewed: [PersistentIdentifier: LegacyMeasurementImport] = [:]
    @State private var proposedTimeZone: String?
    @State private var error: String?
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            ExList {
                Section {
                    Text("The older app did not record which account these measurements belong to. Review them only if this device's saved measurements are yours.")
                    Toggle("These saved measurements are mine", isOn: $confirmedOwner)
                    Text("Selected measurements will sync to \(auth.currentUser?.email ?? "your signed-in account").")
                        .font(.callout)
                    Text("The original time zone was not saved. Import dates are proposed using \(proposedTimeZone ?? sync.calendar.timeZoneIdentifier). Check each date before importing; changing your account time zone does not change a reviewed date.")
                        .font(.callout)
                }
                if confirmedOwner {
                    Section("Choose measurements to import") {
                        ForEach(records) { record in
                            if canImport(record), let item = reviewed[record.persistentModelID] {
                                Toggle(isOn: Binding(
                                    get: { selection.contains(record.persistentModelID) },
                                    set: { if $0 { selection.insert(record.persistentModelID) } else { selection.remove(record.persistentModelID) } }
                                )) { recordLabel(record) }
                                if selection.contains(record.persistentModelID) {
                                    CalendarDayPicker("Import date", selection: Binding(
                                        get: { reviewed[record.persistentModelID]?.day ?? item.day },
                                        set: { reviewed[record.persistentModelID]?.day = $0 }
                                    ), today: sync.today, timeZoneIdentifier: sync.calendar.timeZoneIdentifier)
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 4) {
                                    recordLabel(record)
                                    Text("Keep this record in the export for review.").font(.caption)
                                }
                            }
                        }
                    }
                    Section {
                        Button("Import \(selection.count) selected measurements") {
                            do {
                                let items = selection.compactMap { reviewed[$0] }
                                guard items.count == selection.count else { throw APIError.unknown }
                                try sync.importLegacyMeasurements(items)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }.disabled(selection.isEmpty).frame(minHeight: 44)
                        Button("Prepare an export of all older measurements") { prepareExport() }.frame(minHeight: 44)
                        if let exportURL { ShareLink("Share measurement export", item: exportURL).frame(minHeight: 44) }
                    }
                }
                if let error { Text(error).foregroundStyle(.exError) }
            }.navigationTitle("Older measurements")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .onAppear {
            guard proposedTimeZone == nil else { return }
            proposedTimeZone = sync.calendar.timeZoneIdentifier
            for record in records {
                if let day = sync.calendar.day(containing: record.date) {
                    reviewed[record.persistentModelID] = LegacyMeasurementImport(record, day: day)
                }
            }
        }
    }
    private func recordLabel(_ record: Measurement) -> some View {
        VStack(alignment: .leading) {
            Text("\(record.type.replacingOccurrences(of: "_", with: " ").capitalized): \(record.value, format: .number) \(record.unit)")
            Text("Original timestamp: \(record.date.ISO8601Format())").font(.caption)
        }
    }
    private func canImport(_ record: Measurement) -> Bool {
        let types = ["waist", "chest", "hips", "arms", "thighs", "neck", "calves", "body_fat"]
        let units = record.type == "body_fat" ? ["%"] : ["cm", "in"]
        return types.contains(record.type) && units.contains(record.unit.lowercased()) && record.value.isFinite && record.value > 0
    }
    private func prepareExport() {
        do {
            let rows: [[String: Any]] = records.map {
                ["type": $0.type, "value": $0.value, "unit": $0.unit, "date": $0.date.ISO8601Format()]
            }
            let data = try JSONSerialization.data(withJSONObject: ["version": 1, "account_unassigned": true, "measurements": rows], options: [.prettyPrinted, .sortedKeys])
            let url = FileManager.default.temporaryDirectory.appending(path: "exerly-older-measurements-\(UUID().uuidString).json")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            exportURL = url
        } catch { self.error = error.localizedDescription }
    }
}
