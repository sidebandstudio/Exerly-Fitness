import Foundation

/// The weekly review of a nutrition plan: new targets from the latest
/// expenditure and trend weight, as a proposal the person accepts. See
/// docs/design/011-nutrition-targets.md, which records how closely simulated
/// people following it reach their goal rate.
public enum NutritionCheckIn {
    public static let author = AgentIdentity(kind: .builtIn, name: "Exerly check-in")
    /// A smaller change to the daily budget isn't worth a proposal, in kcal.
    public static let minimumChange = 20.0
    /// An expenditure estimate less certain than this, one standard deviation
    /// in kcal, proposes nothing.
    public static let maximumError = 250.0
    static let namespace = UUID(uuidString: "28C5B64C-5DE9-4F33-AA47-17D99DBB135D")!

    public struct Review: Sendable, Hashable {
        public enum Outcome: String, Sendable, Hashable {
            /// No check-in day has passed since the plan started, or this one was already proposed.
            case notDue
            /// Manual plans get no proposals.
            case manual
            /// Too few complete days or weigh-ins for a confident estimate.
            case notEnoughData
            /// The targets would barely move.
            case unchanged
            /// The goal can't be kept on new targets, for the reasons in `problems`:
            /// a budget under the floor, or macros that don't fit. The person
            /// changes the goal.
            case cannotKeepGoal
            case proposed
        }

        public var outcome: Outcome
        /// The check-in day reviewed: the latest plan weekday on or before today.
        public var date: LocalDate
        /// Expenditure and trend as of the day before.
        public var estimate: EnergyBalance.Estimate?
        /// Trend weight's change over the seven days before, in kilograms.
        public var weekChange: Double?
        /// Complete or fasting days, and days with a weigh-in, of those seven.
        public var completeDays: Int
        public var weighInDays: Int
        /// Of those seven, the fasts among `completeDays`, and the days marked
        /// partial, which are left out. Counted by `NutritionStore.checkIn`.
        public var fastingDays = 0
        public var partialDays = 0
        public var problems: [String] = []
        public var proposal: Proposal?
    }

    /// Reviews the check-in due by `today` for `plan`, the version in force.
    /// `days` is the log up to yesterday (`NutritionStore.energyBalanceDays`),
    /// and `prior` an expenditure guess for its start, with one standard deviation.
    /// Evidence text uses `unit`; the plan and its numbers stay in kilograms.
    public static func review(plan: NutritionPlan, days: [EnergyBalance.Day], prior: (mean: Double, error: Double)?,
                              today: LocalDate, existing: [Proposal], now: Date, unit: MassUnit = .kilograms) throws -> Review {
        let date = today.startOfWeek(firstWeekday: plan.checkInDay)
        let id = UUID(named: "\(plan.id.uuidString)/\(date)", in: namespace)
        let week = days.filter { $0.date < date && $0.date >= date.adding(days: -7) }
        var review = Review(outcome: .notDue, date: date, completeDays: week.filter { $0.intake != nil }.count,
                            weighInDays: week.filter { !$0.weights.isEmpty }.count)
        guard plan.mode != .manual else {
            review.outcome = .manual
            return review
        }
        guard date > plan.startDate, !existing.contains(where: { $0.id == id }) else { return review }
        let estimates = EnergyBalance.estimate(days.filter { $0.date < date }, prior: prior)
        review.estimate = estimates.last
        if let last = estimates.last, let weekAgo = estimates.last(where: { $0.date <= last.date.adding(days: -7) }) {
            review.weekChange = last.trend - weekAgo.trend
        }
        guard let estimate = review.estimate, estimate.date == date.adding(days: -1),
              estimate.expenditureError <= maximumError else {
            review.outcome = .notEnoughData
            return review
        }
        var next = plan
        next.id = UUID(named: "\(plan.id.uuidString)/\(date)/plan", in: namespace)
        // Reviewed after the check-in day, the new targets still start today:
        // days already eaten keep the targets they had.
        next.startDate = max(date, today)
        next.createdAt = now.roundedToMilliseconds
        do {
            next = try next.computed(from: PlanBasis(expenditure: estimate.expenditure.rounded(),
                                                     expenditureError: estimate.expenditureError.rounded(),
                                                     trendWeight: (estimate.trend * 100).rounded() / 100))
        } catch NutritionStore.StoreError.invalid(let problems) {
            review.outcome = .cannotKeepGoal
            review.problems = problems
            return review
        }
        let before = plan.weeklyEnergy / 7
        let after = next.weeklyEnergy / 7
        guard abs(after - before) >= minimumChange else {
            review.outcome = .unchanged
            return review
        }
        let goalPerWeek = plan.goal.signedRate * estimate.trend
        let caveats = ["n=1", "\(review.completeDays) of the last 7 days fully logged",
                       "\(review.weighInDays) of the last 7 days with a weigh-in"]
        let planRef = DataRef(kind: NutritionStore.planKind, id: plan.id.uuidString)
        var evidence = [
            Evidence(claim: "Your expenditure is about \(Int(estimate.expenditure.rounded())) kcal a day, "
                + "give or take \(Int((2 * estimate.expenditureError).rounded())) kcal.",
                level: .personalData, caveats: caveats, dataRefs: [planRef]),
        ]
        if let change = review.weekChange {
            evidence.append(Evidence(claim: "Your trend weight changed \(mass(change, unit)) this week; the goal is "
                + "\(mass(goalPerWeek, unit)) a week.", level: .personalData, caveats: ["n=1"], dataRefs: [planRef]))
        }
        let confidence: Confidence = estimate.expenditureError < 100 ? .high : estimate.expenditureError < 175 ? .medium : .low
        review.outcome = .proposed
        review.proposal = Proposal(
            id: id, createdAt: now.roundedToMilliseconds, author: author,
            title: "New targets: \(Int(after.rounded())) kcal a day",
            summary: "This week's check-in moves your average daily budget from \(Int(before.rounded())) to "
                + "\(Int(after.rounded())) kcal, from your expenditure and trend weight.",
            changes: [try ProposedChange(kind: NutritionStore.planKind, id: next.id.uuidString, before: nil as NutritionPlan?, after: next)],
            evidence: evidence, confidence: confidence,
            falsifier: "Your trend weight keeps moving \(mass(goalPerWeek, unit)) a week on the current targets.")
        return review
    }

    /// A signed change in kilograms, written in `unit` to two decimals.
    private static func mass(_ kilograms: Double, _ unit: MassUnit) -> String {
        let rounded = (kilograms / unit.kilogramsPerUnit * 100).rounded() / 100
        return "\(rounded > 0 ? "+" : "")\(rounded == 0 ? "0" : String(rounded)) \(unit.rawValue)"
    }
}

extension NutritionStore {
    /// The version in force on `date` as a check-in reviews it: a version
    /// that only changed nutrient goals or pins starts when the targets it
    /// kept did, so a goal edit doesn't put off the week's check-in.
    public func checkInPlan(on date: LocalDate) -> NutritionPlan? {
        guard var plan = plan(on: date), var index = plans.firstIndex(where: { $0.id == plan.id }) else { return nil }
        while index > 0, plans[index - 1].sameTargets(as: plan) { index -= 1 }
        plan.startDate = plans[index].startDate
        return plan
    }

    /// The check-in due by `today` for the plan in force, from this store's log.
    /// The first plan's basis is the prior for expenditure. Nil without a plan.
    public func checkIn(today: LocalDate, existing: [Proposal], unit: MassUnit = .kilograms) throws -> NutritionCheckIn.Review? {
        guard let plan = checkInPlan(on: today), let first = plans.first else { return nil }
        let start = min(weights.first?.date ?? first.startDate, first.startDate)
        let days = energyBalanceDays(from: start, through: today.adding(days: -1))
        var review = try NutritionCheckIn.review(plan: plan, days: days,
                                                 prior: first.basis.map { ($0.expenditure, $0.expenditureError) },
                                                 today: today, existing: existing, now: Date(), unit: unit)
        let week = (1...7).map { review.date.adding(days: -$0) }.filter { $0 >= start && $0 < today }
        review.fastingDays = week.filter { day($0).status == .fasting }.count
        review.partialDays = week.filter { day($0).status == .partial }.count
        return review
    }
}
