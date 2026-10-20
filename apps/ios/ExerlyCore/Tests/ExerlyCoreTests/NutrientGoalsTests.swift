import Foundation
import Testing
@testable import ExerlyCore

@MainActor
@Suite struct NutrientGoalsTests {
    let monday = LocalDate("2026-10-05")!
    let utc = TimeZone(identifier: "UTC")!
    let basis = PlanBasis(expenditure: 2500, expenditureError: 400, trendWeight: 80)

    /// A store whose clock reads `days` after Monday afternoon, with a coached
    /// plan in force since `start`.
    func store(days: Double = 2, start: LocalDate? = nil, persistence: InMemoryTrainingPersistence = InMemoryTrainingPersistence())
        throws -> NutritionStore {
        let store = try NutritionStore(persistence: persistence, now: { Fixture.instant(days: days) })
        let plan = try NutritionPlan(startDate: start ?? monday, createdAt: Fixture.instant(days: -30), goal: NutritionGoal(.lose, weeklyRate: 0.005))
            .computed(from: basis)
        try store.prepareWrite(kind: "nutrition_plan", id: plan.id.uuidString, payload: ExerlyJSON.canonical(plan))()
        return store
    }

    @Test func aGoalStartsANewVersionTodayAndPastDaysKeepTheirs() throws {
        let nutrition = try store()
        let wednesday = monday.adding(days: 2)
        let first = try #require(nutrition.plans.first)
        try nutrition.setGoal(NutrientGoal(floor: 30), for: .fiber, timeZone: utc)
        #expect(nutrition.plans.count == 2)
        #expect(nutrition.plans.first == first, "The version in force before is unchanged")
        let edited = try #require(nutrition.plan(on: wednesday))
        #expect(edited.startDate == wednesday && edited.targets == first.targets && edited.basis == first.basis)
        #expect(edited.goal(for: .fiber, on: wednesday) == NutrientGoal(floor: 30))
        // History reads each day's own goal: the reference on Monday, the new floor from Wednesday.
        let series = nutrition.intakeSeries(from: monday, through: wednesday)
        #expect(series.goal(for: .fiber, on: monday) == NutrientGoal(floor: 28))
        #expect(series.goal(for: .fiber, on: monday.adding(days: 1)) == NutrientGoal(floor: 28))
        #expect(series.goal(for: .fiber, on: wednesday) == NutrientGoal(floor: 30))

        // Saving the same goal again adds nothing.
        try nutrition.setGoal(NutrientGoal(floor: 30), for: .fiber, timeZone: utc)
        #expect(nutrition.plans.count == 2)
        // The reference itself, like nil, goes back to the reference.
        try nutrition.setGoal(NutrientGoal(floor: 28), for: .fiber, timeZone: utc)
        #expect(nutrition.plan(on: wednesday)?.nutrientGoals == nil)
        #expect(nutrition.plans.count == 3)
        try nutrition.setGoal(NutrientGoal(floor: 10, ceiling: 1000), for: .water, timeZone: utc)
        try nutrition.setGoal(nil, for: .water, timeZone: utc)
        #expect(nutrition.plan(on: wednesday)?.goal(for: .water, on: wednesday) == nil)

        #expect(throws: NutritionStore.StoreError.invalid(["Protein comes from your daily targets"])) {
            try nutrition.setGoal(NutrientGoal(target: 200), for: .protein, timeZone: utc)
        }
        #expect(throws: NutritionStore.StoreError.invalid(["Fiber: the floor, target and ceiling must be in that order"])) {
            try nutrition.setGoal(NutrientGoal(floor: 40, target: 30), for: .fiber, timeZone: utc)
        }
    }

    @Test func aGoalOrPinNeedsATargetsPlan() throws {
        let nutrition = try NutritionStore(persistence: InMemoryTrainingPersistence(), now: { Fixture.instant() })
        #expect(throws: NutritionStore.StoreError.invalid(["Set up your targets first"])) {
            try nutrition.setPinned(.fiber, true, timeZone: utc)
        }
    }

    @Test func pinsKeepTheirOrderUpToThreeAndSurviveATargetsEdit() throws {
        let persistence = InMemoryTrainingPersistence()
        let nutrition = try store(persistence: persistence)
        let today = monday.adding(days: 2)
        for nutrient in [Nutrient.fiber, .sodium, .vitaminC] { try nutrition.setPinned(nutrient, true, timeZone: utc) }
        #expect(nutrition.pinnedNutrients(today: today) == [.fiber, .sodium, .vitaminC])
        #expect(nutrition.pinnedNutrients(today: monday).isEmpty, "Monday's version had none")
        #expect(throws: NutritionStore.StoreError.self) { try nutrition.setPinned(.potassium, true, timeZone: utc) }
        #expect(throws: NutritionStore.StoreError.self) { try nutrition.setPinned(.protein, true, timeZone: utc) }
        try nutrition.setPinned(.sodium, false, timeZone: utc)
        #expect(nutrition.pinnedNutrients(today: today) == [.fiber, .vitaminC])
        try nutrition.setPinned(.sodium, true, timeZone: utc)
        #expect(nutrition.pinnedNutrients(today: today) == [.fiber, .vitaminC, .sodium], "A new pin goes last")

        // They sync as part of the plan, and an edit in the plan editor keeps them.
        let reloaded = try NutritionStore(persistence: persistence, now: { Fixture.instant(days: 2) })
        #expect(reloaded.pinnedNutrients(today: today) == [.fiber, .vitaminC, .sodium])
        var draft = NutritionPlanDraft(nutrition.plan(on: today))
        draft.diet = .lowCarb
        let edited = try #require(draft.preview(startingOn: today, basis: basis).plan)
        #expect(edited.pinnedNutrients == [.fiber, .vitaminC, .sodium])

        var invalid = edited
        invalid.pinnedNutrients = [.fiber, .fiber]
        #expect(invalid.validationErrors == ["Pin up to 3 nutrients, each once, other than energy and the macros"])
    }

    @Test func orderingNamesTheFirstPairOutOfOrder() {
        #expect(NutrientGoal(floor: 25, target: 35, ceiling: 70).misordered == nil)
        #expect(NutrientGoal(floor: 25, ceiling: 25).misordered == nil, "Equal parts are in order")
        #expect(NutrientGoal(floor: 40, target: 30).misordered! == (.floor, .target))
        #expect(NutrientGoal(target: 80, ceiling: 70).misordered! == (.target, .ceiling))
        #expect(NutrientGoal(floor: 90, target: 80, ceiling: 70).misordered! == (.floor, .target))
        #expect(NutrientGoal(floor: 90, ceiling: 70).misordered! == (.floor, .ceiling))
    }

    @Test func aDaySoFarIsShortMetOrOver() {
        let floor = NutrientGoal(floor: 28)
        #expect(floor.standing(of: 18) == .short(10))
        #expect(floor.standing(of: 28) == .met(left: nil))
        let ceiling = NutrientGoal(ceiling: 2300)
        #expect(ceiling.standing(of: 1240) == .met(left: 1060))
        #expect(ceiling.standing(of: 2540) == .over(240))
        // A lone target is met within 10 %, and short or over from the target itself.
        let target = NutrientGoal(target: 100)
        #expect(target.standing(of: 85) == .short(15))
        #expect(target.standing(of: 95) == .met(left: nil))
        #expect(target.standing(of: 112) == .over(12))
        let range = NutrientGoal(floor: 25, target: 35, ceiling: 70)
        #expect(range.standing(of: 20) == .short(5))
        #expect(range.standing(of: 40) == .met(left: 30))
        #expect(range.standing(of: 75) == .over(5))
    }

    @Test func aPinnedNutrientNoFoodReportsIsUnknownNotZero() throws {
        let nutrition = try store()
        let today = monday.adding(days: 2)
        let berries = Food(name: "Blueberries", per100g: NutrientAmounts([.energy: 57, .fiber: 2.4, .sodium: 0]))
        let bar = Food(name: "Protein bar", per100g: NutrientAmounts([.energy: 350, .protein: 33]))
        try nutrition.setGoal(NutrientGoal(floor: 30), for: .fiber, timeZone: utc)
        try nutrition.log(berries, grams: 200, on: today, meal: "Breakfast")
        try nutrition.log(bar, grams: 60, on: today, meal: "Snacks")
        let days = nutrition.nutrientDays([.fiber, .sodium, .vitaminC], on: today)
        #expect(days.map(\.nutrient) == [.fiber, .sodium, .vitaminC])
        let fiber = days[0]
        #expect(abs(fiber.amount! - 4.8) < 1e-9 && fiber.reporting == 1 && fiber.entries == 2)
        #expect(fiber.goal == NutrientGoal(floor: 30))
        guard case .short(let toGo) = fiber.standing else { Issue.record("Fiber should be short"); return }
        #expect(abs(toGo - 25.2) < 1e-9)
        #expect(days[1].amount == 0 && days[1].reporting == 1, "Reported as none is a real zero")
        #expect(days[2].amount == nil && days[2].reporting == 0, "No food reports vitamin C")
        #expect(days[2].goal == NutrientGoal(floor: 90) && days[2].standing == nil)
        // A day before the goal changed judges by the goal then.
        #expect(nutrition.nutrientDays([.fiber], on: monday).first?.goal == NutrientGoal(floor: 28))
        #expect(nutrition.nutrientDays([.fiber], on: monday).first?.entries == 0)
        #expect(nutrition.summary(on: today).reporting[.energy] == 2)
    }

    /// PARITY N27: alcohol, caffeine, cholesterol, choline and water each take a
    /// goal in their own unit, and a day is judged against it.
    @Test func alcoholCaffeineCholesterolCholineAndWaterTakeGoals() throws {
        let nutrition = try store()
        let today = monday.adding(days: 2)
        #expect(nutrition.plan(on: today)?.goal(for: .caffeine, on: today) == NutrientGoal(ceiling: 400))
        #expect(nutrition.plan(on: today)?.goal(for: .cholesterol, on: today) == NutrientGoal(ceiling: 300))
        #expect(nutrition.plan(on: today)?.goal(for: .choline, on: today) == NutrientGoal(floor: 550))
        #expect(nutrition.plan(on: today)?.goal(for: .alcohol, on: today) == nil && Nutrient.alcohol.unit == .grams)
        try nutrition.setGoal(NutrientGoal(ceiling: 14), for: .alcohol, timeZone: utc)
        try nutrition.setGoal(NutrientGoal(floor: 2000, ceiling: 4000), for: .water, timeZone: utc)
        try nutrition.setGoal(NutrientGoal(ceiling: 200), for: .caffeine, timeZone: utc)
        let drink = Food(name: "Synthetic stout", per100g: NutrientAmounts([.energy: 40, .alcohol: 4, .water: 90, .caffeine: 0]))
        let eggs = Food(name: "Synthetic eggs", per100g: NutrientAmounts([.energy: 143, .cholesterol: 372, .choline: 294]))
        let coffee = Food(name: "Synthetic coffee", per100g: NutrientAmounts([.energy: 1, .caffeine: 40, .water: 99]))
        try nutrition.log(drink, grams: 500, on: today, meal: "Dinner")
        try nutrition.log(eggs, grams: 100, on: today, meal: "Breakfast")
        try nutrition.log(coffee, grams: 600, on: today, meal: "Breakfast")
        let days = Dictionary(uniqueKeysWithValues: nutrition.nutrientDays([.alcohol, .caffeine, .cholesterol, .choline, .water], on: today)
            .map { ($0.nutrient, $0) })
        #expect(days[.alcohol]?.amount == 20 && days[.alcohol]?.standing == .over(6))
        #expect(days[.caffeine]?.amount == 240 && days[.caffeine]?.standing == .over(40) && days[.caffeine]?.reporting == 2)
        #expect(days[.cholesterol]?.standing == .over(72))
        #expect(days[.choline]?.standing == .short(256))
        #expect(days[.water]?.amount == 1044 && days[.water]?.standing == .short(956))
        // Monday keeps the reference goals it had.
        #expect(nutrition.nutrientDays([.caffeine], on: monday).first?.goal == NutrientGoal(ceiling: 400))
    }

    /// PARITY N27: two litres of water logged as drinks meet a 2 L goal on
    /// Today's water card, and should meet a water nutrient goal too.
    @Test func drinksCountTowardAWaterNutrientGoal() throws {
        let nutrition = try store()
        let today = monday.adding(days: 2)
        try nutrition.setGoal(NutrientGoal(floor: 2000), for: .water, timeZone: utc)
        try nutrition.log(Food(name: "Synthetic cucumber", per100g: NutrientAmounts([.energy: 15, .water: 95])), grams: 100,
                          on: today, meal: "Lunch")
        let card = nutrition.water(on: today, drinks: 2000, goal: 2000)
        #expect(card.remaining == 0 && card.fraction == 1, "The water card counts the drinks")
        let goal = try #require(nutrition.nutrientDays([.water], on: today).first)
        withKnownIssue("NutrientGoals.swift:111-118 totals only water in foods; drinks never reach it, so this reads short") {
            #expect(goal.standing == .met(left: nil))
        }
    }

    @Test func aGoalEditKeepsTheWeeksCheckInDue() throws {
        // Monday is the check-in day of a plan from two weeks before.
        let nutrition = try store(days: 0, start: monday.adding(days: -14))
        #expect(try nutrition.checkIn(today: monday, existing: [])?.outcome == .notEnoughData)
        try nutrition.setGoal(NutrientGoal(floor: 30), for: .fiber, timeZone: utc)
        try nutrition.setPinned(.fiber, true, timeZone: utc)
        #expect(nutrition.plan(on: monday)?.startDate == monday)
        #expect(nutrition.checkInPlan(on: monday)?.startDate == monday.adding(days: -14))
        #expect(try nutrition.checkIn(today: monday, existing: [])?.outcome == .notEnoughData, "Still due")

        // New targets start their own weeks, as before.
        var changed = try #require(nutrition.plan(on: monday))
        changed.id = UUID()
        changed.createdAt = Fixture.instant(minutes: 1)
        changed.diet = .lowCarb
        try nutrition.savePlan(changed.computed(from: basis), timeZone: utc)
        #expect(nutrition.checkInPlan(on: monday)?.startDate == monday)
        #expect(try nutrition.checkIn(today: monday, existing: [])?.outcome == .notDue)
    }

    @Test func onlyVersionsInForceCount() throws {
        let nutrition = try store(days: 2)
        let first = try #require(nutrition.plans.first)
        try nutrition.setGoal(NutrientGoal(floor: 30), for: .fiber, timeZone: utc)
        try nutrition.setPinned(.fiber, true, timeZone: utc)
        #expect(nutrition.plans.count == 3)
        #expect(nutrition.versionsInForce.map(\.id) == [first.id, nutrition.plan(on: monday.adding(days: 2))!.id])
        let latest = try #require(nutrition.plans.last)
        #expect(latest.sameTargets(as: first))
        var other = latest
        other.diet = .keto
        #expect(!other.sameTargets(as: first))
    }
}
