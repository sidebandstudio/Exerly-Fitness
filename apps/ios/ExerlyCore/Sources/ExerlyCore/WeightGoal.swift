import Foundation

/// A weight goal over time: the path it planned from the day it was set, and
/// where the trend stands against that path. The goal itself lives in plan
/// versions (`NutritionGoal`); a check-in or a nutrient-goal change adds a
/// version with the same goal, which continues the path rather than starting
/// a new one. Weights are in kilograms. See docs/design/011-nutrition-targets.md.
public enum WeightGoal {
    /// How far the trend may sit from the planned path and still count as on
    /// track, in kilograms (about 1 lb), unless the trend's own standard
    /// deviation is wider.
    public static let tolerance = 0.5

    /// The trend `days` after a day it was `trend`, at the goal's rate, which
    /// compounds weekly as `NutritionGoal.checkpoints` does, stopping at the
    /// goal weight. Flat when maintaining or already at the goal weight.
    public static func planned(from trend: Double, goal: NutritionGoal, days: Int) -> Double {
        let rate = goal.signedRate
        guard rate != 0, days > 0 else { return trend }
        let weight = trend * pow(1 + rate, Double(days) / 7)
        guard let target = goal.goalWeight?.kilograms else { return weight }
        if rate < 0 { return trend <= target ? trend : max(weight, target) }
        return trend >= target ? trend : min(weight, target)
    }

    /// A goal in force over consecutive days, with the trend it started from.
    public struct Stretch: Sendable, Hashable {
        public var goal: NutritionGoal
        /// The day the goal was set, which anchors its path, and the last day
        /// it was in force, which is `through` for the goal in force now.
        public var start: LocalDate
        public var end: LocalDate
        /// The trend on `start`, or on the first day with an estimate when the
        /// goal was set before the first weigh-in.
        public var startTrend: Double
        public var anchor: LocalDate

        public func planned(on date: LocalDate) -> Double {
            WeightGoal.planned(from: startTrend, goal: goal, days: anchor.days(until: date))
        }
    }

    /// The goals in force from `from` through `through`, oldest first, from
    /// plan versions oldest first. Versions in a row with the same goal make
    /// one stretch. Days before the first estimate have no trend to plan from.
    public static func stretches(_ versions: [NutritionPlan], estimates: [EnergyBalance.Estimate],
                                 from: LocalDate, through: LocalDate) -> [Stretch] {
        guard let first = estimates.first, from <= through else { return [] }
        var stretches: [Stretch] = []
        for (index, version) in versions.enumerated() {
            let next = versions.dropFirst(index + 1).first?.startDate
            let end = next.map { $0.adding(days: -1) } ?? through
            guard end >= version.startDate else { continue }
            if var last = stretches.last, last.goal == version.goal {
                last.end = end
                stretches[stretches.count - 1] = last
                continue
            }
            let anchor = max(version.startDate, first.date)
            guard anchor <= end, let trend = estimates.first(where: { $0.date == anchor })?.trend else { continue }
            stretches.append(Stretch(goal: version.goal, start: version.startDate, end: end, startTrend: trend, anchor: anchor))
        }
        return stretches.filter { $0.end >= from && $0.start <= through }
    }

    /// Where the trend stands against its planned path.
    public struct Standing: Sendable, Hashable {
        public enum Status: Sendable, Hashable {
            /// Within `band` of the plan.
            case onTrack
            /// Further toward the goal than planned.
            case ahead
            /// Short of the plan; when maintaining, any drift past the band.
            case behind
        }

        public var status: Status
        /// The trend minus the planned weight.
        public var offset: Double
        /// How far from the plan still counts as on track.
        public var band: Double
    }

    /// The trend against the weight planned for the same day: on track within
    /// `tolerance` or one standard deviation of the trend, whichever is wider.
    public static func standing(trend: Double, trendError: Double, planned: Double, direction: NutritionGoal.Direction,
                                tolerance: Double = tolerance) -> Standing {
        let offset = trend - planned
        let band = max(tolerance, trendError)
        let status: Standing.Status
        if abs(offset) <= band {
            status = .onTrack
        } else {
            switch direction {
            case .lose: status = offset < 0 ? .ahead : .behind
            case .gain: status = offset > 0 ? .ahead : .behind
            case .maintain: status = .behind
            }
        }
        return Standing(status: status, offset: offset, band: band)
    }
}

extension NutritionRate {
    /// The share of a trend weight of `trend` kilograms that `amount` in
    /// `unit` a week makes: `weekly` reversed. Nil without a trend weight.
    public static func share(ofWeekly amount: Double, trend: Double, in unit: MassUnit) -> Double? {
        guard trend > 0, amount.isFinite else { return nil }
        return Mass(abs(amount), unit).kilograms / trend
    }
}
