import ExerlyCore
import SwiftUI

/// Calories, macros and nutrients over time.
struct NutritionInsightsView: View {
    let workspace: TrainingWorkspace?
    let unit: MassUnit
    let timeZone: TimeZone

    var body: some View {
        if let workspace {
            NutritionInsightsContent(workspace: workspace, timeZone: timeZone)
        } else {
            LoadingStateView(message: "Opening your food log…")
        }
    }
}

/// Progress → Nutrition: a span ending yesterday, or this month so far, how
/// many of its days count as known intake, calories and macros against their
/// targets, the foods behind them, when they were eaten, and every nutrient
/// against its goal.
private struct NutritionInsightsContent: View {
    @ObservedObject var workspace: TrainingWorkspace
    let timeZone: TimeZone
    @AppStorage("nutrition.insightsRange") private var range: IntakeRange = .week
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let store = workspace.nutrition
        let today = LocalDate(Date(), in: timeZone)
        let span = range.span(today: today)
        let series = store.intakeSeries(from: span.lowerBound, through: span.upperBound)
        ScrollView {
            VStack(alignment: .leading, spacing: ExSpacing.page) {
                rangePicker(today: today)
                coverage(series, store: store, today: today)
                if series.countedDays > 0 {
                    let overview = store.overview(from: span.lowerBound, through: span.upperBound)
                    IntakeTrendCard(series: series, range: range, today: today)
                    topFoods(store: store, series: series, overview: overview, today: today)
                    timing(store: store, span: span)
                    NutrientGroupsView(overview: overview, series: series) { row in
                        NutrientDetailView(workspace: workspace, row: row, series: series, range: range, today: today, timeZone: timeZone)
                    }
                } else if !store.entries.isEmpty || store.days.values.contains(where: { $0.status == .fasting }) {
                    timing(store: store, span: span)
                }
            }
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, ExSpacing.page)
            .padding(.top, ExSpacing.small)
            .padding(.bottom, ExSpacing.major)
        }
        .scrollIndicators(.hidden)
        .exScrollEdges()
        .background(Color.exBackground)
        .refreshable { await workspace.synchronize() }
        .accessibilityIdentifier("nutrition.insights")
    }

    // MARK: Range

    @ViewBuilder
    private func rangePicker(today: LocalDate) -> some View {
        if typeSize.isAccessibilitySize {
            Picker("Span", selection: $range) {
                ForEach(IntakeRange.allCases) { Text(IntakeFormat.spoken($0)).tag($0) }
            }
            .pickerStyle(.menu).tint(Color.exPrimaryText).accessibilityIdentifier("nutrition.range")
        } else {
            HStack(spacing: 2) {
                ForEach(IntakeRange.allCases) { option in
                    Button { withAnimation(.snappy) { range = option } } label: {
                        Text(IntakeFormat.title(option, today: today)).font(.exLabel).lineLimit(1).minimumScaleFactor(0.8)
                            .fixedSize(horizontal: option == .yesterday, vertical: false)
                            .foregroundStyle(option == range ? Color.white : Color.exTextSecondary)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(option == range ? Color.exActionFill : .clear,
                                        in: RoundedRectangle(cornerRadius: ExRadius.control - 4))
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(IntakeFormat.spoken(option))
                    .accessibilityAddTraits(option == range ? .isSelected : [])
                    .accessibilityIdentifier("nutrition.range.\(option == .thisMonth ? "thisMonth" : IntakeFormat.title(option, today: today))")
                }
            }
            .padding(.horizontal, 3)
            .background(Color.exSurface2, in: RoundedRectangle(cornerRadius: ExRadius.control))
            .sensoryFeedback(.selection, trigger: range)
        }
    }

    // MARK: Coverage

    /// The span, how many of its days count, and why the rest don't.
    private func coverage(_ series: IntakeSeries, store: NutritionStore, today: LocalDate) -> some View {
        let fasts = series.fastedDays
        var reasons: [String] = []
        if series.partialDays > 0 { reasons.append("\(series.partialDays) partial") }
        if series.emptyDays > 0 { reasons.append("\(series.emptyDays) not logged") }
        if fasts > 0 { reasons.append("\(fasts == 1 ? "1 fast" : "\(fasts) fasts") counted as zero") }
        let firstLogged = store.entries.first?.date
        let caution = cautionText(series, firstLogged: firstLogged)
        return ExCard {
            VStack(alignment: .leading, spacing: ExSpacing.small) {
                let span = Text(IntakeFormat.span(series.from, series.through, today: today)).font(.exBodyMedium)
                    .foregroundStyle(Color.exTextPrimary)
                let counted = Text("\(series.countedDays) of \(IntakeFormat.days(series.days.count)) counted").font(.exLabel)
                    .monospacedDigit().foregroundStyle(series.countedDays > 0 ? Color.exTextPrimary : Color.exWarning)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        span.lineLimit(1)
                        Spacer(minLength: ExSpacing.small)
                        counted.lineLimit(1)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        span.fixedSize(horizontal: false, vertical: true)
                        counted.fixedSize(horizontal: false, vertical: true)
                    }
                }
                IntakeCoverageStrip(days: series.days)
                    .frame(height: series.days.count > 31 ? 12 : 10)
                if series.days.count > 1 {
                    legend(series, fasts: fasts).font(.exCaption).foregroundStyle(Color.exTextSecondary).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(IntakeFormat.spokenSpan(series.from, series.through, today: today)). "
                + "\(series.countedDays) of \(IntakeFormat.days(series.days.count)) counted"
                + (reasons.isEmpty ? "." : ", \(reasons.joined(separator: ", ")).") + (caution.map { " \($0)" } ?? ""))
            .accessibilityIdentifier("nutrition.coverage")
            if let caution {
                Label {
                    Text(caution)
                } icon: {
                    Image(systemName: series.countedDays == 0 ? "info.circle" : "exclamationmark.circle")
                        .foregroundStyle(series.countedDays == 0 ? Color.exPrimaryText : Color.exWarning)
                }
                .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            }
        }
    }

    /// The strip's colours with their counts.
    private func legend(_ series: IntakeSeries, fasts: Int) -> Text {
        // Each swatch keeps its words with it when the line wraps.
        func item(_ color: Color, _ words: String) -> Text {
            Text("\(Text(Image(systemName: "square.fill")).foregroundStyle(color))\u{00A0}\(words.replacingOccurrences(of: " ", with: "\u{00A0}"))")
        }
        var text = item(IntakeCoverageStrip.counted, "\(series.countedDays) counted")
        if series.partialDays > 0 { text = Text("\(text)   \(item(IntakeCoverageStrip.partial, "\(series.partialDays) partial"))") }
        if series.emptyDays > 0 { text = Text("\(text)   \(item(IntakeCoverageStrip.empty, "\(series.emptyDays) not logged"))") }
        if fasts > 0 { text = Text("\(text)   \(item(IntakeCoverageStrip.fast, "\(fasts == 1 ? "1 fast" : "\(fasts) fasts") as zero"))") }
        return text
    }

    /// A plain word about spans that are short or mostly unlogged.
    private func cautionText(_ series: IntakeSeries, firstLogged: LocalDate?) -> String? {
        if series.countedDays == 0 {
            guard firstLogged != nil else {
                return "Nothing is logged yet. Log food on Today; a day counts once it has food and isn't marked partial, "
                    + "or when you mark it as a fast."
            }
            return "No day in this span counts. A day counts once it has food and isn't marked partial, or when it's marked as a fast."
        }
        var notes: [String] = []
        if let firstLogged, firstLogged > series.from, firstLogged <= series.through {
            notes.append("Your log starts \(BodyFormat.shortDate(firstLogged)), partway into this span.")
        }
        if series.days.count > 1, series.countedDays * 2 < series.days.count {
            notes.append("Fewer than half of these days count, so the averages may not hold for the whole span.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    // MARK: Foods

    /// The foods that supplied the most calories, with a way into every nutrient's foods.
    @ViewBuilder
    private func topFoods(store: NutritionStore, series: IntakeSeries, overview: NutrientOverview, today: LocalDate) -> some View {
        let energy = store.contributions(of: .energy, from: series.from, through: series.through)
        if let row = overview.rows.first(where: { $0.nutrient == .energy }), !energy.foods.isEmpty {
            ExCard {
                HStack(alignment: .firstTextBaseline) {
                    ExEyebrow("Where calories came from", color: .exPrimaryText)
                    Spacer(minLength: ExSpacing.small)
                    NavigationLink {
                        NutrientDetailView(workspace: workspace, row: row, series: series, range: range, today: today, timeZone: timeZone)
                    } label: {
                        Text("All \(energy.foods.count)").font(.exCaption.weight(.semibold)).foregroundStyle(Color.exPrimaryText)
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("All \(energy.foods.count) foods for calories")
                    .accessibilityIdentifier("nutrition.topFoods.all")
                }
                ForEach(Array(energy.foods.prefix(5).enumerated()), id: \.element.id) { index, food in
                    let amount = range == .yesterday ? IntakeFormat.amount(food.amount, .energy)
                        : "\(IntakeFormat.amount(food.perDay, .energy)) a day"
                    VStack(alignment: .leading, spacing: 5) {
                        if typeSize.isAccessibilitySize {
                            Text(food.name).font(.exLabel).foregroundStyle(Color.exTextPrimary).fixedSize(horizontal: false, vertical: true)
                            Text("\(IntakeFormat.percent(food.share)) · \(amount)").font(.exCaption).monospacedDigit()
                                .foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: ExSpacing.small) {
                                Text(food.name).font(.exLabel).foregroundStyle(Color.exTextPrimary).lineLimit(1)
                                Spacer(minLength: ExSpacing.small)
                                Text(amount).font(.exCaption).monospacedDigit().foregroundStyle(Color.exTextMuted)
                                Text(IntakeFormat.percent(food.share)).font(.exCaption.weight(.semibold)).monospacedDigit()
                                    .foregroundStyle(Color.exTextPrimary).frame(minWidth: 36, alignment: .trailing)
                            }
                        }
                        ExProgressBar(value: food.share, total: energy.foods.first?.share ?? 1, color: .exPrimary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(food.name), \(IntakeFormat.spokenPercent(food.share)) of calories, "
                        + "\(IntakeFormat.spokenAmount(food.perDay, .energy)) a counted day")
                    .accessibilityIdentifier("nutrition.topFood.\(index)")
                }
            }
        }
    }

    // MARK: Timing

    @ViewBuilder
    private func timing(store: NutritionStore, span: ClosedRange<LocalDate>) -> some View {
        let timing = store.timing(from: span.lowerBound, through: span.upperBound, timeZone: timeZone)
        if timing.timedEntries > 0 { IntakeTimingCard(timing: timing) }
    }
}

/// One mark per day of the span: counted, partial or not logged.
struct IntakeCoverageStrip: View {
    let days: [IntakeDay]

    static let counted = Color.exPrimary
    static let fast = Color.exPrimary.opacity(0.5)
    static let partial = Color.exTextMuted.opacity(0.55)
    static let empty = Color.exTextSecondary.opacity(0.18)

    var body: some View {
        Canvas { context, size in
            guard !days.isEmpty else { return }
            let count = CGFloat(days.count)
            let gap: CGFloat = days.count > 60 ? 0.5 : days.count > 31 ? 1 : 3
            let width = max(0.5, (size.width - gap * (count - 1)) / count)
            for (index, day) in days.enumerated() {
                let rect = CGRect(x: CGFloat(index) * (width + gap), y: 0, width: width, height: size.height)
                let color = day.counted ? (day.status == .fasting ? Self.fast : Self.counted) : day.isPartial ? Self.partial : Self.empty
                context.fill(Path(roundedRect: rect, cornerRadius: min(2.5, width / 2)), with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}
