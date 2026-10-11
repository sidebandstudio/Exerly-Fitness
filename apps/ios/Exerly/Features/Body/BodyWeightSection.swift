import ExerlyCore
import SwiftUI

/// Progress → Body's weight: the trend chart with its band and readings, the
/// goal and its planned path, change and rate over a chosen span, what the
/// trend rests on, expenditure with its uncertainty, and every weigh-in, each
/// editable. `measurements` sits between the goal and expenditure.
struct BodyWeightSection<Measurements: View>: View {
    @ObservedObject var workspace: TrainingWorkspace
    let unit: MassUnit
    let timeZone: TimeZone
    let onWeighIn: () -> Void
    let onEdit: (WeightEntry) -> Void
    let onDelete: (WeightEntry) -> Void
    /// A weigh-in deleted from a sheet opened here.
    let onDeleted: (WeightEntry) -> Void
    let onEditGoal: () -> Void
    @ViewBuilder var measurements: Measurements
    @AppStorage("body.weightRange") private var range: BodyRange = .quarter
    @State private var selection: LocalDate?
    @State private var showsAll = false
    @State private var explaining = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let today = LocalDate(Date(), in: timeZone)
        let store = workspace.nutrition
        let estimates = BodyEstimates.shared.estimates(store, through: today)
        VStack(alignment: .leading, spacing: ExSpacing.page) {
            if let summary = WeightTrend.summary(estimates, through: today) {
                let start = range.start(today: today, first: estimates.first?.date)
                let points = WeightTrend.series(estimates, from: start, through: today)
                let readings = store.weights.filter { $0.date >= start && $0.date <= today }
                let goals = WeightGoal.stretches(store.versionsInForce, estimates: estimates, from: start, through: today)
                trendCard(summary, estimates: estimates, points: points, readings: readings, goals: goals, start: start, today: today)
                BodyGoalCard(plan: store.plan(on: today), stretch: goals.last { $0.end == today }, summary: summary, unit: unit,
                             today: today, onEdit: onEditGoal)
                // Under the chart: above it, the offer pushed the chart off an SE's first screen (run 6).
                HealthWeighInPrompt()
                measurements
                expenditureCard(summary.expenditure, points: points)
                history(store.weights.reversed(), today: today)
            } else {
                HealthWeighInPrompt()
                ExEmptyState(icon: "scalemass", title: "No weigh-ins yet",
                             message: "Weigh in a few mornings a week. Exerly turns the readings into a trend weight, "
                                + "then into your expenditure once you've logged food for a while.",
                             action: "Weigh in", actionID: "body.weighIn", perform: onWeighIn)
                measurements
            }
        }
        .sheet(isPresented: $explaining) {
            TrendExplanationSheet(workspace: workspace, unit: unit, timeZone: timeZone, onDeleted: onDeleted)
        }
    }

    // MARK: Trend

    private func trendCard(_ summary: WeightTrend.Summary, estimates: [EnergyBalance.Estimate], points: [WeightTrend.Point],
                           readings: [WeightEntry], goals: [WeightGoal.Stretch], start: LocalDate, today: LocalDate) -> some View {
        ExCard {
            BodyCardHeader(title: "Trend weight") { WeighInButton(identifier: "body.weighIn", action: onWeighIn) }
            readout(summary, points: points, goals: goals, today: today)
            rangePicker
            if summary.weighInDays >= 2, points.count >= 2 {
                let shown = range.phrase(start: start, firstShown: points.first?.date)
                WeightTrendChart(points: points, readings: readings, unit: unit, range: range, goals: goals, selection: $selection)
                    // 200, so the legend under it is on an SE's first screen too (run 6).
                    .frame(height: typeSize.isAccessibilitySize ? 280 : 200)
                    .accessibilityLabel("Weight trend, \(shown == range.phrase ? range.spoken : shown)")
                    .accessibilityValue(chartSummary(summary, points: points, readings: readings, shown: shown))
                    .accessibilityIdentifier("body.chart")
                legend(gaps: WeightTrend.runs(points).contains { !$0.measured }, plan: !goals.isEmpty,
                       goal: goals.contains { $0.goal.goalWeight != nil })
            } else {
                Text("The chart starts with your second weigh-in. Until then the trend is your one reading.")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            }
            rangeStats(estimates, points: points, readings: readings, start: start, today: today)
        }
    }

    /// The current trend, or the touched day's values while scrubbing. Tapping
    /// it shows what the trend rests on.
    @ViewBuilder
    private func readout(_ summary: WeightTrend.Summary, points: [WeightTrend.Point], goals: [WeightGoal.Stretch],
                         today: LocalDate) -> some View {
        let picked = selection.flatMap { day in points.first { $0.date == day } }
        let trend = picked?.trend ?? summary.trend
        let error = picked?.trendError ?? summary.trendError
        let detail = readoutDetail(picked, summary: summary, goals: goals, today: today)
        Button { explaining = true } label: {
            HStack(alignment: .top, spacing: ExSpacing.small) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(BodyFormat.weight(trend, unit, withUnit: false)).font(.exStat).monospacedDigit()
                            .foregroundStyle(Color.exTextPrimary).contentTransition(.numericText(value: trend))
                        Text(unit.rawValue).font(.exBodyMedium).foregroundStyle(Color.exTextSecondary)
                        Text("±\(BodyFormat.number(Mass.kg(error).value(in: unit)))").font(.exLabel).foregroundStyle(Color.exTextMuted)
                    }
                    Text(detail).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                    // At the largest sizes the number fills the row, so the way in is a line of its own.
                    if typeSize.isAccessibilitySize {
                        Label("What it rests on", systemImage: "info.circle").font(.exLabel).foregroundStyle(Color.exPrimaryText)
                    }
                }
                Spacer(minLength: 0)
                if !typeSize.isAccessibilitySize {
                    Image(systemName: "info.circle").font(.body.weight(.medium)).foregroundStyle(Color.exPrimaryText)
                        .frame(width: 28, height: 28).accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trend weight \(BodyFormat.spokenWeight(trend, unit)), give or take "
            + "\(BodyFormat.number(Mass.kg(error).value(in: unit))). "
            + readoutDetail(picked, summary: summary, goals: goals, today: today, spoken: true))
        .accessibilityHint("Double-tap to see the readings it rests on")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("body.trend")
    }

    private func readoutDetail(_ picked: WeightTrend.Point?, summary: WeightTrend.Summary, goals: [WeightGoal.Stretch],
                               today: LocalDate, spoken: Bool = false) -> String {
        let store = workspace.nutrition
        if let picked {
            let day = BodyFormat.day(picked.date, today: today)
            var parts = [picked.reading.map { "\(day) · scale \(BodyFormat.weight($0, unit))" } ?? "\(day) · no weigh-in"]
            // The goal that applied that day, not today's.
            if let goal = goals.last(where: { $0.start <= picked.date && $0.end >= picked.date }), picked.date >= goal.anchor {
                parts.append("planned \(BodyFormat.weight(goal.planned(on: picked.date), unit))")
                if let weight = goal.goal.goalWeight { parts.append("goal \(BodyFormat.reading(weight, unit))") }
            }
            return parts.joined(separator: " · ")
        }
        var parts: [String] = []
        if let week = summary.weekChange { parts.append(spoken ? BodyCopy.spokenWeekChange(week, unit) : BodyCopy.weekChange(week, unit)) }
        if let last = store.weights.last {
            parts.append("last scale \(BodyFormat.reading(last.weight, unit)) \(BodyFormat.day(last.date, today: today).lowercased())")
        }
        let line = parts.joined(separator: " · ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    @ViewBuilder
    private var rangePicker: some View {
        if typeSize.isAccessibilitySize {
            Picker("Chart span", selection: $range) {
                ForEach(BodyRange.allCases) { Text($0.spoken).tag($0) }
            }.pickerStyle(.menu).tint(Color.exPrimaryText).accessibilityIdentifier("body.range")
        } else {
            HStack(spacing: 2) {
                ForEach(BodyRange.allCases) { option in
                    Button { range = option; selection = nil } label: {
                        Text(option.rawValue).font(.exLabel).foregroundStyle(option == range ? Color.white : Color.exTextSecondary)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(option == range ? Color.exActionFill : .clear, in: RoundedRectangle(cornerRadius: ExRadius.control - 4))
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.spoken).accessibilityAddTraits(option == range ? .isSelected : [])
                    .accessibilityIdentifier("body.range.\(option.rawValue)")
                }
            }
            .padding(.horizontal, 3)
            .background(Color.exSurface2, in: RoundedRectangle(cornerRadius: ExRadius.control))
            .sensoryFeedback(.selection, trigger: range)
        }
    }

    private func legend(gaps: Bool, plan: Bool, goal: Bool) -> some View {
        var spoken = "Dots are scale readings, the line is the trend, and the shading is its likely range."
        if gaps { spoken += " Where the trend is dashed there were no weigh-ins, so it's an estimate." }
        if plan { spoken += " The grey dashed line is the path your goal planned." }
        if goal { spoken += " The pink dotted line is the goal weight." }
        return ExFlowLayout(spacing: ExSpacing.small) {
            legendItem { Circle().fill(Color.exTextSecondary.opacity(0.6)).frame(width: 6, height: 6) } label: { Text("Scale") }
            legendItem {
                Capsule().fill(LinearGradient(colors: [.exPrimary, .exAccent], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 14, height: 3)
            } label: { Text("Trend") }
            if gaps {
                legendItem { dash(Color.exPrimary.opacity(0.7), dash: [3, 2.5]) } label: { Text("No weigh-ins") }
            }
            legendItem {
                RoundedRectangle(cornerRadius: 2).fill(Color.exPrimary.opacity(0.25)).frame(width: 14, height: 8)
            } label: { Text("Likely range (±1 SD)") }
            if plan {
                legendItem { dash(Color.exTextSecondary.opacity(0.8), dash: [4, 3]) } label: { Text("Planned") }
            }
            if goal {
                legendItem { dash(Color.exAccent, dash: [1.5, 2]) } label: { Text("Goal") }
            }
        }
        .font(.exSmall).foregroundStyle(Color.exTextMuted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private func dash(_ color: Color, dash: [CGFloat]) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 1.5))
            path.addLine(to: CGPoint(x: 16, y: 1.5))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dash))
        .frame(width: 16, height: 3)
    }

    private func legendItem(@ViewBuilder symbol: () -> some View, @ViewBuilder label: () -> Text) -> some View {
        HStack(spacing: 5) { symbol(); label().lineLimit(typeSize.isAccessibilitySize ? nil : 1) }
    }

    private func rangeStats(_ estimates: [EnergyBalance.Estimate], points: [WeightTrend.Point], readings: [WeightEntry],
                            start: LocalDate, today: LocalDate) -> some View {
        let change = WeightTrend.change(estimates, from: start, through: today)
        let days = Set(readings.map(\.date)).count
        let span = (points.first?.date).map { $0.days(until: today) + 1 } ?? 0
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: ExSpacing.item))
            : AnyLayout(HStackLayout(alignment: .top, spacing: ExSpacing.item))
        return layout {
            stat("Change", value: change.map { BodyFormat.change($0.kilograms, unit) } ?? "–",
                 detail: range.phrase(start: start, firstShown: points.first?.date),
                 spoken: change.map { BodyFormat.spokenChange($0.kilograms, unit) } ?? "Not enough weigh-ins")
            // The range's average, kept apart from "this week", the summary's seven-day change.
            stat("Average", value: change?.weeklyRate.map { BodyFormat.change($0, unit, digits: 2) } ?? "–",
                 detail: change?.weeklyRate == nil ? "needs a week" : "a week",
                 spoken: change?.weeklyRate.map { "\(BodyFormat.spokenChange($0, unit, digits: 2)) a week" } ?? "Needs a week of weigh-ins")
            stat("Weigh-ins", value: "\(days)", detail: "of \(span) days", spoken: "\(days) days with a weigh-in, of \(span)")
        }
        .padding(.top, ExSpacing.tight)
    }

    private func stat(_ title: String, value: String, detail: String, spoken: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.exCaption).foregroundStyle(Color.exTextSecondary)
            Text(value).font(.exStatSmall).foregroundStyle(Color.exTextPrimary).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(detail).font(.exSmall).foregroundStyle(Color.exTextMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(spoken)")
    }

    private func chartSummary(_ summary: WeightTrend.Summary, points: [WeightTrend.Point], readings: [WeightEntry],
                              shown: String) -> String {
        var parts = ["Trend now \(BodyFormat.spokenWeight(summary.trend, unit))"]
        if let first = points.first, let last = points.last, first.date < last.date {
            parts.append("\(BodyFormat.spokenChange(last.trend - first.trend, unit)) \(shown == range.phrase ? "over the " + shown : shown)")
        }
        let values = readings.map { $0.weight.value(in: unit) }
        if let low = values.min(), let high = values.max() {
            parts.append("\(readings.count) readings from \(BodyFormat.number(low)) to \(BodyFormat.number(high)) \(BodyFormat.unitName(unit))")
        }
        return parts.joined(separator: ". ")
    }

    // MARK: Expenditure

    private func expenditureCard(_ value: WeightTrend.Expenditure, points: [WeightTrend.Point]) -> some View {
        ExCard {
            ExEyebrow("Expenditure")
            if value.isMeasured {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(BodyFormat.kcal(value.kcal)).font(.exStat).monospacedDigit().foregroundStyle(Color.exTextPrimary)
                        Text("kcal a day").font(.exBodyMedium).foregroundStyle(Color.exTextSecondary)
                        Text("±\(BodyFormat.kcal(value.error))").font(.exLabel).foregroundStyle(Color.exTextMuted)
                    }
                    Text("Likely \(BodyFormat.kcal(value.kcal - value.error)) to \(BodyFormat.kcal(value.kcal + value.error)) kcal a day")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Expenditure about \(BodyFormat.kcal(value.kcal)) kilocalories a day, likely between "
                    + "\(BodyFormat.kcal(value.kcal - value.error)) and \(BodyFormat.kcal(value.kcal + value.error))")
                .accessibilityIdentifier("body.expenditure")
                let settled = points.filter { $0.expenditureError <= WeightTrend.maximumExpenditureError * 1.2 }
                if settled.count >= 7 {
                    ExpenditureChart(points: settled, range: range).frame(height: 130)
                        .accessibilityLabel("Expenditure, \(range.spoken)")
                        .accessibilityValue(expenditureSummary(settled))
                }
            } else {
                Text("Still estimating").font(.exH3).foregroundStyle(Color.exTextPrimary).accessibilityIdentifier("body.expenditure")
                Text("It needs \(WeightTrend.minimumLoggedDays) fully logged days and \(WeightTrend.minimumWeighInDays) "
                    + "weigh-in days in the last 4 weeks, and a narrow enough range. "
                    + (value.error < 450 ? "The current guess is \(BodyFormat.kcal(value.kcal)) ±\(BodyFormat.kcal(value.error)) kcal a day, "
                        + "mostly from your starting estimate." : "There isn't enough to estimate it yet."))
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            }
            coverage(value)
            Text(BodyCopy.expenditureMethod).font(.exCaption).foregroundStyle(Color.exTextMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func coverage(_ value: WeightTrend.Expenditure) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: ExSpacing.small))
            : AnyLayout(HStackLayout(spacing: ExSpacing.item))
        return layout {
            coverageBar("Fully logged", count: value.loggedDays, needed: WeightTrend.minimumLoggedDays)
            coverageBar("Weigh-in days", count: value.weighInDays, needed: WeightTrend.minimumWeighInDays)
        }
    }

    private func coverageBar(_ title: String, count: Int, needed: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                Spacer(minLength: 4)
                Text("\(count) of \(WeightTrend.window)").font(.exCaption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(count >= needed ? Color.exTextPrimary : Color.exWarning)
            }
            ExProgressBar(value: Double(count), total: Double(WeightTrend.window), color: count >= needed ? .exPrimary : .exWarning)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(count) of the last \(WeightTrend.window) days. \(needed) needed.")
    }

    private func expenditureSummary(_ points: [WeightTrend.Point]) -> String {
        guard let first = points.first, let last = points.last else { return "" }
        return "From \(BodyFormat.kcal(first.expenditure)) to \(BodyFormat.kcal(last.expenditure)) kilocalories a day"
    }

    // MARK: History

    private func history(_ entries: [WeightEntry], today: LocalDate) -> some View {
        let shown = showsAll ? entries : Array(entries.prefix(10))
        return VStack(alignment: .leading, spacing: ExSpacing.item) {
            ExSectionHeading("Weigh-ins", detail: "\(entries.count)")
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Rectangle().fill(Color.exBorder.opacity(0.5)).frame(height: 0.5).padding(.leading, ExSpacing.content) }
                    historyRow(entry, today: today)
                }
            }
            .background(Color.exSurface1, in: RoundedRectangle(cornerRadius: ExRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ExRadius.card, style: .continuous).strokeBorder(Color.exBorder.opacity(0.5), lineWidth: 0.5)
            }
            if entries.count > shown.count {
                Button("Show all \(entries.count) weigh-ins") { showsAll = true }
                    .font(.exBodyMedium).foregroundStyle(Color.exPrimaryText).frame(maxWidth: .infinity, minHeight: 44)
            }
        }
    }

    private func historyRow(_ entry: WeightEntry, today: LocalDate) -> some View {
        var detail = BodyFormat.time(entry.at, in: timeZone)
        if let fat = entry.bodyFat { detail += " · \(BodyFormat.number(fat)) % fat" }
        if entry.source == .appleHealth { detail += " · Apple Health" }
        let day = BodyFormat.day(entry.date, today: today)
        return Button { onEdit(entry) } label: {
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(day).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                        Text(BodyFormat.reading(entry.weight, unit)).font(.exStatSmall).monospacedDigit()
                            .foregroundStyle(Color.exTextPrimary)
                        Text(detail).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, ExSpacing.small)
                } else {
                    HStack(spacing: ExSpacing.item) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(day).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                            Text(detail).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                        }
                        Spacer(minLength: ExSpacing.small)
                        Text(BodyFormat.reading(entry.weight, unit)).font(.exStatSmall).monospacedDigit()
                            .foregroundStyle(Color.exTextPrimary)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.exTextMuted)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(.horizontal, ExSpacing.content).frame(minHeight: 56).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit", systemImage: "pencil") { onEdit(entry) }
            if entry.source != .appleHealth {
                Button("Delete", systemImage: "trash", role: .destructive) { onDelete(entry) }
            }
        }
        .accessibilityLabel("Weigh-in, \(day), \(BodyFormat.spokenReading(entry.weight, unit))")
        .accessibilityHint("Double-tap to edit")
        .accessibilityAction(named: "Delete") { if entry.source != .appleHealth { onDelete(entry) } }
        .accessibilityIdentifier("body.weighIn.\(entry.date)")
    }
}
