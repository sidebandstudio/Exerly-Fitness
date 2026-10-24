import ExerlyCore
import SwiftUI

/// Every site in one sheet, prefilled with its latest value. Only fields
/// changed from what they showed are saved, all together, as new readings.
struct MeasurementEntrySheet: View {
    let unit: LengthUnit
    let onSaved: (Int) -> Void
    private let prefilled: [BodySite: Double]
    @State private var text: [BodySite: String]
    @State private var date: CalendarDay
    @State private var error: String?
    @EnvironmentObject private var sync: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    init(latest: [BodySite: BodyMeasurementReading], unit: LengthUnit, today: CalendarDay, onSaved: @escaping (Int) -> Void) {
        self.unit = unit
        self.onSaved = onSaved
        let shown = Dictionary(uniqueKeysWithValues: BodySite.entry.compactMap { site in
            latest[site].map { (site, BodyMeasurements.display($0.value, site: site, unit: unit)) }
        })
        prefilled = shown
        _text = State(initialValue: shown.mapValues(Self.text))
        _date = State(initialValue: today)
    }

    static func text(_ value: Double) -> String { value.formatted(.number.grouping(.never).precision(.fractionLength(1))) }

    private var changes: [BodySite: Double] {
        BodyMeasurements.changes(entered: text.compactMapValues { TrainingInput.number($0) }, prefilled: prefilled, unit: unit)
    }

    private var problems: [String] {
        BodySite.entry.compactMap { site in changes[site].flatMap { BodyMeasurements.problem($0, site: site, unit: unit) } }
    }

    private var unitName: String { unit == .inches ? "inches" : "centimetres" }

    var body: some View {
        let changes = changes
        NavigationStack {
            ExScreen {
                ExCard(accent: true) {
                    BodyDateRow {
                        CalendarDayPicker("Date", selection: $date, today: sync.today, timeZoneIdentifier: sync.calendar.timeZoneIdentifier)
                            .font(.exLabel).foregroundStyle(Color.exTextSecondary).tint(Color.exPrimaryText)
                    }
                    Text(prefilled.isEmpty ? "In \(unitName). Fill in only what you measured."
                         : "In \(unitName), starting from your latest. Only what you change is saved.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                }
                group("Torso", .torso)
                group("Arms", .arms)
                group("Legs", .legs)
                ExCard {
                    ExEyebrow("Body fat, visual estimate")
                    field(.bodyFat, changed: changes[.bodyFat] != nil)
                    Text("Your best guess from the mirror or photos. A smart scale's reading belongs with its weigh-in.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle").font(.exCaption).foregroundStyle(Color.exWarning)
                }
                if let error { Text(error).font(.exCaption).foregroundStyle(Color.exError).accessibilityIdentifier("measurementEntry.error") }
            }
            .scrollDismissesKeyboard(.interactively)
            // Torso, arms and legs row by row, each left beside its right, then body fat.
            .exFieldOrder(([BodySite.Group.torso, .arms, .legs].flatMap { group in BodySite.entry.filter { $0.group == group } } + [.bodyFat])
                .map { "measurementEntry.\($0.rawValue)" })
            .exFooter {
                Button(action: save) {
                    Text(changes.isEmpty ? "Nothing changed yet" : "Save \(changes.count) \(changes.count == 1 ? "measurement" : "measurements")")
                }
                .buttonStyle(ExActionStyle()).disabled(changes.isEmpty || !problems.isEmpty)
                .accessibilityIdentifier("measurementEntry.save")
                .padding(.horizontal, ExSpacing.page).padding(.vertical, ExSpacing.small)
                .background(Color.exBackground)
            }
            .navigationTitle("Log measurements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("measurementEntry.cancel")
                }
            }
        }
        .interactiveDismissDisabled(!changes.isEmpty)
    }

    /// A group's sites two to a row, so each left limb sits beside its right.
    /// Not lazy: a lazy grid rebuilds a field scrolled for the keypad and drops its focus.
    private func group(_ title: String, _ group: BodySite.Group) -> some View {
        let changes = changes
        let sites = BodySite.entry.filter { $0.group == group }
        return ExCard {
            ExEyebrow(title)
            if typeSize.isAccessibilitySize {
                VStack(spacing: ExSpacing.small) {
                    ForEach(sites) { site in field(site, changed: changes[site] != nil) }
                }
            } else {
                Grid(horizontalSpacing: ExSpacing.small, verticalSpacing: ExSpacing.small) {
                    ForEach(Array(stride(from: 0, to: sites.count, by: 2)), id: \.self) { index in
                        GridRow {
                            field(sites[index], changed: changes[sites[index]] != nil)
                            if index + 1 < sites.count { field(sites[index + 1], changed: changes[sites[index + 1]] != nil) }
                        }
                    }
                }
            }
        }
    }

    private func field(_ site: BodySite, changed: Bool) -> some View {
        let symbol = MeasurementFormat.symbol(site, unit)
        return VStack(alignment: .leading, spacing: 2) {
            Text(site == .bodyFat ? "Estimate" : site.name).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1).minimumScaleFactor(0.85)
            HStack(alignment: .center, spacing: 4) {
                ExNumericTextField(title: "\(site.name) (\(symbol))", text: Binding(get: { text[site] ?? "" }, set: { text[site] = $0 }),
                                   placeholder: "–", identifier: "measurementEntry.\(site.rawValue)")
                Text(symbol).font(.exLabel).foregroundStyle(Color.exTextMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ExSpacing.item).padding(.vertical, ExSpacing.small)
        .background(Color.exSurface2, in: RoundedRectangle(cornerRadius: ExRadius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ExRadius.control, style: .continuous)
                .strokeBorder(changed ? Color.exAccent.opacity(0.85) : .clear, lineWidth: 1.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(changed ? "Changed" : "")
    }

    private func save() {
        let changes = changes
        guard !changes.isEmpty, problems.isEmpty else { return }
        let requests = BodySite.entry.compactMap { site in
            changes[site].map {
                BodyMeasurementRequest(type: site.rawValue, value: ($0 * 10_000).rounded() / 10_000, unit: site.isLength ? "cm" : "%",
                                       entry_date: date.rawValue)
            }
        }
        do {
            try sync.saveMeasurements(requests)
        } catch {
            self.error = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onSaved(requests.count)
        dismiss()
    }
}

/// One saved measurement: its value and day, or deleting it.
struct MeasurementEditSheet: View {
    let record: BodyMeasurementDTO
    let site: BodySite
    let unit: LengthUnit
    let onDeleted: (String) -> Void
    let onSaved: () -> Void
    @State private var text: String
    @State private var date: CalendarDay
    @State private var error: String?
    @EnvironmentObject private var sync: SyncEngine
    @Environment(\.dismiss) private var dismiss

    init(record: BodyMeasurementDTO, site: BodySite, unit: LengthUnit, onDeleted: @escaping (String) -> Void,
         onSaved: @escaping () -> Void) {
        self.record = record
        self.site = site
        self.unit = unit
        self.onDeleted = onDeleted
        self.onSaved = onSaved
        let stored = site.isLength && record.unit.lowercased() == "in" ? LengthUnit.inches.centimetres(record.value) : record.value
        _text = State(initialValue: MeasurementEntrySheet.text(BodyMeasurements.display(stored, site: site, unit: unit)))
        _date = State(initialValue: record.day ?? CalendarDay(rawValue: "2000-01-01")!)
    }

    private var stored: Double? { TrainingInput.number(text).map { BodyMeasurements.stored($0, site: site, unit: unit) } }
    private var problem: String? { stored.flatMap { BodyMeasurements.problem($0, site: site, unit: unit) } }

    var body: some View {
        NavigationStack {
            ExScreen {
                ExCard(accent: true) {
                    ExEyebrow(site == .bodyFat ? "Body fat, visual estimate" : site.name, color: .exPrimaryText)
                    ExQuantityControl(title: "\(site.name) (\(MeasurementFormat.symbol(site, unit)))", text: $text,
                                      step: site.isLength ? (unit == .inches ? 0.25 : 0.5) : 0.5,
                                      unit: MeasurementFormat.symbol(site, unit), identifier: "measurementEdit.value")
                }
                ExCard {
                    BodyDateRow {
                        CalendarDayPicker("Date", selection: $date, today: sync.today, timeZoneIdentifier: sync.calendar.timeZoneIdentifier)
                            .font(.exLabel).foregroundStyle(Color.exTextSecondary).tint(Color.exPrimaryText)
                    }
                }
                if let problem { Label(problem, systemImage: "exclamationmark.triangle").font(.exCaption).foregroundStyle(Color.exWarning) }
                Button("Save changes", action: save).buttonStyle(ExActionStyle())
                    .disabled(stored == nil || problem != nil).accessibilityIdentifier("measurementEdit.save")
                Button("Delete measurement", role: .destructive, action: delete)
                    .font(.exBodyMedium).foregroundStyle(Color.exError).frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("measurementEdit.delete")
                if let error { Text(error).font(.exCaption).foregroundStyle(Color.exError) }
            }
            .navigationTitle("Edit measurement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func save() {
        guard let stored, problem == nil else { return }
        do {
            try sync.saveMeasurement(BodyMeasurementRequest(type: record.type, value: (stored * 10_000).rounded() / 10_000,
                                                            unit: site.isLength ? "cm" : "%", entry_date: date.rawValue,
                                                            note: record.note, source: record.source ?? "manual"), editing: record)
        } catch {
            self.error = error.localizedDescription
            return
        }
        onSaved()
        dismiss()
    }

    private func delete() {
        do {
            let id = try sync.deleteMeasurement(record)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onDeleted(id)
            onSaved()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
