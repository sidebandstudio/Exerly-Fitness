import ExerlyCore
import SwiftUI

/// What today's trend weight rests on: each recent weigh-in's share of it,
/// from `EnergyBalance.influence`, and its uncertainty in plain words. A
/// reading opens for editing from here as from the history.
struct TrendExplanationSheet: View {
    @ObservedObject var workspace: TrainingWorkspace
    let unit: MassUnit
    let timeZone: TimeZone
    let onDeleted: (WeightEntry) -> Void
    @State private var influence: [EnergyBalance.Influence]?
    @State private var editing: WeightEntry?
    @Environment(\.dismiss) private var dismiss

    private static let lookback = 28

    var body: some View {
        let today = LocalDate(Date(), in: timeZone)
        let store = workspace.nutrition
        let summary = WeightTrend.summary(BodyEstimates.shared.estimates(store, through: today), through: today)
        NavigationStack {
            ExScreen {
                if let summary {
                    value(summary)
                    restsOn(summary, today: today)
                    certainty(summary)
                }
            }
            .navigationTitle("Trend weight").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("trendExplanation.done")
                }
            }
        }
        .presentationDragIndicator(.visible)
        .task(id: summary.map { "\($0.trend)-\(store.weights.count)" }) {
            guard let summary, let first = store.weights.map(\.date).min() else { return }
            let days = store.energyBalanceDays(from: first, through: summary.date)
            let prior = store.plans.first?.basis.map { (mean: $0.expenditure, error: $0.expenditureError) }
            let date = summary.date, lookback = Self.lookback
            influence = await Task.detached(priority: .userInitiated) {
                EnergyBalance.influence(days, on: date, lookback: lookback, prior: prior)
            }.value
        }
        .sheet(item: $editing) { entry in
            WeighInSheet(workspace: workspace, unit: unit, timeZone: timeZone, editing: entry, onDeleted: onDeleted)
        }
    }

    private func value(_ summary: WeightTrend.Summary) -> some View {
        let low = summary.trend - summary.trendError, high = summary.trend + summary.trendError
        return ExCard(accent: true) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(BodyFormat.weight(summary.trend, unit, withUnit: false)).font(.exStat).monospacedDigit()
                    .foregroundStyle(Color.exTextPrimary)
                Text(unit.rawValue).font(.exBodyMedium).foregroundStyle(Color.exTextSecondary)
                Text("±\(BodyFormat.number(Mass.kg(summary.trendError).value(in: unit)))").font(.exLabel)
                    .foregroundStyle(Color.exTextMuted)
            }
            Text("Likely between \(BodyFormat.weight(low, unit)) and \(BodyFormat.weight(high, unit))")
                .font(.exCaption).foregroundStyle(Color.exTextSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trend weight \(BodyFormat.spokenWeight(summary.trend, unit)), likely between "
            + "\(BodyFormat.spokenWeight(low, unit)) and \(BodyFormat.spokenWeight(high, unit))")
        .accessibilityIdentifier("trendExplanation.value")
    }

    @ViewBuilder
    private func restsOn(_ summary: WeightTrend.Summary, today: LocalDate) -> some View {
        let swing = unit == .pounds ? "two pounds" : "a kilo"
        ExCard {
            ExEyebrow("What it rests on")
            Text("Each weigh-in's share of today's trend. One reading moves it only part of the way, because water and food "
                + "can swing the scale by \(swing) or more from one morning to the next.")
                .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            if let influence {
                // A share under 1 % wouldn't show; older readings act through expenditure and are summed below.
                let shown = influence.filter { $0.effect >= 0.01 }.sorted { $0.date > $1.date }
                VStack(spacing: 0) {
                    ForEach(shown, id: \.date) { item in row(item, today: today) }
                }
                let rest = 1 - shown.reduce(0) { $0 + $1.effect }
                if rest >= 0.01 {
                    Text("The other \(Self.percent(rest)) comes from earlier readings and your logged food, through the "
                        + "expenditure estimate.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80).accessibilityLabel("Working out the shares")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trendExplanation.readings")
    }

    private func row(_ item: EnergyBalance.Influence, today: LocalDate) -> some View {
        let entries = workspace.nutrition.weights(on: item.date)
        let day = BodyFormat.day(item.date, today: today)
        let readings = entries.map { BodyFormat.reading($0.weight, unit, withUnit: false) }.joined(separator: ", ")
        return Button { editing = entries.last } label: {
            HStack(spacing: ExSpacing.item) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(day).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                        Spacer(minLength: ExSpacing.small)
                        Text("\(readings) \(unit.rawValue)").font(.exBody).monospacedDigit().foregroundStyle(Color.exTextSecondary)
                    }
                    HStack(spacing: ExSpacing.small) {
                        GeometryReader { proxy in
                            Capsule().fill(Color.exSurface2)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(LinearGradient(colors: [.exPrimary, .exAccent], startPoint: .leading, endPoint: .trailing))
                                        .frame(width: max(4, proxy.size.width * min(item.effect, 1)))
                                }
                        }
                        .frame(height: 6)
                        Text(Self.percent(item.effect)).font(.exCaption.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(Color.exTextPrimary).frame(minWidth: 40, alignment: .trailing)
                    }
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.exTextMuted)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, ExSpacing.small).frame(minHeight: 56).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(entries.isEmpty)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(day), \(readings) \(BodyFormat.unitName(unit)), \(Self.percent(item.effect)) of the trend")
        .accessibilityHint("Double-tap to edit")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("trendExplanation.reading.\(item.date)")
    }

    private func certainty(_ summary: WeightTrend.Summary) -> some View {
        let error = "±\(BodyFormat.number(Mass.kg(summary.trendError).value(in: unit))) \(unit.rawValue)"
        return ExCard {
            ExEyebrow("How sure it is")
            Text("\(error) is one standard deviation: about a 2 in 3 chance the true trend is in that range. It narrows "
                + "when you weigh in often and widens across gaps, where the chart's dashed line is an estimate, not a reading.")
                .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            Text("Each day the trend moves by the calories you logged minus your expenditure, and each reading pulls it part "
                + "of the way toward the scale. That's why one high reading after a salty meal barely moves it.")
                .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func percent(_ share: Double) -> String {
        "\((share * 100).formatted(.number.precision(.fractionLength(0)))) %"
    }
}
