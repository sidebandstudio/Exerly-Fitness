import Foundation
import Testing
@testable import ExerlyCore

@MainActor
@Suite struct NutritionRepeatTests {
    let newYork = TimeZone(identifier: "America/New_York")!
    let friday = LocalDate("2026-10-09")!

    func store(_ persistence: InMemoryTrainingPersistence = InMemoryTrainingPersistence()) throws -> NutritionStore {
        try NutritionStore(persistence: persistence, now: { Fixture.instant() })
    }

    /// An instant at a local wall-clock time in New York.
    func at(_ date: LocalDate, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        return calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day, hour: hour, minute: minute))!
    }

    @Test func lateNightRunsFromTenAtNightToFourInTheMorning() {
        func at(_ hour: Int, _ minute: Int = 0) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = newYork
            return calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: hour, minute: minute))!
        }
        #expect(NutritionStore.isLateNight(at(0, 30), timeZone: newYork))
        #expect(NutritionStore.isLateNight(at(22), timeZone: newYork))
        #expect(NutritionStore.isLateNight(at(3, 59), timeZone: newYork))
        #expect(!NutritionStore.isLateNight(at(4), timeZone: newYork))
        #expect(!NutritionStore.isLateNight(at(21, 59), timeZone: newYork))
        #expect(!NutritionStore.isLateNight(at(0, 30), timeZone: TimeZone(identifier: "Europe/London")!), "Read in the zone given")
    }

    @Test func withoutHistoryTheMealFollowsTheClock() throws {
        let nutrition = try store()
        let expected = [(6, "Breakfast"), (10, "Breakfast"), (11, "Lunch"), (15, "Snacks"), (18, "Dinner"), (22, "Snacks"), (2, "Snacks")]
        for (hour, meal) in expected {
            #expect(nutrition.suggestedMeal(at: at(friday, hour), timeZone: newYork) == meal, "at \(hour):00")
            #expect(NutritionStore.meal(atMinute: hour * 60) == meal, "The clock alone, at \(hour):00")
        }
        #expect(NutritionStore.meal(atMinute: 10 * 60 + 29) == "Breakfast")
        #expect(NutritionStore.meal(atMinute: 21 * 60 + 30) == "Snacks")
    }

    @Test func aMealsUsualTimeIsWhenItsFirstFoodIsUsuallyLogged() throws {
        let nutrition = try store()
        #expect(nutrition.usualTime(of: "Dinner", on: friday, timeZone: newYork) == at(friday, 18, 30), "A typical time without history")
        #expect(nutrition.usualTime(of: "Second breakfast", on: friday, timeZone: newYork) == at(friday, 12))
        // Dinner's first food at 19:10, 19:40 and 20:05; a side logged later doesn't count.
        for (days, hour, minute) in [(1, 19, 10), (2, 19, 40), (3, 20, 5)] {
            let day = friday.adding(days: -days)
            try nutrition.log(Foods.chicken, grams: 150, on: day, meal: "Dinner", at: at(day, hour, minute))
            try nutrition.log(Foods.oats, grams: 40, on: day, meal: "Dinner", at: at(day, 22))
        }
        // Logged the next morning, so it says nothing about when dinner is eaten.
        try nutrition.log(Foods.chicken, grams: 150, on: friday.adding(days: -4), meal: "Dinner", at: at(friday.adding(days: -3), 8))
        #expect(nutrition.usualTime(of: "Dinner", on: friday, timeZone: newYork) == at(friday, 19, 40))
        #expect(nutrition.usualTime(of: "Breakfast", on: friday, timeZone: newYork) == at(friday, 8))
    }

    @Test func aHabitOverridesTheClock() throws {
        let nutrition = try store()
        // Lunch logged around 10:15 on three recent days: an early luncher.
        for offset in 1...3 {
            let day = friday.adding(days: -offset)
            try nutrition.log(Foods.chicken, grams: 150, on: day, meal: "Lunch", at: at(day, 10, 15))
        }
        #expect(nutrition.suggestedMeal(at: at(friday, 10, 0), timeZone: newYork) == "Lunch")
        // Two days isn't a habit yet.
        let fresh = try store()
        for offset in 1...2 {
            let day = friday.adding(days: -offset)
            try fresh.log(Foods.chicken, grams: 150, on: day, meal: "Lunch", at: at(day, 10, 15))
        }
        #expect(fresh.suggestedMeal(at: at(friday, 10, 0), timeZone: newYork) == "Breakfast")
    }

    @Test func entriesBackfilledOnALaterDayAreNotAHabit() throws {
        let nutrition = try store()
        // Logged the next morning at 10:00 for the previous day's dinner.
        for offset in 2...4 {
            let day = friday.adding(days: -offset)
            try nutrition.log(Foods.chicken, grams: 150, on: day, meal: "Dinner", at: at(day.adding(days: 1), 10))
        }
        #expect(nutrition.suggestedMeal(at: at(friday, 10), timeZone: newYork) == "Breakfast")
    }

    @Test func repeatFindsTheLatestEarlierDayWithThatMeal() throws {
        let nutrition = try store()
        let tuesday = friday.adding(days: -3), thursday = friday.adding(days: -1)
        try nutrition.log(Foods.oats, grams: 80, on: tuesday, meal: "Breakfast")
        try nutrition.log(Foods.oats, grams: 60, on: thursday, meal: "Breakfast")
        try nutrition.log(Foods.milk, grams: 244, on: thursday, meal: "Breakfast")
        try nutrition.log(Foods.chicken, grams: 150, on: tuesday, meal: "Dinner")

        let breakfast = try #require(nutrition.repeatable("Breakfast", for: friday))
        #expect(breakfast.source == thursday)
        #expect(breakfast.entries.count == 2)
        #expect(abs(breakfast.energy - (380 * 0.6 + 60 * 2.44)) < 0.001)

        let dinner = try #require(nutrition.repeatable("Dinner", for: friday))
        #expect(dinner.source == tuesday)
        #expect(nutrition.repeatable("Lunch", for: friday) == nil)
        // Only earlier days, and only within the window.
        #expect(nutrition.repeatable("Breakfast", for: tuesday) == nil)
        #expect(nutrition.repeatable("Dinner", for: friday, within: 2) == nil)
    }

    @Test func repeatingAWholeDayUsesTheLatestLoggedDay() throws {
        let nutrition = try store()
        let wednesday = friday.adding(days: -2)
        try nutrition.log(Foods.oats, grams: 80, on: wednesday, meal: "Breakfast")
        try nutrition.log(Foods.chicken, grams: 150, on: wednesday, meal: "Dinner")
        let day = try #require(nutrition.repeatable(nil, for: friday))
        #expect(day.source == wednesday && day.meal == nil && day.entries.count == 2)
    }

    @Test func repeatingTheDayLeavesOutMealsAlreadyLogged() throws {
        let nutrition = try store()
        let thursday = friday.adding(days: -1)
        try nutrition.log(Foods.oats, grams: 60, on: thursday, meal: "Breakfast")
        try nutrition.log(Foods.chicken, grams: 150, on: thursday, meal: "Lunch")
        try nutrition.log(Foods.milk, grams: 244, on: thursday, meal: "Dinner")
        #expect(nutrition.repeatableDay(for: friday)?.entries.count == 3, "An empty day takes all of it")

        try nutrition.log(Foods.oats, grams: 40, on: friday, meal: "Breakfast")
        let rest = try #require(nutrition.repeatableDay(for: friday))
        #expect(rest.source == thursday && rest.meal == nil)
        #expect(Set(rest.entries.map(\.meal)) == ["Lunch", "Dinner"])
        try nutrition.apply(rest, to: friday)
        #expect(nutrition.entries(on: friday).filter { $0.meal == "Breakfast" }.count == 1, "Breakfast isn't doubled")
        #expect(nutrition.repeatableDay(for: friday) == nil, "Nothing left to repeat")
        #expect(nutrition.repeatableDay(for: thursday) == nil, "Only earlier days")
    }

    @Test func repeatingTheDayFinishesAMealStartedFromItButNotOneEatenDifferently() throws {
        let nutrition = try store()
        let thursday = friday.adding(days: -1)
        try nutrition.log(Foods.oats, grams: 60, on: thursday, meal: "Lunch")
        try nutrition.log(Foods.chicken, grams: 150, on: thursday, meal: "Lunch")
        try nutrition.log(Foods.milk, grams: 244, on: thursday, meal: "Dinner")
        try nutrition.log(Foods.oats, grams: 40, on: thursday, meal: "Breakfast")
        // Lunch's oats logged on their own (a Log again chip); breakfast eaten differently.
        try nutrition.log(Foods.oats, grams: 60, on: friday, meal: "Lunch")
        try nutrition.log(Foods.milk, grams: 200, on: friday, meal: "Breakfast")
        let rest = try #require(nutrition.repeatableDay(for: friday))
        #expect(Set(rest.entries.map { [$0.meal, $0.food.name] }) == [["Lunch", Foods.chicken.name], ["Dinner", Foods.milk.name]],
                "Lunch's chicken and dinner; not lunch's oats again, nor yesterday's breakfast over today's")
    }

    @Test func whatRemainsOfARepeatLeavesOutFoodsAlreadyInTheMeal() throws {
        let nutrition = try store()
        let thursday = friday.adding(days: -1)
        try nutrition.log(Foods.oats, grams: 60, on: thursday, meal: "Breakfast")
        try nutrition.log(Foods.milk, grams: 244, on: thursday, meal: "Breakfast")
        let breakfast = try #require(nutrition.repeatable("Breakfast", for: friday))
        #expect(nutrition.remaining(breakfast, on: friday)?.entries.count == 2)
        // Oats logged on their own first, and milk at lunch: only breakfast's milk is left.
        try nutrition.log(Foods.oats, grams: 45, on: friday, meal: "Breakfast")
        try nutrition.log(Foods.milk, grams: 100, on: friday, meal: "Lunch")
        let rest = try #require(nutrition.remaining(breakfast, on: friday))
        #expect(rest.entries.map(\.food.foodID) == [Foods.milk.id])
        #expect(rest.source == thursday && rest.meal == "Breakfast")
        try nutrition.apply(rest, to: friday)
        #expect(nutrition.remaining(breakfast, on: friday) == nil)
    }

    @Test func aSecondPortionOfTheSameFoodIsStillRepeated() throws {
        let nutrition = try store()
        let thursday = friday.adding(days: -1)
        // Two separate bars at snack time yesterday, and lunch.
        try nutrition.log(Foods.oats, grams: 60, on: thursday, meal: "Snacks")
        try nutrition.log(Foods.oats, grams: 60, on: thursday, meal: "Snacks")
        try nutrition.log(Foods.chicken, grams: 150, on: thursday, meal: "Lunch")
        try nutrition.log(Foods.oats, grams: 60, on: friday, meal: "Snacks")

        let snacks = try #require(nutrition.repeatable("Snacks", for: friday))
        let rest = try #require(nutrition.remaining(snacks, on: friday), "One of the two bars is still to come")
        #expect(rest.entries.map(\.grams) == [60])
        let day = try #require(nutrition.repeatableDay(for: friday))
        #expect(day.entries.filter { $0.meal == "Snacks" }.count == 1, "The second bar, and lunch")
        #expect(day.entries.filter { $0.meal == "Lunch" }.count == 1)

        try nutrition.log(Foods.oats, grams: 60, on: friday, meal: "Snacks")
        #expect(nutrition.remaining(snacks, on: friday) == nil, "Both bars are in")
        #expect(nutrition.repeatableDay(for: friday)?.entries.map(\.meal) == ["Lunch"])
        try nutrition.log(Foods.oats, grams: 60, on: friday, meal: "Snacks")
        #expect(nutrition.repeatableDay(for: friday)?.entries.contains { $0.meal == "Snacks" } != true,
                "A third bar today means snacks were eaten differently")
    }

    @Test func aPortionLoggedTodayUsesUpTheMatchingOneFromYesterday() throws {
        let nutrition = try store()
        let thursday = friday.adding(days: -1)
        try nutrition.log(Foods.oats, grams: 60, on: thursday, meal: "Breakfast")
        try nutrition.log(Foods.oats, grams: 30, on: thursday, meal: "Breakfast")
        try nutrition.log(Foods.oats, grams: 30, on: friday, meal: "Breakfast")
        let breakfast = try #require(nutrition.repeatable("Breakfast", for: friday))
        #expect(nutrition.remaining(breakfast, on: friday)?.entries.map(\.grams) == [60], "The 30 g matches the 30 g")
        #expect(nutrition.repeatableDay(for: friday)?.entries.map(\.grams) == [60])
        // A portion matching neither still stands for one of them.
        let other = try store()
        try other.log(Foods.oats, grams: 60, on: thursday, meal: "Breakfast")
        try other.log(Foods.oats, grams: 30, on: thursday, meal: "Breakfast")
        try other.log(Foods.oats, grams: 45, on: friday, meal: "Breakfast")
        let again = try #require(other.repeatable("Breakfast", for: friday))
        #expect(other.remaining(again, on: friday)?.entries.count == 1)
        #expect(other.repeatableDay(for: friday)?.entries.count == 1)
    }

    @Test func applyingARepeatCopiesItsEntriesOnce() throws {
        let nutrition = try store()
        let thursday = friday.adding(days: -1)
        try nutrition.log(Foods.oats, grams: 60, on: thursday, meal: "Breakfast")
        try nutrition.log(Foods.milk, grams: 244, on: thursday, meal: "Breakfast")
        let breakfast = try #require(nutrition.repeatable("Breakfast", for: friday))
        let copied = try nutrition.apply(breakfast, to: friday)
        #expect(copied.count == 2)
        #expect(nutrition.entries(on: friday).map(\.meal) == ["Breakfast", "Breakfast"])
        #expect(Set(copied.map(\.id)).isDisjoint(with: breakfast.entries.map(\.id)))
        #expect(nutrition.entries(on: thursday).count == 2)
    }
}
