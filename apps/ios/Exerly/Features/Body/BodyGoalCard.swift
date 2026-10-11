import ExerlyCore
import SwiftUI

/// Progress → Body's goal: what the plan in force aims for, whether the trend
/// keeps to the path it planned, when it reaches the goal weight, and the
/// trend to expect each coming week. Editing opens the plan editor, which
/// saves a new version, so earlier weeks keep the goal they had.
struct BodyGoalCard: View {
    let plan: NutritionPlan?
    /// The goal in force today, with the trend it started from.
    let stretch: WeightGoal.Stretch?
    let summary: WeightTrend.Summary
    let unit: MassUnit
    let today: LocalDate
    let onEdit: () -> Void
    @State private var showsAll = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private static let shownWeeks = 4

    var body: some View {
        ExCard {
            BodyCardHeader(title: "Goal") { editButton }
            if let plan {
                headline(plan.goal)
                if let stretch { standing(stretch) }
                if plan.goal.direction != .maintain { eta(plan.goal) }
            } else {
                Text("Set a goal weight and a weekly rate to see when you'd reach it and the trend to expect each week.")
                    .font(.exBody).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("body.goal")
    }

    private var editButton: some View {
        Button(action: onEdit) {
            Text(plan == nil ? "Set a goal" : "Edit goal").font(.exLabel.weight(.semibold)).foregroundStyle(Color.exPrimaryText)
                .padding(.horizontal, 14).frame(minHeight: 36)
                .background(Color.exPrimary.opacity(0.14), in: Capsule())
                .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("body.goal.edit")
    }

    private func headline(_ goal: NutritionGoal) -> some View {
        let target = goal.goalWeight.map { " to \(BodyFormat.reading($0, unit))" } ?? ""
        let text = goal.direction == .maintain ? "Maintain your weight"
            : "\(TargetsFormat.direction(goal.direction)) \(TargetsFormat.weekly(goal.weeklyRate, trend: summary.trend, unit: unit)) a week\(target)"
        return VStack(alignment: .leading, spacing: 2) {
            Text(text).font(.exH3).foregroundStyle(Color.exTextPrimary).fixedSize(horizontal: false, vertical: true)
            if goal.direction != .maintain {
                Text("\(TargetsFormat.percent(goal.weeklyRate)) of bodyweight a week, easing as your weight changes")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("body.goal.headline")
    }

    // MARK: Standing

    private func standing(_ stretch: WeightGoal.Stretch) -> some View {
        let planned = stretch.planned(on: today)
        let standing = WeightGoal.standing(trend: summary.trend, trendError: summary.trendError, planned: planned,
                                           direction: stretch.goal.direction)
        let (title, color) = Self.status(standing, direction: stretch.goal.direction, unit: unit)
        let detail = stretch.anchor == today
            ? "Set today. Its path starts from your trend of \(BodyFormat.weight(stretch.startTrend, unit))."
            : "Planned \(BodyFormat.weight(planned, unit)) today, from \(BodyFormat.weight(stretch.startTrend, unit)) "
                + "on \(BodyFormat.shortDate(stretch.anchor))"
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: ExSpacing.small))
            : AnyLayout(HStackLayout(alignment: .center, spacing: ExSpacing.item))
        return VStack(alignment: .leading, spacing: ExSpacing.small) {
            layout {
                Text(title).font(.exLabel.weight(.semibold)).foregroundStyle(color).lineLimit(1).fixedSize()
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(color.opacity(0.14), in: Capsule())
                Text(detail).font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title). " + (stretch.anchor == today
                ? "Set today. Its path starts from your trend of \(BodyFormat.spokenWeight(stretch.startTrend, unit))."
                : "Planned \(BodyFormat.spokenWeight(planned, unit)) today, from \(BodyFormat.spokenWeight(stretch.startTrend, unit)) "
                    + "on \(BodyFormat.shortDate(stretch.anchor))"))
            .accessibilityIdentifier("body.goal.standing")
            Text(standing.band > WeightGoal.tolerance
                 ? "On track: within \(BodyFormat.weight(standing.band, unit)) of the planned path, the trend's ± for now."
                 : "On track: within \(BodyFormat.weight(standing.band, unit)) of the planned path.")
                .font(.exSmall).foregroundStyle(Color.exTextMuted).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "On track", "Ahead by 1.2 lb", "Behind by 0.8 lb", or a maintainer's drift, with its colour.
    static func status(_ standing: WeightGoal.Standing, direction: NutritionGoal.Direction, unit: MassUnit) -> (String, Color) {
        let amount = BodyFormat.weight(abs(standing.offset), unit)
        switch standing.status {
        case .onTrack: return ("On track", .exSuccess)
        case .ahead: return ("Ahead by \(amount)", .exPrimaryText)
        case .behind where direction == .maintain: return ("\(standing.offset > 0 ? "Up" : "Down") \(amount)", .exWarning)
        case .behind: return ("Behind by \(amount)", .exWarning)
        }
    }

    // MARK: ETA and checkpoints

    @ViewBuilder
    private func eta(_ goal: NutritionGoal) -> some View {
        TargetsDivider()
        switch goal.projection(from: summary.trend, on: today) {
        case .on(let date, let weeks):
            VStack(alignment: .leading, spacing: 2) {
                Text("Around \(TargetsFormat.shortDate(date, today: today))").font(.exStatMedium).foregroundStyle(Color.exTextPrimary)
                Text("\(weeks) \(weeks == 1 ? "week" : "weeks") from your trend of \(BodyFormat.weight(summary.trend, unit)) at this rate")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("body.goal.eta")
            checkpoints(goal, weeks: weeks)
        case .reached:
            Text("Your trend weight is at or past your goal weight.").font(.exBody).foregroundStyle(Color.exSuccess)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("body.goal.eta")
        case .noGoalWeight, .maintaining:
            Text("Add a goal weight to see when you'd reach it and the trend to expect each week.")
                .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("body.goal.eta")
        }
    }

    private func checkpoints(_ goal: NutritionGoal, weeks: Int) -> some View {
        let all = goal.checkpoints(from: summary.trend, on: today, weeks: min(weeks, 104))
        let shown = showsAll ? all : Array(all.prefix(Self.shownWeeks))
        return VStack(alignment: .leading, spacing: 0) {
            Text("Expected trend each week").font(.exLabel).foregroundStyle(Color.exTextSecondary)
                .padding(.bottom, ExSpacing.tight).accessibilityAddTraits(.isHeader)
            ForEach(Array(shown.enumerated()), id: \.offset) { index, point in
                HStack(alignment: .firstTextBaseline) {
                    Text(TargetsFormat.shortDate(point.date, today: today)).font(.exBody).foregroundStyle(Color.exTextPrimary)
                    Spacer(minLength: ExSpacing.small)
                    Text(BodyFormat.weight(point.weight, unit)).font(.exBodyMedium).monospacedDigit().foregroundStyle(Color.exTextPrimary)
                }
                .frame(minHeight: 36)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(TargetsFormat.shortDate(point.date, today: today)), \(BodyFormat.spokenWeight(point.weight, unit))")
                .accessibilityIdentifier("body.goal.checkpoint.\(index)")
            }
            if all.count > Self.shownWeeks {
                Button(showsAll ? "Show fewer" : "Show all \(all.count) weeks") { withAnimation(.snappy) { showsAll.toggle() } }
                    .font(.exLabel.weight(.semibold)).foregroundStyle(Color.exPrimaryText).frame(minHeight: 44)
                    .accessibilityIdentifier("body.goal.allCheckpoints")
            }
        }
    }
}
