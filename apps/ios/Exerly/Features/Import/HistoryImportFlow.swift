import ExerlyCore
import SwiftUI
import UniformTypeIdentifiers

/// One import: how to export from the other app, choosing the file, the
/// preview with exercise matching, units and what won't come across, then
/// the saved import and its Undo.
struct HistoryImportFlow: View {
    @ObservedObject var workspace: TrainingWorkspace
    let source: ImportSource
    let unit: MassUnit
    let timeZone: TimeZone
    /// A file shared to Exerly, read as soon as the screen opens.
    var shared: [ImportFile]?
    var changed: () -> Void
    @EnvironmentObject private var sync: SyncEngine
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var stepSize = 28.0
    @State private var phase: Phase = .start
    @State private var files: [ImportFile] = []
    @State private var mapping: [String: ExerciseID] = [:]
    @State private var leftOut: Set<String> = []
    @State private var weightUnit: MassUnit?
    @State private var choosing = false
    @State private var remapping: ExerciseMatch?
    @State private var showAllExercises = false
    @State private var confirmUndo = false

    struct ImportFile: Sendable {
        var name: String
        var data: Data
    }

    enum Phase {
        case start
        case reading
        case unreadable(String)
        case preview(HistoryImportPlan)
        case importing(HistoryImportPlan)
        case failed(String, HistoryImportPlan)
        case done(ImportRecord)
        case undone(HistoryImporter.UndoResult)
    }

    init(workspace: TrainingWorkspace, source: ImportSource, unit: MassUnit, timeZone: TimeZone, shared: [ImportFile]? = nil,
         changed: @escaping () -> Void = {}) {
        self.workspace = workspace
        self.source = source
        self.unit = unit
        self.timeZone = timeZone
        self.shared = shared
        self.changed = changed
    }

    private static let types: [UTType] = [UTType("org.openxmlformats.spreadsheetml.sheet"), .commaSeparatedText,
                                          .tabSeparatedText, .spreadsheet, .json, .plainText].compactMap { $0 }

    private var busy: Bool {
        switch phase {
        case .reading, .importing: true
        default: false
        }
    }

    /// The app the file turned out to be from, once read.
    private var shownSource: ImportSource {
        switch phase {
        case .preview(let plan), .importing(let plan), .failed(_, let plan): plan.source
        case .done(let record): record.source
        default: source
        }
    }

    var body: some View {
        ExScreen {
            switch phase {
            case .start: start
            case .reading: reading
            case .unreadable(let message):
                problem(message, identifier: "import.unreadable")
                start
            case .preview(let plan): preview(plan)
            case .importing(let plan): importing(plan)
            case .failed(let message, let plan):
                problem("Nothing was saved. \(message)", identifier: "import.failed")
                preview(plan)
            case .done(let record): done(record)
            case .undone(let result): undone(result)
            }
        }
        .accessibilityIdentifier("import.screen")
        .navigationTitle(shownSource == .exerly ? "Restore an export" : "Import from \(shownSource.name)")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(busy)
        .fileImporter(isPresented: $choosing, allowedContentTypes: Self.types, allowsMultipleSelection: source == .macroFactor) { result in
            switch result {
            case .success(let urls): if !urls.isEmpty { load(urls) }
            case .failure(let error): withAnimation(.snappy) { phase = .unreadable(error.localizedDescription) }
            }
        }
        .sheet(item: $remapping) { match in
            ImportExerciseChooser(library: workspace.store.library, match: match) { choice in
                remapping = nil
                switch choice {
                case .exercise(let id):
                    mapping[match.name] = id
                    leftOut.remove(match.name)
                case .leaveOut:
                    leftOut.insert(match.name)
                    mapping[match.name] = nil
                case .automatic:
                    leftOut.remove(match.name)
                    mapping[match.name] = nil
                }
                read()
            }
        }
        .alert("Undo this import?", isPresented: $confirmUndo) {
            Button("Cancel", role: .cancel) {}
            Button("Undo import", role: .destructive) { if case .done(let record) = phase { undo(record) } }
        } message: {
            Text("Everything it added is removed, and anything it changed is put back. Entries you edited since are kept.")
        }
        .task {
            if let shared, files.isEmpty {
                files = shared
                read()
            }
        }
    }

    // MARK: Start

    @ViewBuilder
    private var start: some View {
        ExCard(accent: true) {
            if !typeSize.isAccessibilitySize {
                Image(systemName: ImportCopy.icon(source)).font(.system(size: 26, weight: .medium)).foregroundStyle(Color.exPrimaryText)
                    .frame(width: 56, height: 56).background(Color.exPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityHidden(true)
            }
            Text(source == .exerly ? "Restore everything from an export" : "Bring your \(source.name) history").font(.exH2)
                .foregroundStyle(Color.exTextPrimary).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            if typeSize.isAccessibilitySize { chooseButtons }
            Text("The file is read on this iPhone. You'll see what comes across, and what doesn't, before anything is saved.")
                .font(typeSize.isAccessibilitySize ? .exCaption : .exBody).foregroundStyle(Color.exTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !typeSize.isAccessibilitySize { chooseButtons }
        }
        ExCard {
            ExEyebrow(source == .exerly ? "Get the file" : "Export from \(source.name)")
            ForEach(Array(ImportCopy.steps(source).enumerated()), id: \.offset) { index, step in
                stepRow(index + 1, step.0, step.1)
            }
        }
    }

    @ViewBuilder
    private var chooseButtons: some View {
        Button { choosing = true } label: {
            Label(source == .macroFactor ? "Choose export files" : "Choose export file", systemImage: "doc.badge.plus")
        }
        .buttonStyle(ExActionStyle()).accessibilityIdentifier("import.choose")
        #if DEBUG
        if let file = Self.testFile {
            Button("Use the test file") {
                files = [file]
                read()
            }
            .buttonStyle(ExActionStyle(secondary: true)).accessibilityIdentifier("import.testFile")
        }
        #endif
    }

    #if DEBUG
    /// A synthetic export UI tests hand over, since the system file picker
    /// runs outside the app.
    static var testFile: ImportFile? {
        let environment = ProcessInfo.processInfo.environment
        guard let data = (environment["EXERLY_IMPORT_FILE"] ?? environment["EXERLY_MF_IMPORT_FILE"]).flatMap({ Data(base64Encoded: $0) })
        else { return nil }
        return ImportFile(name: environment["EXERLY_IMPORT_FILE_NAME"] ?? "Test export.xlsx", data: data)
    }
    #endif

    private func stepRow(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ExSpacing.item) {
            Text("\(number)").font(.system(.subheadline, design: .rounded, weight: .bold)).foregroundStyle(Color.exPrimaryText)
                .frame(width: stepSize, height: stepSize).background(Color.exPrimary.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                Text(detail).font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number), \(title). \(detail)")
    }

    // MARK: Reading

    private var reading: some View {
        ExCard {
            HStack(spacing: ExSpacing.item) {
                ProgressView().tint(Color.exPrimaryText)
                Text("Reading your export…").font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
            }
            .frame(minHeight: 44)
            Text("Large exports take a few seconds. Nothing is saved yet.").font(.exCaption).foregroundStyle(Color.exTextSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("import.reading")
    }

    private func problem(_ message: String, identifier: String) -> some View {
        Label {
            Text(message).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(.exCaption).foregroundStyle(Color.exError)
        .padding(ExSpacing.item)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.exError.opacity(0.08), in: RoundedRectangle(cornerRadius: ExRadius.control))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func load(_ urls: [URL]) {
        do {
            files = try urls.map { url in
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                return ImportFile(name: url.lastPathComponent, data: try Data(contentsOf: url))
            }
            mapping = [:]
            leftOut = []
            weightUnit = nil
            read()
        } catch {
            withAnimation(.snappy) { phase = .unreadable("The file couldn't be opened. \(error.localizedDescription)") }
        }
    }

    /// Reads the files away from the main thread with the current choices,
    /// then checks them against what this account already has.
    private func read() {
        guard !files.isEmpty else { return }
        withAnimation(.snappy) { phase = .reading }
        let options = HistoryImportReader.Options(timeZone: timeZone, unit: weightUnit ?? unit, mapping: mapping, leftOut: leftOut)
        let library = workspace.store.library, files = files, source = source
        Task {
            let parsed = await Task.detached(priority: .userInitiated) {
                Result { try HistoryImportReader.read(files.map { ($0.name, $0.data) }, options: options, library: library) }
            }.value
            let hosts: [DocumentHost] = [workspace.store, workspace.programs, workspace.nutrition, workspace.gyms, workspace.agent]
            let result = parsed.flatMap { parsed in
                Result { try HistoryImportReader.plan(parsed, files: files.map(\.name), options: options, hosts: hosts) }
            }
            withAnimation(.snappy) {
                switch result {
                case .success(let plan): phase = .preview(plan)
                case .failure(let error): phase = .unreadable(Self.message(error, source: source))
                }
            }
        }
    }

    static func message(_ error: Error, source: ImportSource) -> String {
        let app = source == .exerly ? "Exerly" : source.name
        switch error {
        case HistoryImportReader.ReadError.unrecognized(let name):
            return "\(name) isn't an export Exerly knows. Choose the file \(app) exported, without editing it."
        case HistoryImportReader.ReadError.mixed(let sources):
            return "These files come from \(sources.map(\.name).joined(separator: " and ")). Import one app's files at a time."
        case Spreadsheet.ReadError.unreadable: return "This file isn't a spreadsheet or a CSV. Choose the file \(app) exported."
        case Spreadsheet.ReadError.damaged(let detail): return "This spreadsheet can't be read (\(detail)). Export it again."
        case Spreadsheet.ReadError.tooLarge: return "This spreadsheet is too large to import."
        case WorkoutImport.ImportError.unrecognized: return "This CSV isn't a Hevy or Strong export: its columns aren't theirs."
        case let error as DocumentError: return error.message
        default: return "The file couldn't be read. \(error.localizedDescription)"
        }
    }

    // MARK: Preview

    @ViewBuilder
    private func preview(_ plan: HistoryImportPlan) -> some View {
        ExCard(accent: true) {
            ExEyebrow(plan.isEmpty ? "Nothing new" : "Ready to import · \(plan.source.name)", color: .exPrimaryText)
            Text(range(plan.dateRange) ?? "No dated history").font(.exH2).foregroundStyle(Color.exTextPrimary)
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            Text(previewDetail(plan)).font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            lines(plan.lines, showExisting: true)
            if !plan.isEmpty {
                Button { commit(plan) } label: {
                    Label("Import \(Self.amount(plan))", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(ExActionStyle()).accessibilityIdentifier("import.import")
            }
            Button(plan.isEmpty ? "Choose another file" : "Choose a different file") { choosing = true }
                .buttonStyle(ExActionStyle(secondary: true)).accessibilityIdentifier("import.chooseAgain")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("import.preview")
        if !plan.exercises.isEmpty { exercises(plan) }
        unitsCard(plan)
        losses(plan)
        if plan.skippedCount > 0 {
            ExCard {
                ExSectionHeading("Rows left out", detail: plan.skippedCount.formatted())
                ForEach(Array(plan.skipped.prefix(5).enumerated()), id: \.offset) { _, text in bullet(text, icon: "minus") }
                if plan.skippedCount > 5 {
                    Text("and \((plan.skippedCount - 5).formatted()) more").font(.exSmall).foregroundStyle(Color.exTextMuted)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("import.skipped")
        }
    }

    /// "2 workouts" when that's all a plan adds, otherwise "120 items".
    static func amount(_ plan: HistoryImportPlan) -> String { amount(plan.lines, total: plan.additions) }

    static func amount(_ lines: [ImportLine], total: Int) -> String {
        let adding = lines.filter { !ImportLine.breakdowns.contains($0.key) && $0.new > 0 }
        if adding.count == 1, ["workouts", "workout_session"].contains(adding[0].key) {
            return "\(adding[0].new.formatted()) \(adding[0].new == 1 ? "workout" : "workouts")"
        }
        return "\(total.formatted()) \(total == 1 ? "item" : "items")"
    }

    private func previewDetail(_ plan: HistoryImportPlan) -> String {
        let from = plan.files.count == 1 ? plan.files[0] : "\(plan.files.count) files"
        if plan.lines.allSatisfy({ $0.new == 0 && $0.existing == 0 }) { return "Exerly found nothing it can import in \(from)." }
        if plan.isEmpty { return "Everything in \(from) is already in Exerly. Importing it again changes nothing." }
        return "From \(from). Nothing is saved until you import, and you can undo it afterwards."
    }

    @ViewBuilder
    private func lines(_ lines: [ImportLine], showExisting: Bool) -> some View {
        let shown = lines.filter { $0.new > 0 || (showExisting && $0.existing > 0) }
        if !shown.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, line in
                    if index > 0 { TargetsDivider() }
                    lineRow(line, showExisting: showExisting)
                }
            }
        }
    }

    private func lineRow(_ line: ImportLine, showExisting: Bool) -> some View {
        let detail = showExisting && line.existing > 0 ? "\(line.existing.formatted()) already in Exerly" : ""
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: ExSpacing.small))
        return layout {
            VStack(alignment: .leading, spacing: 1) {
                Text(line.title).font(.exBody).foregroundStyle(Color.exTextSecondary)
                if !detail.isEmpty { Text(detail).font(.exSmall).foregroundStyle(Color.exTextMuted) }
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: ExSpacing.small) }
            Text(line.new.formatted()).font(.exStatSmall).monospacedDigit()
                .foregroundStyle(line.new > 0 ? Color.exTextPrimary : Color.exTextMuted)
        }
        .padding(.vertical, ExSpacing.small).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.title)
        .accessibilityValue([line.new.formatted() + " to add", detail.isEmpty ? nil : detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("import.count.\(line.key)")
    }

    private func exercises(_ plan: HistoryImportPlan) -> some View {
        let ordered = plan.exercisesInOrder
        let unmatched = ordered.filter { $0.how == .unmatched }.count
        let shown = showAllExercises ? ordered : Array(ordered.prefix(6))
        return ExCard {
            ExSectionHeading("Exercises", detail: unmatched > 0 ? "\(unmatched) to match" : "All matched")
            Text(unmatched > 0 ? "Choose an Exerly exercise for each one without a match, or leave its sets out. Tap any to change it."
                 : "Each name in the file and the Exerly exercise its sets go to. Tap one to change it.")
                .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, match in
                    if index > 0 { TargetsDivider() }
                    Button { remapping = match } label: { exerciseRow(match) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("import.exercise.\(index)")
                }
            }
            if ordered.count > 6 {
                Button(showAllExercises ? "Show fewer" : "Show all \(ordered.count) exercises") {
                    withAnimation(.snappy) { showAllExercises.toggle() }
                }
                .font(.exLabel).foregroundStyle(Color.exPrimaryText).frame(minHeight: 44)
                .accessibilityIdentifier("import.exercisesAll")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("import.exercises")
    }

    private func exerciseRow(_ match: ExerciseMatch) -> some View {
        let target: String
        let color: Color
        switch match.how {
        case .automatic, .chosen:
            target = match.exerciseID.flatMap { workspace.store.library.exercise($0)?.name } ?? match.exerciseID?.rawValue ?? ""
            color = .exTextPrimary
        case .leftOut:
            target = "Left out"
            color = .exTextMuted
        case .unmatched:
            target = "No match. Choose one"
            color = .exWarning
        }
        let sets = "\(match.sets.formatted()) \(match.sets == 1 ? "set" : "sets")"
        return HStack(alignment: .center, spacing: ExSpacing.item) {
            VStack(alignment: .leading, spacing: 2) {
                Text(match.name).font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: ExSpacing.tight) {
                    if match.how == .unmatched {
                        Image(systemName: "exclamationmark.circle").font(.caption).foregroundStyle(color).accessibilityHidden(true)
                    }
                    Text(target).font(.exBodyMedium).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: ExSpacing.small)
            Text(sets).font(.exCaption).monospacedDigit().foregroundStyle(Color.exTextMuted)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.exTextMuted).accessibilityHidden(true)
        }
        .padding(.vertical, ExSpacing.small)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(match.name)
        .accessibilityValue("\(match.how == .chosen ? "You chose " : "")\(target), \(sets)")
        .accessibilityHint("Choose the Exerly exercise for these sets")
    }

    private func unitsCard(_ plan: HistoryImportPlan) -> some View {
        ExCard {
            ExSectionHeading("Units and times")
            ForEach(plan.units, id: \.self) { bullet($0, icon: "ruler") }
            if let assumed = plan.assumedWeightUnit {
                VStack(alignment: .leading, spacing: ExSpacing.small) {
                    Text("\(plan.source.name) doesn't say which unit its weights are in. Which did you use?")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                    ExSegmentedControl(values: [MassUnit.kilograms, .pounds], selection: Binding(get: { assumed }, set: { chosen in
                        guard chosen != assumed else { return }
                        weightUnit = chosen
                        read()
                    })) { $0 == .kilograms ? "Kilograms" : "Pounds" }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Weights in this file")
                    .accessibilityIdentifier("import.weightUnit")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("import.units")
    }

    private func losses(_ plan: HistoryImportPlan) -> some View {
        ExCard {
            ExSectionHeading("What won't come across")
            if plan.lost.isEmpty {
                bullet("Nothing. Every row in the file has a place in Exerly.", icon: "checkmark")
            } else {
                ForEach(plan.lost, id: \.self) { bullet($0, icon: "minus.circle") }
            }
            if !plan.approximated.isEmpty {
                Text("Comes across differently").font(.exBodyMedium).foregroundStyle(Color.exTextPrimary).padding(.top, ExSpacing.tight)
                    .accessibilityAddTraits(.isHeader)
                ForEach(plan.approximated, id: \.self) { bullet($0, icon: "arrow.triangle.swap") }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("import.losses")
    }

    private func bullet(_ text: String, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ExSpacing.small) {
            Image(systemName: icon).font(.caption.weight(.semibold)).foregroundStyle(Color.exTextMuted).frame(width: 16).accessibilityHidden(true)
            Text(text).font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func range(_ range: ClosedRange<LocalDate>?) -> String? {
        guard let range else { return nil }
        let today = LocalDate(Date(), in: timeZone)
        let last = TargetsFormat.shortDate(range.upperBound, today: today)
        guard range.lowerBound != range.upperBound else { return last }
        let first = TargetsFormat.shortDate(range.lowerBound, today: range.lowerBound.year == range.upperBound.year ? range.upperBound : today)
        return "\(first) – \(last)"
    }

    // MARK: Import

    /// Saves the plan as one unit, checked again against the stores in case a
    /// sync changed them since the preview.
    private func commit(_ plan: HistoryImportPlan) {
        withAnimation(.snappy) { phase = .importing(plan) }
        Task {
            // Let the progress show before the save holds the main thread.
            try? await Task.sleep(for: .milliseconds(80))
            do {
                let record = try workspace.importer.commit(plan)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation(.snappy) { phase = .done(record) }
                UIAccessibility.post(notification: .announcement, argument: "Import finished")
                changed()
                await workspace.synchronize()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                withAnimation(.snappy) { phase = .failed(HistoryImporter.describe(error), plan) }
            }
        }
    }

    private func importing(_ plan: HistoryImportPlan) -> some View {
        ExCard {
            ExEyebrow("Importing", color: .exPrimaryText)
            HStack(spacing: ExSpacing.item) {
                ProgressView().tint(Color.exPrimaryText)
                Text("Saving \(Self.amount(plan))…").font(.exH3)
                    .foregroundStyle(Color.exTextPrimary).fixedSize(horizontal: false, vertical: true)
            }
            Text("All of it is saved, or none of it.").font(.exCaption).foregroundStyle(Color.exTextSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("import.importing")
    }

    // MARK: Done

    private func done(_ record: ImportRecord) -> some View {
        ExCard(accent: true) {
            if !typeSize.isAccessibilitySize {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 30, weight: .medium)).foregroundStyle(Color.exSuccess)
                    .accessibilityHidden(true)
            }
            Text("Your history is in Exerly").font(.exH2).foregroundStyle(Color.exTextPrimary)
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            Text(doneDetail(record)).font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            lines(record.lines, showExisting: false)
            if record.changes.contains(where: { ["food_entry", "weight_entry"].contains($0.kind) }) {
                NavigationLink { ProgressView_(initialDate: sync.today) } label: {
                    Label("See your trend", systemImage: "chart.line.uptrend.xyaxis")
                }
                .buttonStyle(ExActionStyle()).accessibilityIdentifier("import.seeTrend")
            } else {
                NavigationLink { WorkoutHistoryView(store: workspace.store, unit: unit) } label: {
                    Label("See your workouts", systemImage: "dumbbell")
                }
                .buttonStyle(ExActionStyle()).accessibilityIdentifier("import.seeWorkouts")
            }
            Button { confirmUndo = true } label: { Label("Undo import", systemImage: "arrow.uturn.backward") }
                .buttonStyle(ExActionStyle(secondary: true)).accessibilityIdentifier("import.undo")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("import.done")
    }

    private func doneDetail(_ record: ImportRecord) -> String {
        let range = range(record.dateRange).map { " from \($0)" } ?? ""
        let total = record.lines.filter { !ImportLine.breakdowns.contains($0.key) }.reduce(0) { $0 + $1.new }
        return "\(Self.amount(record.lines, total: total))\(range) \(total == 1 ? "is" : "are") saved and syncing. "
            + "Undo removes exactly these, now or later from Profile → Import & export."
    }

    private func undo(_ record: ImportRecord) {
        do {
            let result = try workspace.importer.undo(record.id)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.snappy) { phase = .undone(result) }
            UIAccessibility.post(notification: .announcement, argument: "Import undone. " + ImportCopy.undone(result))
            changed()
            Task { await workspace.synchronize() }
        } catch {
            withAnimation(.snappy) {
                phase = .unreadable("The import couldn't be undone. Nothing changed. \(HistoryImporter.describe(error))")
            }
        }
    }

    private func undone(_ result: HistoryImporter.UndoResult) -> some View {
        ExCard(accent: true) {
            if !typeSize.isAccessibilitySize {
                Image(systemName: "arrow.uturn.backward.circle.fill").font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.exPrimaryText).accessibilityHidden(true)
            }
            Text("Import undone").font(.exH2).foregroundStyle(Color.exTextPrimary).accessibilityAddTraits(.isHeader)
            Text(ImportCopy.undone(result)).font(.exBody).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("import.undoneDetail")
            Button("Review the file again") { read() }
                .buttonStyle(ExActionStyle(secondary: true)).accessibilityIdentifier("import.again")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("import.undone")
    }
}

// MARK: - Exercise chooser

/// Picks the Exerly exercise for a name in an imported file.
struct ImportExerciseChooser: View {
    enum Choice { case exercise(ExerciseID), leaveOut, automatic }

    let library: ExerlyCore.ExerciseLibrary
    let match: ExerciseMatch
    let choose: (Choice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query: String

    init(library: ExerlyCore.ExerciseLibrary, match: ExerciseMatch, choose: @escaping (Choice) -> Void) {
        self.library = library
        self.match = match
        self.choose = choose
        // Start from the name without the equipment in brackets: "Landmine Twist".
        _query = State(initialValue: match.name.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression))
    }

    /// Exercises sharing any word of four letters or more with the search,
    /// for a name the library has no exact match for.
    private var closeMatches: [ExerlyCore.Exercise] {
        var seen = Set<ExerciseID>()
        return query.split(separator: " ").map(String.init).filter { $0.count >= 4 }
            .flatMap { library.search($0) }
            .filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        NavigationStack {
            ExList {
                Section {
                    VStack(alignment: .leading, spacing: ExSpacing.small) {
                        ExEyebrow("In the file", color: .exPrimaryText)
                        Text(match.name).font(.exH2).fixedSize(horizontal: false, vertical: true)
                        Text("\(match.sets.formatted()) \(match.sets == 1 ? "set goes" : "sets go") to the exercise you choose.")
                            .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    }.padding(.vertical, ExSpacing.small)
                }.listRowBackground(Color.clear)
                Section {
                    Button(role: .destructive) { choose(.leaveOut) } label: { Label("Leave these sets out", systemImage: "minus.circle") }
                        .frame(minHeight: 44).accessibilityIdentifier("import.chooser.leaveOut")
                    if match.how == .chosen || match.how == .leftOut {
                        Button { choose(.automatic) } label: { Label("Match by name again", systemImage: "arrow.counterclockwise") }
                            .frame(minHeight: 44).accessibilityIdentifier("import.chooser.automatic")
                    }
                }
                let exact = library.search(query)
                let results = exact.isEmpty ? closeMatches : exact
                Section(query.isEmpty ? "All exercises" : exact.isEmpty && !results.isEmpty ? "Close matches" : "Matches") {
                    if results.isEmpty { ContentUnavailableView.search(text: query) }
                    ForEach(results) { exercise in
                        Button { choose(.exercise(exercise.id)) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(exercise.name).font(.body.weight(.medium)).foregroundStyle(Color.exTextPrimary)
                                    Text(exercise.equipment.map { TrainingFormat.words($0.rawValue) }.joined(separator: ", "))
                                        .font(.caption).foregroundStyle(Color.exTextSecondary)
                                }
                                Spacer()
                                if exercise.id == match.exerciseID {
                                    Image(systemName: "checkmark").foregroundStyle(Color.exPrimaryText).accessibilityHidden(true)
                                }
                            }
                            .frame(minHeight: 44)
                        }
                        .accessibilityLabel(exercise.name)
                        .accessibilityAddTraits(exercise.id == match.exerciseID ? .isSelected : [])
                        .accessibilityIdentifier("import.chooser.\(exercise.id.rawValue)")
                    }
                }
            }
            .exListStyle()
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search exercises")
            .navigationTitle("Match exercise").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("import.chooser.cancel")
                }
            }
        }
    }
}
