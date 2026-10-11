import Foundation
import Testing
@testable import ExerlyCore

/// Gaps in the trend line and what a trend rests on.
@Suite struct WeightTrendExplanationTests {
    let start = LocalDate("2026-09-07")!

    func points(_ readings: [Bool]) -> [WeightTrend.Point] {
        let days = readings.enumerated().map { day, weighed in
            EnergyBalance.Day(date: start.adding(days: day), intake: nil, weights: weighed ? [80 - Double(day) * 0.05] : [])
        }
        return WeightTrend.series(EnergyBalance.estimate(days), from: start, through: start.adding(days: readings.count - 1))
    }

    @Test func gapsOfTwoOrMoreDaysAreDrawnApartAndRunsJoinUp() {
        // Weighed, one day missed, weighed, three days missed, weighed twice, then two days since.
        let runs = WeightTrend.runs(points([true, false, true, false, false, false, true, true, false, false]))
        #expect(runs.map(\.measured) == [true, false, true, false])
        #expect(runs[0].points.map { start.days(until: $0.date) } == [0, 1, 2], "One missed day isn't a gap")
        #expect(runs[1].points.map { start.days(until: $0.date) } == [2, 3, 4, 5, 6], "A gap spans from reading to reading")
        #expect(runs[2].points.map { start.days(until: $0.date) } == [6, 7])
        #expect(runs[3].points.map { start.days(until: $0.date) } == [7, 8, 9], "Days since the last weigh-in are a gap too")
        for (earlier, later) in zip(runs, runs.dropFirst()) { #expect(earlier.points.last == later.points.first) }
        // A lone reading between two gaps keeps its dot; the line either side is one gap.
        let lone = WeightTrend.runs(points([true, true, false, false, true, false, false, true, true]))
        #expect(lone.map(\.measured) == [true, false, true])
        #expect(lone[1].points.map { start.days(until: $0.date) } == [1, 2, 3, 4, 5, 6, 7])
        #expect(WeightTrend.runs(points([true, true, true])).map(\.measured) == [true])
        #expect(WeightTrend.runs(points([true])).isEmpty)
    }

    /// Food fully logged at 2,000 kcal against 2,500 burned, weighed every morning with water swings.
    func loggedDays(_ count: Int) -> [EnergyBalance.Day] {
        (0..<count).map { day in
            let weight = 82 - Double(day) * 500 / 7700 + 0.4 * sin(Double(day) * 1.9)
            return EnergyBalance.Day(date: start.adding(days: day), intake: 2000, weights: [weight])
        }
    }

    @Test func todaysTrendRestsMostOnTheLatestReadingsAndTheEffectsSumToOne() throws {
        let days = loggedDays(42)
        let today = start.adding(days: 41)
        let prior = (mean: 2500.0, error: 375.0)
        let all = EnergyBalance.influence(days, on: today, lookback: 60, prior: prior)
        #expect(all.count == 42)
        #expect(abs(all.reduce(0) { $0 + $1.effect } - 1) < 1e-6, "Moving every reading by 1 kg moves the trend by 1 kg")
        let recent = EnergyBalance.influence(days, on: today, prior: prior)
        #expect(recent.count == 29, "Four weeks back, through today")
        let latest = try #require(recent.last)
        #expect(latest.date == today)
        #expect(latest.effect == recent.map(\.effect).max(), "The newest reading counts most")
        #expect(recent.suffix(7).reduce(0) { $0 + $1.effect } > 0.5, "The last week carries most of the trend")
        // Exact for a linear smoother: nudging by 2 kg moves the trend twice as far.
        var nudged = days
        nudged[41].weights = nudged[41].weights.map { $0 + 2 }
        let base = try #require(EnergyBalance.estimate(days, prior: prior).last?.trend)
        let moved = try #require(EnergyBalance.estimate(nudged, prior: prior).last?.trend)
        #expect(abs((moved - base) - 2 * latest.effect) < 1e-9)
        #expect(EnergyBalance.influence(days, on: start.adding(days: 99), prior: prior).isEmpty)
    }
}
