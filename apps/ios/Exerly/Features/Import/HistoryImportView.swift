import ExerlyCore
import SwiftUI
import UniformTypeIdentifiers

/// Profile → Import & export: bring history from MacroFactor, MacroFactor
/// Workouts, Hevy, Strong or an Exerly export, see and undo past imports,
/// and export everything. Reading, matching and saving are ExerlyCore's
/// (`HistoryImportReader`, `HistoryImporter`); these screens show them.
/// PARITY I02, I12, I13, I14.
struct ImportExportView: View {
    @ObservedObject var workspace: TrainingWorkspace
    let unit: MassUnit
    let timeZone: TimeZone
    var exportActions: AccountManagementActions?
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var records: [ImportRecord] = []
    @State private var undoing: ImportRecord?
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        ExScreen {
            ExCard(accent: true) {
                HStack(alignment: .center, spacing: ExSpacing.item) {
                    if !typeSize.isAccessibilitySize { ExerlyMarkTile(size: 48).accessibilityHidden(true) }
                    VStack(alignment: .leading, spacing: 2) {
                        ExEyebrow("Switching is free", color: .exPrimaryText)
                        Text("Bring your history").font(.exH2).foregroundStyle(Color.exTextPrimary)
                            .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                    }
                }
                Text("Your workouts, food log and weigh-ins come with you. You see what comes across before anything is saved, "
                     + "and any import can be undone.")
                    .font(.exBody).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            }
            ExCard {
                ExSectionHeading("Import from")
                VStack(spacing: 0) {
                    ForEach(Array(ImportSource.allCases.enumerated()), id: \.element) { index, source in
                        if index > 0 { TargetsDivider() }
                        NavigationLink {
                            HistoryImportFlow(workspace: workspace, source: source, unit: unit, timeZone: timeZone) { reload() }
                        } label: {
                            ImportRow(icon: ImportCopy.icon(source), title: source == .exerly ? "Restore an Exerly export" : source.name,
                                      detail: ImportCopy.summary(source))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("import.source.\(source.rawValue)")
                    }
                }
            }
            imports
            if let exportActions {
                ExCard {
                    ExSectionHeading("Export")
                    NavigationLink {
                        DataExportView(actions: exportActions)
                    } label: {
                        ImportRow(icon: "square.and.arrow.up.on.square", title: "Export everything",
                                  detail: "JSON, a CSV for each kind of data and a spreadsheet. Free, and works offline.")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("import.export")
                }
            }
        }
        .navigationTitle("Import & export").navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("import.hub")
        .task(id: workspace.identity) { reload() }
        .alert("Undo this import?", isPresented: Binding(get: { undoing != nil }, set: { if !$0 { undoing = nil } })) {
            Button("Cancel", role: .cancel) { undoing = nil }
            Button("Undo import", role: .destructive) { if let undoing { undo(undoing) } }
        } message: {
            Text("Everything it added is removed, and anything it changed is put back. Entries you edited since are kept.")
        }
    }

    @ViewBuilder
    private var imports: some View {
        ExCard {
            ExSectionHeading("Your imports")
            if let message {
                Label(message, systemImage: "checkmark.circle").font(.exCaption).foregroundStyle(Color.exSuccess)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("import.undoMessage")
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.exCaption).foregroundStyle(Color.exError)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("import.error")
            }
            if records.isEmpty {
                Text("Nothing imported yet. Each import is listed here, so you can undo it.")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("import.noRecords")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                        if index > 0 { TargetsDivider() }
                        recordRow(record, index: index)
                    }
                }
            }
        }
    }

    private func recordRow(_ record: ImportRecord, index: Int) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ExSpacing.small))
            : AnyLayout(HStackLayout(alignment: .center, spacing: ExSpacing.item))
        return layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.source.name).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                Text(ImportCopy.recordDetail(record)).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: ExSpacing.small) }
            if record.undoneAt != nil {
                Text("Undone").font(.exLabel).foregroundStyle(Color.exTextMuted)
            } else {
                Button("Undo") { undoing = record }
                    .font(.exLabel).foregroundStyle(Color.exPrimaryText).frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Undo the \(record.source.name) import")
                    .accessibilityIdentifier("import.record.\(index).undo")
            }
        }
        .padding(.vertical, ExSpacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("import.record.\(index)")
    }

    private func reload() {
        do {
            records = try workspace.importer.records()
        } catch {
            self.error = "Past imports couldn't be read. \(HistoryImporter.describe(error))"
        }
    }

    private func undo(_ record: ImportRecord) {
        undoing = nil
        error = nil
        do {
            let result = try workspace.importer.undo(record.id)
            let text = ImportCopy.undone(result)
            message = text
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            UIAccessibility.post(notification: .announcement, argument: text)
            Task { await workspace.synchronize() }
        } catch {
            self.error = "The import couldn't be undone. Nothing changed. \(HistoryImporter.describe(error))"
        }
        reload()
    }
}

/// A row that opens a screen: an icon, a title and a line of detail.
private struct ImportRow: View {
    let icon: String
    let title: String
    let detail: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .center, spacing: ExSpacing.item) {
            if !typeSize.isAccessibilitySize {
                Image(systemName: icon).font(.system(size: 16, weight: .medium)).foregroundStyle(Color.exPrimaryText)
                    .frame(width: 36, height: 36).background(Color.exPrimary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.exTextMuted).accessibilityHidden(true)
        }
        .padding(.vertical, ExSpacing.small)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The words for each source.
enum ImportCopy {
    static func icon(_ source: ImportSource) -> String {
        switch source {
        case .macroFactor: "fork.knife"
        case .macroFactorWorkouts: "figure.strengthtraining.traditional"
        case .hevy: "dumbbell"
        case .strong: "dumbbell.fill"
        case .exerly: "arrow.uturn.backward.circle"
        }
    }

    static func summary(_ source: ImportSource) -> String {
        switch source {
        case .macroFactor: "Food log, weigh-ins, targets, foods and workouts"
        case .macroFactorWorkouts: "Your workout log, with myo-reps and RIR"
        case .hevy: "Workouts, sets, supersets and notes"
        case .strong: "Workouts, sets and notes"
        case .exerly: "Everything from another account or phone"
        }
    }

    /// How to get the file out of the app, in three steps.
    static func steps(_ source: ImportSource) -> [(String, String)] {
        switch source {
        case .macroFactor:
            [("Open Data Export", "In MacroFactor, tap More, then Data Export under Data Management."),
             ("Choose Granular Export", "Select every kind of data. Quick Export works too, with each day's totals instead of each food."),
             ("Save the spreadsheet", "Save it to Files or iCloud Drive, then choose it here. You can choose several files at once.")]
        case .macroFactorWorkouts:
            [("Open Data Export", "In MacroFactor Workouts or MacroFactor, tap More, then Data Export."),
             ("Export the workout log", "Choose Granular Export, then Workout Log, and pick All time."),
             ("Save the file", "Save it to Files, then choose it here, or share it to Exerly.")]
        case .hevy:
            [("Open Settings", "In Hevy, open your Profile, then Settings."),
             ("Export workouts", "Tap Export & Import Data, then Export Workouts."),
             ("Save workout_data.csv", "Save it to Files, then choose it here, or share it straight to Exerly.")]
        case .strong:
            [("Open Settings", "In Strong, open Settings from your Profile."),
             ("Export your data", "Tap Export Strong Data. Newer versions call it Export Workouts."),
             ("Save the CSV", "Save it to Files, then choose it here, or share it straight to Exerly.")]
        case .exerly:
            [("Export from Exerly", "On the phone or account with your data, open Profile, then Import & export, then Export everything."),
             ("Unzip it", "Open the zip in Files. Inside is exerly-export with its date, ending in .json."),
             ("Choose the .json file", "Choose it here. Anything this account already has is kept as it is.")]
        }
    }

    static func recordDetail(_ record: ImportRecord) -> String {
        let when = record.importedAt.formatted(date: .abbreviated, time: .shortened)
        let added = record.lines.filter { $0.new > 0 && $0.key != "sets" && $0.key != "exercises" }
            .prefix(3).map { "\($0.new.formatted()) \($0.title.lowercased())" }.joined(separator: ", ")
        return [when, added.isEmpty ? nil : added, record.undoneAt.map { "undone \($0.formatted(date: .abbreviated, time: .omitted))" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    static func undone(_ result: HistoryImporter.UndoResult) -> String {
        let removed = "Import undone: \(result.undone.formatted()) \(result.undone == 1 ? "item" : "items") removed or put back."
        guard result.kept > 0 else { return removed }
        return removed + " \(result.kept.formatted()) you changed since \(result.kept == 1 ? "was" : "were") kept."
    }
}

/// Setup's "Bring your history": remembered for the account until its tabs
/// open, which then show Import & export.
enum BringHistory {
    private static func key(_ accountID: String) -> String { "exerly.bringHistory.\(accountID)" }

    static func isOn(accountID: String) -> Bool { UserDefaults.standard.bool(forKey: key(accountID)) }

    static func remember(accountID: String, _ on: Bool) { UserDefaults.standard.set(on, forKey: key(accountID)) }

    /// Whether it was asked for, forgetting it so it opens once.
    static func take(accountID: String) -> Bool {
        defer { UserDefaults.standard.removeObject(forKey: key(accountID)) }
        return isOn(accountID: accountID)
    }
}
