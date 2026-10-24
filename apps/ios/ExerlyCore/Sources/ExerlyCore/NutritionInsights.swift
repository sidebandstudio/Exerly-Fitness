import Foundation

/// Averages, goals, completeness and timing over a span of days. See
/// docs/design/013-nutrient-insights.md.
public struct NutrientOverview: Sendable, Hashable {
    public struct Row: Sendable, Hashable {
        public var nutrient: Nutrient
        /// Mean daily amount over the counted days, in the nutrient's unit.
        /// Foods that don't report the nutrient add nothing, so read it with `completeness`.
        public var average: Double
        /// Counted days with some of this nutrient logged.
        public var observedDays: Int
        /// The goal in force on the last counted day.
        public var goal: NutrientGoal?
        /// Intake over the goal's reference amount, each day against its own goal.
        public var shareOfGoal: Double?
        /// Of the counted days' entries, the share whose food reports this nutrient.
        public var completeness: Double
    }

    public var from: LocalDate
    public var through: LocalDate
    /// Days that count: those with entries not marked partial, and fasting days.
    public var days: Int
    public var entries: Int
    /// Every nutrient with an amount or a goal, and the standard ones even
    /// when nothing reported them, in catalog order.
    public var rows: [Row]
}

/// Energy logged by local hour. An entry is timed when it was logged, or set,
/// on its own day; one logged on another day has no known time.
public struct IntakeTiming: Sendable, Hashable {
    public struct Hour: Sendable, Hashable {
        public var hour: Int
        public var energy: Double
        public var entries: Int
    }

    /// Twenty-four hours, midnight first.
    public var hours: [Hour]
    public var untimedEntries: Int
}

extension NutritionStore {
    /// Whether a day counts toward averages: it has entries and isn't marked
    /// partial, or it is marked fasting (a real zero).
    public func counts(_ date: LocalDate) -> Bool {
        let status = day(date).status
        return status == .fasting || (status != .partial && !entries(on: date).isEmpty)
    }

    public func overview(from start: LocalDate, through end: LocalDate) -> NutrientOverview {
        let counted = start <= end ? (0...start.days(until: end)).map { start.adding(days: $0) }.filter(counts) : []
        let logged = counted.flatMap { entries(on: $0) }
        var intake: [LocalDate: NutrientAmounts] = [:]
        for date in counted { intake[date] = entries(on: date).reduce(NutrientAmounts()) { $0 + $1.nutrients } }
        let rows = Nutrient.allCases.compactMap { nutrient -> NutrientOverview.Row? in
            let observed = counted.filter { intake[$0]?[nutrient] != nil }
            let goal = counted.last.flatMap { date in plan(on: date)?.goal(for: nutrient, on: date) }
            guard !observed.isEmpty || goal != nil || nutrient.isStandard else { return nil }
            let total = counted.reduce(0.0) { $0 + (intake[$1]?[nutrient] ?? 0) }
            var goalTotal = 0.0, goalIntake = 0.0
            for date in counted {
                guard let reference = plan(on: date)?.goal(for: nutrient, on: date)?.reference, reference > 0 else { continue }
                goalTotal += reference
                goalIntake += intake[date]?[nutrient] ?? 0
            }
            let reporting = logged.filter { $0.food.per100g[nutrient] != nil }.count
            return NutrientOverview.Row(nutrient: nutrient, average: counted.isEmpty ? 0 : total / Double(counted.count),
                                        observedDays: observed.count, goal: goal,
                                        shareOfGoal: goalTotal > 0 ? goalIntake / goalTotal : nil,
                                        completeness: logged.isEmpty ? 0 : Double(reporting) / Double(logged.count))
        }
        return NutrientOverview(from: start, through: end, days: counted.count, entries: logged.count, rows: rows)
    }

    public func timing(from start: LocalDate, through end: LocalDate, timeZone: TimeZone) -> IntakeTiming {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var hours = (0..<24).map { IntakeTiming.Hour(hour: $0, energy: 0, entries: 0) }
        var untimed = 0
        for entry in entries where (start...end).contains(entry.date) {
            guard entry.timeUnknown != true, LocalDate(entry.loggedAt, in: timeZone) == entry.date else {
                untimed += 1
                continue
            }
            let hour = calendar.component(.hour, from: entry.loggedAt)
            hours[hour].energy += entry.nutrients.energy
            hours[hour].entries += 1
        }
        return IntakeTiming(hours: hours, untimedEntries: untimed)
    }
}

extension NutritionGoal {
    /// When trend weight reaches the goal weight at the planned rate, which
    /// compounds weekly: today if it already has, nil without a goal weight,
    /// when maintaining, or when the goal lies the other way.
    public func eta(from trend: Double, on date: LocalDate) -> LocalDate? {
        guard let goal = goalWeight?.kilograms, signedRate != 0, trend > 0, goal > 0 else { return nil }
        if (signedRate < 0 && trend <= goal) || (signedRate > 0 && trend >= goal) { return date }
        let weeks = log(goal / trend) / log(1 + signedRate)
        guard weeks.isFinite, weeks > 0 else { return nil }
        return date.adding(days: Int((weeks * 7).rounded(.up)))
    }

    /// The expected trend weight at the end of each coming week, stopping at the goal weight.
    public func checkpoints(from trend: Double, on date: LocalDate, weeks: Int) -> [(date: LocalDate, weight: Double)] {
        guard signedRate != 0, weeks > 0 else { return [] }
        var weight = trend
        var points: [(date: LocalDate, weight: Double)] = []
        for week in 1...weeks {
            weight *= 1 + signedRate
            if let goal = goalWeight?.kilograms, signedRate < 0 ? weight <= goal : weight >= goal {
                points.append((date.adding(days: week * 7), goal))
                break
            }
            points.append((date.adding(days: week * 7), weight))
        }
        return points
    }
}
