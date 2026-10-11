import ExerlyCore
import SwiftUI

/// Trend weight at a glance for the home screen: the trend, its week, a month
/// of the line, today's reading or a Weigh in button, and expenditure once
/// there's enough data to call it measured.
struct WeightTrendCard: View {
    @ObservedObject var workspace: TrainingWorkspace
    let unit: MassUnit
    let timeZone: TimeZone
    let onWeighIn: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    init(workspace: TrainingWorkspace, unit: MassUnit, timeZone: TimeZone, onWeighIn: @escaping () -> Void) {
        self.workspace = workspace
        self.unit = unit
        self.timeZone = timeZone
        self.onWeighIn = onWeighIn
    }

    var body: some View {
        let today = LocalDate(Date(), in: timeZone)
        let store = workspace.nutrition
        let estimates = BodyEstimates.shared.estimates(store, through: today)
        let summary = WeightTrend.summary(estimates, through: today)
        ExCard {
            BodyCardHeader(title: "Trend weight") { weighInButton(today: store.weights(on: today)) }
            if let summary {
                let month = WeightTrend.series(estimates, from: today.adding(days: -29), through: today)
                if typeSize.isAccessibilitySize {
                    stats(summary)
                    sparkline(month, summary: summary).frame(height: 64)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: ExSpacing.content) {
                            stats(summary).fixedSize()
                            Spacer(minLength: 0)
                            sparkline(month, summary: summary).frame(width: 132, height: 56)
                        }
                        VStack(alignment: .leading, spacing: ExSpacing.small) {
                            stats(summary)
                            sparkline(month, summary: summary).frame(height: 52)
                        }
                    }
                }
                Rectangle().fill(Color.exBorder.opacity(0.6)).frame(height: 0.5).accessibilityHidden(true)
                expenditure(summary.expenditure)
            } else {
                Text("Weigh in to start your trend").font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                Text("Daily readings swing with water and food. Exerly smooths them into a trend you can trust.")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: workspace.identity) { await LegacyWeighIns.importIfNeeded(workspace, timeZone: timeZone) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("weightCard")
    }

    @ViewBuilder
    private func weighInButton(today readings: [WeightEntry]) -> some View {
        if let last = readings.last {
            Button(action: onWeighIn) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.exSuccess).accessibilityHidden(true)
                    Text(BodyFormat.reading(last.weight, unit)).font(.exLabel).foregroundStyle(Color.exTextPrimary)
                        .lineLimit(1).fixedSize()
                }
                .padding(.horizontal, ExSpacing.item).frame(minHeight: 36)
                .background(Color.exSurface2, in: Capsule())
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Weighed in today, \(BodyFormat.spokenReading(last.weight, unit))")
            .accessibilityHint("Double-tap to weigh in again")
            .accessibilityIdentifier("weightCard.weighIn")
        } else {
            WeighInButton(identifier: "weightCard.weighIn", action: onWeighIn)
        }
    }

    private func stats(_ summary: WeightTrend.Summary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(BodyFormat.weight(summary.trend, unit, withUnit: false)).font(.exStat).foregroundStyle(Color.exTextPrimary)
                    .monospacedDigit()
                Text(unit.rawValue).font(.exLabel).foregroundStyle(Color.exTextSecondary)
                Text("±\(BodyFormat.number(Mass.kg(summary.trendError).value(in: unit)))").font(.exCaption)
                    .foregroundStyle(Color.exTextMuted)
            }
            weekLine(summary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummary(summary))
        .accessibilityIdentifier("weightCard.trend")
    }

    @ViewBuilder
    private func weekLine(_ summary: WeightTrend.Summary) -> some View {
        if let week = summary.weekChange {
            // The arrow follows the change as shown, so a rounded 0.0 reads as steady.
            let shown = (Mass.kg(week.kilograms).value(in: unit) * 10).rounded() / 10
            HStack(spacing: 4) {
                Image(systemName: shown < 0 ? "arrow.down.right" : shown > 0 ? "arrow.up.right" : "arrow.right")
                    .font(.exCaption.weight(.semibold)).accessibilityHidden(true)
                Text(BodyCopy.weekChange(week, unit)).font(.exLabel)
            }.foregroundStyle(Color.exTextSecondary)
        } else {
            Text(summary.weighInDays < 2 ? "One reading so far" : "Weekly change after 7 days")
                .font(.exCaption).foregroundStyle(Color.exTextSecondary)
        }
    }

    @ViewBuilder
    private func sparkline(_ points: [WeightTrend.Point], summary: WeightTrend.Summary) -> some View {
        if summary.weighInDays >= 2, points.count >= 2 {
            WeightSparkline(points: points, unit: unit)
        }
    }

    @ViewBuilder
    private func expenditure(_ value: WeightTrend.Expenditure) -> some View {
        if value.isMeasured {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Expenditure").font(.exLabel).foregroundStyle(Color.exTextSecondary)
                Spacer(minLength: ExSpacing.small)
                Text(BodyFormat.kcal(value.kcal)).font(.exStatSmall).foregroundStyle(Color.exTextPrimary).monospacedDigit()
                Text("±\(BodyFormat.kcal(value.error)) kcal").font(.exCaption).foregroundStyle(Color.exTextMuted)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Expenditure about \(BodyFormat.kcal(value.kcal)) kilocalories a day, give or take \(BodyFormat.kcal(value.error))")
        } else {
            Text(BodyCopy.expenditureWaiting(value)).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func spokenSummary(_ summary: WeightTrend.Summary) -> String {
        var parts = ["Trend weight \(BodyFormat.spokenWeight(summary.trend, unit)), give or take "
            + "\(BodyFormat.number(Mass.kg(summary.trendError).value(in: unit)))"]
        if let week = summary.weekChange { parts.append(BodyCopy.spokenWeekChange(week, unit)) }
        return parts.joined(separator: ". ")
    }
}

/// A card's eyebrow with its action beside it, or above a full-width action at accessibility sizes.
struct BodyCardHeader<Action: View>: View {
    let title: String
    @ViewBuilder var action: Action
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: ExSpacing.small) {
                ExEyebrow(title, color: .exPrimaryText)
                action
            }
        } else {
            HStack(alignment: .center, spacing: ExSpacing.small) {
                ExEyebrow(title, color: .exPrimaryText)
                Spacer(minLength: ExSpacing.small)
                action
            }
        }
    }
}

/// "+ Weigh in": a compact capsule, or a full-width button at accessibility sizes.
struct WeighInButton: View {
    let identifier: String
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            Button(action: action) { Label("Weigh in", systemImage: "plus") }
                .buttonStyle(ExActionStyle()).accessibilityIdentifier(identifier)
        } else {
            Button(action: action) {
                Label("Weigh in", systemImage: "plus").font(.exLabel.weight(.semibold)).foregroundStyle(Color.white)
                    .padding(.horizontal, 14).frame(minHeight: 36)
                    .background(Color.exActionFill, in: Capsule())
                    .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier(identifier)
        }
    }
}

/// Sentences shared by the weight screens.
enum BodyCopy {
    /// The summary's seven-day change, the only figure called "this week":
    /// "−0.7 lb this week", or "Steady this week" when it rounds to nothing.
    static func weekChange(_ change: WeightTrend.Change, _ unit: MassUnit) -> String {
        let steady = (Mass.kg(change.kilograms).value(in: unit) * 10).rounded() == 0
        return steady ? "Steady this week" : "\(BodyFormat.change(change.kilograms, unit)) this week"
    }

    /// `weekChange` in words: "down 0.7 pounds this week", "steady this week".
    static func spokenWeekChange(_ change: WeightTrend.Change, _ unit: MassUnit) -> String {
        let words = BodyFormat.spokenChange(change.kilograms, unit)
        return words == "no change" ? "steady this week" : "\(words) this week"
    }

    /// Why expenditure isn't shown yet, in one line.
    static func expenditureWaiting(_ value: WeightTrend.Expenditure) -> String {
        if value.loggedDaysNeeded > 0 {
            let days = value.loggedDaysNeeded
            return "Expenditure appears after \(days) more fully logged \(days == 1 ? "day" : "days")."
        }
        if value.weighInDaysNeeded > 0 {
            let days = value.weighInDaysNeeded
            return "Expenditure appears after \(days) more \(days == 1 ? "weigh-in" : "weigh-ins")."
        }
        return "Expenditure is still settling. Keep logging full days."
    }

    static let expenditureMethod = "Exerly compares the calories you log on fully logged days with how fast your "
        + "trend weight moves. It's measured in the calories you log, so steady under-counting is already built in. "
        + "The ± is one standard deviation: about a 2 in 3 chance your true expenditure is in that range."
}
