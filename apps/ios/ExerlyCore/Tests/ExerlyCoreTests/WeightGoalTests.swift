import Foundation
import Testing
@testable import ExerlyCore

@Suite struct WeightGoalTests {
    let monday = LocalDate("2026-09-07")!
    let lose = NutritionGoal(.lose, weeklyRate: 0.005, goalWeight: .kg(75))

    @Test func thePathCompoundsWeeklyLikeTheCheckpointsAndStopsAtTheGoal() throws {
        let checkpoints = lose.checkpoints(from: 80, on: monday, weeks: 3)
        for (week, point) in checkpoints.enumerated() {
            #expect(abs(WeightGoal.planned(from: 80, goal: lose, days: (week + 1) * 7) - point.weight) < 1e-9)
        }
        let halfWeek = WeightGoal.planned(from: 80, goal: lose, days: 3)
        #expect(halfWeek < 80 && halfWeek > checkpoints[0].weight)
        #expect(WeightGoal.planned(from: 80, goal: lose, days: 700) == 75, "Never past the goal weight")
        #expect(WeightGoal.planned(from: 74, goal: lose, days: 70) == 74, "Already there: flat")
        #expect(WeightGoal.planned(from: 80, goal: NutritionGoal(.maintain), days: 70) == 80)
        let gain = NutritionGoal(.gain, weeklyRate: 0.0025, goalWeight: .kg(81))
        #expect(WeightGoal.planned(from: 80, goal: gain, days: 7) == 80 * 1.0025)
        #expect(WeightGoal.planned(from: 80, goal: gain, days: 700) == 81)
        #expect(WeightGoal.planned(from: 80, goal: lose, days: -3) == 80)
    }

    @Test func theEtaIsTheDayThePathReachesTheGoal() throws {
        let eta = try #require(lose.eta(from: 80, on: monday))
        let days = monday.days(until: eta)
        #expect(WeightGoal.planned(from: 80, goal: lose, days: days) == 75)
        #expect(WeightGoal.planned(from: 80, goal: lose, days: days - 7) > 75)
    }

    @Test func standingKeepsATolerantBandAroundThePlan() {
        let on = WeightGoal.standing(trend: 79.7, trendError: 0.2, planned: 80, direction: .lose)
        #expect(on.status == .onTrack && abs(on.offset + 0.3) < 1e-9 && on.band == WeightGoal.tolerance)
        #expect(WeightGoal.standing(trend: 79.2, trendError: 0.2, planned: 80, direction: .lose).status == .ahead)
        #expect(WeightGoal.standing(trend: 80.8, trendError: 0.2, planned: 80, direction: .lose).status == .behind)
        #expect(WeightGoal.standing(trend: 80.8, trendError: 0.2, planned: 80, direction: .gain).status == .ahead)
        #expect(WeightGoal.standing(trend: 79.2, trendError: 0.2, planned: 80, direction: .gain).status == .behind)
        #expect(WeightGoal.standing(trend: 79.2, trendError: 0.2, planned: 80, direction: .maintain).status == .behind)
        let unsure = WeightGoal.standing(trend: 80.8, trendError: 0.9, planned: 80, direction: .lose)
        #expect(unsure.status == .onTrack && unsure.band == 0.9, "A wide trend can't call it either way")
    }

    func estimates(from start: LocalDate, days: Int, trend: (Int) -> Double) -> [EnergyBalance.Estimate] {
        (0..<days).map { day in
            EnergyBalance.Estimate(date: start.adding(days: day), trend: trend(day), trendError: 0.2, expenditure: 2500,
                                   expenditureError: 100, weight: nil, intake: nil)
        }
    }

    func plan(_ start: LocalDate, _ goal: NutritionGoal, minutes: Double = 0) -> NutritionPlan {
        NutritionPlan(startDate: start, createdAt: Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60), goal: goal)
    }

    @Test func checkInsContinueAGoalAndANewGoalStartsAPath() throws {
        let estimates = estimates(from: monday, days: 70) { 82 - 0.06 * Double($0) }
        let later = NutritionGoal(.lose, weeklyRate: 0.0075, goalWeight: .kg(74))
        let versions = [
            plan(monday.adding(days: -10), lose),
            plan(monday.adding(days: 14), lose, minutes: 1),
            plan(monday.adding(days: 35), later, minutes: 2),
        ]
        let today = monday.adding(days: 69)
        let stretches = WeightGoal.stretches(versions, estimates: estimates, from: monday, through: today)
        #expect(stretches.count == 2)
        let first = try #require(stretches.first)
        #expect(first.goal == lose && first.start == monday.adding(days: -10) && first.end == monday.adding(days: 34))
        #expect(first.anchor == monday && first.startTrend == 82, "Before the first weigh-in it starts from the first trend")
        #expect(first.planned(on: monday.adding(days: 7)) == 82 * 0.995)
        let second = try #require(stretches.last)
        #expect(second.goal == later && second.start == monday.adding(days: 35) && second.end == today)
        #expect(abs(second.startTrend - (82 - 0.06 * 35)) < 1e-9)
        #expect(WeightGoal.stretches(versions, estimates: estimates, from: monday.adding(days: 40), through: today) == [second])
        #expect(WeightGoal.stretches(versions, estimates: [], from: monday, through: today).isEmpty)
    }

    @Test func aRateConvertsBetweenAShareAndAnAmountAWeek() throws {
        let share = try #require(NutritionRate.share(ofWeekly: 1, trend: 90.718_474, in: .pounds))
        #expect(abs(share - 0.005) < 1e-9, "1 lb a week at 200 lb is 0.5 %")
        #expect(abs(NutritionRate.weekly(share, trend: 90.718_474, in: .pounds) - 1) < 1e-9)
        #expect(abs(try #require(NutritionRate.share(ofWeekly: 0.4, trend: 80, in: .kilograms)) - 0.005) < 1e-12)
        #expect(NutritionRate.share(ofWeekly: -0.4, trend: 80, in: .kilograms) == 0.005, "Unsigned, like weeklyRate")
        #expect(NutritionRate.share(ofWeekly: 1, trend: 0, in: .pounds) == nil)
    }
}
