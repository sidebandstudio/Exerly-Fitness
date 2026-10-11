import ExerlyCore
import SwiftUI

/// Who the person is: initials, name and email, an Edit button, and the body
/// numbers Exerly works from.
struct ProfileIdentityCard: View {
    let name: String
    let email: String
    let workspace: TrainingWorkspace?
    let user: UserDTO?
    let unit: MassUnit
    let timeZone: TimeZone
    let onEdit: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: ExSpacing.content) {
            let header = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: ExSpacing.item))
                : AnyLayout(HStackLayout(alignment: .center, spacing: ExSpacing.content))
            header {
                if !typeSize.isAccessibilitySize { avatar }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.exH2).foregroundStyle(Color.exTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(email).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1).truncationMode(.middle)
                        .accessibilityLabel("Email")
                        .accessibilityValue(email)
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                Button(action: onEdit) {
                    Text("Edit").font(.exLabel.weight(.semibold)).foregroundStyle(Color.exPrimaryText)
                        .padding(.horizontal, ExSpacing.content).frame(minHeight: 36)
                        .background(Color.exPrimary.opacity(0.12), in: Capsule())
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(TodayPressStyle())
                .accessibilityLabel("Edit your details")
                .accessibilityIdentifier("profile.preferences")
            }
            ProfileBodyStats(workspace: workspace, user: user, unit: unit, timeZone: timeZone)
        }
        .padding(ExSpacing.content)
        .background(Color.exSurface1, in: RoundedRectangle(cornerRadius: ExRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ExRadius.card, style: .continuous)
                .strokeBorder(Color.exBorder.opacity(0.5), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private var avatar: some View {
        Text(Self.initials(name))
            .font(.system(.title2, design: .rounded, weight: .bold)).foregroundStyle(.white)
            .minimumScaleFactor(0.6).lineLimit(1)
            .frame(width: 60, height: 60)
            .background(LinearGradient(colors: [.exPrimary, .exAccent], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: Circle())
            .accessibilityHidden(true)
    }

    static func initials(_ name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

/// Trend weight, height and age side by side. Weight comes from ExerlyCore's
/// weigh-ins: the trend once there is one, else the latest reading, else
/// the weight saved at setup.
struct ProfileBodyStats: View {
    let workspace: TrainingWorkspace?
    let user: UserDTO?
    let unit: MassUnit
    let timeZone: TimeZone
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ExSpacing.item))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 0))
        layout {
            weight
            divider
            stat("Height", value: height, spoken: spokenHeight)
            divider
            stat("Age", value: user?.age.map(String.init) ?? "—", spoken: user?.age.map { "\($0) years" } ?? "Not set")
        }
        .padding(.vertical, ExSpacing.item)
        .padding(.horizontal, ExSpacing.small)
        .background(Color.exSurface2.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("profile.bodyStats")
    }

    @ViewBuilder private var divider: some View {
        if !typeSize.isAccessibilitySize {
            Rectangle().fill(Color.exBorder.opacity(0.6)).frame(width: 0.5, height: 36)
                .frame(maxHeight: .infinity).accessibilityHidden(true)
        }
    }

    @ViewBuilder private var weight: some View {
        if let workspace {
            let today = LocalDate(Date(), in: timeZone)
            let store = workspace.nutrition
            let summary = WeightTrend.summary(BodyEstimates.shared.estimates(store, through: today), through: today)
            if let summary {
                stat("Trend weight", value: BodyFormat.weight(summary.trend, unit), detail: change(summary),
                     spoken: "\(BodyFormat.spokenWeight(summary.trend, unit))\(summary.weekChange.map { ", \(BodyFormat.spokenChange($0.kilograms, unit)) this week" } ?? "")")
            } else if let last = store.weights.last {
                stat("Weight", value: BodyFormat.reading(last.weight, unit), spoken: BodyFormat.spokenReading(last.weight, unit))
            } else { setupWeight }
        } else { setupWeight }
    }

    @ViewBuilder private var setupWeight: some View {
        if let kilograms = user?.weight {
            stat("Weight", value: BodyFormat.weight(kilograms, unit), spoken: BodyFormat.spokenWeight(kilograms, unit))
        } else {
            stat("Weight", value: "—", spoken: "Not set")
        }
    }

    private func change(_ summary: WeightTrend.Summary) -> String? {
        guard let week = summary.weekChange else { return nil }
        return "\(BodyFormat.change(week.kilograms, unit)) a week"
    }

    private var height: String {
        guard let centimeters = user?.height else { return "—" }
        guard unit == .pounds else { return "\(centimeters.formatted(.number.precision(.fractionLength(0)))) cm" }
        let height = USUnits.feetAndInches(centimeters: centimeters)
        return "\(height.feet)′ \(Int(height.inches.rounded()))″"
    }

    private var spokenHeight: String {
        guard let centimeters = user?.height else { return "Not set" }
        guard unit == .pounds else { return "\(centimeters.formatted(.number.precision(.fractionLength(0)))) centimeters" }
        let height = USUnits.feetAndInches(centimeters: centimeters)
        return "\(height.feet) feet \(Int(height.inches.rounded())) inches"
    }

    private func stat(_ title: String, value: String, detail: String? = nil, spoken: String) -> some View {
        VStack(alignment: typeSize.isAccessibilitySize ? .leading : .center, spacing: 2) {
            Text(value).font(.exStatSmall).monospacedDigit().foregroundStyle(Color.exTextPrimary)
                .lineLimit(1).minimumScaleFactor(0.75)
            Text(title).font(.exSmall).foregroundStyle(Color.exTextSecondary)
            if let detail {
                Text(detail).font(.exSmall.weight(.medium)).foregroundStyle(Color.exPrimaryText).lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: typeSize.isAccessibilitySize ? .leading : .center)
        .padding(.horizontal, ExSpacing.tight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(spoken)
    }
}

/// Today's calorie and macro targets and the goal behind them, opening the
/// full Targets screen.
struct ProfilePlanCard: View {
    let workspace: TrainingWorkspace?
    let unit: MassUnit
    let timeZone: TimeZone
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let today = LocalDate(Date(), in: timeZone)
        let plan = workspace?.nutrition.plan(on: today)
        VStack(alignment: .leading, spacing: ExSpacing.item) {
            HStack(spacing: ExSpacing.small) {
                ExEyebrow("Your plan", color: .exPrimaryText)
                if let plan, !typeSize.isAccessibilitySize {
                    Text(TargetsFormat.mode(plan.mode)).font(.exCaption.weight(.semibold)).foregroundStyle(Color.exPrimaryText)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.exPrimary.opacity(0.12), in: Capsule())
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.exTextMuted)
                    .accessibilityHidden(true)
            }
            if let plan, let day = plan.targets(on: today) {
                if day.energy > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(TargetsFormat.kcal(day.energy)).font(.exStat).monospacedDigit().foregroundStyle(Color.exTextPrimary)
                        Text("kcal today").font(.exBodyMedium).foregroundStyle(Color.exTextSecondary)
                    }
                    TargetsMacroBar(day: day)
                    macros(day)
                } else {
                    Text("Fasting day").font(.exH2).foregroundStyle(Color.exTextPrimary)
                }
                Text(goal(plan.goal)).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Set your calorie and macro targets").font(.exH3).foregroundStyle(Color.exTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Today and Progress measure your food against them.")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(ExSpacing.content)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.exPrimary.opacity(0.07), in: RoundedRectangle(cornerRadius: ExRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ExRadius.card, style: .continuous)
                .strokeBorder(Color.exPrimary.opacity(0.24), lineWidth: 0.5)
        }
        .contentShape(Rectangle())
    }

    /// Today's targets in a sentence, for VoiceOver.
    static func spoken(workspace: TrainingWorkspace?, timeZone: TimeZone) -> String {
        let today = LocalDate(Date(), in: timeZone)
        guard let day = workspace?.nutrition.targets(on: today) else { return "No targets set" }
        guard day.energy > 0 else { return "Fasting day" }
        return "\(TargetsFormat.kcal(day.energy)) kilocalories today. Protein \(TargetsFormat.grams(day.protein)), "
            + "carbs \(TargetsFormat.grams(day.carbohydrate)), fat \(TargetsFormat.grams(day.fat))"
    }

    /// "Protein 165 g · Carbs 295 g · Fat 78 g", each name in its macro colour.
    private func macros(_ day: DailyTargets) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ExSpacing.tight))
            : AnyLayout(HStackLayout(spacing: ExSpacing.content))
        return layout {
            macro("Protein", grams: day.protein, color: .exPrimaryText)
            macro("Carbs", grams: day.carbohydrate, color: .exAccent)
            macro("Fat", grams: day.fat, color: .exSecondary)
        }
    }

    private func macro(_ title: String, grams: Double, color: Color) -> some View {
        HStack(alignment: .center, spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(TargetsFormat.grams(grams)).font(.exLabel.weight(.semibold)).monospacedDigit().foregroundStyle(Color.exTextPrimary)
            Text(title).font(.exCaption).foregroundStyle(Color.exTextSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func goal(_ goal: NutritionGoal) -> String {
        let target = goal.goalWeight.map { " to \(BodyFormat.weight($0.kilograms, unit))" } ?? ""
        switch goal.direction {
        case .lose: return "Losing weight\(target)"
        case .gain: return "Gaining weight\(target)"
        case .maintain: return "Maintaining weight"
        }
    }
}

/// A titled group of rows on one card, separated by hairlines.
struct ProfileSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: ExSpacing.small) {
            Text(title).font(.exLabel.weight(.semibold)).foregroundStyle(Color.exTextSecondary)
                .padding(.leading, ExSpacing.tight)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 {
                            Rectangle().fill(Color.exBorder.opacity(0.5)).frame(height: 0.5)
                                .padding(.leading, 60).accessibilityHidden(true)
                        }
                        row
                    }
                }
            }
            .background(Color.exSurface1, in: RoundedRectangle(cornerRadius: ExRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ExRadius.card, style: .continuous)
                    .strokeBorder(Color.exBorder.opacity(0.5), lineWidth: 0.5)
            }
        }
    }
}

/// A row: a tinted symbol, a title with an optional line below, an optional
/// value on the right, and a chevron when it opens something.
struct ProfileRow: View {
    let title: String
    let icon: String
    var subtitle: String?
    var value: String?
    var tint: Color = .exPrimaryText
    var destructive = false
    var chevron = true
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: ExSpacing.item) {
            if !typeSize.isAccessibilitySize {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(destructive ? Color.exError : tint)
                    .frame(width: 32, height: 32)
                    .background((destructive ? Color.exError : tint).opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.exBody).foregroundStyle(destructive ? Color.exError : Color.exTextPrimary)
                if let subtitle {
                    Text(subtitle).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }
                if typeSize.isAccessibilitySize, let value {
                    Text(value).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
            Spacer(minLength: ExSpacing.small)
            if !typeSize.isAccessibilitySize, let value {
                Text(value).font(.exLabel).foregroundStyle(Color.exTextSecondary).lineLimit(1)
            }
            if chevron {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.exTextMuted)
            }
        }
        .padding(.horizontal, ExSpacing.item).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue([subtitle, value].compactMap { $0 }.joined(separator: ", "))
    }
}

/// A row holding a control, such as the units or appearance switch.
struct ProfileControlRow<Control: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var control: Control
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: ExSpacing.small) { label; control }
            } else {
                // The control keeps its labels on one line beside the title,
                // or moves under it when there isn't room for both.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: ExSpacing.item) {
                        badge
                        label
                        Spacer(minLength: ExSpacing.small)
                        control.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: ExSpacing.small) {
                        HStack(spacing: ExSpacing.item) { badge; label }
                        control
                    }
                }
            }
        }
        .padding(.horizontal, ExSpacing.item).padding(.vertical, ExSpacing.small)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    }

    private var badge: some View {
        Image(systemName: icon).font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.exPrimaryText)
            .frame(width: 32, height: 32)
            .background(Color.exPrimary.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }

    private var label: some View {
        Text(title).font(.exBody).foregroundStyle(Color.exTextPrimary).accessibilityHidden(true)
    }
}
