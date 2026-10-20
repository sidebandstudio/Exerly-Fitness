import Foundation
import Testing
@testable import ExerlyCore

@Suite struct NutritionTargetsTests {
    let monday = LocalDate("2026-10-05")!
    let basis = PlanBasis(expenditure: 2500, expenditureError: 100, trendWeight: 80)

    func plan(_ goal: NutritionGoal, diet: DietType = .balanced, protein: ProteinLevel = .moderate,
              weights: [Double] = Array(repeating: 1, count: 7), allowBelowFloor: Bool = false) -> NutritionPlan {
        NutritionPlan(startDate: monday, goal: goal, diet: diet, protein: protein, weekdayWeights: weights,
                      allowBelowFloor: allowBelowFloor)
    }

    func invalid(_ body: () throws -> Void) -> [String] {
        do {
            try body()
        } catch NutritionStore.StoreError.invalid(let problems) {
            return problems
        } catch {
            return ["unexpected \(error)"]
        }
        return []
    }

    @Test func aLossBudgetTakesTheRateOffExpenditureAndSplitsTheMacros() throws {
        // 2500 − 0.005 × 80 × 7700 / 7 = 2060 kcal; protein 1.8 × 80; fat 30 % of 2060 / 9.
        let targets = try plan(NutritionGoal(.lose, weeklyRate: 0.005)).computed(from: basis).targets
        #expect(targets.count == 7)
        #expect(targets[1] == DailyTargets(energy: 2060, protein: 144, fat: 69, carbohydrate: 215))
        #expect(Set(targets) == [targets[1]])

        // Losing toward a goal weight under the trend sets protein by the goal weight.
        let toward = try plan(NutritionGoal(.lose, weeklyRate: 0.005, goalWeight: .kg(70))).computed(from: basis)
        #expect(toward.targets[1] == DailyTargets(energy: 2060, protein: 126, fat: 69, carbohydrate: 233))

        let maintain = try plan(NutritionGoal(.maintain, weeklyRate: 0.004)).computed(from: basis)
        #expect(maintain.targets[1].energy == 2500)
        let gain = try plan(NutritionGoal(.gain, weeklyRate: 0.0025)).computed(from: basis)
        #expect(gain.targets[1].energy == 2720)
    }

    @Test func aFirstPlanFromOnboardingStartsFromTheFormulaWithAWideError() throws {
        // 10 × 80 + 6.25 × 180 − 5 × 30 + 5 = 1780 kcal at rest, × 1.55 = 2759 kcal.
        let profile = BodyProfile(sex: .male, age: 30, height: 180, weight: .kg(80), activity: .moderate)
        let start = try PlanBasis.formula(profile)
        #expect(start == PlanBasis(expenditure: 2759, expenditureError: 414, trendWeight: 80))
        var female = profile
        female.sex = .female
        #expect(try PlanBasis.formula(female).expenditure == ((1780 - 166) * 1.55).rounded())
        // Targets the new diary can show as soon as setup ends: 2759 − 440 kcal.
        let first = try plan(NutritionGoal(.lose, weeklyRate: 0.005)).computed(from: start)
        #expect(first.validationErrors.isEmpty && first.targets[1].energy == 2319)
        #expect(BodyProfile.Activity(rawValue: "very_active") == .veryActive)
        let child = BodyProfile(sex: .unspecified, age: 9, height: 40, weight: .lb(20), activity: .light)
        #expect(invalid { _ = try PlanBasis.formula(child) }
            == ["Age must be 13 to 100", "Height must be 100 to 250 cm", "Weight must be 25 to 400 kg"])
    }

    @Test func weekdayBudgetsSumToTheWeekAndAFastingDayHasNone() throws {
        let weekends = try plan(NutritionGoal(.lose, weeklyRate: 0.005), weights: [1.2, 1, 1, 1, 1, 1, 1.2]).computed(from: basis)
        #expect(weekends.weeklyEnergy == 14420)
        #expect(weekends.targets[0].energy > weekends.targets[1].energy)
        #expect(weekends.targets[0].protein == weekends.targets[1].protein, "Protein is the same every day")

        let fast = try plan(NutritionGoal(.maintain), weights: [1, 1, 0, 1, 1, 1, 1]).computed(from: basis)
        #expect(fast.weeklyEnergy == 17500)
        #expect(fast.targets[2] == DailyTargets(energy: 0, protein: 0, fat: 0, carbohydrate: 0))
        #expect(fast.targets.filter { $0.energy > 0 }.allSatisfy { [2916, 2917].contains($0.energy) })
        #expect(fast.targets(on: LocalDate("2026-10-06")!)?.energy == 0, "Tuesday")
    }

    @Test func ketoCapsCarbohydrateAndGivesFatTheRest() throws {
        let keto = try plan(NutritionGoal(.lose, weeklyRate: 0.005), diet: .keto).computed(from: basis)
        // (2060 − 144 × 4 − 30 × 4) / 9 = 151.6
        #expect(keto.targets[1] == DailyTargets(energy: 2060, protein: 144, fat: 151, carbohydrate: 30))
    }

    /// PARITY S02: high-carb (low fat) and low-carb split the same budget by fat's share.
    @Test func lowFatKeepsTheFatFloorAndLowCarbGivesFatTwoFifths() throws {
        // 20 % of 2060 / 9 is 45.8 g, under the 0.6 g/kg floor of 48 g; carbs take the rest: (2060 − 576 − 432) / 4.
        let lowFat = try plan(NutritionGoal(.lose, weeklyRate: 0.005), diet: .lowFat).computed(from: basis)
        #expect(lowFat.targets[1] == DailyTargets(energy: 2060, protein: 144, fat: 48, carbohydrate: 263))
        // 40 % of 2060 / 9 is 91.6 g; (2060 − 576 − 828) / 4 = 164.
        let lowCarb = try plan(NutritionGoal(.lose, weeklyRate: 0.005), diet: .lowCarb).computed(from: basis)
        #expect(lowCarb.targets[1] == DailyTargets(energy: 2060, protein: 144, fat: 92, carbohydrate: 164))
        // More protein comes out of carbohydrate, not fat.
        let high = try plan(NutritionGoal(.lose, weeklyRate: 0.005), diet: .lowCarb, protein: .high).computed(from: basis)
        #expect(high.targets[1].fat == 92 && high.targets[1].protein > 144 && high.targets[1].carbohydrate < 164)
    }

    @Test func unsafeRatesLowBudgetsAndCrowdedMacrosAreRefusedWithReasons() {
        #expect(invalid { _ = try plan(NutritionGoal(.lose, weeklyRate: 0.015)).computed(from: basis) }
            == ["Losing needs a rate above 0 and up to 1 % of bodyweight a week"])
        #expect(invalid { _ = try plan(NutritionGoal(.gain, weeklyRate: 0.006)).computed(from: basis) }
            == ["Gaining needs a rate above 0 and up to 0.5 % of bodyweight a week"])
        // 1700 − 0.01 × 60 × 1100 = 1040 kcal.
        let small = PlanBasis(expenditure: 1700, expenditureError: 100, trendWeight: 60)
        #expect(invalid { _ = try plan(NutritionGoal(.lose, weeklyRate: 0.01)).computed(from: small) }.first
            == "Sunday's budget, 1040 kcal, is under 1200 kcal")
        #expect(invalid { _ = try plan(NutritionGoal(.lose, weeklyRate: 0.01), allowBelowFloor: true).computed(from: small) }.isEmpty)
        // 2.2 × 100 g of protein is 880 kcal, and the fat floor 60 g another 540.
        let heavy = PlanBasis(expenditure: 1300, expenditureError: 100, trendWeight: 100)
        #expect(invalid {
            _ = try plan(NutritionGoal(.maintain), protein: .high, allowBelowFloor: true).computed(from: heavy)
        }.first == "Sunday's 1300 kcal can't hold 220 g of protein and 60 g of fat")
        #expect(invalid { _ = try plan(NutritionGoal(.maintain), weights: [0, 0, 0, 0, 0, 0, 0]).computed(from: basis) }
            == ["Weekday budgets need seven shares of zero or more, not all zero"])
    }
}

@MainActor
@Suite struct NutritionPlanStoreTests {
    let monday = LocalDate("2026-10-05")!

    func store(_ persistence: InMemoryTrainingPersistence = InMemoryTrainingPersistence(), today: LocalDate) throws -> NutritionStore {
        let noon = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: .gmt, year: today.year, month: today.month,
                                                                             day: today.day, hour: 12))!
        return try NutritionStore(persistence: persistence, now: { noon })
    }

    func version(starting date: LocalDate, expenditure: Double) throws -> NutritionPlan {
        try NutritionPlan(startDate: date, goal: NutritionGoal(.lose, weeklyRate: 0.005))
            .computed(from: PlanBasis(expenditure: expenditure, expenditureError: 100, trendWeight: 80))
    }

    @Test func eachDayUsesTheVersionInForceAndHistoryIsKept() throws {
        let persistence = InMemoryTrainingPersistence()
        let first = try version(starting: monday, expenditure: 2500)
        try store(persistence, today: monday).savePlan(first, timeZone: .gmt)
        let later = try store(persistence, today: monday.adding(days: 7))
        let second = try version(starting: monday.adding(days: 7), expenditure: 2400)
        try later.savePlan(second, timeZone: .gmt)

        let reopened = try store(persistence, today: monday.adding(days: 8))
        #expect(reopened.plans.map(\.id) == [first.id, second.id])
        #expect(reopened.plan(on: monday.adding(days: -1)) == nil)
        #expect(reopened.targets(on: monday.adding(days: 6))?.energy == 2060)
        #expect(reopened.targets(on: monday.adding(days: 7))?.energy == 1960)

        // Neither a past start nor an edit to a version in force rewrites history.
        var edited = second
        edited.goal = NutritionGoal(.maintain)
        #expect(throws: NutritionStore.StoreError.invalid(["A plan can't start in the past",
                                                           "This version is already in force; start a new one"])) {
            try reopened.savePlan(edited, timeZone: .gmt)
        }
        #expect(throws: NutritionStore.StoreError.invalid(["A plan can't start in the past"])) {
            try reopened.savePlan(try version(starting: monday, expenditure: 2300), timeZone: .gmt)
        }
    }
}

@MainActor
@Suite struct NutritionCheckInTests {
    let monday = LocalDate("2026-10-05")!

    /// A plan started on a Monday from a guess of 2500 kcal, losing 0.5 % a week.
    func plan(mode: PlanMode = .coached, expenditure: Double = 2500) throws -> NutritionPlan {
        try NutritionPlan(startDate: monday, createdAt: Fixture.instant(), goal: NutritionGoal(.lose, weeklyRate: 0.005), mode: mode)
            .computed(from: PlanBasis(expenditure: expenditure, expenditureError: 400, trendWeight: 80))
    }

    /// Three weeks at a steady 80 kg on a logged 2300 kcal: expenditure is 2300.
    func steadyDays(_ count: Int = 21, logged: Bool = true) -> [EnergyBalance.Day] {
        (0..<count).map { EnergyBalance.Day(date: monday.adding(days: $0), intake: logged ? 2300 : nil, weights: [80]) }
    }

    func review(_ plan: NutritionPlan, _ days: [EnergyBalance.Day], today: LocalDate, existing: [Proposal] = [],
                prior: Double = 2500) throws -> NutritionCheckIn.Review {
        try NutritionCheckIn.review(plan: plan, days: days, prior: (prior, 400), today: today, existing: existing,
                                    now: Fixture.instant(days: 21))
    }

    @Test func aWeeklyCheckInProposesTargetsFromTheMeasuredExpenditure() throws {
        let current = try plan()
        let checkIn = try review(current, steadyDays(), today: monday.adding(days: 21))
        #expect(checkIn.outcome == .proposed)
        #expect(checkIn.date == monday.adding(days: 21))
        #expect(checkIn.completeDays == 7 && checkIn.weighInDays == 7)
        let proposal = try #require(checkIn.proposal)
        #expect(proposal.author == NutritionCheckIn.author)
        #expect(proposal.changes.map(\.kind) == ["nutrition_plan"] && proposal.changes[0].before == nil)
        let next = try ExerlyJSON.decoder.decode(NutritionPlan.self, from: try #require(proposal.changes[0].after?.canonicalData))
        #expect(next.startDate == checkIn.date)
        let basis = try #require(next.basis)
        #expect(abs(basis.expenditure - 2300) < 60, "\(basis)")
        // 2300 − 440 for the loss, against 2060 before.
        #expect(abs(next.weeklyEnergy / 7 - 1860) < 60)
        #expect(proposal.title == "New targets: \(Int((next.weeklyEnergy / 7).rounded())) kcal a day")
        #expect(proposal.evidence.first?.claim.hasPrefix("Your expenditure is about ") == true)
        #expect(proposal.evidence.first?.caveats.contains("7 of the last 7 days fully logged") == true)
        let pounds = try #require(try NutritionCheckIn.review(plan: current, days: steadyDays(), prior: (2500, 400),
                                                               today: monday.adding(days: 21), existing: [],
                                                               now: Fixture.instant(days: 21), unit: .pounds).proposal)
        let texts = pounds.evidence.map(\.claim) + [pounds.falsifier]
        #expect(texts.contains { $0.contains(" lb") } && !texts.contains { $0.contains(" kg") })

        // The same check-in on another device is the same proposal, and once filed it isn't proposed again.
        #expect(try review(current, steadyDays(), today: monday.adding(days: 22)).proposal?.id == proposal.id)
        #expect(try review(current, steadyDays(), today: monday.adding(days: 22), existing: [proposal]).outcome == .notDue)
    }

    @Test func noProposalBeforeTheFirstCheckInForManualPlansOrOnThinData() throws {
        #expect(try review(try plan(), steadyDays(3), today: monday.adding(days: 3)).outcome == .notDue)
        #expect(try review(try plan(mode: .manual), steadyDays(), today: monday.adding(days: 21)).outcome == .manual)
        let thin = (0..<21).map { EnergyBalance.Day(date: monday.adding(days: $0), intake: nil, weights: $0 == 0 ? [80] : []) }
        #expect(try review(try plan(), thin, today: monday.adding(days: 21)).outcome == .notEnoughData)
        #expect(try review(try plan(expenditure: 2300), steadyDays(), today: monday.adding(days: 21), prior: 2300).outcome
            == .unchanged)
        // Expenditure far under the guess would put the budget under the floor.
        let low = (0..<21).map { EnergyBalance.Day(date: monday.adding(days: $0), intake: 1400, weights: [80]) }
        let floored = try review(try plan(), low, today: monday.adding(days: 21), prior: 1400)
        #expect(floored.outcome == .cannotKeepGoal && floored.proposal == nil)
        #expect(floored.problems.first?.hasSuffix("is under 1200 kcal") == true)
    }

    @Test func acceptingACheckInStartsANewVersionAndUndoRemovesIt() throws {
        let persistence = InMemoryTrainingPersistence()
        let nutrition = try NutritionStore(persistence: persistence, now: { Fixture.instant() })
        let agent = try AgentStore(persistence: persistence, hosts: [nutrition], now: { Fixture.instant(days: 21) })
        let current = try plan()
        try nutrition.savePlan(current, timeZone: .gmt)
        let proposal = try #require(try review(current, steadyDays(), today: monday.adding(days: 21)).proposal)
        try agent.file(proposal)
        try agent.accept(proposal.id)
        #expect(nutrition.plans.count == 2)
        #expect(nutrition.targets(on: monday.adding(days: 20)) == current.targets[0], "The past keeps its targets")
        #expect(try #require(nutrition.targets(on: monday.adding(days: 21))).energy < current.targets[1].energy)
        try agent.undo(proposal.id)
        #expect(nutrition.plans == [current])
    }

    /// PARITY S05: keeping the current targets changes nothing and isn't asked
    /// again that week; the next week's check-in still comes.
    @Test func decliningACheckInKeepsThePlanUntilTheNextWeek() throws {
        let persistence = InMemoryTrainingPersistence()
        let nutrition = try NutritionStore(persistence: persistence, now: { Fixture.instant() })
        let agent = try AgentStore(persistence: persistence, hosts: [nutrition], now: { Fixture.instant(days: 21) })
        let current = try plan()
        try nutrition.savePlan(current, timeZone: .gmt)
        let proposal = try #require(try review(current, steadyDays(), today: monday.adding(days: 21)).proposal)
        try agent.file(proposal)
        try agent.reject(proposal.id)
        #expect(nutrition.plans == [current])
        let declined = try #require(agent.proposal(proposal.id))
        #expect(declined.status == .rejected && declined.decidedAt == Fixture.instant(days: 21))
        #expect(throws: (any Error).self) { try agent.accept(proposal.id) }
        #expect(throws: (any Error).self) { try agent.undo(proposal.id) }
        #expect(try review(current, steadyDays(), today: monday.adding(days: 22), existing: [declined]).outcome == .notDue)
        let next = try review(current, steadyDays(28), today: monday.adding(days: 28), existing: [declined])
        #expect(next.outcome == .proposed && next.proposal?.id != proposal.id)
    }
}

@MainActor
@Suite struct DayProgressTests {
    @Test func remainingAndOverFollowTheTargetsInForceAndCountUnreportedEntries() throws {
        let monday = LocalDate("2026-10-05")!
        let persistence = InMemoryTrainingPersistence()
        let nutrition = try NutritionStore(persistence: persistence, now: { Fixture.instant() })
        #expect(nutrition.progress(on: monday).hasTargets == false)
        let plan = NutritionPlan(startDate: monday, createdAt: Fixture.instant(), goal: NutritionGoal(.maintain), mode: .manual,
                                 targets: Array(repeating: DailyTargets(energy: 2000, protein: 150, fat: 60, carbohydrate: 200), count: 7))
        try nutrition.savePlan(plan, timeZone: .gmt)
        try nutrition.log(Foods.oats, grams: 200, on: monday, meal: "Breakfast")
        try nutrition.log(Food(name: "Mystery bar", per100g: NutrientAmounts([.energy: 500])), grams: 100, on: monday, meal: "Snacks")
        let day = nutrition.progress(on: monday)
        #expect(day.hasTargets && day.energy.consumed == 1260 && day.energy.remaining == 740 && day.energy.over == 0)
        #expect(day.protein.consumed == 26 && day.protein.unreported == 1 && day.energy.unreported == 0)
        #expect(abs((day.energy.fraction ?? 0) - 0.63) < 1e-12)
        try nutrition.log(Foods.oats, grams: 300, on: monday, meal: "Dinner")
        let over = nutrition.progress(on: monday).energy
        #expect(over.remaining == 0 && over.over == 400)
    }
}
