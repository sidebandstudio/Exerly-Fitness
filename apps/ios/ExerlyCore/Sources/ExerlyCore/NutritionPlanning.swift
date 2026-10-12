import Foundation

// The arithmetic behind the targets screen and its plan editor: rates in the
// person's unit, weekday shares, typed targets, what a new version rests on,
// live previews, goal projections and when the next check-in falls. See
// docs/design/011-nutrition-targets.md.

// MARK: Rates

/// A goal's weekly rate as the person sees it: a share of bodyweight, and the
/// same rate in their unit a week.
public enum NutritionRate {
    /// The preset rates, as shares of bodyweight a week.
    public static func presets(for direction: NutritionGoal.Direction) -> [Double] {
        switch direction {
        case .lose: [0.0025, 0.005, 0.0075, 0.01]
        case .gain: [0.001, 0.0025, 0.005]
        case .maintain: []
        }
    }

    /// The preset rates for a trend weight of `trend` kilograms: round amounts
    /// a week in `unit` (0.5, 1, 1.5 and 2 lb to lose, 0.2 to 0.8 lb to gain;
    /// 0.25 to 1 kg to lose, 0.1 to 0.4 kg to gain), those within the
    /// direction's maximum, as shares of bodyweight. Without a trend weight,
    /// or when none fits, the shares of `presets(for:)`.
    public static func presets(for direction: NutritionGoal.Direction, trend: Double?, unit: MassUnit) -> [Double] {
        guard let trend, trend > 0 else { return presets(for: direction) }
        let amounts: [Double] = switch (direction, unit) {
        case (.lose, .pounds): [0.5, 1, 1.5, 2]
        case (.lose, .kilograms): [0.25, 0.5, 0.75, 1]
        case (.gain, .pounds): [0.2, 0.4, 0.6, 0.8]
        case (.gain, .kilograms): [0.1, 0.2, 0.3, 0.4]
        case (.maintain, _): []
        }
        let shares = amounts.map { rounded(Mass($0, unit).kilograms / trend) }.filter { $0 <= maximum(for: direction) }
        return shares.isEmpty ? presets(for: direction) : shares
    }

    /// The rate a direction starts at: 0.5 % to lose, 0.25 % to gain.
    public static func standard(for direction: NutritionGoal.Direction) -> Double {
        switch direction {
        case .lose: 0.005
        case .gain: 0.0025
        case .maintain: 0
        }
    }

    /// The preset nearest `standard(for:)`, so a direction starts on a round
    /// amount in `unit`.
    public static func standard(for direction: NutritionGoal.Direction, trend: Double?, unit: MassUnit) -> Double {
        let standard = standard(for: direction)
        return presets(for: direction, trend: trend, unit: unit).min { abs($0 - standard) < abs($1 - standard) } ?? standard
    }

    /// The fastest rate a direction allows.
    public static func maximum(for direction: NutritionGoal.Direction) -> Double {
        switch direction {
        case .lose: NutritionTargets.maximumLoss
        case .gain: NutritionTargets.maximumGain
        case .maintain: 0
        }
    }

    /// The change a week at `share` of a trend weight of `trend` kilograms, in `unit`, unsigned.
    public static func weekly(_ share: Double, trend: Double, in unit: MassUnit) -> Double {
        Mass.kg(share * trend).value(in: unit)
    }

    /// The fine control's step a week: 0.1 lb or 0.05 kg.
    public static func step(for unit: MassUnit) -> Double { unit == .pounds ? 0.1 : 0.05 }

    /// The step without a trend weight: 0.05 % of bodyweight a week.
    public static let shareStep = 0.0005

    /// `share` moved by `steps` steps of the weekly amount in `unit`, landing
    /// on a whole step, and kept between one step and the direction's
    /// maximum. It moves from the amount as the editor shows it (to 0.1 lb or
    /// 0.01 kg), so each step changes what's shown. Returned as a share of
    /// `trend`. Without a trend weight it moves by `shareStep` from the share
    /// shown to 0.01 %.
    public static func nudged(_ share: Double, by steps: Int, direction: NutritionGoal.Direction, trend: Double?,
                              unit: MassUnit) -> Double {
        let maximum = maximum(for: direction)
        guard maximum > 0, steps != 0 else { return share }
        // In steps from the shown amount, with a little tolerance so one on a step stays there.
        func moved(_ amount: Double, shown: Double, step: Double) -> Double {
            let position = ((amount / shown).rounded() * shown / step * 1000).rounded() / 1000
            return max(1, steps > 0 ? position.rounded(.down) + Double(steps) : position.rounded(.up) + Double(steps))
        }
        guard let trend, trend > 0 else {
            return min((moved(share, shown: 0.0001, step: shareStep) * shareStep * 100_000).rounded() / 100_000, maximum)
        }
        let step = step(for: unit)
        let amount = moved(weekly(share, trend: trend, in: unit), shown: unit == .pounds ? 0.1 : 0.01, step: step) * step
        return rounded(min(Mass(amount, unit).kilograms / trend, maximum))
    }

    /// A share to seven decimals, so the same amount always gives the same share.
    static func rounded(_ share: Double) -> Double { (share * 10_000_000).rounded() / 10_000_000 }
}

// MARK: Weekday budgets

/// How the weekly budget is shared out by weekday: relative weights, Sunday
/// first. Raising one day takes the difference from the others, since the
/// weekly total stays.
public enum WeekdayBudget {
    public static let even = Array(repeating: 1.0, count: 7)
    /// One step of the custom control.
    public static let step = 0.05
    /// The weights the custom control allows.
    public static let range: ClosedRange<Double> = 0.5...1.5

    /// Whether every day has the same budget.
    public static func isEven(_ weights: [Double]) -> Bool {
        weights.count == 7 && weights.allSatisfy { $0 > 0 && $0 == weights[0] }
    }

    /// The weights with `day` moved by `steps` steps, on a whole step within `range`.
    public static func nudged(_ weights: [Double], day: Weekday, by steps: Int) -> [Double] {
        guard weights.count == 7 else { return weights }
        var next = weights
        let index = day.rawValue - 1
        let position = (next[index] / step * 1000).rounded() / 1000
        let moved = steps > 0 ? position.rounded(.down) + Double(steps) : position.rounded(.up) + Double(steps)
        next[index] = min(max((moved * step * 100).rounded() / 100, range.lowerBound), range.upperBound)
        return next
    }
}

// MARK: Typed targets

extension DailyTargets {
    /// The energy the macros supply: 4 kcal a gram of protein and of
    /// carbohydrate, 9 of fat.
    public var macroEnergy: Double { 4 * protein + 4 * carbohydrate + 9 * fat }

    /// Each macro's share of `macroEnergy`; all zero without any.
    public var macroShares: (protein: Double, carbohydrate: Double, fat: Double) {
        let total = macroEnergy
        guard total > 0 else { return (0, 0, 0) }
        return (4 * protein / total, 4 * carbohydrate / total, 9 * fat / total)
    }

    /// Each target's mean over `days`; nil without any.
    public static func average(_ days: [DailyTargets]) -> DailyTargets? {
        guard !days.isEmpty else { return nil }
        let count = Double(days.count)
        return DailyTargets(energy: days.reduce(0) { $0 + $1.energy } / count,
                            protein: days.reduce(0) { $0 + $1.protein } / count,
                            fat: days.reduce(0) { $0 + $1.fat } / count,
                            carbohydrate: days.reduce(0) { $0 + $1.carbohydrate } / count)
    }
}

extension NutritionPlan {
    /// The week's mean day; nil without targets.
    public var averageDay: DailyTargets? { DailyTargets.average(targets) }
}

extension NutritionTargets {
    /// Typed targets for an average day, shared out by weekday: the week's
    /// energy (seven of the typed day) by `weekdayWeights`, protein the same
    /// on every day with a budget, and fat and carbohydrate in proportion to
    /// the day's energy. With even weights every day is the typed day.
    public static func manual(_ day: DailyTargets, weekdayWeights: [Double]) throws -> [DailyTargets] {
        var problems: [String] = []
        if !(day.energy.isFinite && day.energy > 0) { problems.append("Calories must be above 0") }
        if [day.protein, day.fat, day.carbohydrate].contains(where: { !$0.isFinite || $0 < 0 }) {
            problems.append("Protein, carbs and fat must be 0 or more")
        }
        problems += Self.problems(goal: NutritionGoal(.maintain), weekdayWeights: weekdayWeights)
        guard problems.isEmpty else { throw NutritionStore.StoreError.invalid(problems) }
        let energies = shares(of: (day.energy * 7).rounded(), by: weekdayWeights)
        return energies.enumerated().map { index, energy in
            guard weekdayWeights[index] > 0 else { return DailyTargets(energy: 0, protein: 0, fat: 0, carbohydrate: 0) }
            let ratio = energy / day.energy
            return DailyTargets(energy: energy, protein: day.protein.rounded(), fat: (day.fat * ratio).rounded(),
                                carbohydrate: (day.carbohydrate * ratio).rounded())
        }
    }
}

// MARK: What a new version rests on

/// The expenditure and trend weight a new plan version is computed from, and
/// where they came from.
public struct PlanBasisChoice: Sendable, Hashable {
    public enum Source: String, Sendable, Hashable {
        /// The latest estimate, from logged intake and weigh-ins.
        case measured
        /// The newest plan's expenditure, at today's trend weight.
        case previous
        /// The profile's formula (Mifflin–St Jeor times activity).
        case formula
    }

    public var basis: PlanBasis
    public var source: Source

    public init(basis: PlanBasis, source: Source) {
        self.basis = basis
        self.source = source
    }

    /// The latest estimate once expenditure is measured; else the expenditure
    /// of the newest plan that has a basis; else the formula from `profile`.
    /// Trend weight is today's when there is one. Nil when none applies.
    public static func current(summary: WeightTrend.Summary?, plans: [NutritionPlan], profile: BodyProfile?) -> PlanBasisChoice? {
        let trend = summary.map { ($0.trend * 100).rounded() / 100 }
        if let summary, summary.expenditure.isMeasured, let trend {
            return PlanBasisChoice(basis: PlanBasis(expenditure: summary.expenditure.kcal.rounded(),
                                                    expenditureError: summary.expenditure.error.rounded(), trendWeight: trend),
                                   source: .measured)
        }
        if let previous = plans.last(where: { $0.basis != nil })?.basis {
            return PlanBasisChoice(basis: PlanBasis(expenditure: previous.expenditure, expenditureError: previous.expenditureError,
                                                    trendWeight: trend ?? previous.trendWeight), source: .previous)
        }
        guard var profile else { return nil }
        if let trend { profile.weight = .kg(trend) }
        return (try? PlanBasis.formula(profile)).map { PlanBasisChoice(basis: $0, source: .formula) }
    }
}

// MARK: Drafts and previews

/// The plan editor's choices before they become a version.
public struct NutritionPlanDraft: Sendable, Hashable {
    public var goal: NutritionGoal
    public var mode: PlanMode
    public var diet: DietType
    public var protein: ProteinLevel
    /// Relative budgets, Sunday first.
    public var weekdayWeights: [Double]
    public var checkInDay: Weekday
    public var allowBelowFloor: Bool
    /// A manual plan's typed average day.
    public var manual: DailyTargets
    /// Kept from the plan the draft started from.
    public var nutrientGoals: [Nutrient: NutrientGoal]?
    public var pinnedNutrients: [Nutrient]?

    /// Starts from `plan`; without one, a coached plan toward `goal` with
    /// balanced macros, moderate protein, even days and Monday check-ins.
    public init(_ plan: NutritionPlan?, goal: NutritionGoal = NutritionGoal(.lose, weeklyRate: 0.005)) {
        self.goal = plan?.goal ?? goal
        mode = plan?.mode ?? .coached
        diet = plan?.diet ?? .balanced
        protein = plan?.protein ?? .moderate
        weekdayWeights = plan?.weekdayWeights ?? WeekdayBudget.even
        checkInDay = plan?.checkInDay ?? .monday
        allowBelowFloor = plan?.allowBelowFloor ?? false
        manual = plan?.averageDay.map(Self.whole) ?? DailyTargets(energy: 2000, protein: 140, fat: 65, carbohydrate: 210)
        nutrientGoals = plan?.nutrientGoals
        pinnedNutrients = plan?.pinnedNutrients
        if self.goal.direction != .maintain && !(self.goal.weeklyRate > 0) {
            self.goal.weeklyRate = NutritionRate.standard(for: self.goal.direction)
        }
    }

    public struct Preview: Sendable, Hashable {
        /// The version, when it can be made.
        public var plan: NutritionPlan?
        /// Why it can't, in words.
        public var problems: [String]
    }

    /// The version this draft makes from `date` on: computed from `basis`
    /// when coached or collaborative, the typed day when manual. Maintaining
    /// keeps no rate or goal weight. None for a goal weight that `basis`'s
    /// trend has already reached, which would be saved as a goal it can't
    /// move toward.
    public func preview(startingOn date: LocalDate, basis: PlanBasis?, id: UUID = UUID(), now: Date = Date()) -> Preview {
        var goal = goal
        if goal.direction == .maintain { goal = NutritionGoal(.maintain) }
        if let trend = basis?.trendWeight, let problem = goal.reachedProblem(trend: trend) {
            return Preview(plan: nil, problems: [problem])
        }
        var plan = NutritionPlan(id: id, startDate: date, createdAt: now.roundedToMilliseconds, goal: goal, mode: mode, diet: diet,
                                 protein: protein, weekdayWeights: weekdayWeights, checkInDay: checkInDay,
                                 allowBelowFloor: allowBelowFloor, nutrientGoals: nutrientGoals,
                                 pinnedNutrients: pinnedNutrients)
        do {
            if mode == .manual {
                plan.targets = try NutritionTargets.manual(manual, weekdayWeights: weekdayWeights)
            } else if let basis {
                plan = try plan.computed(from: basis)
            } else {
                return Preview(plan: nil, problems: ["Exerly needs your expenditure or your profile to work out targets"])
            }
        } catch NutritionStore.StoreError.invalid(let problems) {
            return Preview(plan: nil, problems: problems)
        } catch {
            return Preview(plan: nil, problems: ["\(error)"])
        }
        let problems = plan.validationErrors
        return Preview(plan: problems.isEmpty ? plan : nil, problems: problems)
    }

    /// Whole numbers, for typing.
    public static func whole(_ day: DailyTargets) -> DailyTargets {
        DailyTargets(energy: day.energy.rounded(), protein: day.protein.rounded(), fat: day.fat.rounded(),
                     carbohydrate: day.carbohydrate.rounded())
    }
}

// MARK: Goal projection

extension NutritionGoal {
    public enum Projection: Sendable, Hashable {
        case noGoalWeight
        /// Maintaining: no date to reach.
        case maintaining
        /// The trend is already at or past the goal weight.
        case reached
        /// When the trend reaches the goal weight at the planned rate, in whole weeks.
        case on(LocalDate, weeks: Int)
    }

    /// Where the goal weight lies from a trend weight in kilograms on `date`.
    public func projection(from trend: Double, on date: LocalDate) -> Projection {
        guard goalWeight != nil else { return .noGoalWeight }
        guard direction != .maintain, weeklyRate > 0 else { return .maintaining }
        guard let eta = eta(from: trend, on: date) else { return .noGoalWeight }
        if eta == date { return .reached }
        return .on(eta, weeks: Int((Double(date.days(until: eta)) / 7).rounded(.up)))
    }

    /// How close to the goal weight counts as at it, in kilograms (about 0.1 lb).
    public static let atGoal = 0.05

    /// Whether a trend weight of `trend` kilograms is already at or past the
    /// goal weight in the goal's direction: at or under it to lose, at or over
    /// it to gain. Targets then hold the trend rather than overshoot. False
    /// without a goal weight or when maintaining.
    public func isReached(trend: Double) -> Bool {
        guard let goal = goalWeight?.kilograms, goal > 0, trend > 0 else { return false }
        switch direction {
        case .lose: return trend <= goal
        case .gain: return trend >= goal
        case .maintain: return false
        }
    }

    /// What the goal weight asks for once `isReached`: the other direction for
    /// a goal weight on the far side of the trend, or maintaining within
    /// `atGoal` of it. Nil while the goal's own direction leads there.
    public func redirection(trend: Double) -> Direction? {
        guard isReached(trend: trend), let goal = goalWeight?.kilograms else { return nil }
        if abs(trend - goal) < Self.atGoal { return .maintain }
        return goal > trend ? .gain : .lose
    }

    /// Why a new version can't aim for a goal weight the trend has reached.
    func reachedProblem(trend: Double) -> String? {
        switch redirection(trend: trend) {
        case .gain: "Your trend weight is already under this goal weight, so losing can't reach it. Switch to Gain, or Maintain."
        case .lose: "Your trend weight is already over this goal weight, so gaining can't reach it. Switch to Lose, or Maintain."
        case .maintain: "Your trend weight is already at this goal weight. Choose Maintain, or a new goal weight."
        case nil: nil
        }
    }
}

// MARK: Check-in timing and decisions

extension NutritionCheckIn {
    /// The ID of the check-in's proposal for `plan` on the check-in day
    /// `date`, the same on every device.
    public static func proposalID(plan: NutritionPlan, date: LocalDate) -> UUID {
        UUID(named: "\(plan.id.uuidString)/\(date)", in: namespace)
    }

    /// The check-in day after `review` of `plan`: the reviewed day while it
    /// is still open, else the next check-in day after the plan starts.
    public static func nextDate(plan: NutritionPlan, review: Review) -> LocalDate {
        let first = plan.startDate.startOfWeek(firstWeekday: plan.checkInDay).adding(days: 7)
        if review.date < first { return first }
        switch review.outcome {
        case .notDue, .manual: return review.date.adding(days: 7)
        case .notEnoughData, .unchanged, .cannotKeepGoal, .proposed: return review.date
        }
    }

    /// The newest proposal a check-in made, from `proposals` in any order.
    public static func latest(in proposals: [Proposal]) -> Proposal? {
        proposals.filter { $0.author == author }.max { $0.createdAt < $1.createdAt }
    }

    /// The plan version a check-in's proposal adds.
    public static func proposedPlan(_ proposal: Proposal) -> NutritionPlan? {
        proposal.changes.first { $0.kind == NutritionStore.planKind }?.after.flatMap { try? $0.decode(NutritionPlan.self) }
    }

    /// The check-in's proposal with the person's changes to the version it
    /// adds, for a collaborative plan: the same ID, evidence and falsifier,
    /// and a title and summary that say what changed.
    public static func adjusted(_ proposal: Proposal, to plan: NutritionPlan, from current: NutritionPlan) throws -> Proposal {
        var adjusted = proposal
        let proposed = (proposedPlan(proposal)?.weeklyEnergy ?? 0) / 7
        let before = current.weeklyEnergy / 7
        let after = plan.weeklyEnergy / 7
        adjusted.changes = [try ProposedChange(kind: NutritionStore.planKind, id: plan.id.uuidString,
                                               before: nil as NutritionPlan?, after: plan)]
        adjusted.title = "New targets, adjusted: \(Int(after.rounded())) kcal a day"
        adjusted.summary = "This week's check-in proposed \(Int(proposed.rounded())) kcal a day. You adjusted it, so your "
            + "average daily budget moves from \(Int(before.rounded())) to \(Int(after.rounded())) kcal."
        return adjusted
    }
}

extension NutritionStore {
    /// The version in force before `plan` took over: the one before it in
    /// `plans`, or the one in force today when `plan` isn't saved.
    public func plan(before plan: NutritionPlan) -> NutritionPlan? {
        guard let index = plans.firstIndex(where: { $0.id == plan.id }) else {
            return plans.last { Self.planOrder($0, plan) }
        }
        return index > 0 ? plans[index - 1] : nil
    }
}
