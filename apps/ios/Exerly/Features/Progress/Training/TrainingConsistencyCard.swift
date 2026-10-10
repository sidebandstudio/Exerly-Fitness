import Charts
import ExerlyCore
import SwiftUI

/// Workouts, hard sets and volume per calendar week, with the span's average
/// and totals. The current week is drawn lighter: it isn't over.
struct TrainingConsistencyCard: View {
    let report: TrainingInsights.Report
    let unit: MassUnit
    let span: TrainingInsights.Span
    @State private var metric: WeeklyMetric = .workouts
    @State private var selected: LocalDate?
    @Environment(\.dynamicTypeSize) private var typeSize

    enum WeeklyMetric: String, CaseIterable, Identifiable {
        case workouts = "Workouts", sets = "Sets", volume = "Volume"
        var id: String { rawValue }
    }

    var body: some View {
        ExCard {
            ExEyebrow("Training per week")
            readout
            metricPicker
            if report.weeks.count >= 2 {
                WeeklyBarChart(weeks: report.weeks, metric: metric, unit: unit, span: span, average: average,
                               selection: $selected)
                    .frame(height: typeSize.isAccessibilitySize ? 240 : 170)
                    .accessibilityLabel("\(metric.rawValue) per week, \(InsightFormat.spokenSpan(span))")
                    .accessibilityValue(chartSummary)
                    .accessibilityIdentifier("training.weeklyChart")
                chartLegend
            } else {
                Text("The weekly chart starts once you've trained in two different weeks.")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            }
            totals
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("training.consistency")
        .onChange(of: span) { _, _ in selected = nil }
    }

    // MARK: Readout

    private var average: Double? { report.weeklyAverage { value($0) } }

    @ViewBuilder
    private var readout: some View {
        let week = selected.flatMap { day in report.weeks.first { $0.start == day } }
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
        HStack(alignment: .top, spacing: ExSpacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                layout {
                    Text(week.map { formatted(value($0)) } ?? average.map(formatted) ?? "–")
                        .font(.exStat).monospacedDigit().foregroundStyle(Color.exTextPrimary)
                        .contentTransition(.numericText())
                    Text(week == nil ? "\(noun) a week" : noun).font(.exBodyMedium).foregroundStyle(Color.exTextSecondary)
                }
                Text(readoutDetail(week)).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenReadout(week))
            .accessibilityIdentifier("training.weeklyAverage")
            Spacer(minLength: 0)
            if week != nil {
                Button {
                    withAnimation(.snappy) { selected = nil }
                } label: {
                    Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Color.exTextSecondary)
                        .frame(width: 30, height: 30).background(Color.exSurface2, in: Circle())
                        .frame(width: 44, height: 44).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show the average")
                .accessibilityIdentifier("training.clearSelection")
            }
        }
    }

    private var noun: String {
        switch metric {
        case .workouts: "workouts"
        case .sets: "hard sets"
        case .volume: unit.rawValue
        }
    }

    private func readoutDetail(_ week: TrainingInsights.Week?) -> String {
        if let week {
            let prefix = week.isPartial ? "This week so far" : "Week of \(InsightFormat.shortDate(week.start))"
            return "\(prefix) · \(InsightFormat.workouts(week.sessions)) · \(InsightFormat.sets(week.sets)) sets"
        }
        let complete = report.completeWeeks
        let basis = complete == 0 ? "This week so far" : "Average of \(InsightFormat.weeks(complete))"
        return "\(basis) · trained \(report.trainedWeeks) of \(report.weeks.count) weeks"
    }

    private func spokenReadout(_ week: TrainingInsights.Week?) -> String {
        let number = week.map { spoken(value($0)) } ?? average.map(spoken) ?? "no data"
        return "\(number)\(week == nil ? " a week" : ""). \(readoutDetail(week))"
    }

    // MARK: Metric

    private var metricPicker: some View {
        ExChoiceChips(values: WeeklyMetric.allCases, selection: $metric) { $0.rawValue }
            .sensoryFeedback(.selection, trigger: metric)
            .accessibilityIdentifier("training.weeklyMetric")
    }

    private func value(_ week: TrainingInsights.Week) -> Double {
        switch metric {
        case .workouts: Double(week.sessions)
        case .sets: week.sets
        case .volume: Mass.kg(week.tonnage.total).value(in: unit)
        }
    }

    private func formatted(_ value: Double) -> String {
        switch metric {
        case .workouts: value.formatted(.number.precision(.fractionLength(0...1)))
        case .sets: InsightFormat.sets(value)
        case .volume: InsightFormat.volume(Mass(value, unit).kilograms, unit, withUnit: false)
        }
    }

    private func spoken(_ value: Double) -> String {
        switch metric {
        case .workouts: "\(value.formatted(.number.precision(.fractionLength(0...1)))) workouts"
        case .sets: "\(InsightFormat.sets(value)) hard sets"
        case .volume: InsightFormat.spokenVolume(Mass(value, unit).kilograms, unit)
        }
    }

    private var chartSummary: String {
        let values = report.weeks.map(value)
        guard let low = values.min(), let high = values.max() else { return "" }
        return "\(report.weeks.count) weeks, from \(spoken(low)) to \(spoken(high)). Average \(average.map(spoken) ?? "unavailable")."
    }

    private var chartLegend: some View {
        HStack(spacing: ExSpacing.item) {
            HStack(spacing: 5) {
                Rectangle().fill(Color.exTextSecondary.opacity(0.7)).frame(width: 14, height: 1)
                    .overlay(Rectangle().fill(Color.exSurface1).frame(width: 3, height: 1))
                Text("Average")
            }
            if report.weeks.last?.isPartial == true {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.exPrimary.opacity(0.4)).frame(width: 8, height: 10)
                    Text("This week so far")
                }
            }
        }
        .font(.exSmall).foregroundStyle(Color.exTextMuted)
        .accessibilityHidden(true)
    }

    // MARK: Totals

    private var totals: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: ExSpacing.item))
            : AnyLayout(HStackLayout(alignment: .top, spacing: ExSpacing.item))
        let tonnage = report.tonnage
        return layout {
            stat("Workouts", value: "\(report.sessions)", spoken: "\(report.sessions) workouts")
            stat("Hard sets", value: InsightFormat.sets(report.sets), spoken: "\(InsightFormat.sets(report.sets)) hard sets")
            stat("Volume", value: InsightFormat.volume(tonnage.total, unit),
                 spoken: InsightFormat.spokenVolume(tonnage.total, unit) + (tonnage.isComplete ? "" : ", missing some bodyweight sets"))
        }
        .padding(.top, ExSpacing.tight)
    }

    private func stat(_ title: String, value: String, spoken: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.exCaption).foregroundStyle(Color.exTextSecondary)
            Text(value).font(.exStatSmall).foregroundStyle(Color.exTextPrimary).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(span == .all ? "all time" : "in \(InsightFormat.spokenSpan(span))")
                .font(.exSmall).foregroundStyle(Color.exTextMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(spoken), \(InsightFormat.spanPhrase(span))")
    }
}

/// Weekly bars with a dashed average; scrub to read a week.
private struct WeeklyBarChart: View {
    let weeks: [TrainingInsights.Week]
    let metric: TrainingConsistencyCard.WeeklyMetric
    let unit: MassUnit
    let span: TrainingInsights.Span
    let average: Double?
    @Binding var selection: LocalDate?
    @State private var scrub: Date?

    var body: some View {
        Chart {
            ForEach(weeks, id: \.start) { week in
                BarMark(x: .value("Week", BodyDates.anchor(week.start), unit: .weekOfYear), y: .value(metric.rawValue, value(week)),
                        width: .ratio(0.62))
                    .foregroundStyle(LinearGradient(colors: [.exPrimary, .exAccent], startPoint: .bottom, endPoint: .top)
                        .opacity(opacity(week)))
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            if let average, average > 0 {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(Color.exTextSecondary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXScale(domain: BodyDates.anchor(weeks.first!.start)...BodyDates.anchor(weeks.last!.start.adding(days: 7)))
        .chartXAxis {
            // A label under its bar, centred on its week, counting back from this week. The last
            // week's end is a tick too, so the last bar has one to centre against.
            let every = max(1, Int((Double(weeks.count) / 4).rounded(.up)))
            let ticks = weeks.map { BodyDates.anchor($0.start) } + [BodyDates.anchor(weeks.last!.start.adding(days: 7))]
            AxisMarks(values: ticks) { value in
                if value.index < weeks.count, (weeks.count - 1 - value.index) % every == 0 {
                    AxisValueLabel(format: InsightFormat.axisFormat(span), centered: true).font(.exSmall).foregroundStyle(Color.exTextMuted)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Color.exBorder)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(metric == .volume ? number.formatted(.number.notation(.compactName)) : number.formatted())
                            .font(.exSmall).foregroundStyle(Color.exTextMuted)
                    }
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .chartPicking($scrub) { (date: Date) in
            let day = BodyDates.date(date)
            selection = weeks.last { $0.start <= day }?.start
        }
        .sensoryFeedback(.selection, trigger: selection)
        .environment(\.timeZone, BodyDates.utc).environment(\.calendar, calendar)
        .accessibilityElement(children: .ignore)
        .accessibilityChartDescriptor(WeeklyChartDescriptor(weeks: weeks, metric: metric, unit: unit, values: weeks.map(value)))
    }

    private func value(_ week: TrainingInsights.Week) -> Double {
        switch metric {
        case .workouts: Double(week.sessions)
        case .sets: week.sets
        case .volume: Mass.kg(week.tonnage.total).value(in: unit)
        }
    }

    /// UTC dates, with weeks starting where the report's weeks start.
    private var calendar: Calendar {
        var calendar = BodyDates.calendar
        calendar.firstWeekday = weeks.first?.start.weekday.rawValue ?? 2
        return calendar
    }

    private func opacity(_ week: TrainingInsights.Week) -> Double {
        if let selection { return week.start == selection ? 1 : 0.35 }
        return week.isPartial ? 0.4 : 1
    }
}

/// VoiceOver's audio graph and data table for the weekly bars.
private struct WeeklyChartDescriptor: AXChartDescriptorRepresentable {
    let weeks: [TrainingInsights.Week]
    let metric: TrainingConsistencyCard.WeeklyMetric
    let unit: MassUnit
    let values: [Double]

    func makeChartDescriptor() -> AXChartDescriptor {
        let labels = weeks.map { "Week of \(InsightFormat.shortDate($0.start))\($0.isPartial ? ", so far" : "")" }
        let x = AXCategoricalDataAxisDescriptor(title: "Week", categoryOrder: labels)
        let y = AXNumericDataAxisDescriptor(title: metric.rawValue, range: 0...max(values.max() ?? 1, 1), gridlinePositions: []) { value in
            switch metric {
            case .workouts: "\(value.formatted(.number.precision(.fractionLength(0)))) workouts"
            case .sets: "\(InsightFormat.sets(value)) sets"
            case .volume: InsightFormat.spokenVolume(Mass(value, unit).kilograms, unit)
            }
        }
        let series = AXDataSeriesDescriptor(name: "\(metric.rawValue) per week", isContinuous: false,
                                            dataPoints: zip(labels, values).map { AXDataPoint(x: $0.0, y: $0.1) })
        return AXChartDescriptor(title: "\(metric.rawValue) per week", summary: nil, xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}
