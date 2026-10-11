import Foundation
import Testing
@testable import ExerlyCore

/// Today's diary beyond the meals: food by the hour, water, the habits
/// calendar, and which days analysis may trust.
@MainActor
@Suite struct NutritionDiaryTests {
    let monday = LocalDate("2026-10-05")!
    let newYork = Fixture.newYork
    let cucumber = Food(name: "Cucumber", per100g: NutrientAmounts([.energy: 15, .carbohydrate: 3.6, .water: 95]))

    func store() throws -> NutritionStore {
        try NutritionStore(persistence: InMemoryTrainingPersistence(), now: { Fixture.instant() })
    }

    func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    // MARK: By time

    @Test func byTimeGroupsADaysFoodByTheHourItWasEaten() throws {
        let nutrition = try store()
        let breakfast = try nutrition.log(Foods.oats, grams: 50, on: monday, meal: "Breakfast", at: utc("2026-10-05T12:40:00Z"))
        let coffee = try nutrition.log(Foods.milk, grams: 100, on: monday, meal: "Breakfast", at: utc("2026-10-05T12:10:00Z"))
        let lunch = try nutrition.log(Foods.chicken, grams: 150, on: monday, meal: "Lunch", at: utc("2026-10-05T16:30:00Z"))
        // Logged on Sunday for Monday, so its time on Monday isn't known.
        let planned = try nutrition.log(Foods.oats, grams: 40, on: monday, meal: "Snacks", at: utc("2026-10-04T22:00:00Z"))
        let timeline = nutrition.timeline(on: monday, timeZone: newYork)
        #expect(timeline.hours.map(\.hour) == [8, 12])
        #expect(timeline.hours[0].entries.map(\.id) == [coffee.id, breakfast.id], "Earliest first within the hour")
        #expect(timeline.hours[1].entries.map(\.id) == [lunch.id])
        #expect(timeline.hours[0].energy == 60 + 190)
        #expect(timeline.untimed.map(\.id) == [planned.id])
        #expect(timeline.hours.map(\.repeated) == [false, false])
    }

    /// 2026-03-08 in New York skips 2:00 to 3:00; 2026-11-01 passes 1:00 to 2:00 twice.
    @Test func theHourClocksSkipAndTheHourTheyRepeatKeepFoodInOrder() throws {
        let spring = LocalDate("2026-03-08")!, autumn = LocalDate("2026-11-01")!
        var clock = Calendar(identifier: .gregorian)
        clock.timeZone = newYork

        // The eaten-at control keeps the time when the day moves: a skipped
        // time moves on by the gap, a repeated one is the first.
        let skipped = spring.sameTime(as: utc("2026-03-07T07:30:00Z"), in: newYork) // 2:30 EST the day before
        #expect(skipped == utc("2026-03-08T07:30:00Z") && clock.component(.hour, from: skipped) == 3)
        #expect(LocalDate(skipped, in: newYork) == spring)
        let repeated = autumn.sameTime(as: utc("2026-10-31T05:30:00Z"), in: newYork) // 1:30 EDT the day before
        #expect(repeated == utc("2026-11-01T05:30:00Z"), "The first 1:30, still daylight time")
        #expect(autumn.sameTime(as: repeated, in: newYork) == repeated, "Same day: unchanged")

        let nutrition = try store()
        let late = try nutrition.log(Foods.oats, grams: 40, on: spring, meal: "Snacks", at: utc("2026-03-08T06:59:00Z")) // 1:59 EST
        let early = try nutrition.log(Foods.milk, grams: 200, on: spring, meal: "Breakfast", at: skipped) // 3:30 EDT
        let springLine = nutrition.timeline(on: spring, timeZone: newYork)
        #expect(springLine.hours.map(\.hour) == [1, 3] && springLine.untimed.isEmpty)
        #expect(springLine.hours.flatMap(\.entries).map(\.id) == [late.id, early.id])

        let first = try nutrition.log(Foods.oats, grams: 40, on: autumn, meal: "Snacks", at: utc("2026-11-01T05:30:00Z")) // 1:30 EDT
        let again = try nutrition.log(Foods.milk, grams: 200, on: autumn, meal: "Snacks", at: utc("2026-11-01T06:10:00Z")) // 1:10 EST
        let autumnLine = nutrition.timeline(on: autumn, timeZone: newYork)
        #expect(autumnLine.hours.map(\.hour) == [1, 1])
        #expect(autumnLine.hours.map(\.repeated) == [false, true])
        #expect(autumnLine.hours.map { $0.entries.map(\.id) } == [[first.id], [again.id]], "1:30 EDT comes before 1:10 EST")
        // The hourly analysis puts both in the one clock hour.
        let timing = nutrition.timing(from: autumn, through: autumn, timeZone: newYork)
        #expect(timing.hours[1].entries == 2 && timing.untimedEntries == 0)
    }

    // MARK: Coaching

    /// A coached plan from three weeks before `monday`, with 21 days of
    /// complete logging at 2,280 kcal and a steady 80 kg.
    func loggedWeeks() throws -> NutritionStore {
        let nutrition = try store()
        let plan = try NutritionPlan(startDate: monday.adding(days: -21), createdAt: Fixture.instant(days: -21),
                                     goal: NutritionGoal(.lose, weeklyRate: 0.005), mode: .coached)
            .computed(from: PlanBasis(expenditure: 2500, expenditureError: 400, trendWeight: 80))
        try nutrition.prepareWrite(kind: "nutrition_plan", id: plan.id.uuidString, payload: ExerlyJSON.canonical(plan))()
        for offset in -21 ... -1 {
            let date = monday.adding(days: offset)
            try nutrition.log(Foods.oats, grams: 600, on: date, meal: "Breakfast", at: Fixture.instant(days: Double(offset)))
            try nutrition.setStatus(.complete, on: date)
            try nutrition.logWeight(.kg(80), at: Fixture.instant(days: Double(offset)), timeZone: Fixture.utc)
        }
        return nutrition
    }

    @Test func foodLoggedForLaterDaysStaysOutOfHistoricalCoaching() throws {
        let nutrition = try loggedWeeks()
        let before = try #require(try nutrition.checkIn(today: monday, existing: []))
        let estimates = nutrition.weightEstimates(through: monday)
        let month = IntakeRange.thisMonth.span(today: monday)
        let series = nutrition.intakeSeries(from: month.lowerBound, through: month.upperBound)
        let suggestions = nutrition.suggestions(at: Fixture.instant(), timeZone: Fixture.utc)

        // A feast planned for tomorrow and next week, marked complete.
        for offset in [1, 7] {
            try nutrition.log(Foods.oats, grams: 2000, on: monday.adding(days: offset), meal: "Dinner", at: Fixture.instant(days: Double(offset)))
            try nutrition.setStatus(.complete, on: monday.adding(days: offset))
        }
        let after = try #require(try nutrition.checkIn(today: monday, existing: []))
        #expect(after.outcome == before.outcome && after.estimate == before.estimate)
        #expect(after.completeDays == before.completeDays && after.proposal?.title == before.proposal?.title)
        #expect(nutrition.weightEstimates(through: monday) == estimates)
        #expect(nutrition.intakeSeries(from: month.lowerBound, through: month.upperBound) == series)
        #expect(nutrition.suggestions(at: Fixture.instant(), timeZone: Fixture.utc) == suggestions)
        #expect(before.estimate != nil)
    }

    @Test func checkInsCountFastsAndLeaveOutPartialDays() throws {
        let nutrition = try loggedWeeks()
        let first = try #require(try nutrition.checkIn(today: monday, existing: []))
        #expect(first.completeDays == 7 && first.fastingDays == 0 && first.partialDays == 0)
        try nutrition.setStatus(.fasting, on: first.date.adding(days: -2))
        try nutrition.setStatus(.partial, on: first.date.adding(days: -3))
        let review = try #require(try nutrition.checkIn(today: monday, existing: []))
        #expect(review.completeDays == 6, "The fast counts as known intake; the partial day doesn't")
        #expect(review.fastingDays == 1 && review.partialDays == 1)
    }

    @Test func pastDaysKeepTheTargetsTheyHad() throws {
        let nutrition = try store()
        let targets = { (energy: Double) in Array(repeating: DailyTargets(energy: energy, protein: 150, fat: 60, carbohydrate: 200), count: 7) }
        let old = NutritionPlan(startDate: monday.adding(days: -14), createdAt: Fixture.instant(days: -14), goal: NutritionGoal(.maintain),
                                mode: .manual, targets: targets(2000))
        let new = NutritionPlan(startDate: monday, createdAt: Fixture.instant(), goal: NutritionGoal(.maintain), mode: .manual,
                                targets: targets(2400))
        for plan in [old, new] {
            try nutrition.prepareWrite(kind: "nutrition_plan", id: plan.id.uuidString, payload: ExerlyJSON.canonical(plan))()
        }
        try nutrition.log(Foods.oats, grams: 600, on: monday.adding(days: -1), meal: "Dinner")
        let yesterday = nutrition.progress(on: monday.adding(days: -1)).energy
        #expect(yesterday.target == 2000 && yesterday.over == 280 && yesterday.remaining == 0)
        #expect(nutrition.progress(on: monday).energy.target == 2400)
    }

    /// Complete with food, partial with food, partial with nothing, a fast,
    /// nothing, and complete with nothing.
    @Test func fastedPartialAndUnknownDaysStayDistinct() throws {
        let nutrition = try store()
        try nutrition.log(Foods.oats, grams: 500, on: monday, meal: "Breakfast")
        try nutrition.setStatus(.complete, on: monday)
        try nutrition.log(Foods.oats, grams: 300, on: monday.adding(days: 1), meal: "Breakfast")
        try nutrition.setStatus(.partial, on: monday.adding(days: 1))
        try nutrition.setStatus(.partial, on: monday.adding(days: 2))
        try nutrition.setStatus(.fasting, on: monday.adding(days: 3))
        try nutrition.setStatus(.complete, on: monday.adding(days: 5))
        let end = monday.adding(days: 5)

        #expect(nutrition.energyBalanceDays(from: monday, through: end).map(\.intake) == [1900, nil, nil, 0, nil, nil],
                "Only the fast is a known zero")
        let series = nutrition.intakeSeries(from: monday, through: end)
        #expect(series.countedDays == 2 && series.fastedDays == 1)
        #expect(series.partialDays == 2 && series.emptyDays == 2)
        #expect(series.average(.energy) == 950, "1,900 and the fast's zero")
        #expect(nutrition.habits(from: monday, through: end, today: monday.adding(days: 7)).map(\.food)
                == [.complete, .partial, .partial, .fasted, .missing, .missing])
    }

    // MARK: Water

    @Test func waterKeepsDrinksAndFoodApartAndTheGoalCountsDrinks() throws {
        let nutrition = try store()
        try nutrition.log(cucumber, grams: 200, on: monday, meal: "Lunch")
        try nutrition.log(Foods.oats, grams: 50, on: monday, meal: "Breakfast")
        let day = nutrition.water(on: monday, drinks: 1250, goal: 2000)
        #expect(day.drinks == 1250 && day.food == 190 && day.total == 1440)
        #expect(day.reporting == 1 && day.entries == 2, "Oats don't report water")
        #expect(day.remaining == 750 && day.fraction == 0.625, "Water in food isn't counted toward the goal")
        let dry = nutrition.water(on: monday, drinks: 0, goal: nil)
        #expect(dry.food == 190 && dry.total == 190 && dry.remaining == nil && dry.fraction == nil)
        #expect(nutrition.water(on: monday.adding(days: 1), drinks: 500, goal: 2000).food == 0)
    }

    @Test func removingWaterStopsAtZero() {
        #expect(WaterDay.change(250, to: 0) == 250)
        #expect(WaterDay.change(-250, to: 1000) == -250)
        #expect(WaterDay.change(-500, to: 250) == -250)
        #expect(WaterDay.change(-250, to: 0) == 0)
    }

    // MARK: Habits

    @Test func theHabitsCalendarShowsWhatEachDayRecorded() throws {
        let nutrition = try store()
        let today = monday.adding(days: 2)
        try nutrition.log(Foods.oats, grams: 100, on: monday, meal: "Breakfast")
        try nutrition.logWeight(.kg(80), at: Fixture.instant(), timeZone: Fixture.utc)
        try nutrition.log(Foods.oats, grams: 100, on: today.adding(days: 1), meal: "Breakfast")
        let days = nutrition.habits(from: monday.adding(days: -1), through: today.adding(days: 1), today: today)
        #expect(days.map(\.date) == (-1...3).map { monday.adding(days: $0) })
        #expect(days.map(\.food) == [.missing, .recorded, .missing, .upcoming, .upcoming],
                "Today with nothing yet, and planned food tomorrow, are still to come")
        #expect(days.map(\.weighedIn) == [false, true, false, false, false])
        #expect(nutrition.habits(from: today, through: monday, today: today).isEmpty)
    }
}
