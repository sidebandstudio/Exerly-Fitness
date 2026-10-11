import Charts
import ExerlyCore
import SwiftUI

/// The spans the weight chart offers.
enum BodyRange: String, CaseIterable, Identifiable {
    case week = "1W", month = "1M", quarter = "3M", half = "6M", year = "1Y", all = "All"

    var id: String { rawValue }

    /// The span in days, ending today, so the week's change is the summary's
    /// "this week"; nil for everything.
    var days: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .quarter: 91
        case .half: 182
        case .year: 365
        case .all: nil
        }
    }

    var spoken: String {
        switch self {
        case .week: "1 week"
        case .month: "1 month"
        case .quarter: "3 months"
        case .half: "6 months"
        case .year: "1 year"
        case .all: "All time"
        }
    }

    /// "this week", "past 3 months", for sentences.
    var phrase: String {
        switch self {
        case .week: "past week"
        case .month: "past month"
        case .quarter: "past 3 months"
        case .half: "past 6 months"
        case .year: "past year"
        case .all: "all time"
        }
    }

    /// The span the chart really covers: the range's phrase, or "since
    /// Sep 13" when the trend starts after the range does.
    func phrase(start: LocalDate, firstShown: LocalDate?) -> String {
        guard let firstShown, firstShown > start else { return phrase }
        return "since \(BodyFormat.shortDate(firstShown))"
    }

    func start(today: LocalDate, first: LocalDate?) -> LocalDate {
        days.map { today.adding(days: -$0) } ?? first ?? today
    }

    var axisFormat: Date.FormatStyle {
        let style = Date.FormatStyle(timeZone: BodyDates.utc)
        return switch self {
        case .week: style.weekday(.abbreviated)
        case .month, .quarter: style.month(.abbreviated).day()
        case .half, .year: style.month(.abbreviated)
        case .all: style.month(.abbreviated).year(.twoDigits)
        }
    }
}

private extension View {
    /// Charts read their dates in UTC, where `BodyDates` anchors each local date.
    func bodyChartDates() -> some View {
        environment(\.timeZone, BodyDates.utc).environment(\.calendar, BodyDates.calendar)
    }
}

/// A small line of the trend with its band and the scale's dots, for cards.
struct WeightSparkline: View {
    let points: [WeightTrend.Point]
    let unit: MassUnit

    var body: some View {
        let domain = WeightTrend.domain(points, minimumSpan: 0.8) ?? 0...1
        Chart {
            ForEach(points) { point in
                AreaMark(x: .value("Day", BodyDates.anchor(point.date)),
                         yStart: .value("Low", Mass.kg(point.trend - point.trendError).value(in: unit)),
                         yEnd: .value("High", Mass.kg(point.trend + point.trendError).value(in: unit)))
                    .foregroundStyle(Color.exPrimary.opacity(0.16)).interpolationMethod(.monotone)
                LineMark(x: .value("Day", BodyDates.anchor(point.date)), y: .value("Trend", Mass.kg(point.trend).value(in: unit)))
                    .foregroundStyle(LinearGradient(colors: [.exPrimary, .exAccent], startPoint: .leading, endPoint: .trailing))
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)).interpolationMethod(.monotone)
                if let reading = point.reading {
                    PointMark(x: .value("Day", BodyDates.anchor(point.date)), y: .value("Scale", Mass.kg(reading).value(in: unit)))
                        .symbolSize(9).foregroundStyle(Color.exTextSecondary.opacity(0.55))
                }
            }
        }
        .chartYScale(domain: Mass.kg(domain.lowerBound).value(in: unit)...Mass.kg(domain.upperBound).value(in: unit))
        .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
        .bodyChartDates()
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(true)
    }
}

/// Scale readings as dots, the trend as a line inside its ±1 SD band, dashed
/// across gaps in the weigh-ins, the goal in force and the path it planned,
/// with a readout for the day under a finger.
struct WeightTrendChart: View {
    let points: [WeightTrend.Point]
    let readings: [WeightEntry]
    let unit: MassUnit
    let range: BodyRange
    var goals: [WeightGoal.Stretch] = []
    @Binding var selection: LocalDate?
    @State private var scrub: Date?

    private var line: [WeightTrend.Point] { WeightTrend.thinned(points, limit: 240) }

    /// The trend's runs, each thinned in proportion, so a gap keeps its edges.
    private var runs: [WeightTrend.Run] {
        let total = max(points.count, 1)
        return WeightTrend.runs(points).map { run in
            var run = run
            run.points = WeightTrend.thinned(run.points, limit: max(2, 240 * run.points.count / total))
            return run
        }
    }

    var body: some View {
        Chart {
            ForEach(line) { point in
                AreaMark(x: .value("Day", BodyDates.anchor(point.date)),
                         yStart: .value("Low", display(point.trend - point.trendError)),
                         yEnd: .value("High", display(point.trend + point.trendError)))
                    .foregroundStyle(Color.exPrimary.opacity(0.17)).interpolationMethod(.monotone)
            }
            ForEach(Array(shownGoals.enumerated()), id: \.offset) { index, goal in
                if let weight = goal.goal.goalWeight, drawsLine(goal) {
                    RuleMark(xStart: .value("Day", BodyDates.anchor(clamp(goal.start))),
                             xEnd: .value("Day", BodyDates.anchor(clamp(goal.end))), y: .value("Goal", display(weight.kilograms)))
                        .foregroundStyle(Color.exAccent.opacity(0.75)).lineStyle(StrokeStyle(lineWidth: 1.2, dash: [2, 3]))
                }
                ForEach(path(goal), id: \.self) { day in
                    LineMark(x: .value("Day", BodyDates.anchor(day)), y: .value("Plan", display(goal.planned(on: day))),
                             series: .value("Series", "Plan \(index)"))
                        .foregroundStyle(Color.exTextSecondary.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [5, 4]))
                }
            }
            ForEach(readings) { entry in
                PointMark(x: .value("Day", BodyDates.anchor(entry.date)), y: .value("Scale", entry.weight.value(in: unit)))
                    .symbolSize(dotSize).foregroundStyle(Color.exTextSecondary.opacity(selection == nil ? 0.6 : 0.35))
            }
            // One series per run, all under the same gradient, so the line is one
            // colour sweep; across a gap it's dashed and fainter, never dotted with readings.
            ForEach(Array(runs.enumerated()), id: \.offset) { index, run in
                ForEach(run.points) { point in
                    LineMark(x: .value("Day", BodyDates.anchor(point.date)), y: .value("Trend", display(point.trend)),
                             series: .value("Series", "Trend \(index)"))
                        .foregroundStyle(LinearGradient(colors: [.exPrimary, .exAccent], startPoint: .leading, endPoint: .trailing))
                        .opacity(run.measured ? 1 : 0.55)
                        .lineStyle(run.measured ? StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)
                            : StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [4, 4]))
                        .interpolationMethod(.monotone)
                }
            }
            if let selected = selection.flatMap({ day in points.first { $0.date == day } }) {
                RuleMark(x: .value("Day", BodyDates.anchor(selected.date)))
                    .foregroundStyle(Color.exTextMuted.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(x: .value("Day", BodyDates.anchor(selected.date)), y: .value("Trend", display(selected.trend)))
                    .symbolSize(70).foregroundStyle(Color.exAccent)
                    .symbol { Circle().fill(Color.exAccent).frame(width: 10, height: 10).overlay(Circle().stroke(Color.exSurface1, lineWidth: 2)) }
            }
            // Today's goal weight is named: on its line, or at the edge it lies beyond.
            if let goal = shownGoals.last, let weight = goal.goal.goalWeight?.kilograms, let lastDay {
                let onChart = drawsLine(goal)
                let below = weight < domain.lowerBound
                PointMark(x: .value("Day", BodyDates.anchor(lastDay)),
                          y: .value("Goal", display(onChart ? weight : below ? domain.lowerBound : domain.upperBound)))
                    .opacity(0)
                    .annotation(position: onChart || below ? .top : .bottom, alignment: .trailing, spacing: 2) {
                        Text("Goal \(BodyFormat.weight(weight, unit))\(onChart ? "" : below ? " ↓" : " ↑")")
                            .font(.exSmall.weight(.semibold)).foregroundStyle(Color.exAccent)
                    }
            }
        }
        .chartYScale(domain: display(domain.lowerBound)...display(domain.upperBound))
        .chartXScale(domain: BodyDates.anchor(points.first?.date ?? LocalDate(Date(), in: BodyDates.utc))
                     ... BodyDates.anchor(points.last?.date ?? LocalDate(Date(), in: BodyDates.utc)))
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: range == .week ? 7 : 4)) { value in
                AxisGridLine().foregroundStyle(Color.clear)
                AxisValueLabel(format: range.axisFormat, centered: false).font(.exSmall).foregroundStyle(Color.exTextMuted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Color.exBorder)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(number.formatted(.number.precision(.fractionLength(0...1)))).font(.exSmall)
                            .foregroundStyle(Color.exTextMuted)
                    }
                }
            }
        }
        // Axis labels stay readable without overlapping; VoiceOver reads the descriptor.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .chartXSelection(value: $scrub)
        .onChange(of: scrub) { _, date in
            selection = date.map { nearest(BodyDates.date($0)) } ?? nil
        }
        .sensoryFeedback(.selection, trigger: selection)
        .bodyChartDates()
        // One summarised element with an audio graph, not one per mark.
        .accessibilityElement(children: .ignore)
        .accessibilityChartDescriptor(WeightChartDescriptor(points: points, unit: unit, goals: shownGoals))
    }

    private var dotSize: CGFloat {
        switch range {
        case .week: 46
        case .month: 26
        case .quarter: 16
        default: 9
        }
    }

    private func display(_ kilograms: Double) -> Double { Mass.kg(kilograms).value(in: unit) }

    private var firstDay: LocalDate? { points.first?.date }
    private var lastDay: LocalDate? { points.last?.date }

    private func clamp(_ date: LocalDate) -> LocalDate {
        guard let firstDay, let lastDay else { return date }
        return min(max(date, firstDay), lastDay)
    }

    /// Goals in force on a day the chart shows.
    private var shownGoals: [WeightGoal.Stretch] {
        guard let firstDay, let lastDay else { return [] }
        return goals.filter { $0.end >= firstDay && $0.start <= lastDay }
    }

    /// The days a goal's path is drawn through on the chart: every few days and its ends.
    private func path(_ goal: WeightGoal.Stretch) -> [LocalDate] {
        let start = clamp(max(goal.anchor, goal.start)), end = clamp(goal.end)
        guard start < end else { return [] }
        let step = max(1, start.days(until: end) / 40)
        return Array(stride(from: 0, to: start.days(until: end), by: step).map { start.adding(days: $0) }) + [end]
    }

    /// The trend's band and readings: what the goal line must not squash.
    private var dataDomain: ClosedRange<Double> {
        let base = WeightTrend.domain(points, minimumSpan: unit == .pounds ? 0.9 : 0.6) ?? 70...71
        let values = readings.map(\.weight.kilograms)
        return min(base.lowerBound, (values.min() ?? .infinity) - 0.1)...max(base.upperBound, (values.max() ?? -.infinity) + 0.1)
    }

    /// A goal weight draws as a line across the days it was in force when
    /// that's at least a day of the chart and within the data's own height of
    /// it; farther, it would flatten the trend, and the goal card has it.
    private func drawsLine(_ goal: WeightGoal.Stretch) -> Bool {
        guard let kilograms = goal.goal.goalWeight?.kilograms, clamp(goal.start) < clamp(goal.end) else { return false }
        let data = dataDomain, span = data.upperBound - data.lowerBound
        return kilograms >= data.lowerBound - span && kilograms <= data.upperBound + span
    }

    /// The data, widened to the planned paths and the goal weights shown.
    private var domain: ClosedRange<Double> {
        var values = [dataDomain.lowerBound, dataDomain.upperBound]
        for goal in shownGoals {
            values += path(goal).map { goal.planned(on: $0) }
            if let weight = goal.goal.goalWeight?.kilograms, drawsLine(goal) { values.append(weight) }
        }
        let low = values.min() ?? 70, high = values.max() ?? 71
        let pad = (high - low) > (dataDomain.upperBound - dataDomain.lowerBound) ? (high - low) * 0.04 : 0
        return (low - pad)...(high + pad)
    }

    private func nearest(_ date: LocalDate) -> LocalDate? {
        guard let first = points.first?.date, let last = points.last?.date else { return nil }
        return min(max(date, first), last)
    }
}

/// The same days' expenditure with its band.
struct ExpenditureChart: View {
    let points: [WeightTrend.Point]
    let range: BodyRange

    var body: some View {
        let values = points.flatMap { [$0.expenditure - $0.expenditureError, $0.expenditure + $0.expenditureError] }
        // At least 500 kcal tall, so a drift of a few dozen calories doesn't look like a cliff.
        let middle = ((values.min() ?? 0) + (values.max() ?? 1)) / 2
        let half = max(((values.max() ?? 1) - (values.min() ?? 0)) / 2, 250)
        let low = ((middle - half) / 50).rounded(.down) * 50
        let high = ((middle + half) / 50).rounded(.up) * 50
        Chart {
            ForEach(WeightTrend.thinned(points, limit: 200)) { point in
                AreaMark(x: .value("Day", BodyDates.anchor(point.date)),
                         yStart: .value("Low", point.expenditure - point.expenditureError),
                         yEnd: .value("High", point.expenditure + point.expenditureError))
                    .foregroundStyle(Color.exAccent.opacity(0.15)).interpolationMethod(.monotone)
                LineMark(x: .value("Day", BodyDates.anchor(point.date)), y: .value("Expenditure", point.expenditure),
                         series: .value("Series", "Expenditure"))
                    .foregroundStyle(Color.exAccent).lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: low...high)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: range.axisFormat, centered: false).font(.exSmall).foregroundStyle(Color.exTextMuted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Color.exBorder)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(number.formatted(.number.precision(.fractionLength(0)))).font(.exSmall).foregroundStyle(Color.exTextMuted)
                    }
                }
            }
        }
        .bodyChartDates()
        .accessibilityElement(children: .ignore)
        .accessibilityChartDescriptor(ExpenditureChartDescriptor(points: points))
    }
}

/// VoiceOver's audio graph and data table for the trend.
struct WeightChartDescriptor: AXChartDescriptorRepresentable {
    let points: [WeightTrend.Point]
    let unit: MassUnit
    var goals: [WeightGoal.Stretch] = []

    func makeChartDescriptor() -> AXChartDescriptor {
        let values = points.map { Mass.kg($0.trend).value(in: unit) }
        let dates = points.map { BodyFormat.shortDate($0.date) }
        let x = AXNumericDataAxisDescriptor(title: "Day", range: 0...Double(max(points.count - 1, 1)), gridlinePositions: []) { index in
            dates.indices.contains(Int(index)) ? dates[Int(index)] : ""
        }
        let y = AXNumericDataAxisDescriptor(title: "Trend weight", range: (values.min() ?? 0)...(values.max() ?? 1),
                                            gridlinePositions: []) { "\(BodyFormat.number($0)) \(BodyFormat.unitName(unit))" }
        let trend = AXDataSeriesDescriptor(name: "Trend weight", isContinuous: true,
                                           dataPoints: values.enumerated().map { AXDataPoint(x: Double($0.offset), y: $0.element) })
        let scale = AXDataSeriesDescriptor(name: "Scale readings", isContinuous: false, dataPoints: points.enumerated().compactMap { index, point in
            point.reading.map { AXDataPoint(x: Double(index), y: Mass.kg($0).value(in: unit)) }
        })
        let plan = AXDataSeriesDescriptor(name: "Planned path", isContinuous: true, dataPoints: points.enumerated().compactMap { index, point in
            goals.last { $0.anchor <= point.date && $0.end >= point.date }
                .map { AXDataPoint(x: Double(index), y: Mass.kg($0.planned(on: point.date)).value(in: unit)) }
        })
        return AXChartDescriptor(title: "Weight trend", summary: nil, xAxis: x, yAxis: y, additionalAxes: [],
                                 series: [trend, scale] + (plan.dataPoints.isEmpty ? [] : [plan]))
    }
}

struct ExpenditureChartDescriptor: AXChartDescriptorRepresentable {
    let points: [WeightTrend.Point]

    func makeChartDescriptor() -> AXChartDescriptor {
        let dates = points.map { BodyFormat.shortDate($0.date) }
        let values = points.map(\.expenditure)
        let x = AXNumericDataAxisDescriptor(title: "Day", range: 0...Double(max(points.count - 1, 1)), gridlinePositions: []) { index in
            dates.indices.contains(Int(index)) ? dates[Int(index)] : ""
        }
        let y = AXNumericDataAxisDescriptor(title: "Expenditure", range: (values.min() ?? 0)...(values.max() ?? 1),
                                            gridlinePositions: []) { "\(BodyFormat.kcal($0)) kilocalories a day" }
        let series = AXDataSeriesDescriptor(name: "Expenditure", isContinuous: true,
                                            dataPoints: values.enumerated().map { AXDataPoint(x: Double($0.offset), y: $0.element) })
        return AXChartDescriptor(title: "Expenditure", summary: nil, xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}
