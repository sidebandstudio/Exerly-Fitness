import Charts
import ExerlyCore
import SwiftUI

/// One lift over a span: a chart of any per-session measure with its trend,
/// MacroFactor's exercise statistics, the best sets and the records.
struct LiftDetailView: View {
    let store: TrainingStore
    let exerciseID: ExerciseID
    let unit: MassUnit
    let timeZone: TimeZone
    @State private var span: TrainingInsights.Span
    @State private var report: TrainingInsights.LiftReport?
    @State private var metric: LiftMetric = .oneRepMax
    @State private var selected: UUID?
    @Environment(\.dynamicTypeSize) private var typeSize

    init(store: TrainingStore, exerciseID: ExerciseID, unit: MassUnit, timeZone: TimeZone, initialSpan: TrainingInsights.Span) {
        self.store = store
        self.exerciseID = exerciseID
        self.unit = unit
        self.timeZone = timeZone
        _span = State(initialValue: initialSpan)
    }

    private struct Input: Hashable {
        let history: TrainingAnalysisInput
        let span: TrainingInsights.Span
        let today: LocalDate
    }

    private var exercise: ExerlyCore.Exercise? { store.library.exercise(exerciseID) }

    var body: some View {
        let today = LocalDate(Date(), in: timeZone)
        let history = store.history
        ExScreen {
            InsightSpanPicker(span: $span, identifier: "liftDetail.span")
            if let report {
                if report.sessions.isEmpty {
                    ExCard {
                        Text("No \(exercise?.name ?? "sets") in \(InsightFormat.spanPhrase(span))").font(.exH3)
                        Text("Choose a longer span to see earlier sessions.").font(.exBody).foregroundStyle(Color.exTextSecondary)
                    }
                } else {
                    chartCard(report, today: today)
                    if let statistics = report.statistics { stats(statistics, sessions: report.sessions.count) }
                    bestSets(report.bestSets, today: today)
                    RecordsSection(records: report.records, span: span, library: store.library, unit: unit, today: today,
                                   identifier: "liftDetail.records", showsExercise: false)
                }
                NavigationLink {
                    ExerciseLogView(store: store, exerciseID: exerciseID, unit: unit)
                } label: {
                    ExNavigationLabel(title: "Every logged set", icon: "list.bullet.rectangle",
                                      detail: "All sessions, with RIR and bodyweight")
                        .padding(.horizontal, ExSpacing.content).padding(.vertical, ExSpacing.tight)
                        .background(Color.exSurface1, in: RoundedRectangle(cornerRadius: ExRadius.card, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("liftDetail.log")
                Text(InsightCopy.estimateMethod).font(.exCaption).foregroundStyle(Color.exTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LoadingStateView(message: "Reading your sessions…").frame(height: 200)
            }
        }
        .navigationTitle(exercise?.name ?? "Lift").navigationBarTitleDisplayMode(.inline)
        .task(id: Input(history: TrainingAnalysisInput(history), span: span, today: today)) {
            let id = exerciseID, span = span, weekday = TrainingInsightsModel.firstWeekday
            let result = await Task.detached(priority: .userInitiated) {
                TrainingInsights.liftReport(id, in: history, span: span, through: today, firstWeekday: weekday)
            }.value
            guard !Task.isCancelled else { return }
            selected = nil
            report = result
        }
    }

    // MARK: Chart

    private func chartCard(_ report: TrainingInsights.LiftReport, today: LocalDate) -> some View {
        let sessions = report.sessions
        let picked = selected.flatMap { id in sessions.first { $0.sessionID == id } }
        let shown = picked ?? sessions.last!
        let tracksLoad = exercise?.metric.tracksLoad ?? true
        // With no session picked, the e1RM is where the trend stands now.
        let now = picked == nil && metric == .oneRepMax ? report.summary.map { Mass.kg($0.current).value(in: unit) } : nil
        let value = now ?? metric.value(shown, unit: unit)
        let detail = now != nil ? currentLine(report, today: today) : sessionLine(shown, isLatest: picked == nil, today: today)
        return ExCard {
            ExEyebrow(metric.title)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value.map { metric.format($0, unit: unit) } ?? "–")
                        .font(.exStat).monospacedDigit().foregroundStyle(Color.exTextPrimary)
                        .contentTransition(.numericText())
                    Text(metric.suffix(unit)).font(.exBodyMedium).foregroundStyle(Color.exTextSecondary)
                }
                Text(detail).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(metric.title)\(now != nil ? " now" : ""), \(value.map { metric.spoken($0, unit: unit) } ?? "not recorded"). \(detail)")
            .accessibilityIdentifier(metric == .oneRepMax ? "liftDetail.estimate" : "liftDetail.readout")
            if metric == .oneRepMax, picked == nil { trendLine(report.summary) }
            ExChoiceChips(values: LiftMetric.allCases.filter { tracksLoad || !$0.needsLoad }, selection: $metric) { $0.chip }
                .onChange(of: metric) { _, _ in selected = nil }
            if sessions.count >= 2 {
                LiftChart(sessions: sessions, metric: metric, unit: unit, span: span,
                          trend: metric == .oneRepMax ? report.summary?.trendLine : nil, selection: $selected)
                    .frame(height: typeSize.isAccessibilitySize ? 260 : 210)
                    .accessibilityLabel("\(metric.title) by session, \(InsightFormat.spokenSpan(span))")
                    .accessibilityValue(chartSummary(sessions))
                    .accessibilityIdentifier("liftDetail.chart")
            } else {
                Text("The chart starts with a second session in this span.").font(.exCaption).foregroundStyle(Color.exTextSecondary)
            }
        }
    }

    private func currentLine(_ report: TrainingInsights.LiftReport, today: LocalDate) -> String {
        guard let summary = report.summary else { return "" }
        // The headline is the trend's estimate; the best set's own e1RM is
        // labelled as such, as the Stats tile is, so 142 and 141 don't read as a disagreement.
        let basis = summary.trend == nil ? "Last session" : "Trend estimate"
        return "\(basis) · best set e1RM \(InsightFormat.estimate(summary.best.oneRepMax, unit)) "
            + "\(InsightFormat.day(summary.best.date, today: today).lowercased().hasPrefix("to") ? "today" : "on " + InsightFormat.day(summary.best.date, today: today))"
            + (exercise?.metric.usesBodyweight == true ? " · includes bodyweight" : "")
    }

    private func sessionLine(_ session: TrainingInsights.LiftSession, isLatest: Bool, today: LocalDate) -> String {
        let day = InsightFormat.day(session.date, today: today)
        let relative = session.date >= today.adding(days: -1)
        var parts = [isLatest ? "Last session \(relative ? day.lowercased() : "on " + day)" : day]
        if let best = session.bestSet {
            parts.append("best set \(InsightFormat.set(best, unit: unit, bodyweight: exercise?.metric.usesBodyweight == true))")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func trendLine(_ summary: TrainingInsights.LiftSummary?) -> some View {
        if let summary, let trend = summary.trend, let change = summary.change {
            let tone = LiftTone.color(change, unit: unit)
            let arrow = Text(Image(systemName: LiftTone.symbol(change, unit: unit))).foregroundStyle(tone)
            let gain = Text(verbatim: "\(InsightFormat.change(change, unit)) over \(InsightFormat.sessions(trend.sessions))").foregroundStyle(tone)
            let rate = Text(verbatim: "· \(InsightFormat.rate(trend.slopePerWeek, unit)) a week").foregroundStyle(Color.exTextSecondary)
            Text("\(arrow) \(gain) \(rate)")
            .font(.exLabel).monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(tone.opacity(0.12), in: RoundedRectangle(cornerRadius: ExRadius.control, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Trend \(InsightFormat.spokenChange(change, unit)) over \(InsightFormat.sessions(trend.sessions)), "
                + InsightFormat.spokenRate(trend.slopePerWeek, unit))
            .accessibilityIdentifier("liftDetail.trend")
        } else if let summary {
            Text("A trend needs 3 sessions in the span; this has \(summary.sessions).")
                .font(.exCaption).foregroundStyle(Color.exTextSecondary)
        }
    }

    private func chartSummary(_ sessions: [TrainingInsights.LiftSession]) -> String {
        let values = sessions.compactMap { metric.value($0, unit: unit) }
        guard let first = values.first, let last = values.last, let low = values.min(), let high = values.max() else { return "" }
        return "\(sessions.count) sessions. First \(metric.spoken(first, unit: unit)), last \(metric.spoken(last, unit: unit)). "
            + "Range \(metric.spoken(low, unit: unit)) to \(metric.spoken(high, unit: unit))."
    }

    // MARK: Statistics

    private func stats(_ statistics: ExerciseStatistics, sessions: Int) -> some View {
        var items: [(String, String, String)] = []
        func mass(_ title: String, _ value: Mass?) {
            guard let value else { return }
            items.append((title, InsightFormat.estimate(value.kilograms, unit), InsightFormat.spokenEstimate(value.kilograms, unit)))
        }
        mass("Best e1RM", statistics.estimatedOneRepMax)
        mass("Est. 3RM", statistics.estimatedThreeRepMax)
        mass("Est. 10RM", statistics.estimatedTenRepMax)
        if let heaviest = statistics.heaviestLoad {
            items.append(("Heaviest", InsightFormat.load(heaviest.kilograms, unit), "\(InsightFormat.load(heaviest.kilograms, unit, withUnit: false)) \(InsightFormat.unitName(unit))"))
        }
        if statistics.totalVolume > 0 {
            items.append(("Best set volume", InsightFormat.volume(statistics.bestSetVolume, unit), InsightFormat.spokenVolume(statistics.bestSetVolume, unit)))
            items.append(("Total volume", InsightFormat.volume(statistics.totalVolume, unit), InsightFormat.spokenVolume(statistics.totalVolume, unit)))
        }
        items.append(("Total reps", statistics.totalReps.formatted(), "\(statistics.totalReps) reps"))
        items.append(("Working sets", "\(statistics.totalSets)", "\(statistics.totalSets) sets"))
        items.append(("Sessions", "\(sessions)", InsightFormat.sessions(sessions)))
        let columns = Array(repeating: GridItem(.flexible(), spacing: ExSpacing.item, alignment: .topLeading),
                            count: typeSize.isAccessibilitySize ? 1 : 3)
        return VStack(alignment: .leading, spacing: ExSpacing.item) {
            ExSectionHeading("Stats", detail: span == .all ? "all time" : "in \(InsightFormat.spokenSpan(span))")
            ExCard {
                LazyVGrid(columns: columns, alignment: .leading, spacing: ExSpacing.content) {
                    ForEach(items, id: \.0) { title, value, spoken in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                            Text(value).font(.exStatSmall).monospacedDigit().foregroundStyle(Color.exTextPrimary)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(title), \(spoken)")
                    }
                }
                if !statistics.isVolumeComplete {
                    Text("Some sets had no bodyweight recorded, so volume leaves their bodyweight out.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liftDetail.stats")
    }

    // MARK: Best sets

    @ViewBuilder
    private func bestSets(_ sets: [TrainingInsights.RankedSet], today: LocalDate) -> some View {
        if !sets.isEmpty {
            VStack(alignment: .leading, spacing: ExSpacing.item) {
                ExSectionHeading("Best sets", detail: "by estimated 1RM")
                InsightList {
                    ForEach(Array(sets.enumerated()), id: \.offset) { index, ranked in
                        if index > 0 { InsightDivider() }
                        let day = InsightFormat.day(ranked.record.date, today: today)
                        let set = InsightFormat.set(ranked.record.set, unit: unit, bodyweight: exercise?.metric.usesBodyweight == true)
                        HStack(spacing: ExSpacing.item) {
                            Text("\(index + 1)").font(.exStatSmall).monospacedDigit().foregroundStyle(Color.exPrimaryText)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(set).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary).fixedSize(horizontal: false, vertical: true)
                                Text(day).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                            }
                            Spacer(minLength: ExSpacing.small)
                            VStack(alignment: .trailing, spacing: 0) {
                                Text(InsightFormat.estimate(ranked.oneRepMax, unit, withUnit: false)).font(.exStatSmall).monospacedDigit()
                                    .foregroundStyle(Color.exTextPrimary)
                                Text("\(unit.rawValue) e1RM").font(.exSmall).foregroundStyle(Color.exTextMuted)
                            }
                        }
                        .padding(.vertical, ExSpacing.item)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Number \(index + 1): \(set.replacingOccurrences(of: "×", with: "for")), \(day), "
                            + "estimated 1RM \(InsightFormat.spokenEstimate(ranked.oneRepMax, unit))")
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("liftDetail.bestSets")
        }
    }
}

/// An exercise's history on its library page: where its estimated 1RM
/// stands and trends, the last sessions, and a way into the lift's detail.
struct ExerciseHistorySection: View {
    let store: TrainingStore
    let exerciseID: ExerciseID
    let unit: MassUnit
    let timeZone: TimeZone
    @State private var report: TrainingInsights.LiftReport?
    @State private var selected: UUID?

    private let shownSessions = 3

    var body: some View {
        let today = LocalDate(Date(), in: timeZone)
        let history = store.history
        let exercise = store.library.exercise(exerciseID)
        ExCard {
            ExSectionHeading("Your history", detail: report.flatMap { $0.sessions.isEmpty ? nil : InsightFormat.sessions($0.sessions.count) })
            if let report {
                if report.sessions.isEmpty {
                    Text("Nothing logged yet. After a workout with this exercise, your sessions and estimated 1RM show here.")
                        .font(.exBody).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("exerciseHistory.empty")
                } else {
                    if let summary = report.summary { estimate(summary) }
                    if report.summary != nil, report.sessions.count >= 2 {
                        LiftChart(sessions: report.sessions, metric: .oneRepMax, unit: unit, span: axisSpan(report, today: today),
                                  trend: report.summary?.trendLine, selection: $selected)
                            .frame(height: 150)
                            .accessibilityLabel("Estimated 1RM by session")
                            .accessibilityIdentifier("exerciseHistory.chart")
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(report.sessions.suffix(shownSessions).reversed().enumerated()), id: \.element.sessionID) { index, session in
                            if index > 0 { Divider().overlay(Color.exBorder.opacity(0.35)) }
                            sessionRow(session, today: today, bodyweight: exercise?.metric.usesBodyweight == true)
                        }
                    }
                    NavigationLink {
                        LiftDetailView(store: store, exerciseID: exerciseID, unit: unit, timeZone: timeZone, initialSpan: .threeMonths)
                    } label: {
                        ExNavigationLabel(title: "All sessions and records", icon: "chart.xyaxis.line")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("exerciseHistory.detail")
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 60).accessibilityLabel("Reading your sessions")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("exerciseHistory")
        .task(id: TrainingAnalysisInput(history)) {
            let id = exerciseID, weekday = TrainingInsightsModel.firstWeekday
            let result = await Task.detached(priority: .userInitiated) {
                TrainingInsights.liftReport(id, in: history, span: .all, through: today, firstWeekday: weekday)
            }.value
            guard !Task.isCancelled else { return }
            report = result
        }
    }

    /// The shortest span covering every session, for the axis's date labels.
    private func axisSpan(_ report: TrainingInsights.LiftReport, today: LocalDate) -> TrainingInsights.Span {
        let days = report.sessions.first.map { $0.date.days(until: today) } ?? 0
        return days < 28 ? .fourWeeks : days < 91 ? .threeMonths : days < 365 ? .year : .all
    }

    private func estimate(_ summary: TrainingInsights.LiftSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(InsightFormat.estimate(summary.current, unit, withUnit: false)).font(.exStat).monospacedDigit()
                    .foregroundStyle(Color.exTextPrimary)
                Text("\(unit.rawValue) estimated 1RM").font(.exBodyMedium).foregroundStyle(Color.exTextSecondary)
            }
            if let change = summary.change, let trend = summary.trend {
                Text("\(InsightFormat.change(change, unit)) over \(InsightFormat.sessions(trend.sessions))")
                    .font(.exLabel).foregroundStyle(LiftTone.color(change, unit: unit))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Estimated 1RM \(InsightFormat.spokenEstimate(summary.current, unit))"
            + ((summary.change).map { ", \(InsightFormat.spokenChange($0, unit)) over \(InsightFormat.sessions(summary.trend?.sessions ?? summary.sessions))" } ?? ""))
        .accessibilityIdentifier("exerciseHistory.estimate")
    }

    private func sessionRow(_ session: TrainingInsights.LiftSession, today: LocalDate, bodyweight: Bool) -> some View {
        let day = InsightFormat.day(session.date, today: today)
        let sets = session.statistics.totalSets == 1 ? "1 set" : "\(session.statistics.totalSets) sets"
        let best = session.bestSet.map { InsightFormat.set($0, unit: unit, bodyweight: bodyweight) }
        return HStack(alignment: .firstTextBaseline, spacing: ExSpacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text(day).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                Text(sets).font(.exCaption).foregroundStyle(Color.exTextSecondary)
            }
            Spacer(minLength: ExSpacing.small)
            if let best {
                Text(best).font(.system(.subheadline, design: .rounded, weight: .medium)).foregroundStyle(Color.exTextPrimary)
                    .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, ExSpacing.small)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(day), \(sets)\(best.map { ", best set \($0.replacingOccurrences(of: "×", with: "for"))" } ?? "")")
    }
}

/// What the lift chart can plot, one value per session.
enum LiftMetric: String, CaseIterable, Identifiable, Hashable {
    case oneRepMax, heaviest, bestSetVolume, volume, reps
    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneRepMax: "Estimated 1RM"
        case .heaviest: "Heaviest"
        case .bestSetVolume: "Best set"
        case .volume: "Volume"
        case .reps: "Reps"
        }
    }

    var chip: String {
        switch self {
        case .oneRepMax: "e1RM"
        case .heaviest: "Heaviest"
        case .bestSetVolume: "Best set"
        case .volume: "Volume"
        case .reps: "Reps"
        }
    }

    var needsLoad: Bool { self != .reps }

    /// The session's value in the display unit.
    func value(_ session: TrainingInsights.LiftSession, unit: MassUnit) -> Double? {
        let statistics = session.statistics
        switch self {
        case .oneRepMax: return session.bestSetOneRepMax.map { Mass.kg($0).value(in: unit) }
        case .heaviest: return statistics.heaviestLoad?.value(in: unit)
        case .bestSetVolume: return statistics.bestSetVolume > 0 ? Mass.kg(statistics.bestSetVolume).value(in: unit) : nil
        case .volume: return statistics.totalVolume > 0 ? Mass.kg(statistics.totalVolume).value(in: unit) : nil
        case .reps: return Double(statistics.totalReps)
        }
    }

    func format(_ value: Double, unit: MassUnit) -> String {
        switch self {
        case .oneRepMax: InsightFormat.estimate(Mass(value, unit).kilograms, unit, withUnit: false)
        case .heaviest: InsightFormat.load(Mass(value, unit).kilograms, unit, withUnit: false)
        case .bestSetVolume, .volume: InsightFormat.volume(Mass(value, unit).kilograms, unit, withUnit: false)
        case .reps: value.formatted(.number.precision(.fractionLength(0)))
        }
    }

    func suffix(_ unit: MassUnit) -> String {
        switch self {
        case .oneRepMax, .heaviest: unit.rawValue
        case .bestSetVolume, .volume: "\(unit.rawValue) moved"
        case .reps: "reps"
        }
    }

    func spoken(_ value: Double, unit: MassUnit) -> String {
        switch self {
        case .reps: "\(Int(value.rounded())) reps"
        case .bestSetVolume, .volume: InsightFormat.spokenVolume(Mass(value, unit).kilograms, unit)
        default: "\(format(value, unit: unit)) \(InsightFormat.unitName(unit))"
        }
    }
}

/// Session values as a line with dots; the e1RM's fitted trend dashed.
private struct LiftChart: View {
    let sessions: [TrainingInsights.LiftSession]
    let metric: LiftMetric
    let unit: MassUnit
    let span: TrainingInsights.Span
    let trend: TrainingInsights.TrendLine?
    @Binding var selection: UUID?
    @State private var scrub: Date?

    private var points: [(session: TrainingInsights.LiftSession, value: Double)] {
        sessions.compactMap { session in metric.value(session, unit: unit).map { (session, $0) } }
    }

    private var firstDay: LocalDate { sessions.first?.date ?? LocalDate(Date(), in: BodyDates.utc) }
    private var lastDay: LocalDate { sessions.last?.date ?? firstDay }

    /// The first session's noon to the last's; a day either side when they share one.
    private var xDomain: ClosedRange<Date> {
        firstDay == lastDay ? BodyDates.anchor(firstDay.adding(days: -1))...BodyDates.anchor(lastDay.adding(days: 1))
            : BodyDates.anchor(firstDay)...BodyDates.anchor(lastDay)
    }

    private var axisDays: [LocalDate] { LocalDate.evenlySpaced(from: firstDay, through: lastDay, count: 4) }

    var body: some View {
        let points = points
        let values = points.map(\.value) + [trend?.startValue, trend?.endValue].compactMap { $0.map { Mass.kg($0).value(in: unit) } }
        let low = values.min() ?? 0, high = values.max() ?? 1
        let pad = max((high - low) * 0.12, high * 0.01, 1)
        let picked = selection.flatMap { id in points.first { $0.session.sessionID == id } }
        Chart {
            ForEach(points, id: \.session.sessionID) { point in
                LineMark(x: .value("Day", BodyDates.anchor(point.session.date)), y: .value(metric.title, point.value),
                         series: .value("Series", "Sessions"))
                    .foregroundStyle(trend == nil
                        ? AnyShapeStyle(LinearGradient(colors: [.exPrimary, .exAccent], startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(Color.exPrimary.opacity(0.45)))
                    .lineStyle(StrokeStyle(lineWidth: trend == nil ? 2.4 : 1.4, lineCap: .round, lineJoin: .round))
                PointMark(x: .value("Day", BodyDates.anchor(point.session.date)), y: .value(metric.title, point.value))
                    .symbolSize(points.count > 40 ? 10 : 24)
                    .foregroundStyle(Color.exPrimary.opacity(picked == nil ? 0.9 : 0.4))
            }
            if let trend {
                LineMark(x: .value("Day", BodyDates.anchor(trend.start)), y: .value("Trend", Mass.kg(trend.startValue).value(in: unit)),
                         series: .value("Series", "Trend"))
                    .foregroundStyle(LinearGradient(colors: [.exPrimary, .exAccent], startPoint: .leading, endPoint: .trailing))
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                LineMark(x: .value("Day", BodyDates.anchor(trend.end)), y: .value("Trend", Mass.kg(trend.endValue).value(in: unit)),
                         series: .value("Series", "Trend"))
                    .foregroundStyle(LinearGradient(colors: [.exPrimary, .exAccent], startPoint: .leading, endPoint: .trailing))
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            if let picked {
                RuleMark(x: .value("Day", BodyDates.anchor(picked.session.date)))
                    .foregroundStyle(Color.exTextMuted.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(x: .value("Day", BodyDates.anchor(picked.session.date)), y: .value(metric.title, picked.value))
                    .symbol { Circle().fill(Color.exAccent).frame(width: 10, height: 10).overlay(Circle().stroke(Color.exSurface1, lineWidth: 2)) }
            }
        }
        .chartYScale(domain: max(0, low - pad)...(high + pad))
        .chartXScale(domain: xDomain)
        .chartXAxis {
            // Marks from the first session to the last, so every point has a date under the span.
            AxisMarks(values: axisDays.map(BodyDates.anchor)) { value in
                AxisValueLabel(format: InsightFormat.axisFormat(span), centered: false,
                               anchor: value.index == 0 ? .topLeading : value.index == value.count - 1 ? .topTrailing : .top)
                    .font(.exSmall).foregroundStyle(Color.exTextMuted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Color.exBorder)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(number >= 10_000 ? number.formatted(.number.notation(.compactName)) : number.formatted(.number.precision(.fractionLength(0))))
                            .font(.exSmall).foregroundStyle(Color.exTextMuted)
                    }
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .chartXSelection(value: $scrub)
        .onChange(of: scrub) { _, date in
            selection = date.flatMap { date in
                let day = BodyDates.date(date)
                return points.min { abs($0.session.date.days(until: day)) < abs($1.session.date.days(until: day)) }?.session.sessionID
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
        .environment(\.timeZone, BodyDates.utc).environment(\.calendar, BodyDates.calendar)
        .accessibilityElement(children: .ignore)
        .accessibilityChartDescriptor(LiftChartDescriptor(points: points.map { ($0.session.date, $0.value) }, metric: metric, unit: unit))
    }
}

private struct LiftChartDescriptor: AXChartDescriptorRepresentable {
    let points: [(date: LocalDate, value: Double)]
    let metric: LiftMetric
    let unit: MassUnit

    func makeChartDescriptor() -> AXChartDescriptor {
        let dates = points.map { InsightFormat.shortDate($0.date) }
        let values = points.map(\.value)
        let x = AXNumericDataAxisDescriptor(title: "Session", range: 0...Double(max(points.count - 1, 1)), gridlinePositions: []) { index in
            dates.indices.contains(Int(index)) ? dates[Int(index)] : ""
        }
        let y = AXNumericDataAxisDescriptor(title: metric.title, range: (values.min() ?? 0)...max(values.max() ?? 1, (values.min() ?? 0) + 1),
                                            gridlinePositions: []) { metric.spoken($0, unit: unit) }
        let series = AXDataSeriesDescriptor(name: metric.title, isContinuous: true,
                                            dataPoints: values.enumerated().map { AXDataPoint(x: Double($0.offset), y: $0.element) })
        return AXChartDescriptor(title: metric.title, summary: nil, xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}

enum InsightCopy {
    static let estimateMethod = "Estimated 1RM comes from each set's weight, reps and reps in reserve (Brzycki to 10 reps to failure, "
        + "Epley above), so it's an estimate, not a tested max. The trend is a straight line fitted through each session's best. "
        + "Warm-ups never count."
}
