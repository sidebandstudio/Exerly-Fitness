import Foundation
import Testing
@testable import ExerlyCore

@Suite struct NutritionPlanningTests {
    let monday = LocalDate("2026-10-05")!
    let basis = PlanBasis(expenditure: 2500, expenditureError: 100, trendWeight: 80)

    @Test func ratesReadInThePersonsUnitAndStepOnWholeAmounts() {
        // 0.5 % of 80 kg is 0.4 kg, or 0.88 lb, a week.
        #expect(abs(NutritionRate.weekly(0.005, trend: 80, in: .kilograms) - 0.4) < 1e-9)
        #expect(abs(NutritionRate.weekly(0.005, trend: 80, in: .pounds) - 0.8818) < 1e-4)
        // 0.88 lb shows as 0.9 lb: one step up lands on 1.0 lb and the next on 1.1 lb.
        let up = NutritionRate.nudged(0.005, by: 1, direction: .lose, trend: 80, unit: .pounds)
        #expect(abs(NutritionRate.weekly(up, trend: 80, in: .pounds) - 1.0) < 1e-5)
        let twice = NutritionRate.nudged(up, by: 1, direction: .lose, trend: 80, unit: .pounds)
        #expect(abs(NutritionRate.weekly(twice, trend: 80, in: .pounds) - 1.1) < 1e-5)
        // Down from 0.88 lb lands on 0.8 lb; in kilograms the step is 0.05 kg.
        let down = NutritionRate.nudged(0.005, by: -1, direction: .lose, trend: 80, unit: .pounds)
        #expect(abs(NutritionRate.weekly(down, trend: 80, in: .pounds) - 0.8) < 1e-5)
        let kilograms = NutritionRate.nudged(0.005, by: 1, direction: .lose, trend: 80, unit: .kilograms)
        #expect(abs(NutritionRate.weekly(kilograms, trend: 80, in: .kilograms) - 0.45) < 1e-6)
        // Never under one step, never over the direction's maximum.
        let slowest = NutritionRate.nudged(0.0006, by: -3, direction: .lose, trend: 80, unit: .pounds)
        #expect(abs(NutritionRate.weekly(slowest, trend: 80, in: .pounds) - 0.1) < 1e-5)
        #expect(NutritionRate.nudged(0.0099, by: 5, direction: .lose, trend: 80, unit: .pounds) == 0.01)
        #expect(NutritionRate.nudged(0.0049, by: 5, direction: .gain, trend: 80, unit: .kilograms) == 0.005)
        #expect(NutritionRate.nudged(0, by: 1, direction: .maintain, trend: 80, unit: .pounds) == 0)
        // Without a trend weight it steps by 0.05 % of bodyweight.
        #expect(NutritionRate.nudged(0.005, by: 1, direction: .lose, trend: nil, unit: .pounds) == 0.0055)
        #expect(NutritionRate.nudged(0.0052, by: -1, direction: .lose, trend: nil, unit: .pounds) == 0.005)
        #expect(NutritionRate.nudged(0.0005, by: -2, direction: .gain, trend: nil, unit: .kilograms) == 0.0005)
        #expect(NutritionRate.presets(for: .lose).allSatisfy { $0 <= NutritionTargets.maximumLoss })
        #expect(NutritionRate.presets(for: .gain).allSatisfy { $0 <= NutritionTargets.maximumGain })
        #expect(NutritionRate.presets(for: .maintain).isEmpty)
    }

    @Test func everyStepChangesTheAmountShown() {
        // A trend of 72.57 kg (160.0 lb) made 0.5 % read 0.8 lb, and Faster kept it at 0.8 lb.
        func shown(_ share: Double, _ trend: Double, _ unit: MassUnit) -> String {
            NutritionRate.weekly(share, trend: trend, in: unit).formatted(.number.precision(.fractionLength(unit == .pounds ? 1 : 2)))
        }
        for trend in [72.57, 72.6, 80, 95.31] {
            for unit in MassUnit.allCases {
                for direction in [NutritionGoal.Direction.lose, .gain] {
                    var share = NutritionRate.presets(for: direction)[0]
                    for steps in [1, 1, 1, -1, -1] {
                        let next = NutritionRate.nudged(share, by: steps, direction: direction, trend: trend, unit: unit)
                        if next < NutritionRate.maximum(for: direction) {
                            #expect(shown(next, trend, unit) != shown(share, trend, unit), "\(trend) kg, \(unit), \(direction)")
                        }
                        share = next
                    }
                }
            }
        }
        #expect(shown(NutritionRate.nudged(0.005, by: 1, direction: .lose, trend: 72.57, unit: .pounds), 72.57, .pounds) == "0.9")
    }

    @Test func presetsAreRoundAmountsInThePersonsUnit() {
        func amounts(_ direction: NutritionGoal.Direction, _ trend: Double, _ unit: MassUnit) -> [Double] {
            NutritionRate.presets(for: direction, trend: trend, unit: unit).map {
                (NutritionRate.weekly($0, trend: trend, in: unit) * 100).rounded() / 100
            }
        }
        // 160 lb may lose up to 1.6 lb a week, so 2 lb isn't offered; 220 lb gets all four.
        #expect(amounts(.lose, Mass.lb(160).kilograms, .pounds) == [0.5, 1, 1.5])
        #expect(amounts(.lose, Mass.lb(220).kilograms, .pounds) == [0.5, 1, 1.5, 2])
        #expect(amounts(.gain, Mass.lb(170).kilograms, .pounds) == [0.2, 0.4, 0.6, 0.8])
        #expect(amounts(.lose, 80, .kilograms) == [0.25, 0.5, 0.75])
        #expect(amounts(.gain, 80, .kilograms) == [0.1, 0.2, 0.3, 0.4])
        #expect(NutritionRate.presets(for: .lose, trend: nil, unit: .pounds) == NutritionRate.presets(for: .lose))
        #expect(NutritionRate.presets(for: .maintain, trend: 80, unit: .pounds).isEmpty)
        // A direction starts on the preset nearest 0.5 % (or 0.25 % to gain): 0.8 lb → 1 lb.
        let start = NutritionRate.standard(for: .lose, trend: Mass.lb(160).kilograms, unit: .pounds)
        #expect(NutritionRate.presets(for: .lose, trend: Mass.lb(160).kilograms, unit: .pounds)[1] == start)
        #expect(NutritionRate.standard(for: .lose, trend: nil, unit: .pounds) == 0.005)
    }

    @Test func aGoalWeightAlreadyPassedNeverCutsOrAddsCalories() throws {
        let trend = Mass.lb(160).kilograms
        let basis = PlanBasis(expenditure: 2400, expenditureError: 100, trendWeight: trend)
        // Losing toward 165 lb from a trend of 160 lb: the tester's goal.
        let wrongWay = NutritionGoal(.lose, weeklyRate: 0.00625, goalWeight: .lb(165))
        #expect(wrongWay.isReached(trend: trend))
        #expect(wrongWay.redirection(trend: trend) == .gain)
        #expect(NutritionGoal(.gain, weeklyRate: 0.0025, goalWeight: .lb(150)).redirection(trend: trend) == .lose)
        #expect(NutritionGoal(.lose, weeklyRate: 0.005, goalWeight: .lb(160)).redirection(trend: trend) == .maintain)
        #expect(NutritionGoal(.lose, weeklyRate: 0.005, goalWeight: .lb(150)).redirection(trend: trend) == nil)
        #expect(NutritionGoal(.gain, weeklyRate: 0.0025, goalWeight: .lb(165)).redirection(trend: trend) == nil)
        #expect(!NutritionGoal(.maintain, goalWeight: .lb(165)).isReached(trend: trend))
        #expect(!NutritionGoal(.lose, weeklyRate: 0.005).isReached(trend: trend))

        // The editor's draft refuses it and says what to do instead.
        var draft = NutritionPlanDraft(nil, goal: wrongWay)
        let refused = draft.preview(startingOn: monday, basis: basis)
        #expect(refused.plan == nil)
        #expect(refused.problems == ["Your trend weight is already under this goal weight, so losing can't reach it. Switch to Gain, or Maintain."])
        // Switching to gain makes a surplus toward it; maintaining holds expenditure.
        draft.goal.direction = .gain
        draft.goal.weeklyRate = 0.0025
        let gain = try #require(draft.preview(startingOn: monday, basis: basis).plan)
        #expect(gain.goal.goalWeight == .lb(165))
        #expect(try #require(gain.averageDay).energy > basis.expenditure)
        draft.goal.direction = .maintain
        let maintain = try #require(draft.preview(startingOn: monday, basis: basis).plan)
        #expect(maintain.goal == NutritionGoal(.maintain))
        #expect(try #require(maintain.averageDay).energy == basis.expenditure)

        // A version already made toward a goal the trend has since reached (a
        // check-in's) holds the trend instead of cutting further.
        let reached = NutritionPlan(startDate: monday, goal: NutritionGoal(.lose, weeklyRate: 0.005, goalWeight: .lb(162)))
        let held = try reached.computed(from: basis)
        #expect(held.averageDay?.energy == basis.expenditure)
    }

    @Test func weekdayStepsMoveOneDayAndStayInRange() {
        #expect(WeekdayBudget.isEven(WeekdayBudget.even))
        let saturday = WeekdayBudget.nudged(WeekdayBudget.even, day: .saturday, by: 2)
        #expect(saturday == [1, 1, 1, 1, 1, 1, 1.1])
        #expect(!WeekdayBudget.isEven(saturday))
        #expect(WeekdayBudget.nudged(saturday, day: .saturday, by: 20)[6] == 1.5)
        #expect(WeekdayBudget.nudged(saturday, day: .sunday, by: -20)[0] == 0.5)
        // A fasting day steps back into range; an odd weight lands on a step.
        #expect(WeekdayBudget.nudged([0, 1, 1, 1, 1, 1, 1], day: .sunday, by: 1)[0] == 0.5)
        #expect(WeekdayBudget.nudged([1.02, 1, 1, 1, 1, 1, 1], day: .sunday, by: 1)[0] == 1.05)
        #expect(WeekdayBudget.nudged([1.02, 1, 1, 1, 1, 1, 1], day: .sunday, by: -1)[0] == 1)
        #expect(!WeekdayBudget.isEven([0, 0, 0, 0, 0, 0, 0]))
    }

    @Test func typedTargetsShareTheWeekByWeekday() throws {
        let day = DailyTargets(energy: 2000, protein: 150, fat: 60, carbohydrate: 215)
        let supplied: Double = 600 + 860 + 540
        #expect(day.macroEnergy == supplied, "4 kcal a gram of protein and carbohydrate, 9 of fat")
        let shares = day.macroShares
        #expect(shares.protein == 600 / supplied && shares.carbohydrate == 860 / supplied && shares.fat == 540 / supplied)
        #expect(DailyTargets(energy: 0, protein: 0, fat: 0, carbohydrate: 0).macroShares == (0, 0, 0))
        #expect(try NutritionTargets.manual(day, weekdayWeights: WeekdayBudget.even) == Array(repeating: day, count: 7))
        let weekends = try NutritionTargets.manual(day, weekdayWeights: [1.2, 1, 1, 1, 1, 1, 1.2])
        #expect(weekends.reduce(0) { $0 + $1.energy } == 14000, "The week is seven typed days")
        #expect(weekends[0].energy > weekends[1].energy && weekends[0].protein == weekends[1].protein)
        // Fat and carbohydrate follow the day's energy.
        #expect(weekends[1].fat == (60 * weekends[1].energy / 2000).rounded())
        let fast = try NutritionTargets.manual(day, weekdayWeights: [1, 1, 0, 1, 1, 1, 1])
        #expect(fast[2] == DailyTargets(energy: 0, protein: 0, fat: 0, carbohydrate: 0))
        #expect(throws: NutritionStore.StoreError.invalid(["Calories must be above 0", "Protein, carbs and fat must be 0 or more"])) {
            try NutritionTargets.manual(DailyTargets(energy: 0, protein: -1, fat: 0, carbohydrate: 0), weekdayWeights: WeekdayBudget.even)
        }
        #expect(DailyTargets.average([]) == nil)
    }

    func summary(trend: Double, expenditure: Double, error: Double, logged: Int, weighIns: Int) -> WeightTrend.Summary {
        WeightTrend.Summary(date: monday, trend: trend, trendError: 0.2, weekChange: nil,
                            expenditure: WeightTrend.Expenditure(kcal: expenditure, error: error, loggedDays: logged, weighInDays: weighIns),
                            weighInDays: weighIns)
    }

    @Test func aNewVersionRestsOnMeasuredExpenditureThenTheLastPlanThenTheFormula() throws {
        let profile = BodyProfile(sex: .male, age: 30, height: 180, weight: .kg(80), activity: .moderate)
        let measured = summary(trend: 78.456, expenditure: 2431.6, error: 98.2, logged: 20, weighIns: 18)
        #expect(PlanBasisChoice.current(summary: measured, plans: [], profile: profile)
            == PlanBasisChoice(basis: PlanBasis(expenditure: 2432, expenditureError: 98, trendWeight: 78.46), source: .measured))

        let thin = summary(trend: 78.456, expenditure: 2431.6, error: 380, logged: 3, weighIns: 2)
        let previous = try NutritionPlan(startDate: monday, goal: NutritionGoal(.lose, weeklyRate: 0.005)).computed(from: basis)
        let manual = NutritionPlan(startDate: monday.adding(days: 1), goal: NutritionGoal(.maintain), mode: .manual)
        #expect(PlanBasisChoice.current(summary: thin, plans: [previous, manual], profile: profile)
            == PlanBasisChoice(basis: PlanBasis(expenditure: 2500, expenditureError: 100, trendWeight: 78.46), source: .previous))
        #expect(PlanBasisChoice.current(summary: nil, plans: [previous], profile: nil)?.basis == basis)

        // The formula uses today's trend weight in place of the profile's.
        let formula = try #require(PlanBasisChoice.current(summary: thin, plans: [manual], profile: profile))
        var lighter = profile
        lighter.weight = .kg(78.46)
        #expect(formula == PlanBasisChoice(basis: try PlanBasis.formula(lighter), source: .formula))
        #expect(PlanBasisChoice.current(summary: nil, plans: [], profile: profile)?.basis == (try PlanBasis.formula(profile)))
        #expect(PlanBasisChoice.current(summary: nil, plans: [manual], profile: nil) == nil)
    }

    @Test func aDraftPreviewsTheVersionItWouldSave() throws {
        let now = Fixture.instant()
        var draft = NutritionPlanDraft(nil)
        #expect(draft.goal == NutritionGoal(.lose, weeklyRate: 0.005) && draft.mode == .coached)
        let preview = draft.preview(startingOn: monday, basis: basis, now: now)
        #expect(preview.problems.isEmpty)
        let plan = try #require(preview.plan)
        #expect(plan.startDate == monday && plan.basis == basis)
        #expect(plan.targets == (try NutritionPlan(startDate: monday, goal: draft.goal).computed(from: basis).targets))

        // Maintaining saves no rate or goal weight; without a basis, coached targets can't be worked out.
        draft.goal.direction = .maintain
        draft.goal.goalWeight = .kg(75)
        #expect(draft.preview(startingOn: monday, basis: basis).plan?.goal == NutritionGoal(.maintain))
        #expect(draft.preview(startingOn: monday, basis: nil).problems
            == ["Exerly needs your expenditure or your profile to work out targets"])

        // Manual plans keep the typed day and no basis.
        draft.mode = .manual
        draft.manual = DailyTargets(energy: 2100, protein: 160, fat: 70, carbohydrate: 205)
        let typed = try #require(draft.preview(startingOn: monday, basis: basis).plan)
        #expect(typed.basis == nil && typed.targets == Array(repeating: draft.manual, count: 7))

        // Problems come back in words instead of a version.
        draft.mode = .coached
        draft.goal = NutritionGoal(.lose, weeklyRate: 0.02)
        #expect(draft.preview(startingOn: monday, basis: basis).problems
            == ["Losing needs a rate above 0 and up to 1 % of bodyweight a week"])
    }

    @Test func aDraftStartsFromThePlanItEditsAndKeepsItsOtherGoals() throws {
        var current = try NutritionPlan(startDate: monday, goal: NutritionGoal(.gain, weeklyRate: 0.0025, goalWeight: .lb(180)),
                                        mode: .collaborative, diet: .lowCarb, protein: .high,
                                        weekdayWeights: [1.1, 1, 1, 1, 1, 1, 1.1], checkInDay: .friday,
                                        nutrientGoals: [.fiber: NutrientGoal(target: 35)]).computed(from: basis)
        let draft = NutritionPlanDraft(current)
        #expect(draft.goal == current.goal && draft.mode == .collaborative && draft.diet == .lowCarb)
        #expect(draft.protein == .high && draft.checkInDay == .friday && draft.weekdayWeights == current.weekdayWeights)
        #expect(draft.manual.energy == (current.weeklyEnergy / 7).rounded())
        let saved = try #require(draft.preview(startingOn: monday.adding(days: 3), basis: basis).plan)
        #expect(saved.nutrientGoals == [.fiber: NutrientGoal(target: 35)])
        #expect(saved.targets == current.targets)
        // A plan saved without a rate (an older import) starts at the standard one.
        current.goal = NutritionGoal(.lose)
        #expect(NutritionPlanDraft(current).goal.weeklyRate == 0.005)
    }

    @Test func theGoalWeightProjectsADateOrSaysWhyNot() {
        let lose = NutritionGoal(.lose, weeklyRate: 0.005, goalWeight: .kg(76))
        guard case .on(let date, let weeks) = lose.projection(from: 80, on: monday) else {
            Issue.record("Expected a date")
            return
        }
        #expect(date == lose.eta(from: 80, on: monday))
        #expect(weeks == Int((Double(monday.days(until: date)) / 7).rounded(.up)) && weeks == 11)
        #expect(lose.projection(from: 75, on: monday) == .reached)
        #expect(NutritionGoal(.lose, weeklyRate: 0.005).projection(from: 80, on: monday) == .noGoalWeight)
        #expect(NutritionGoal(.maintain, goalWeight: .kg(80)).projection(from: 80, on: monday) == .maintaining)
    }
}

@MainActor
@Suite struct NutritionCheckInPlanningTests {
    let monday = LocalDate("2026-10-05")!

    func plan(checkInDay: Weekday = .monday) throws -> NutritionPlan {
        try NutritionPlan(startDate: monday, createdAt: Fixture.instant(), goal: NutritionGoal(.lose, weeklyRate: 0.005),
                          checkInDay: checkInDay)
            .computed(from: PlanBasis(expenditure: 2500, expenditureError: 400, trendWeight: 80))
    }

    func steadyDays(through last: Int) -> [EnergyBalance.Day] {
        (0...last).map { EnergyBalance.Day(date: monday.adding(days: $0), intake: 2300, weights: [80]) }
    }

    func review(_ plan: NutritionPlan, today: LocalDate, existing: [Proposal] = []) throws -> NutritionCheckIn.Review {
        try NutritionCheckIn.review(plan: plan, days: steadyDays(through: monday.days(until: today) - 1), prior: (2500, 400),
                                    today: today, existing: existing, now: Fixture.instant(days: 21))
    }

    @Test func aCheckInReviewedLateStillStartsItsTargetsToday() throws {
        let current = try plan()
        let onTheDay = try #require(try review(current, today: monday.adding(days: 21)).proposal)
        let late = try review(current, today: monday.adding(days: 23))
        #expect(late.date == monday.adding(days: 21))
        let proposal = try #require(late.proposal)
        #expect(proposal.id == onTheDay.id, "The same check-in on any day of its week")
        #expect(NutritionCheckIn.proposedPlan(proposal)?.startDate == monday.adding(days: 23))
        #expect(NutritionCheckIn.proposedPlan(onTheDay)?.startDate == monday.adding(days: 21))
        #expect(NutritionCheckIn.proposalID(plan: current, date: late.date) == proposal.id)
    }

    @Test func theNextCheckInFollowsThePlanAndTheReview() throws {
        let current = try plan(checkInDay: .thursday)
        // Started Monday: the first check-in is that Thursday's.
        let early = try review(current, today: monday.adding(days: 2))
        #expect(NutritionCheckIn.nextDate(plan: current, review: early) == monday.adding(days: 3))
        // A check-in that's open is today's; once decided, the next is a week on.
        let due = try review(current, today: monday.adding(days: 17))
        #expect(due.outcome == .proposed && NutritionCheckIn.nextDate(plan: current, review: due) == monday.adding(days: 17))
        let decided = try review(current, today: monday.adding(days: 18), existing: [try #require(due.proposal)])
        #expect(decided.outcome == .notDue && NutritionCheckIn.nextDate(plan: current, review: decided) == monday.adding(days: 24))
        // A plan starting on its check-in day has its first check-in a week later.
        var thursday = current
        thursday.startDate = monday.adding(days: 3)
        let started = try review(thursday, today: monday.adding(days: 3))
        #expect(NutritionCheckIn.nextDate(plan: thursday, review: started) == monday.adding(days: 10))
    }

    @Test func aCollaborativeAdjustmentKeepsTheCheckInAndChangesItsVersion() throws {
        let persistence = InMemoryTrainingPersistence()
        let nutrition = try NutritionStore(persistence: persistence, now: { Fixture.instant() })
        let agent = try AgentStore(persistence: persistence, hosts: [nutrition], now: { Fixture.instant(days: 21) })
        let current = try plan()
        try nutrition.savePlan(current, timeZone: .gmt)
        let proposal = try #require(try review(current, today: monday.adding(days: 21)).proposal)
        var mine = try #require(NutritionCheckIn.proposedPlan(proposal))
        mine.protein = .high
        mine = try mine.computed(from: try #require(mine.basis))
        let adjusted = try NutritionCheckIn.adjusted(proposal, to: mine, from: current)
        #expect(adjusted.id == proposal.id && adjusted.evidence == proposal.evidence && adjusted.falsifier == proposal.falsifier)
        #expect(adjusted.title.hasPrefix("New targets, adjusted: "))
        try agent.file(adjusted)
        try agent.accept(adjusted.id)
        #expect(nutrition.plan(on: monday.adding(days: 21))?.protein == .high)
        #expect(nutrition.plan(before: mine) == current)
        #expect(NutritionCheckIn.latest(in: agent.proposals)?.id == proposal.id)
        try agent.undo(adjusted.id)
        #expect(nutrition.plans == [current])
        #expect(nutrition.plan(before: mine) == current, "An unsaved version follows the one in force")
        #expect(nutrition.plan(before: current) == nil)
    }
}
