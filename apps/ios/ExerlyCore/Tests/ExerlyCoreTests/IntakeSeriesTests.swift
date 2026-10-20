import Foundation
import Testing
@testable import ExerlyCore

@MainActor
@Suite struct IntakeSeriesTests {
    let monday = LocalDate("2026-10-05")!
    let oats = Food(name: "Oats", per100g: NutrientAmounts([.energy: 380, .protein: 13, .iron: 4.3, .fiber: 10]))
    let milk = Food(name: "Milk", per100g: NutrientAmounts([.energy: 60, .protein: 3.3]))

    /// 2,400 kcal at weekends and 2,000 on weekdays, with a fiber floor and target.
    func plan(starting date: LocalDate) -> NutritionPlan {
        let weekday = DailyTargets(energy: 2000, protein: 150, fat: 70, carbohydrate: 250)
        let weekend = DailyTargets(energy: 2400, protein: 150, fat: 70, carbohydrate: 350)
        return NutritionPlan(startDate: date, createdAt: Fixture.instant(), goal: NutritionGoal(.maintain),
                             targets: [weekend] + Array(repeating: weekday, count: 5) + [weekend],
                             nutrientGoals: [.fiber: NutrientGoal(floor: 25, target: 35)])
    }

    /// Monday to Sunday: complete, partial, unmarked with food, a fast,
    /// nothing, a complete quick add, and Sunday marked complete but empty.
    func week() throws -> NutritionStore {
        let nutrition = try NutritionStore(persistence: InMemoryTrainingPersistence(), now: { Fixture.instant() })
        try nutrition.prepareWrite(kind: "nutrition_plan", id: UUID().uuidString,
                                   payload: ExerlyJSON.canonical(plan(starting: monday.adding(days: -7))))()
        try nutrition.log(oats, grams: 500, on: monday, meal: "Breakfast")
        try nutrition.setStatus(.complete, on: monday)
        try nutrition.log(oats, grams: 900, on: monday.adding(days: 1), meal: "Breakfast")
        try nutrition.setStatus(.partial, on: monday.adding(days: 1))
        try nutrition.log(milk, grams: 1000, on: monday.adding(days: 2), meal: "Snacks")
        try nutrition.setStatus(.fasting, on: monday.adding(days: 3))
        try nutrition.quickAdd(NutrientAmounts([.energy: 2400]), on: monday.adding(days: 5), meal: "Dinner")
        try nutrition.setStatus(.complete, on: monday.adding(days: 5))
        try nutrition.setStatus(.complete, on: monday.adding(days: 6))
        return nutrition
    }

    @Test func spansEndYesterdayAndAYearIsDrawnInWeeks() {
        #expect(IntakeRange.yesterday.span(today: monday) == monday.adding(days: -1)...monday.adding(days: -1))
        #expect(IntakeRange.week.span(today: monday) == LocalDate("2026-09-28")!...LocalDate("2026-10-04")!)
        let year = IntakeRange.year.span(today: monday)
        #expect(year.lowerBound.days(until: year.upperBound) == 364)
        #expect(IntakeRange.quarter.barDays == 1 && IntakeRange.year.barDays == 7)
    }

    /// PARITY N28: 1 month is 30 days and 3 months is 13 whole weeks, 91 days.
    @Test func aMonthIsThirtyDaysAndAQuarterThirteenWeeks() {
        for (range, days) in [(IntakeRange.yesterday, 1), (.week, 7), (.month, 30), (.quarter, 91), (.year, 365)] {
            let span = range.span(today: monday)
            #expect(span.upperBound == monday.adding(days: -1) && span.lowerBound.days(until: span.upperBound) + 1 == days, "\(range)")
        }
    }

    @Test func thisMonthRunsFromTheFirstThroughToday() {
        #expect(IntakeRange.thisMonth.span(today: monday) == LocalDate("2026-10-01")!...monday)
        let first = LocalDate("2026-11-01")!
        #expect(IntakeRange.thisMonth.span(today: first) == first...first, "On the 1st, just today")
        #expect(IntakeRange.thisMonth.barDays == 1)
    }

    @Test func daysCountAsTheStoreCountsThem() throws {
        let nutrition = try week()
        let series = nutrition.intakeSeries(from: monday, through: monday.adding(days: 6))
        #expect(series.days.count == 7)
        for day in series.days { #expect(day.counted == nutrition.counts(day.date), "\(day.date)") }
        #expect(series.countedDays == 4 && series.partialDays == 1 && series.emptyDays == 2)
        #expect(series.days[1].isPartial && series.days[1].entries == 1)
        #expect(!series.days[6].counted, "Marked complete with nothing logged isn't known intake")
        #expect(nutrition.intakeSeries(from: monday, through: monday.adding(days: -1)).days.isEmpty)
    }

    @Test func averagesArePerCountedDayAndMatchTheOverview() throws {
        let nutrition = try week()
        let end = monday.adding(days: 6)
        let series = nutrition.intakeSeries(from: monday, through: end)
        // 1,900, 600, a fast and 2,400.
        #expect(series.average(.energy) == 1225)
        let overview = nutrition.overview(from: monday, through: end)
        for row in overview.rows { #expect(close(series.average(row.nutrient), row.average), "\(row.nutrient)") }
        let empty = nutrition.intakeSeries(from: monday.adding(days: 4), through: monday.adding(days: 4))
        #expect(empty.average(.energy) == nil && empty.comparison(.energy) == nil)
    }

    @Test func eachDayIsJudgedAgainstItsOwnGoal() throws {
        let nutrition = try week()
        let end = monday.adding(days: 6)
        let series = nutrition.intakeSeries(from: monday, through: end)
        let energy = try #require(series.comparison(.energy))
        // Goals of 2,000 on Monday, Wednesday and Thursday, and 2,400 on Saturday.
        #expect(energy.days == 4 && energy.reference == 2100 && energy.average == 1225)
        #expect(energy.met == 2, "1,900 is within 10 % of 2,000 and 2,400 meets 2,400; 600 and the fast don't")
        #expect(energy.share == 1225.0 / 2100)
        #expect(close(energy.share, nutrition.overview(from: monday, through: end).rows.first { $0.nutrient == .energy }!.shareOfGoal!))
        #expect(close(energy.difference, -875))
        let fiber = try #require(series.comparison(.fiber))
        #expect(fiber.reference == 35 && fiber.met == 1, "Only Monday's oats reach the 25 g floor")
        #expect(series.comparison(.water) == nil, "No goal")
        // Three weekdays at 2,000 and a Saturday at 2,400.
        #expect(series.averageGoal(.energy) == NutrientGoal(target: 2100) && series.goalsVary(.energy))
        #expect(series.averageGoal(.fiber) == NutrientGoal(floor: 25, target: 35) && !series.goalsVary(.fiber))
        #expect(series.averageGoal(.water) == nil && !series.goalsVary(.water))
    }

    @Test func barsAverageTheirCountedDaysAndShowPartialDaysApart() throws {
        let series = try week().intakeSeries(from: monday, through: monday.adding(days: 6))
        let daily = series.bars(.energy)
        #expect(daily.count == 7)
        #expect(daily[0].value == 1900 && daily[0].goal == NutrientGoal(target: 2000) && daily[0].uncounted == nil)
        #expect(daily[1].value == nil && daily[1].uncounted == 3420, "A partial day shows what was logged, apart")
        #expect(daily[3].value == 0 && daily[3].countedDays == 1, "A fast is a real zero")
        #expect(daily[4].value == nil && daily[4].uncounted == nil)
        #expect(daily[5].goal == NutrientGoal(target: 2400))
        let threes = series.bars(.energy, length: 3)
        #expect(threes.map(\.days) == [3, 3, 1] && threes.map(\.start) == [monday, monday.adding(days: 3), monday.adding(days: 6)])
        #expect(threes[0].value == 1250 && threes[0].countedDays == 2 && threes[0].uncounted == nil)
        #expect(close(threes[1].goal?.target, 6400.0 / 3) && threes[1].value == 1200)
        #expect(threes[2].value == nil && threes[2].end == monday.adding(days: 6))
        #expect(series.bars(.fiber)[0].goal == NutrientGoal(floor: 25, target: 35))
    }

    @Test func goalBandsFollowFloorsTargetsAndCeilings() {
        let energy = NutrientGoal(target: 2000)
        #expect(energy.band().lower == 1800 && energy.band().upper == 2200)
        #expect(energy.contains(2200) && !energy.contains(2201) && !energy.contains(1799))
        let fiber = NutrientGoal(floor: 25, target: 35)
        #expect(fiber.band().lower == 25 && fiber.band().upper == nil, "More than the target of a floor is fine")
        let sodium = NutrientGoal(ceiling: 2300)
        #expect(sodium.band().lower == nil && sodium.contains(0) && !sodium.contains(2301))
        let custom = NutrientGoal(target: 90, ceiling: 2000)
        #expect(close(custom.band().lower, 81) && custom.band().upper == 2000)
        #expect(IntakeSeries.mean([NutrientGoal(target: 100), NutrientGoal(floor: 10, target: 200)])
                == NutrientGoal(floor: 10, target: 150))
        #expect(IntakeSeries.mean([]) == nil)
    }

    @Test func macroEnergySharesComeFromTheAverageDay() throws {
        let nutrition = try NutritionStore(persistence: InMemoryTrainingPersistence(), now: { Fixture.instant() })
        let food = Food(name: "Plate", per100g: NutrientAmounts([.energy: 500, .protein: 25, .carbohydrate: 50, .fat: 20]))
        try nutrition.log(food, grams: 100, on: monday, meal: "Lunch")
        try nutrition.setStatus(.fasting, on: monday.adding(days: 1))
        let shares = nutrition.intakeSeries(from: monday, through: monday.adding(days: 1)).energyShares
        // 100, 200 and 180 kcal.
        #expect(close(shares[.protein], 100.0 / 480) && close(shares[.carbohydrate], 200.0 / 480) && close(shares[.fat], 180.0 / 480))
        #expect(shares[.alcohol] == nil)
        #expect(nutrition.intakeSeries(from: monday.adding(days: 1), through: monday.adding(days: 1)).energyShares.isEmpty)
    }
}
