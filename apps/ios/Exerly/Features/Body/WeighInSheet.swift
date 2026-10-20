import ExerlyCore
import SwiftUI
import UIKit

/// A weigh-in in two taps: it opens on the last reading with the keypad up,
/// so the scale's number is typed straight over it, then Save (Save alone
/// keeps the last reading). Done puts the keypad away for the ruler, ± and
/// body fat. Also edits a saved one: its weight, body fat, day and time.
struct WeighInSheet: View {
    @ObservedObject var workspace: TrainingWorkspace
    let unit: MassUnit
    let timeZone: TimeZone
    private let editing: WeightEntry?
    private let onDeleted: (WeightEntry) -> Void
    private let onSaved: (WeightEntry) -> Void
    private let initialValue: Double

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize: CGFloat = 60
    @State private var value: Double
    @State private var bodyFat: Double?
    @State private var date: LocalDate
    /// An edited weigh-in's clock time, read in `timeZone`.
    @State private var time: Date
    @State private var choosingTime = false
    @State private var typing: Field?
    @State private var typed = ""
    @State private var choosingDate = false
    @State private var error: String?
    @State private var context: String?
    @State private var detent: PresentationDetent = .weighIn

    private enum Field { case weight, bodyFat }

    /// `onSaved` gets a new weigh-in once it's saved, for a confirmation with Undo.
    init(workspace: TrainingWorkspace, unit: MassUnit, timeZone: TimeZone, onSaved: @escaping (WeightEntry) -> Void = { _ in }) {
        self.init(workspace: workspace, unit: unit, timeZone: timeZone, editing: nil, onSaved: onSaved)
    }

    /// `editing` opens a saved weigh-in; `date` starts a new one on another day.
    init(workspace: TrainingWorkspace, unit: MassUnit, timeZone: TimeZone, editing: WeightEntry?, date: LocalDate? = nil,
         onDeleted: @escaping (WeightEntry) -> Void = { _ in }, onSaved: @escaping (WeightEntry) -> Void = { _ in }) {
        self.workspace = workspace
        self.unit = unit
        self.timeZone = timeZone
        self.editing = editing
        self.onDeleted = onDeleted
        self.onSaved = onSaved
        let latest = workspace.nutrition.weights.last
        let start = editing.map { ($0.weight.value(in: unit) * 100).rounded() / 100 }
            ?? WeightTrend.suggestedReading(latest: latest?.weight, trend: nil, unit: unit)
            ?? (unit == .pounds ? 165 : 75)
        initialValue = start
        _value = State(initialValue: start)
        _bodyFat = State(initialValue: editing?.bodyFat)
        _date = State(initialValue: editing?.date ?? date ?? LocalDate(Date(), in: timeZone))
        _time = State(initialValue: editing?.at ?? Date())
        // A new weigh-in is typed (docs/TAP_BUDGETS.md); an edit has more to
        // show (day, time, Delete) and starts on its reading.
        _typing = State(initialValue: editing == nil ? .weight : nil)
        _detent = State(initialValue: .large)
    }

    private var range: ClosedRange<Double> { WeightRuler.range(for: unit) }
    private var restingDetent: PresentationDetent { editing == nil ? .weighIn : .large }
    private var step: Double { WeightTrend.step(for: unit) }
    private var today: LocalDate { LocalDate(Date(), in: timeZone) }
    private var fromHealth: Bool { editing?.source == .appleHealth }
    private var lastBodyFat: Double? { workspace.nutrition.weights.last { $0.bodyFat != nil }?.bodyFat }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: ExSpacing.content) {
                    reading
                    if typing != nil {
                        keypad
                    } else if !fromHealth {
                        adjuster
                        bodyFatRow
                    }
                    if editing != nil { editFooter }
                }
                .padding(.horizontal, ExSpacing.page)
                .padding(.bottom, ExSpacing.content)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .exFooter { saveBar }
        .background(Color.exSurface1)
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.weighIn, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.exSurface1)
        .presentationCornerRadius(ExRadius.card + 10)
        .onAppear { if typeSize.isAccessibilitySize { detent = .large } }
        .task(id: date) { context = describe() }
    }

    // MARK: Parts

    private var header: some View {
        let close = Button { dismiss() } label: {
            Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.exTextSecondary)
                .frame(width: 44, height: 44).background(Color.exSurface2, in: Circle())
        }.buttonStyle(.plain).accessibilityLabel("Cancel").accessibilityIdentifier("weighIn.cancel")
        let title = Text(editing == nil ? "Weigh-in" : "Edit weigh-in").font(.exH3).foregroundStyle(Color.exTextPrimary)
            .accessibilityAddTraits(.isHeader)
        return Group {
            if typeSize.isAccessibilitySize || editing != nil {
                // An edit's day and time sit under the title, clear of it on a small phone.
                VStack(alignment: .leading, spacing: ExSpacing.small) {
                    HStack(spacing: ExSpacing.small) { close; title }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: ExSpacing.small) { dateChip; if editing != nil { timeChip } }
                        VStack(alignment: .leading, spacing: ExSpacing.small) { dateChip; if editing != nil { timeChip } }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: ExSpacing.small) {
                    close
                    title.lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: ExSpacing.small)
                    dateChip
                }
            }
        }
        .padding(.horizontal, ExSpacing.page).padding(.top, 18).padding(.bottom, ExSpacing.small)
    }

    private var dateChip: some View {
        Button { choosingDate = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar").font(.exLabel).accessibilityHidden(true)
                Text(BodyFormat.day(date, today: today)).font(.exLabel).lineLimit(1)
            }
            .foregroundStyle(Color.exPrimaryText).padding(.horizontal, 14).frame(minHeight: 44)
            .background(Color.exPrimary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain).disabled(fromHealth)
        .accessibilityLabel("Date, \(BodyFormat.day(date, today: today))").accessibilityHint("Choose another day")
        .accessibilityIdentifier("weighIn.date")
        .popover(isPresented: $choosingDate) {
            DatePicker("Weigh-in date", selection: Binding(get: { BodyDates.anchor(date) }, set: { picked in
                date = min(BodyDates.date(picked), today)
                choosingDate = false
            }), in: ...BodyDates.anchor(today), displayedComponents: .date)
            .datePickerStyle(.graphical).labelsHidden()
            .environment(\.calendar, BodyDates.calendar).environment(\.timeZone, BodyDates.utc)
            .tint(Color.exPrimaryText).frame(minWidth: 300).padding(ExSpacing.item)
            .presentationCompactAdaptation(.popover)
        }
    }

    private var timeChip: some View {
        Button { choosingTime = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock").font(.exLabel).accessibilityHidden(true)
                Text(BodyFormat.time(time, in: timeZone)).font(.exLabel).lineLimit(1)
            }
            .foregroundStyle(Color.exPrimaryText).padding(.horizontal, 14).frame(minHeight: 44)
            .background(Color.exPrimary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain).disabled(fromHealth)
        .accessibilityLabel("Time, \(BodyFormat.time(time, in: timeZone))").accessibilityHint("Choose another time")
        .accessibilityIdentifier("weighIn.time")
        .popover(isPresented: $choosingTime) {
            DatePicker("Weigh-in time", selection: $time, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel).labelsHidden()
                .environment(\.timeZone, timeZone)
                .frame(minWidth: 280).padding(ExSpacing.item)
                .presentationCompactAdaptation(.popover)
        }
    }

    private var reading: some View {
        // What's typed so far, once there is something, else the weight.
        let shown = typing == .weight && !typed.isEmpty ? typed : Self.display(value)
        return VStack(spacing: 6) {
            Button { if !fromHealth { startTyping(.weight) } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(shown)
                        .font(.system(size: numberSize, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(typing == .weight && typed.isEmpty ? Color.exTextMuted : Color.exTextPrimary)
                        .contentTransition(.numericText(value: value))
                        .animation(.snappy(duration: 0.18), value: value)
                        .lineLimit(1).minimumScaleFactor(0.5)
                    if typing == .weight {
                        Capsule().fill(Color.exAccent).frame(width: 3, height: numberSize * 0.7).accessibilityHidden(true)
                    }
                    Text(unit.rawValue).font(.exH2).foregroundStyle(Color.exTextSecondary)
                }
                .frame(maxWidth: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // While typing, what's typed so far, not a weight: "1" read as "1 pounds" in run 7.
            .accessibilityLabel(typing == .weight
                ? "Weight, typing \(typed.isEmpty ? "nothing yet" : typed), in \(BodyFormat.unitName(unit))"
                : "Weight, \(shown) \(BodyFormat.unitName(unit))")
            .accessibilityHint(fromHealth ? "" : "Double-tap to type a weight")
            .accessibilityIdentifier("weighIn.value")
            if let context {
                Text(context).font(.exCaption).foregroundStyle(Color.exTextSecondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("weighIn.context")
            }
        }
        .padding(.top, ExSpacing.small)
    }

    private var adjuster: some View {
        HStack(spacing: ExSpacing.small) {
            stepButton("minus", ticks: -1, label: "Decrease")
            WeightRuler(value: $value, unit: unit, range: range)
            stepButton("plus", ticks: 1, label: "Increase")
        }
    }

    private func stepButton(_ symbol: String, ticks: Int, label: String) -> some View {
        Button { value = WeightRuler.nudged(value, by: ticks, unit: unit, range: range) } label: {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.exPrimaryText)
                .frame(width: 48, height: 48).background(Color.exSurface2, in: Circle())
        }
        .buttonStyle(.plain).buttonRepeatBehavior(.enabled)
        .accessibilityLabel("\(label) by \(BodyFormat.number(step)) \(BodyFormat.unitName(unit))")
        .accessibilityIdentifier(ticks > 0 ? "weighIn.increase" : "weighIn.decrease")
    }

    private var bodyFatRow: some View {
        HStack(spacing: ExSpacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Body fat").font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                if bodyFat == nil, let lastBodyFat {
                    Text("Last \(BodyFormat.number(lastBodyFat)) %").font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }
            }
            Spacer(minLength: ExSpacing.small)
            Button { startTyping(.bodyFat) } label: {
                Text(bodyFat.map { "\(BodyFormat.number($0)) %" } ?? "Add").font(.exBodyMedium)
                    .foregroundStyle(Color.exPrimaryText).padding(.horizontal, ExSpacing.item).frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(bodyFat.map { "Body fat, \(BodyFormat.number($0)) percent" } ?? "Add body fat")
            .accessibilityHint(bodyFat == nil ? "Optional" : "Double-tap to change")
            .accessibilityIdentifier("weighIn.bodyFat")
            if bodyFat != nil {
                Button { bodyFat = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.exTextMuted).frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("Remove body fat")
            }
        }
        .padding(.leading, ExSpacing.content).padding(.trailing, ExSpacing.tight).padding(.vertical, 2)
        .background(Color.exSurface2, in: RoundedRectangle(cornerRadius: ExRadius.control, style: .continuous))
    }

    private var keypad: some View {
        VStack(spacing: ExSpacing.small) {
            if typing == .bodyFat {
                HStack {
                    Text("Body fat").font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                    Spacer()
                    Text(typed.isEmpty ? bodyFat.map { "\(BodyFormat.number($0)) %" } ?? "–" : "\(typed) %")
                        .font(.exStatMedium).monospacedDigit().foregroundStyle(typed.isEmpty ? Color.exTextMuted : Color.exTextPrimary)
                }
                .padding(.horizontal, ExSpacing.content).accessibilityElement(children: .combine)
            }
            ExNumericKeypad(title: typing == .bodyFat ? "Body fat (%)" : "Weight (\(unit.rawValue))", integer: false,
                            insert: insert, delete: { typed = String(typed.dropLast()) }, done: { commit() })
                .clipShape(RoundedRectangle(cornerRadius: ExRadius.card, style: .continuous))
        }
    }

    @ViewBuilder
    private var editFooter: some View {
        if fromHealth {
            Text("This weigh-in comes from Apple Health. Change or delete it in the Health app and Exerly will follow.")
                .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
        } else if typing == nil {
            Button("Delete weigh-in", role: .destructive, action: delete)
                .font(.exBodyMedium).foregroundStyle(Color.exError).frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("weighIn.delete")
        }
    }

    private var saveBar: some View {
        VStack(spacing: ExSpacing.small) {
            if let error {
                Text(error).font(.exCaption).foregroundStyle(Color.exError).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("weighIn.error")
            }
            if !fromHealth {
                Button(action: save) { Text(editing == nil ? "Save" : "Save changes") }
                    .buttonStyle(ExActionStyle()).accessibilityIdentifier("weighIn.save")
            }
        }
        .padding(.horizontal, ExSpacing.page).padding(.top, ExSpacing.small).padding(.bottom, ExSpacing.small)
        .background(Color.exSurface1)
    }

    // MARK: Typing

    private static var decimal: String { Locale.current.decimalSeparator ?? "." }

    static func display(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1...2)).grouping(.never))
    }

    private func startTyping(_ field: Field) {
        if typing != nil, !commit() { return }
        error = nil
        typed = ""
        typing = field
        if !typeSize.isAccessibilitySize { detent = .large }
    }

    private func insert(_ key: String) {
        var next = typed + key
        if key == Self.decimal {
            guard !typed.contains(key) else { return }
            if typed.isEmpty { next = "0" + key }
        }
        let parts = next.components(separatedBy: Self.decimal)
        let fraction = typing == .bodyFat ? 1 : 2
        guard parts[0].count <= 3, parts.count < 2 || parts[1].count <= fraction else { return }
        typed = next
    }

    /// Applies what was typed. False, with a message, when it isn't a usable value.
    @discardableResult
    private func commit() -> Bool {
        let text = typed.trimmingCharacters(in: .whitespaces)
        defer { if error == nil { typing = nil; typed = ""; if !typeSize.isAccessibilitySize { detent = restingDetent } } }
        guard !text.isEmpty else { error = nil; return true }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .current
        guard let number = formatter.number(from: text)?.doubleValue, number.isFinite else {
            error = "Enter a number."
            return false
        }
        switch typing {
        case .bodyFat:
            guard number > 1, number < 75 else {
                error = "Enter body fat between 1 and 75 %."
                return false
            }
            bodyFat = (number * 10).rounded() / 10
        default:
            guard range.contains(number) else {
                error = "Enter a weight from \(BodyFormat.number(range.lowerBound, digits: 0)) to "
                    + "\(BodyFormat.number(range.upperBound, digits: 0)) \(unit.rawValue)."
                return false
            }
            value = (number * 100).rounded() / 100
        }
        error = nil
        return true
    }

    // MARK: Saving

    private func save() {
        if typing != nil, !commit() { return }
        let store = workspace.nutrition
        var logged: WeightEntry?
        do {
            if var entry = editing {
                if value != initialValue { entry.weight = Mass((value * 100).rounded() / 100, unit) }
                entry.bodyFat = bodyFat
                let at = WeightTrend.instant(on: date, timeOf: time, in: timeZone)
                if entry.date != date || abs(at.timeIntervalSince(entry.at)) >= 60 {
                    entry.date = date
                    entry.at = at
                }
                try store.updateWeight(entry)
            } else {
                let now = Date()
                let at = date == LocalDate(now, in: timeZone) ? now : WeightTrend.instant(on: date, timeOf: now, in: timeZone)
                logged = try store.logWeight(Mass((value * 100).rounded() / 100, unit), bodyFat: bodyFat, at: at, timeZone: timeZone)
            }
        } catch {
            self.error = BodyFormat.message(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let workspace = workspace
        Task { await workspace.synchronize() }
        if let logged { onSaved(logged) }
        dismiss()
    }

    private func delete() {
        guard let entry = editing else { return }
        do {
            try workspace.nutrition.deleteWeight(entry.id)
        } catch {
            self.error = BodyFormat.message(error)
            return
        }
        let workspace = workspace
        Task {
            await LegacyWeighIns.forget(entry, accountID: workspace.accountID)
            await workspace.synchronize()
        }
        onDeleted(entry)
        dismiss()
    }

    /// One line of context under the number, worked out once per date.
    private func describe() -> String? {
        let store = workspace.nutrition
        if let editing {
            let source = editing.source == .appleHealth ? " from Apple Health" : ""
            return "Logged\(source) \(BodyFormat.day(editing.date, today: today).lowercasedIfRelative) at "
                + BodyFormat.time(editing.at, in: timeZone)
        }
        let day = BodyFormat.day(date, today: today)
        if let same = store.weights(on: date).last {
            return "\(day) already has \(BodyFormat.reading(same.weight, unit)). Both readings count."
        }
        var parts: [String] = []
        if let trend = BodyEstimates.shared.estimates(store, through: today).last?.trend {
            parts.append("Trend \(BodyFormat.weight(trend, unit))")
        }
        if let latest = store.weights.last {
            let when = BodyFormat.day(latest.date, today: today)
            parts.append("last \(BodyFormat.reading(latest.weight, unit)) \(when.lowercasedIfRelative)")
        }
        guard !parts.isEmpty else { return nil }
        let line = parts.joined(separator: " · ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }
}

private extension String {
    /// "today" and "yesterday" mid-sentence; "on Tue, Oct 6" otherwise.
    var lowercasedIfRelative: String { self == "Today" || self == "Yesterday" ? lowercased() : "on \(self)" }
}

private struct WeighInDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? { min(context.maxDetentValue, 440) }
}

extension PresentationDetent {
    static let weighIn = Self.custom(WeighInDetent.self)
}
