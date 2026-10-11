import Charts
import ExerlyCore
import SwiftUI

/// Measurements as the screens write them: in the person's unit to 0.1, body fat in percent.
enum MeasurementFormat {
    static func value(_ stored: Double, _ site: BodySite, _ unit: LengthUnit, withUnit: Bool = true) -> String {
        let text = BodyMeasurements.display(stored, site: site, unit: unit).formatted(.number.precision(.fractionLength(1)))
        return withUnit ? "\(text) \(symbol(site, unit))" : text
    }

    static func symbol(_ site: BodySite, _ unit: LengthUnit) -> String { site.isLength ? unit.rawValue : "%" }

    static func spoken(_ stored: Double, _ site: BodySite, _ unit: LengthUnit) -> String {
        "\(value(stored, site, unit, withUnit: false)) \(site.isLength ? (unit == .inches ? "inches" : "centimetres") : "percent")"
    }

    /// "+0.5 in", "−1.0 in" or "No change", with a true minus sign.
    static func change(_ stored: Double, _ site: BodySite, _ unit: LengthUnit) -> String {
        let shown = BodyMeasurements.display(stored, site: site, unit: unit)
        guard shown != 0 else { return "No change" }
        return "\(shown > 0 ? "+" : "−")\(abs(shown).formatted(.number.precision(.fractionLength(1)))) \(symbol(site, unit))"
    }

    static func spokenChange(_ stored: Double, _ site: BodySite, _ unit: LengthUnit) -> String {
        let shown = BodyMeasurements.display(stored, site: site, unit: unit)
        guard shown != 0 else { return "no change" }
        return "\(shown > 0 ? "up" : "down") \(spoken(abs(stored), site, unit))"
    }
}

/// A date picker with its label beside it, or above it at the largest
/// sizes, where the picker would squeeze the label to a letter a line.
struct BodyDateRow<Picker: View>: View {
    @ViewBuilder var picker: Picker
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: ExSpacing.small) {
                Text("Date").font(.exLabel).foregroundStyle(Color.exTextSecondary).accessibilityHidden(true)
                picker.labelsHidden()
            }
        } else {
            picker
        }
    }
}

/// Measurements from the daily-log sync, as ExerlyCore readings, with the
/// records they came from for editing and deleting.
struct MeasurementRecords {
    let readings: [BodyMeasurementReading]
    let records: [String: BodyMeasurementDTO]

    init(_ measurements: [BodyMeasurementDTO]) {
        var records: [String: BodyMeasurementDTO] = [:]
        readings = measurements.compactMap { record in
            guard let site = BodySite(rawValue: record.type), let date = LocalDate(record.entry_date) else { return nil }
            // The server stores centimetres; a record saved as inches converts.
            let value = site.isLength && record.unit.lowercased() == "in" ? LengthUnit.inches.centimetres(record.value) : record.value
            records[record.client_id] = record
            return BodyMeasurementReading(id: record.client_id, site: site, date: date, value: value)
        }
        self.records = records
    }

    /// Sites with at least one reading, in the entry's order, older sites last.
    var sites: [BodySite] {
        let measured = Set(readings.map(\.site))
        return BodySite.allCases.filter { measured.contains($0) }
    }
}

/// Progress → Body's measurements: each measured site's latest value and its
/// change since the reading before, opening its history; and one button to
/// log any of them in one sheet.
struct BodyMeasurementsCard: View {
    let records: MeasurementRecords
    let unit: LengthUnit
    let today: LocalDate
    let isLoading: Bool
    let error: String?
    let onLog: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ExCard {
            BodyCardHeader(title: "Measurements") {
                Button(action: onLog) {
                    Label("Log", systemImage: "ruler").font(.exLabel.weight(.semibold)).foregroundStyle(Color.exPrimaryText)
                        .padding(.horizontal, 14).frame(minHeight: 36)
                        .background(Color.exPrimary.opacity(0.14), in: Capsule())
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Log measurements")
                .accessibilityIdentifier("body.measurements.log")
            }
            if records.readings.isEmpty {
                Text(isLoading ? "Loading measurements…"
                     : "A tape shows change the scale can hide. Log your waist, hips, arms and more in one sheet.")
                    .font(.exBody).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(records.sites.enumerated()), id: \.element) { index, site in
                        if index > 0 { TargetsDivider() }
                        row(site)
                    }
                }
            }
            if let error { Text(error).font(.exCaption).foregroundStyle(Color.exError).fixedSize(horizontal: false, vertical: true) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("body.measurements")
    }

    private func row(_ site: BodySite) -> some View {
        let history = BodyMeasurements.history(records.readings, site: site)
        let latest = history.last
        let change = BodyMeasurements.change(records.readings, site: site)
        let since = history.count >= 2 ? BodyFormat.shortDate(history[history.count - 2].date) : nil
        let detail = [latest.map { BodyFormat.day($0.date, today: today) }, change.map { MeasurementFormat.change($0, site, unit) }]
            .compactMap { $0 }.joined(separator: " · ") + (since.map { " since \($0)" } ?? "")
        return NavigationLink(value: site) {
            HStack(spacing: ExSpacing.item) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(site.name).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                    Text(detail).font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: ExSpacing.small)
                if let latest {
                    Text(MeasurementFormat.value(latest.value, site, unit)).font(.exStatSmall).monospacedDigit()
                        .foregroundStyle(Color.exTextPrimary).lineLimit(1).fixedSize()
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.exTextMuted)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 52).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(site.name), \(latest.map { MeasurementFormat.spoken($0.value, site, unit) } ?? "")"
            + (change.map { ", \(MeasurementFormat.spokenChange($0, site, unit))" + (since.map { " since \($0)" } ?? "") } ?? ""))
        .accessibilityHint("Shows its history")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("body.measurement.\(site.rawValue)")
    }
}

/// One site's measurements over time: a chart and every reading, each
/// editable, deleted with Undo.
struct MeasurementHistoryView: View {
    let site: BodySite
    let unit: LengthUnit
    let timeZone: TimeZone
    @ObservedObject var model: MeasurementsViewModel
    @EnvironmentObject private var sync: SyncEngine
    @State private var editing: BodyMeasurementDTO?
    @State private var deleted: String?
    @State private var error: String?

    var body: some View {
        let records = MeasurementRecords(model.measurements)
        let history = BodyMeasurements.history(records.readings, site: site)
        let today = LocalDate(Date(), in: timeZone)
        ExScreen {
            if history.count >= 2 {
                ExCard {
                    MeasurementChart(history: history, site: site, unit: unit).frame(height: 180)
                    if let first = history.first, let last = history.last {
                        Text("\(MeasurementFormat.change(last.value - first.value, site, unit)) since \(BodyFormat.shortDate(first.date))")
                            .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    }
                }
            }
            if let error { Text(error).font(.exCaption).foregroundStyle(Color.exError) }
            VStack(spacing: 0) {
                ForEach(Array(history.reversed().enumerated()), id: \.element.id) { index, reading in
                    if index > 0 { TargetsDivider().padding(.leading, ExSpacing.content) }
                    row(reading, record: records.records[reading.id], today: today)
                }
            }
            .background(Color.exSurface1, in: RoundedRectangle(cornerRadius: ExRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ExRadius.card, style: .continuous).strokeBorder(Color.exBorder.opacity(0.5), lineWidth: 0.5)
            }
            if history.isEmpty {
                Text("No \(site.name.lowercased()) measurements left.").font(.exBody).foregroundStyle(Color.exTextSecondary)
            }
        }
        .navigationTitle(site.name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let deleted {
                TodayToast(message: "Measurement deleted", undo: { undo(deleted) }, undoIdentifier: "measurement.undo")
                    .padding(.bottom, ExSpacing.small)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: deleted) {
                        try? await Task.sleep(for: .seconds(UIAccessibility.isVoiceOverRunning ? 15 : 10))
                        withAnimation(.snappy) { if self.deleted == deleted { self.deleted = nil } }
                    }
            }
        }
        .sheet(item: $editing) { record in
            MeasurementEditSheet(record: record, site: site, unit: unit, onDeleted: { id in
                withAnimation(.snappy) { deleted = id }
            }, onSaved: reload)
        }
    }

    private func row(_ reading: BodyMeasurementReading, record: BodyMeasurementDTO?, today: LocalDate) -> some View {
        let day = BodyFormat.day(reading.date, today: today)
        return Button { editing = record } label: {
            HStack(spacing: ExSpacing.item) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(day).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                    if let state = record?.sync_state, state != "synced" {
                        Text(state == "attention" ? "Needs review" : "Waiting to sync").font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    }
                }
                Spacer(minLength: ExSpacing.small)
                Text(MeasurementFormat.value(reading.value, site, unit)).font(.exStatSmall).monospacedDigit()
                    .foregroundStyle(Color.exTextPrimary)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.exTextMuted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, ExSpacing.content).frame(minHeight: 56).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(record == nil)
        .contextMenu {
            Button("Edit", systemImage: "pencil") { editing = record }
            Button("Delete", systemImage: "trash", role: .destructive) { delete(record) }
        }
        .accessibilityLabel("\(site.name), \(day), \(MeasurementFormat.spoken(reading.value, site, unit))")
        .accessibilityHint("Double-tap to edit")
        .accessibilityAction(named: "Delete") { delete(record) }
        .accessibilityIdentifier("measurement.reading.\(reading.date)")
    }

    private func delete(_ record: BodyMeasurementDTO?) {
        guard let record else { return }
        do {
            let id = try sync.deleteMeasurement(record)
            withAnimation(.snappy) { deleted = id }
            reload()
        } catch { self.error = error.localizedDescription }
    }

    private func undo(_ id: String) {
        do {
            try sync.undoMeasurementDeletion(entityID: id)
            withAnimation(.snappy) { deleted = nil }
            reload()
        } catch { self.error = error.localizedDescription }
    }

    private func reload() { Task { await model.load(today: sync.today) } }
}

/// A site's readings as a line, in the person's unit.
struct MeasurementChart: View {
    let history: [BodyMeasurementReading]
    let site: BodySite
    let unit: LengthUnit

    var body: some View {
        let values = history.map { BodyMeasurements.display($0.value, site: site, unit: unit) }
        let low = values.min() ?? 0, high = values.max() ?? 1
        let pad = max((high - low) * 0.2, site.isLength && unit == .inches ? 0.5 : 1)
        Chart {
            ForEach(history) { reading in
                LineMark(x: .value("Day", BodyDates.anchor(reading.date)),
                         y: .value(site.name, BodyMeasurements.display(reading.value, site: site, unit: unit)))
                    .foregroundStyle(LinearGradient(colors: [.exPrimary, .exAccent], startPoint: .leading, endPoint: .trailing))
                    .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                PointMark(x: .value("Day", BodyDates.anchor(reading.date)),
                          y: .value(site.name, BodyMeasurements.display(reading.value, site: site, unit: unit)))
                    .symbolSize(36).foregroundStyle(Color.exAccent)
            }
        }
        .chartYScale(domain: (low - pad)...(high + pad))
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: Date.FormatStyle(timeZone: BodyDates.utc).month(.abbreviated).day(), centered: false)
                    .font(.exSmall).foregroundStyle(Color.exTextMuted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Color.exBorder)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(number.formatted(.number.precision(.fractionLength(0...1)))).font(.exSmall).foregroundStyle(Color.exTextMuted)
                    }
                }
            }
        }
        .environment(\.timeZone, BodyDates.utc).environment(\.calendar, BodyDates.calendar)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(site.name) over time")
        .accessibilityValue(summary)
        .accessibilityIdentifier("measurement.chart")
    }

    private var summary: String {
        guard let first = history.first, let last = history.last else { return "" }
        return "\(history.count) readings, from \(MeasurementFormat.spoken(first.value, site, unit)) on \(BodyFormat.shortDate(first.date)) "
            + "to \(MeasurementFormat.spoken(last.value, site, unit)) on \(BodyFormat.shortDate(last.date))"
    }
}
