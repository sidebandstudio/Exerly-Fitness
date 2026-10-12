import Foundation

/// What the person wants their weight to do. See docs/design/011-nutrition-targets.md.
public struct NutritionGoal: Sendable, Codable, Hashable {
    public enum Direction: String, Sendable, Codable, Hashable, CaseIterable {
        case lose, maintain, gain
    }

    public var direction: Direction
    /// The change a week as a share of bodyweight: 0.005 is 0.5 % a week.
    /// Ignored when maintaining.
    public var weeklyRate: Double
    public var goalWeight: Mass?

    public init(_ direction: Direction, weeklyRate: Double = 0, goalWeight: Mass? = nil) {
        self.direction = direction
        self.weeklyRate = weeklyRate
        self.goalWeight = goalWeight
    }

    /// The weekly rate with its sign: negative to lose.
    public var signedRate: Double {
        switch direction {
        case .lose: -weeklyRate
        case .maintain: 0
        case .gain: weeklyRate
        }
    }
}

public enum PlanMode: String, Sendable, Codable, Hashable, CaseIterable {
    /// Weekly check-ins propose new targets.
    case coached
    /// The same proposals, which the person edits before accepting.
    case collaborative
    /// Typed-in targets; no check-in proposals.
    case manual
}

public enum DietType: String, Sendable, Codable, Hashable, CaseIterable {
    case balanced, lowFat, lowCarb, keto

    /// Fat's share of each day's energy.
    public var fatShare: Double {
        switch self {
        case .balanced: 0.30
        case .lowFat: 0.20
        case .lowCarb: 0.40
        case .keto: 0.70
        }
    }
}

public enum ProteinLevel: String, Sendable, Codable, Hashable, CaseIterable {
    case low, moderate, high

    public var gramsPerKilogram: Double {
        switch self {
        case .low: 1.4
        case .moderate: 1.8
        case .high: 2.2
        }
    }
}

/// One day's targets: energy in kcal, macros in grams.
public struct DailyTargets: Sendable, Codable, Hashable {
    public var energy: Double
    public var protein: Double
    public var fat: Double
    public var carbohydrate: Double

    public init(energy: Double, protein: Double, fat: Double, carbohydrate: Double) {
        self.energy = energy
        self.protein = protein
        self.fat = fat
        self.carbohydrate = carbohydrate
    }
}

/// A goal for one nutrient a day: reach the floor, aim for the target, stay
/// under the ceiling. Any of the three may be missing.
public struct NutrientGoal: Sendable, Codable, Hashable {
    public var floor: Double?
    public var target: Double?
    public var ceiling: Double?

    public init(floor: Double? = nil, target: Double? = nil, ceiling: Double? = nil) {
        self.floor = floor
        self.target = target
        self.ceiling = ceiling
    }

    /// The reference intake as a goal: a minimum becomes a floor, a maximum a
    /// ceiling, and a typical amount a target.
    public init?(reference nutrient: Nutrient) {
        guard let reference = nutrient.reference else { return nil }
        switch reference.kind {
        case .atLeast: self.init(floor: reference.amount)
        case .atMost: self.init(ceiling: reference.amount)
        case .target: self.init(target: reference.amount)
        }
    }

    /// The amount to compare intake with: the target, else the floor, else the ceiling.
    public var reference: Double? { target ?? floor ?? ceiling }

    var problems: [String] {
        let values = [floor, target, ceiling].compactMap { $0 }
        if values.isEmpty { return ["a goal needs a floor, a target or a ceiling"] }
        if values.contains(where: { !$0.isFinite || $0 < 0 }) { return ["goal amounts must be 0 or more"] }
        return values == values.sorted() ? [] : ["the floor, target and ceiling must be in that order"]
    }
}

/// What a plan version's targets were computed from.
public struct PlanBasis: Sendable, Codable, Hashable {
    /// In logged kcal a day, with one standard deviation.
    public var expenditure: Double
    public var expenditureError: Double
    /// Trend weight, in kilograms.
    public var trendWeight: Double

    public init(expenditure: Double, expenditureError: Double, trendWeight: Double) {
        self.expenditure = expenditure
        self.expenditureError = expenditureError
        self.trendWeight = trendWeight
    }
}

/// What onboarding asks, to estimate expenditure before there is any data.
public struct BodyProfile: Sendable, Codable, Hashable {
    public enum Sex: String, Sendable, Codable, Hashable, CaseIterable {
        case male, female, unspecified
    }

    /// The raw values are the onboarding wizard's.
    public enum Activity: String, Sendable, Codable, Hashable, CaseIterable {
        case sedentary, light, moderate, active, veryActive = "very_active"

        /// The physical activity level that multiplies resting energy.
        public var factor: Double {
            switch self {
            case .sedentary: 1.2
            case .light: 1.375
            case .moderate: 1.55
            case .active: 1.725
            case .veryActive: 1.9
            }
        }
    }

    public var sex: Sex
    public var age: Int
    /// In centimetres.
    public var height: Double
    public var weight: Mass
    public var activity: Activity

    public init(sex: Sex, age: Int, height: Double, weight: Mass, activity: Activity) {
        self.sex = sex
        self.age = age
        self.height = height
        self.weight = weight
        self.activity = activity
    }

    public var problems: [String] {
        var problems: [String] = []
        if !(13...100).contains(age) { problems.append("Age must be 13 to 100") }
        if !(height.isFinite && (100...250).contains(height)) { problems.append("Height must be 100 to 250 cm") }
        if !(weight.kilograms.isFinite && (25...400).contains(weight.kilograms)) { problems.append("Weight must be 25 to 400 kg") }
        return problems
    }
}

extension PlanBasis {
    /// A first plan's basis from the profile: Mifflin–St Jeor resting energy
    /// times the activity factor, with a standard deviation of 15 %. As the
    /// first plan's basis it is the energy balance's prior, so logged intake
    /// and weigh-ins take over within weeks. See docs/design/011.
    public static func formula(_ profile: BodyProfile) throws -> PlanBasis {
        guard profile.problems.isEmpty else { throw NutritionStore.StoreError.invalid(profile.problems) }
        let offset: Double = switch profile.sex {
        case .male: 5
        case .female: -161
        case .unspecified: -78
        }
        let kilograms = profile.weight.kilograms
        let resting = 10 * kilograms + 6.25 * profile.height - 5 * Double(profile.age) + offset
        let expenditure = (resting * profile.activity.factor).rounded()
        return PlanBasis(expenditure: expenditure, expenditureError: (0.15 * expenditure).rounded(), trendWeight: kilograms)
    }
}

/// One version of the person's nutrition plan, synced as a `nutrition_plan`
/// document. A version never changes once in force: a new goal or an accepted
/// check-in adds a version with a later `startDate`, so past days keep the
/// targets that held then.
public struct NutritionPlan: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var startDate: LocalDate
    public var createdAt: Date
    public var goal: NutritionGoal
    public var mode: PlanMode
    public var diet: DietType
    public var protein: ProteinLevel
    /// Relative budgets, Sunday first. 0 is a planned fasting day.
    public var weekdayWeights: [Double]
    public var checkInDay: Weekday
    /// Lets a day's budget go under `NutritionTargets.floor`.
    public var allowBelowFloor: Bool
    /// Nil for manual targets.
    public var basis: PlanBasis?
    /// Sunday first.
    public var targets: [DailyTargets]
    /// Goals for other nutrients, in each nutrient's unit. Nutrients without
    /// one use their reference intake; energy and macros come from `targets`.
    public var nutrientGoals: [Nutrient: NutrientGoal]?
    /// Nutrients Today shows beside the macros, in the order pinned: up to
    /// `maximumPins`, none of them energy or a macro.
    public var pinnedNutrients: [Nutrient]?

    public static let maximumPins = 3

    public init(id: UUID = UUID(), startDate: LocalDate, createdAt: Date = Date().roundedToMilliseconds, goal: NutritionGoal,
                mode: PlanMode = .coached, diet: DietType = .balanced, protein: ProteinLevel = .moderate,
                weekdayWeights: [Double] = Array(repeating: 1, count: 7), checkInDay: Weekday = .monday,
                allowBelowFloor: Bool = false, basis: PlanBasis? = nil, targets: [DailyTargets] = [],
                nutrientGoals: [Nutrient: NutrientGoal]? = nil, pinnedNutrients: [Nutrient]? = nil) {
        self.id = id
        self.startDate = startDate
        self.createdAt = createdAt
        self.goal = goal
        self.mode = mode
        self.diet = diet
        self.protein = protein
        self.weekdayWeights = weekdayWeights
        self.checkInDay = checkInDay
        self.allowBelowFloor = allowBelowFloor
        self.basis = basis
        self.targets = targets
        self.nutrientGoals = nutrientGoals
        self.pinnedNutrients = pinnedNutrients
    }

    /// The goal for a nutrient on a date: energy and macros from that weekday's
    /// target, others from `nutrientGoals` or the reference intake.
    public func goal(for nutrient: Nutrient, on date: LocalDate) -> NutrientGoal? {
        if let day = targets(on: date) {
            switch nutrient {
            case .energy: return NutrientGoal(target: day.energy)
            case .protein: return NutrientGoal(target: day.protein)
            case .fat: return NutrientGoal(target: day.fat)
            case .carbohydrate: return NutrientGoal(target: day.carbohydrate)
            default: break
            }
        }
        return nutrientGoals?[nutrient] ?? NutrientGoal(reference: nutrient)
    }

    public func targets(on date: LocalDate) -> DailyTargets? {
        targets.count == 7 ? targets[date.weekday.rawValue - 1] : nil
    }

    /// The weekly energy budget: the seven days' sum.
    public var weeklyEnergy: Double { targets.reduce(0) { $0 + $1.energy } }

    /// The plan with targets computed from `basis`.
    public func computed(from basis: PlanBasis) throws -> NutritionPlan {
        var plan = self
        plan.basis = basis
        plan.targets = try NutritionTargets.compute(for: self, basis: basis)
        return plan
    }

    /// What's wrong with this version, in words; empty when it's valid.
    public var validationErrors: [String] {
        var problems = NutritionTargets.problems(goal: goal, weekdayWeights: weekdayWeights)
        if targets.count != 7 { problems.append("A plan needs targets for all seven days") }
        for (index, day) in targets.enumerated() where [day.energy, day.protein, day.fat, day.carbohydrate].contains(where: { !$0.isFinite || $0 < 0 }) {
            problems.append("\(NutritionTargets.dayNames[index])'s targets must be zero or more")
        }
        for (nutrient, goal) in (nutrientGoals ?? [:]).sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if [.energy, .protein, .fat, .carbohydrate].contains(nutrient) {
                problems.append("\(nutrient.name) comes from the daily targets")
            } else {
                problems += goal.problems.map { "\(nutrient.name): \($0)" }
            }
        }
        let pins = pinnedNutrients ?? []
        if pins.count > Self.maximumPins || Set(pins).count < pins.count || pins.contains(where: \.isTarget) {
            problems.append("Pin up to \(Self.maximumPins) nutrients, each once, other than energy and the macros")
        }
        return problems
    }
}

/// The target maths of docs/design/011-nutrition-targets.md.
public enum NutritionTargets {
    /// Kilocalories per kilogram of tissue change.
    public static let energyDensity = 7700.0
    /// The lowest daily budget without `allowBelowFloor`, in kcal.
    public static let floor = 1200.0
    /// The fastest rates allowed, as shares of bodyweight a week.
    public static let maximumLoss = 0.01
    public static let maximumGain = 0.005
    /// Fat's lower bound, in g/kg.
    public static let fatFloor = 0.6
    /// Keto's carbohydrate cap, in grams a day.
    public static let ketoCarbohydrate = 30.0
    static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    static func problems(goal: NutritionGoal, weekdayWeights: [Double]) -> [String] {
        var problems: [String] = []
        switch goal.direction {
        case .lose where !(goal.weeklyRate > 0 && goal.weeklyRate <= maximumLoss):
            problems.append("Losing needs a rate above 0 and up to \(percent(maximumLoss)) of bodyweight a week")
        case .gain where !(goal.weeklyRate > 0 && goal.weeklyRate <= maximumGain):
            problems.append("Gaining needs a rate above 0 and up to \(percent(maximumGain)) of bodyweight a week")
        default: break
        }
        if let weight = goal.goalWeight, !(weight.kilograms > 0) { problems.append("The goal weight must be above 0") }
        if weekdayWeights.count != 7 || weekdayWeights.contains(where: { !$0.isFinite || $0 < 0 })
            || weekdayWeights.reduce(0, +) <= 0 {
            problems.append("Weekday budgets need seven shares of zero or more, not all zero")
        }
        return problems
    }

    /// Seven daily targets, Sunday first, for the plan's goal and preferences.
    /// Throws `NutritionStore.StoreError.invalid` with the reasons when they
    /// can't be met.
    public static func compute(for plan: NutritionPlan, basis: PlanBasis) throws -> [DailyTargets] {
        var problems = problems(goal: plan.goal, weekdayWeights: plan.weekdayWeights)
        guard problems.isEmpty, basis.expenditure.isFinite, basis.trendWeight > 0 else {
            if problems.isEmpty { problems.append("Targets need an expenditure and a trend weight") }
            throw NutritionStore.StoreError.invalid(problems)
        }
        // A goal weight already reached holds the trend: no deficit or surplus toward it.
        let rate = plan.goal.isReached(trend: basis.trendWeight) ? 0 : plan.goal.signedRate
        let daily = basis.expenditure + rate * basis.trendWeight * energyDensity / 7
        let energies = shares(of: (daily * 7).rounded(), by: plan.weekdayWeights)
        var reference = basis.trendWeight
        if plan.goal.direction == .lose, let goal = plan.goal.goalWeight?.kilograms { reference = min(reference, goal) }
        let protein = (plan.protein.gramsPerKilogram * reference).rounded()
        let fatMinimum = fatFloor * reference
        var targets: [DailyTargets] = []
        for (index, energy) in energies.enumerated() {
            guard plan.weekdayWeights[index] > 0 else {
                targets.append(DailyTargets(energy: 0, protein: 0, fat: 0, carbohydrate: 0))
                continue
            }
            let name = dayNames[index]
            if energy < floor && !plan.allowBelowFloor {
                problems.append("\(name)'s budget, \(Int(energy)) kcal, is under \(Int(floor)) kcal")
            }
            var fat: Double
            var carbohydrate: Double
            if plan.diet == .keto {
                carbohydrate = min(ketoCarbohydrate, max(0, (energy - protein * 4) / 4)).rounded()
                fat = ((energy - protein * 4 - carbohydrate * 4) / 9).rounded(.down)
            } else {
                fat = max(plan.diet.fatShare * energy / 9, fatMinimum).rounded()
                carbohydrate = ((energy - protein * 4 - fat * 9) / 4).rounded(.down)
            }
            if fat < fatMinimum.rounded(.down) || carbohydrate < 0 {
                problems.append("\(name)'s \(Int(energy)) kcal can't hold \(Int(protein)) g of protein and \(Int(fatMinimum.rounded())) g of fat")
                fat = max(0, fat)
                carbohydrate = max(0, carbohydrate)
            }
            targets.append(DailyTargets(energy: energy, protein: protein, fat: fat, carbohydrate: carbohydrate))
        }
        guard problems.isEmpty else { throw NutritionStore.StoreError.invalid(problems) }
        return targets
    }

    /// Whole-kilocalorie shares of `total` in proportion to `weights` that sum
    /// to it exactly (largest remainder).
    static func shares(of total: Double, by weights: [Double]) -> [Double] {
        let sum = weights.reduce(0, +)
        let exact = weights.map { total * $0 / sum }
        var floors = exact.map { $0.rounded(.down) }
        let left = Int((total - floors.reduce(0, +)).rounded())
        let order = exact.indices.sorted { (exact[$0] - floors[$0], -$0) > (exact[$1] - floors[$1], -$1) }
        for index in order.prefix(max(0, left)) { floors[index] += 1 }
        return floors
    }

    private static func percent(_ share: Double) -> String {
        "\((share * 100).formatted(.number.precision(.fractionLength(0...2)))) %"
    }
}
