import Foundation

/// The spans Progress → Nutrition offers. Each ends yesterday, the last day
/// that can be finished; today belongs to the diary.
public enum IntakeRange: String, Sendable, Hashable, CaseIterable, Identifiable {
    case yesterday, week, thisMonth, month, quarter, year

    public var id: String { rawValue }

    /// The span: a number of whole days through yesterday, or for this
    /// month, the calendar month so far including today.
    public func span(today: LocalDate) -> ClosedRange<LocalDate> {
        let end = today.adding(days: -1)
        let days: Int
        switch self {
        case .thisMonth: return LocalDate(year: today.year, month: today.month, day: 1)!...today
        case .yesterday: days = 1
        case .week: days = 7
        case .month: days = 30
        case .quarter: days = 91
        case .year: days = 365
        }
        return end.adding(days: -(days - 1))...end
    }

    /// Days each chart bar covers: one, or a week across a year.
    public var barDays: Int { self == .year ? 7 : 1 }
}

/// One day of a span: what was logged, and whether it counts as known intake.
public struct IntakeDay: Sendable, Hashable, Identifiable {
    public var date: LocalDate
    public var status: DayStatus
    /// As `NutritionStore.counts`: entries and not marked partial, or a fast.
    public var counted: Bool
    public var entries: Int
    /// Every entry's nutrients added up; unknowns stay out.
    public var totals: NutrientAmounts

    public var id: LocalDate { date }
    /// Marked partial, or food was logged but the day doesn't count, so it
    /// isn't known intake.
    public var isPartial: Bool { !counted && (entries > 0 || status == .partial) }

    public init(date: LocalDate, status: DayStatus, counted: Bool, entries: Int, totals: NutrientAmounts) {
        self.date = date
        self.status = status
        self.counted = counted
        self.entries = entries
        self.totals = totals
    }
}

/// How intake compared with a goal over the counted days that had one, each
/// day against its own goal.
public struct GoalComparison: Sendable, Hashable {
    /// Mean intake over those days.
    public var average: Double
    /// Mean of their goals' reference amounts.
    public var reference: Double
    /// Counted days with a goal.
    public var days: Int
    /// Of those, the days inside the goal's band.
    public var met: Int

    public var difference: Double { average - reference }
    /// Intake over the goal: 1 is exactly on it. Nil without a positive reference.
    public var share: Double? { reference > 0 ? average / reference : nil }
}

/// A chart bar: one day, or several days averaged.
public struct IntakeBar: Sendable, Hashable, Identifiable {
    public var start: LocalDate
    public var days: Int
    /// Mean over the bar's counted days; nil when none counted.
    public var value: Double?
    /// For a one-day bar that doesn't count, what was logged on it.
    public var uncounted: Double?
    public var countedDays: Int
    /// The goal over the bar: each part averaged over the days that have it.
    public var goal: NutrientGoal?

    public var id: LocalDate { start }
    public var end: LocalDate { start.adding(days: days - 1) }
}

/// Intake day by day over a span, with the goals in force on each day.
/// Averages are per counted day, so days without a full log don't pull them
/// down. See docs/design/013-nutrient-insights.md.
public struct IntakeSeries: Sendable, Hashable {
    /// How far from a lone target still meets it: 10 %.
    public static let tolerance = 0.1

    public var from: LocalDate
    public var through: LocalDate
    /// Every date of the span, oldest first.
    public var days: [IntakeDay]
    /// Plan versions, the earliest in force first.
    public var plans: [NutritionPlan]

    public init(from: LocalDate, through: LocalDate, days: [IntakeDay], plans: [NutritionPlan]) {
        self.from = from
        self.through = through
        self.days = days
        self.plans = plans
    }

    public var countedDays: Int { days.filter(\.counted).count }
    public var partialDays: Int { days.filter(\.isPartial).count }
    /// Counted days marked as a fast, a known zero or what was logged on them.
    public var fastedDays: Int { days.filter { $0.counted && $0.status == .fasting }.count }
    /// Days with nothing logged, not marked partial and no fast: unknown, not zero.
    public var emptyDays: Int { days.count - countedDays - partialDays }

    /// The goal on a date, from the plan version in force then.
    public func goal(for nutrient: Nutrient, on date: LocalDate) -> NutrientGoal? {
        plans.last { $0.startDate <= date }?.goal(for: nutrient, on: date)
    }

    /// The counted days' goals with each part averaged, so weekday targets
    /// read as one goal; nil when no counted day had one.
    public func averageGoal(_ nutrient: Nutrient) -> NutrientGoal? {
        Self.mean(days.filter(\.counted).compactMap { goal(for: nutrient, on: $0.date) })
    }

    /// Whether the counted days' goals differ, so an average goal needs saying.
    public func goalsVary(_ nutrient: Nutrient) -> Bool {
        Set(days.filter(\.counted).compactMap { goal(for: nutrient, on: $0.date) }).count > 1
    }

    /// Mean daily amount over the counted days, as `NutritionStore.overview`
    /// gives it: foods that don't report the nutrient add nothing. Nil when
    /// no day counts.
    public func average(_ nutrient: Nutrient) -> Double? {
        let counted = days.filter(\.counted)
        guard !counted.isEmpty else { return nil }
        return counted.reduce(0) { $0 + ($1.totals[nutrient] ?? 0) } / Double(counted.count)
    }

    /// Intake against the goal over counted days with one; nil when none has.
    public func comparison(_ nutrient: Nutrient, tolerance: Double = tolerance) -> GoalComparison? {
        var intake = 0.0, reference = 0.0, count = 0, met = 0
        for day in days where day.counted {
            guard let goal = goal(for: nutrient, on: day.date), let amount = goal.reference, amount > 0 else { continue }
            let eaten = day.totals[nutrient] ?? 0
            intake += eaten
            reference += amount
            count += 1
            if goal.contains(eaten, tolerance: tolerance) { met += 1 }
        }
        guard count > 0 else { return nil }
        return GoalComparison(average: intake / Double(count), reference: reference / Double(count), days: count, met: met)
    }

    /// Bars of `length` days from the span's first day; the last may be shorter.
    public func bars(_ nutrient: Nutrient, length: Int = 1) -> [IntakeBar] {
        let size = max(1, length)
        return stride(from: 0, to: days.count, by: size).map { index in
            let slice = days[index..<min(index + size, days.count)]
            let counted = slice.filter(\.counted)
            let value = counted.isEmpty ? nil : counted.reduce(0) { $0 + ($1.totals[nutrient] ?? 0) } / Double(counted.count)
            let single = slice.count == 1 ? slice.first : nil
            let uncounted = single.flatMap { $0.isPartial ? ($0.totals[nutrient] ?? 0) : nil }
            let goals = slice.compactMap { goal(for: nutrient, on: $0.date) }
            return IntakeBar(start: slice.first!.date, days: slice.count, value: value, uncounted: uncounted,
                             countedDays: counted.count, goal: Self.mean(goals))
        }
    }

    /// Each macro's share of the average day's energy, from Atwater factors.
    /// Empty when nothing counted or the macros are unknown.
    public var energyShares: [Nutrient: Double] {
        let parts = [Nutrient.protein, .carbohydrate, .fat, .alcohol].compactMap { nutrient -> (Nutrient, Double)? in
            guard let grams = average(nutrient), let factor = nutrient.kilocaloriesPerGram, grams > 0 else { return nil }
            return (nutrient, grams * factor)
        }
        let total = parts.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return [:] }
        return Dictionary(uniqueKeysWithValues: parts.map { ($0.0, $0.1 / total) })
    }

    /// Each part of the goals averaged over the goals that have it.
    static func mean(_ goals: [NutrientGoal]) -> NutrientGoal? {
        guard !goals.isEmpty else { return nil }
        func mean(_ part: KeyPath<NutrientGoal, Double?>) -> Double? {
            let values = goals.compactMap { $0[keyPath: part] }
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        return NutrientGoal(floor: mean(\.floor), target: mean(\.target), ceiling: mean(\.ceiling))
    }
}

extension NutrientGoal {
    /// The amounts that meet the goal: from the floor, or from `tolerance`
    /// under a target without one, up to the ceiling, or to `tolerance` over
    /// a target with neither. Nil ends are open.
    public func band(tolerance: Double = IntakeSeries.tolerance) -> (lower: Double?, upper: Double?) {
        let lower = floor ?? target.map { $0 * (1 - tolerance) }
        let upper = ceiling ?? (floor == nil ? target.map { $0 * (1 + tolerance) } : nil)
        return (lower, upper)
    }

    public func contains(_ amount: Double, tolerance: Double = IntakeSeries.tolerance) -> Bool {
        let band = band(tolerance: tolerance)
        return (band.lower.map { amount >= $0 } ?? true) && (band.upper.map { amount <= $0 } ?? true)
    }
}

extension NutritionStore {
    /// Every day from `start` through `end`, with its intake and whether it counts.
    public func intakeSeries(from start: LocalDate, through end: LocalDate) -> IntakeSeries {
        guard start <= end else { return IntakeSeries(from: start, through: end, days: [], plans: plans) }
        var logged: [LocalDate: [FoodEntry]] = [:]
        for entry in entries where entry.date >= start && entry.date <= end { logged[entry.date, default: []].append(entry) }
        let days = (0...start.days(until: end)).map { offset -> IntakeDay in
            let date = start.adding(days: offset)
            let food = logged[date] ?? []
            let status = day(date).status
            // The rule of `counts(_:)`, without filtering every entry for each day.
            let counted = status == .fasting || (status != .partial && !food.isEmpty)
            return IntakeDay(date: date, status: status, counted: counted, entries: food.count,
                             totals: food.reduce(NutrientAmounts()) { $0 + $1.nutrients })
        }
        return IntakeSeries(from: start, through: end, days: days, plans: plans)
    }
}
