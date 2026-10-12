import Charts
import ExerlyCore
import SwiftUI

/// Words and numbers as the targets screens write them. Weights go through
/// `BodyFormat`, so they match the weight screens.
enum TargetsFormat {
    /// Whole kilocalories, grouped: "2,140".
    static func kcal(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0))) }

    static func grams(_ value: Double) -> String { "\(value.formatted(.number.precision(.fractionLength(0)))) g" }

    /// "+80" or "−80", with a true minus sign.
    static func signedKcal(_ value: Double) -> String {
        let rounded = value.rounded()
        return rounded > 0 ? "+\(kcal(rounded))" : rounded < 0 ? "−\(kcal(-rounded))" : "0"
    }

    /// A share of bodyweight: "0.5 %".
    static func percent(_ share: Double) -> String {
        "\((share * 100).formatted(.number.precision(.fractionLength(0...2)))) %"
    }

    /// A weekly rate's amount in the person's unit: "0.9 lb" or "0.45 kg".
    static func weekly(_ share: Double, trend: Double, unit: MassUnit, withUnit: Bool = true) -> String {
        let value = NutritionRate.weekly(share, trend: trend, in: unit)
        let text = value.formatted(.number.precision(.fractionLength(unit == .pounds ? 1 : 2)))
        return withUnit ? "\(text) \(unit.rawValue)" : text
    }

    static func spokenWeekly(_ share: Double, trend: Double, unit: MassUnit) -> String {
        "\(weekly(share, trend: trend, unit: unit, withUnit: false)) \(BodyFormat.unitName(unit)) a week"
    }

    static func direction(_ direction: NutritionGoal.Direction) -> String {
        switch direction {
        case .lose: "Lose"
        case .maintain: "Maintain"
        case .gain: "Gain"
        }
    }

    static func mode(_ mode: PlanMode) -> String {
        switch mode {
        case .coached: "Coached"
        case .collaborative: "Collaborative"
        case .manual: "Manual"
        }
    }

    static func modeDetail(_ mode: PlanMode) -> String {
        switch mode {
        case .coached: "Exerly checks in weekly and proposes new targets. Accept them in one tap."
        case .collaborative: "The same weekly proposals, which you can adjust before accepting."
        case .manual: "You set the numbers. Check-ins never change them."
        }
    }

    static func diet(_ diet: DietType) -> String {
        switch diet {
        case .balanced: "Balanced"
        case .lowFat: "Low fat"
        case .lowCarb: "Low carb"
        case .keto: "Keto"
        }
    }

    static func dietDetail(_ diet: DietType) -> String {
        switch diet {
        case .keto: "Fat gives 70 % of calories, carbs stay at 30 g or less, protein as chosen."
        default: "Fat gives \(percent(diet.fatShare)) of calories, protein as chosen, carbs the rest."
        }
    }

    static func protein(_ level: ProteinLevel) -> String {
        switch level {
        case .low: "Low"
        case .moderate: "Moderate"
        case .high: "High"
        }
    }

    /// "1.8 g/kg" for metric accounts, "0.82 g/lb" for imperial ones.
    static func proteinRate(_ level: ProteinLevel, unit: MassUnit) -> String {
        let value = level.gramsPerKilogram * unit.kilogramsPerUnit
        return "\(value.formatted(.number.precision(.fractionLength(unit == .pounds ? 2 : 1)))) g/\(unit.rawValue)"
    }

    static func weekday(_ day: Weekday, style: WeekdayStyle = .full) -> String {
        let calendar = Calendar.current
        let symbols = switch style {
        case .full: calendar.weekdaySymbols
        case .short: calendar.shortWeekdaySymbols
        case .narrow: calendar.veryShortWeekdaySymbols
        }
        return symbols[day.rawValue - 1]
    }

    enum WeekdayStyle { case full, short, narrow }

    /// "Monday, Oct 12"; "Today" and "Tomorrow" when they apply.
    static func day(_ date: LocalDate, today: LocalDate) -> String {
        if date == today { return "Today" }
        if date == today.adding(days: 1) { return "Tomorrow" }
        var style = Date.FormatStyle.dateTime.weekday(.wide).month(.abbreviated).day()
        if date.year != today.year { style = style.year() }
        style.timeZone = BodyDates.utc
        return BodyDates.anchor(date).formatted(style)
    }

    /// `day` mid-sentence: "today", "tomorrow" or "on Monday, Oct 12".
    static func onDay(_ date: LocalDate, today: LocalDate) -> String {
        let text = day(date, today: today)
        return date == today || date == today.adding(days: 1) ? text.lowercased() : "on \(text)"
    }

    /// "Jan 14" or "Jan 14, 2027".
    static func shortDate(_ date: LocalDate, today: LocalDate) -> String {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        if date.year != today.year { style = style.year() }
        style.timeZone = BodyDates.utc
        return BodyDates.anchor(date).formatted(style)
    }

    static func message(_ error: Error) -> String {
        switch error {
        case NutritionStore.StoreError.invalid(let problems): return problems.joined(separator: ". ") + "."
        case AgentStore.AgentError.stale: return "Your targets changed since this check-in, so nothing was applied."
        case AgentStore.AgentError.invalid(let reason): return reason
        case AgentStore.AgentError.alreadyDecided: return "This check-in already has a decision."
        default: return "That could not be saved. Your targets are unchanged. Try again."
        }
    }
}

/// The onboarding answers the formula needs, from the account.
enum TargetsProfile {
    static func body(_ user: UserDTO?) -> BodyProfile? {
        guard let user, let age = user.age, let height = user.height, let weight = user.weight,
              let activity = user.activityLevel.flatMap(BodyProfile.Activity.init(rawValue:)) else { return nil }
        let sex: BodyProfile.Sex = switch user.gender?.lowercased() {
        case "male": .male
        case "female": .female
        default: .unspecified
        }
        let profile = BodyProfile(sex: sex, age: age, height: height, weight: .kg(weight), activity: activity)
        return profile.problems.isEmpty ? profile : nil
    }

    /// The goal chosen at setup, as a first plan's goal.
    static func goal(_ user: UserDTO?, unit: MassUnit) -> NutritionGoal {
        let direction: NutritionGoal.Direction = switch user?.goal {
        case "lose_weight": .lose
        case "gain_muscle": .gain
        default: .maintain
        }
        let weight = user?.targetWeight.flatMap { $0 > 0 ? Mass(((Mass.kg($0).value(in: unit)) * 10).rounded() / 10, unit) : nil }
        return NutritionGoal(direction, weeklyRate: NutritionRate.standard(for: direction),
                             goalWeight: direction == .maintain ? nil : weight)
    }
}

/// The day's calories split by macro, as one bar: protein, carbs, fat.
struct TargetsMacroBar: View {
    let day: DailyTargets

    var body: some View {
        let shares = day.macroShares
        GeometryReader { geometry in
            HStack(spacing: 2) {
                segment(shares.protein, width: geometry.size.width, color: .exPrimaryText)
                segment(shares.carbohydrate, width: geometry.size.width, color: .exAccent)
                segment(shares.fat, width: geometry.size.width, color: .exSecondary)
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    private func segment(_ share: Double, width: CGFloat, color: Color) -> some View {
        Rectangle().fill(color).frame(width: max(0, (width - 4) * share))
    }
}

/// A macro's name over its grams, with its colour and share of calories.
struct TargetsMacroColumn: View {
    let title: String
    let grams: Double
    let share: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(title).font(.exCaption).foregroundStyle(Color.exTextSecondary)
            }
            Text(TargetsFormat.grams(grams)).font(.exStatSmall).monospacedDigit().foregroundStyle(Color.exTextPrimary)
                .contentTransition(.numericText(value: grams))
            Text("\(Int((share * 100).rounded())) % of kcal").font(.exSmall).foregroundStyle(Color.exTextMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(TargetsFormat.kcal(grams)) grams, \(Int((share * 100).rounded())) percent of calories")
    }
}

/// Protein, carbs and fat side by side, or stacked at accessibility sizes.
struct TargetsMacroRow: View {
    let day: DailyTargets
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let shares = day.macroShares
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ExSpacing.item))
            : AnyLayout(HStackLayout(alignment: .top, spacing: ExSpacing.item))
        layout {
            TargetsMacroColumn(title: "Protein", grams: day.protein, share: shares.protein, color: .exPrimaryText)
            TargetsMacroColumn(title: "Carbs", grams: day.carbohydrate, share: shares.carbohydrate, color: .exAccent)
            TargetsMacroColumn(title: "Fat", grams: day.fat, share: shares.fat, color: .exSecondary)
        }
    }
}

/// Each weekday's budget as a bar, today's highlighted.
struct TargetsWeekChart: View {
    let targets: [DailyTargets]
    let today: Weekday
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: ExSpacing.small) {
                ForEach(Weekday.allCases, id: \.self) { day in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(TargetsFormat.weekday(day)).font(day == today ? .exBodyMedium : .exBody)
                        Text("\(TargetsFormat.kcal(energy(day))) kcal").font(.exStatSmall).monospacedDigit()
                    }
                    .foregroundStyle(day == today ? Color.exPrimaryText : Color.exTextPrimary)
                    .accessibilityElement(children: .combine)
                }
            }
        } else {
            Chart {
                ForEach(Weekday.allCases, id: \.self) { day in
                    BarMark(x: .value("Day", TargetsFormat.weekday(day, style: .short)), y: .value("Calories", energy(day)),
                            width: .ratio(0.62))
                        .foregroundStyle(day == today
                            ? AnyShapeStyle(LinearGradient(colors: [.exAccent, .exPrimary], startPoint: .top, endPoint: .bottom))
                            : AnyShapeStyle(Color.exPrimary.opacity(0.32)))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .annotation(position: .top, spacing: 3) {
                            Text(TargetsFormat.kcal(energy(day))).font(.system(size: 10, weight: .semibold, design: .rounded))
                                .monospacedDigit().lineLimit(1).fixedSize()
                                .foregroundStyle(day == today ? Color.exTextPrimary : Color.exTextMuted)
                        }
                }
            }
            .chartYScale(domain: 0...(max(targets.map(\.energy).max() ?? 1, 1) * 1.18))
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(label).font(.exSmall).foregroundStyle(Color.exTextMuted)
                        }
                    }
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .frame(height: 132)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Calories by weekday")
            .accessibilityValue(Weekday.allCases.map { "\(TargetsFormat.weekday($0)) \(TargetsFormat.kcal(energy($0)))" }
                .joined(separator: ", "))
        }
    }

    private func energy(_ day: Weekday) -> Double { targets.indices.contains(day.rawValue - 1) ? targets[day.rawValue - 1].energy : 0 }
}

/// The trend weight's path to the goal weight at the planned rate.
struct TargetsGoalChart: View {
    let points: [(date: LocalDate, weight: Double)]
    let goal: Double
    let unit: MassUnit

    var body: some View {
        let values = points.map(\.weight) + [goal]
        let low = Mass.kg(values.min() ?? goal).value(in: unit)
        let high = Mass.kg(values.max() ?? goal).value(in: unit)
        let pad = max((high - low) * 0.15, unit == .pounds ? 1 : 0.5)
        Chart {
            RuleMark(y: .value("Goal", Mass.kg(goal).value(in: unit)))
                .foregroundStyle(Color.exTextMuted.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("Week", BodyDates.anchor(point.date)), y: .value("Trend", Mass.kg(point.weight).value(in: unit)))
                    .foregroundStyle(LinearGradient(colors: [.exPrimary, .exAccent], startPoint: .leading, endPoint: .trailing))
                    .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, dash: [6, 4]))
                    .interpolationMethod(.monotone)
            }
            if let first = points.first {
                PointMark(x: .value("Week", BodyDates.anchor(first.date)), y: .value("Trend", Mass.kg(first.weight).value(in: unit)))
                    .symbolSize(44).foregroundStyle(Color.exPrimary)
            }
            if let last = points.last {
                PointMark(x: .value("Week", BodyDates.anchor(last.date)), y: .value("Trend", Mass.kg(last.weight).value(in: unit)))
                    .symbolSize(44).foregroundStyle(Color.exAccent)
            }
        }
        .chartYScale(domain: (low - pad)...(high + pad))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: Date.FormatStyle(timeZone: BodyDates.utc).month(.abbreviated).day(), centered: false)
                    .font(.exSmall).foregroundStyle(Color.exTextMuted)
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
        .environment(\.timeZone, BodyDates.utc).environment(\.calendar, BodyDates.calendar)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityHidden(true)
    }
}

/// A row of a settings-like list inside a card: title, value, chevron.
struct TargetsDetailRow: View {
    let title: String
    let value: String
    var detail: String?
    var hint = "Opens the plan editor"
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: ExSpacing.small))
            HStack(spacing: ExSpacing.small) {
                layout {
                    Text(title).font(.exBody).foregroundStyle(Color.exTextSecondary)
                    if !typeSize.isAccessibilitySize { Spacer(minLength: ExSpacing.small) }
                    VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 1) {
                        Text(value).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                        if let detail { Text(detail).font(.exSmall).foregroundStyle(Color.exTextMuted) }
                    }
                    .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
                }
                if typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.exTextMuted)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, ExSpacing.small).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Labelled itself: a new element around the button made a second row for VoiceOver.
        .accessibilityLabel(title)
        .accessibilityValue([value, detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(hint)
        .accessibilityAddTraits(.isButton)
    }
}

/// A thin divider inside cards.
struct TargetsDivider: View {
    var body: some View { Rectangle().fill(Color.exBorder.opacity(0.6)).frame(height: 0.5).accessibilityHidden(true) }
}
