import Foundation
import Testing
@testable import ExerlyCore

@MainActor
@Suite struct WeightTrendSummaryTests {
    let start = LocalDate("2026-09-07")!

    /// A person burning 2,500 kcal who logs 2,000 on complete days, so the
    /// trend falls about 65 g a day; scale readings swing with water.
    func days(_ count: Int, logged: Bool = true, weighIn: (Int) -> Bool = { _ in true }) -> [EnergyBalance.Day] {
        (0..<count).map { day in
            let water = 0.4 * sin(Double(day) * 1.9)
            let weight = 82 - Double(day) * 500 / 7700 + water
            return EnergyBalance.Day(date: start.adding(days: day), intake: logged ? 2000 : nil,
                                     weights: weighIn(day) ? [weight] : [])
        }
    }

    @Test func noWeighInsHaveNoSummary() {
        #expect(WeightTrend.summary([], through: start) == nil)
        #expect(WeightTrend.summary(EnergyBalance.estimate(days(5, weighIn: { _ in false })), through: start) == nil)
    }

    @Test func oneReadingIsTheTrendWithNoChangeAndNoMeasuredExpenditure() throws {
        let estimates = EnergyBalance.estimate([EnergyBalance.Day(date: start, intake: nil, weights: [80])])
        let summary = try #require(WeightTrend.summary(estimates, through: start))
        #expect(summary.trend == 80)
        #expect(summary.trendError > 0)
        #expect(summary.weekChange == nil)
        #expect(summary.weighInDays == 1)
        #expect(!summary.expenditure.isMeasured)
        #expect(summary.expenditure.loggedDaysNeeded == WeightTrend.minimumLoggedDays)
    }

    @Test func fourWeeksOfLoggingMeasureTheLossAndTheExpenditure() throws {
        let estimates = EnergyBalance.estimate(days(28))
        let today = start.adding(days: 27)
        let summary = try #require(WeightTrend.summary(estimates, through: today))
        let week = try #require(summary.weekChange)
        #expect(week.days == 7 && week.through == today)
        #expect(abs(week.kilograms - (-7 * 500 / 7700)) < 0.2)
        #expect(abs(try #require(week.weeklyRate) - week.kilograms) < 1e-9)
        #expect(summary.expenditure.loggedDays == 28 && summary.expenditure.weighInDays == 28)
        #expect(summary.expenditure.isMeasured)
        #expect(abs(summary.expenditure.kcal - 2500) < 2 * summary.expenditure.error)
        #expect(abs(summary.trend - (82 - 27 * 500 / 7700)) < 0.5)
    }

    @Test func expenditureFromAConfidentGuessAloneIsNotMeasured() throws {
        let estimates = EnergyBalance.estimate(days(28, logged: false), prior: (2500, 80))
        let summary = try #require(WeightTrend.summary(estimates, through: start.adding(days: 27)))
        #expect(summary.expenditure.error <= WeightTrend.maximumExpenditureError)
        #expect(summary.expenditure.loggedDays == 0)
        #expect(!summary.expenditure.isMeasured)
        #expect(summary.expenditure.loggedDaysNeeded == 7 && summary.expenditure.weighInDaysNeeded == 0)
    }

    @Test func theWindowCountsOnlyTheLastFourWeeks() throws {
        // Logged for six weeks, then a week off: the window holds 21 logged days.
        var history = days(49)
        for day in 42..<49 { history[day].intake = nil }
        let summary = try #require(WeightTrend.summary(EnergyBalance.estimate(history), through: start.adding(days: 48)))
        #expect(summary.expenditure.loggedDays == 21)
        #expect(summary.expenditure.weighInDays == 28)
    }

    @Test func aWeekChangeNeedsAWeekOfHistoryAndTwoWeighInDays() throws {
        let short = EnergyBalance.estimate(days(5))
        #expect(try #require(WeightTrend.summary(short, through: start.adding(days: 4))).weekChange == nil)
        // Weighed once at the start and once nine days later: only one reading in the last week.
        let sparse = EnergyBalance.estimate(days(10, weighIn: { $0 == 0 || $0 == 9 }))
        let summary = try #require(WeightTrend.summary(sparse, through: start.adding(days: 9)))
        #expect(summary.weekChange == nil)
        // The trend still runs to today, honest about its wider band.
        #expect(summary.date == start.adding(days: 9))
        let gap = sparse[5]
        #expect(gap.weight == nil && gap.trendError > sparse[0].trendError * 0.5)
    }

    @Test func aRangeChangeStartsAtTheFirstEstimateAndGivesAWeeklyRate() throws {
        let estimates = EnergyBalance.estimate(days(21))
        let change = try #require(WeightTrend.change(estimates, from: start.adding(days: -60), through: start.adding(days: 20)))
        #expect(change.from == start && change.days == 20)
        let rate = try #require(change.weeklyRate)
        #expect(abs(rate - change.kilograms / 20 * 7) < 1e-9)
        #expect(rate < -0.25 && rate > -0.65)
        let threeDays = try #require(WeightTrend.change(estimates, from: start, through: start.adding(days: 3)))
        #expect(threeDays.weeklyRate == nil)
        #expect(WeightTrend.change(estimates, from: start, through: start) == nil)
    }

    /// Today, Profile and Progress read one summary: its trend is the chart's
    /// last point, and "this week" is the trend's change over seven days,
    /// which a seven-day range's change and average repeat.
    @Test func theHeadlineThisWeekAndASevenDayRangeAreOneFigure() throws {
        let estimates = EnergyBalance.estimate(days(28, weighIn: { $0 % 4 != 1 && $0 != 27 }))
        let today = start.adding(days: 27)
        let summary = try #require(WeightTrend.summary(estimates, through: today))
        let last = try #require(WeightTrend.series(estimates, from: today.adding(days: -90), through: today).last)
        #expect(summary.trend == last.trend && summary.trendError == last.trendError && last.date == today)
        let week = try #require(summary.weekChange)
        #expect(week.kilograms == estimates[27].trend - estimates[20].trend)
        let range = try #require(WeightTrend.change(estimates, from: today.adding(days: -7), through: today))
        #expect(range == week)
        #expect(abs(try #require(range.weeklyRate) - week.kilograms) < 1e-12)
    }

    /// With no weigh-in today, today's trend is yesterday's moved by
    /// yesterday's logged balance. Moving a 520 kcal lunch off yesterday
    /// lowers it by 520 / 7,700 kg and leaves every earlier day as it was.
    @Test func pastTheLastWeighInTheTrendIsAForecastFromLoggedFood() throws {
        var history = days(28, weighIn: { $0 != 27 })
        let before = EnergyBalance.estimate(history)
        history[26].intake = 1480
        let after = EnergyBalance.estimate(history)
        let yesterday = after[26], today = after[27]
        #expect(today.weight == nil && yesterday.weight != nil)
        #expect(abs(today.trend - (yesterday.trend + (1480 - yesterday.expenditure) / 7700)) < 1e-9)
        #expect(abs(before[27].trend - today.trend - 520.0 / 7700) < 1e-9)
        #expect(after.dropLast().map(\.trend) == before.dropLast().map(\.trend))
        #expect(after.dropLast().map(\.expenditure) == before.dropLast().map(\.expenditure))
        #expect(today.trendError > yesterday.trendError)
        #expect(try #require(WeightTrend.summary(after, through: start.adding(days: 27))).trend == today.trend)
    }

    /// Two readings in a row well above the trend are read as water: the
    /// trend stays near the truth below them, following the logged deficit,
    /// rather than bending up toward them.
    @Test func twoHighReadingsAtTheEndAreReadAsWater() {
        // Truth loses 28 g a day on 1,784 kcal logged against 2,000.
        let history = (0..<28).map { day -> EnergyBalance.Day in
            let truth = 80 - 0.028 * Double(day)
            let water = day == 25 ? 0.3 : day == 26 ? 0.35 : 0.3 * sin(Double(day) * 1.7) + 0.12 * cos(Double(day) * 3.1)
            return EnergyBalance.Day(date: start.adding(days: day), intake: 1784,
                                     weights: day == 27 || day % 9 == 4 ? [] : [truth + water])
        }
        let estimates = EnergyBalance.estimate(history, prior: (2000, 300))
        for day in [25, 26] {
            let truth = 80 - 0.028 * Double(day)
            #expect(estimates[day].trend < estimates[day].weight! - 0.1)
            #expect(abs(estimates[day].trend - truth) < 0.2)
        }
        #expect(estimates[26].trend < estimates[24].trend && estimates[27].trend < estimates[26].trend)
    }

    @Test func seriesKeepReadingsAndThinningKeepsTheEnds() throws {
        let estimates = EnergyBalance.estimate(days(30, weighIn: { $0 % 3 == 0 }))
        let points = WeightTrend.series(estimates, from: start.adding(days: 10), through: start.adding(days: 19))
        #expect(points.count == 10)
        #expect(points.first?.date == start.adding(days: 10))
        #expect(points.filter { $0.reading != nil }.map(\.date) == [12, 15, 18].map { start.adding(days: $0) })
        let all = WeightTrend.series(estimates, from: start, through: start.adding(days: 29))
        let thin = WeightTrend.thinned(all, limit: 7)
        #expect(thin.count == 7 && thin.first == all.first && thin.last == all.last)
        #expect(thin == thin.sorted { $0.date < $1.date })
        #expect(WeightTrend.thinned(all, limit: 100) == all)
    }

    @Test func theDomainCoversReadingsAndTheBandWithAMinimumSpan() throws {
        let points = WeightTrend.series(EnergyBalance.estimate(days(14)), from: start, through: start.adding(days: 13))
        let domain = try #require(WeightTrend.domain(points, minimumSpan: 1))
        for point in points {
            #expect(domain.contains(point.trend + point.trendError) && domain.contains(point.trend - point.trendError))
            if let reading = point.reading { #expect(domain.contains(reading)) }
        }
        let flat = [WeightTrend.Point(EnergyBalance.Estimate(date: start, trend: 80, trendError: 0, expenditure: 2000,
                                                               expenditureError: 100, weight: 80, intake: nil))]
        let span = try #require(WeightTrend.domain(flat, minimumSpan: 2))
        #expect(abs(span.upperBound - span.lowerBound - 2) < 1e-9 && span.contains(80))
        #expect(WeightTrend.domain([], minimumSpan: 1) == nil)
    }

    @Test func suggestionsUseTheLatestReadingAsEnteredOrTheTrend() {
        #expect(WeightTrend.suggestedReading(latest: .lb(184.6), trend: 80, unit: .pounds) == 184.6)
        #expect(WeightTrend.suggestedReading(latest: .kg(80), trend: nil, unit: .pounds) == 176.4)
        #expect(WeightTrend.suggestedReading(latest: .lb(180), trend: nil, unit: .kilograms) == 81.6)
        #expect(WeightTrend.suggestedReading(latest: nil, trend: 80.04, unit: .kilograms) == 80)
        #expect(WeightTrend.suggestedReading(latest: nil, trend: nil, unit: .kilograms) == nil)
        #expect(WeightTrend.step(for: .kilograms) == 0.1 && WeightTrend.step(for: .pounds) == 0.1)
    }

    @Test func movingAWeighInToAnotherDayKeepsItsLocalClockTime() throws {
        let zone = Fixture.newYork
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        // 00:30 on Oct 9 in New York is still Oct 9 there, though Oct 9 04:30 in UTC.
        let late = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 0, minute: 30)))
        #expect(LocalDate(late, in: zone) == LocalDate("2026-10-09"))
        let moved = WeightTrend.instant(on: LocalDate("2026-10-07")!, timeOf: late, in: zone)
        #expect(LocalDate(moved, in: zone) == LocalDate("2026-10-07"))
        #expect(calendar.dateComponents([.hour, .minute], from: moved) == DateComponents(hour: 0, minute: 30))
        // 02:30 doesn't exist on 2026-03-08 in New York; it moves forward, staying on the date.
        let early = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 2, minute: 30)))
        let skipped = WeightTrend.instant(on: LocalDate("2026-03-08")!, timeOf: early, in: zone)
        #expect(LocalDate(skipped, in: zone) == LocalDate("2026-03-08"))
        let noon = WeightTrend.noon(on: LocalDate("2026-10-09")!, in: TimeZone(identifier: "Pacific/Kiritimati")!)
        #expect(LocalDate(noon, in: TimeZone(identifier: "Pacific/Kiritimati")!) == LocalDate("2026-10-09"))
    }

    // MARK: Store

    func store(_ persistence: InMemoryTrainingPersistence = InMemoryTrainingPersistence()) throws -> NutritionStore {
        try NutritionStore(persistence: persistence, now: { Fixture.instant() })
    }

    @Test func aWeighInJustAfterMidnightBelongsToThatLocalDay() throws {
        let nutrition = try store()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Fixture.newYork
        let at = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 0, minute: 30)))
        let entry = try nutrition.logWeight(.lb(184.6), at: at, timeZone: Fixture.newYork)
        #expect(entry.date == LocalDate("2026-10-09"))
        #expect(nutrition.weights(on: LocalDate("2026-10-09")!) == [entry])
        #expect(nutrition.weights(on: LocalDate("2026-10-08")!).isEmpty)
    }

    @Test func editingAWeighInKeepsItsIdentity() throws {
        let persistence = InMemoryTrainingPersistence()
        let nutrition = try store(persistence)
        let entry = try nutrition.logWeight(.lb(184.6), timeZone: Fixture.utc)
        var edited = entry
        edited.weight = .lb(183.8)
        edited.bodyFat = 21.5
        edited.date = entry.date.adding(days: -1)
        edited.at = WeightTrend.instant(on: edited.date, timeOf: entry.at, in: Fixture.utc)
        try nutrition.updateWeight(edited)
        #expect(nutrition.weights == [edited])
        #expect(try NutritionStore(persistence: persistence).weights == [edited])
        var invalid = edited
        invalid.weight = .kg(5)
        #expect(throws: NutritionStore.StoreError.invalid(["weight must be 20 to 400 kg"])) { try nutrition.updateWeight(invalid) }
        #expect(throws: NutritionStore.StoreError.notFound) {
            try nutrition.updateWeight(WeightEntry(at: entry.at, date: entry.date, weight: .kg(80)))
        }
        #expect(nutrition.weights == [edited])
    }

    @Test func weighInsFromAppleHealthCannotBeEditedHere() throws {
        let nutrition = try store()
        let sample = HealthWeight(id: UUID(), at: Fixture.instant(), kilograms: 80)
        try nutrition.importHealthWeights([sample], timeZone: Fixture.utc)
        var edited = try #require(nutrition.weights.first)
        edited.weight = .kg(79)
        #expect(throws: NutritionStore.StoreError.self) { try nutrition.updateWeight(edited) }
        #expect(nutrition.weights.first?.weight == .kg(80))
    }

    @Test func legacyWeighInsImportOnceWithStableIDsAtMiddayOnTheirDates() throws {
        let persistence = InMemoryTrainingPersistence()
        let nutrition = try store(persistence)
        let readings = [
            LegacyWeighIn(date: LocalDate("2026-10-01")!, kilograms: 82.25, bodyFat: 22),
            LegacyWeighIn(date: LocalDate("2026-10-02")!, kilograms: 82.1, bodyFat: 1),
            LegacyWeighIn(date: LocalDate("2026-10-03")!, kilograms: 450),
        ]
        #expect(try nutrition.importLegacyWeights(readings, accountID: "account-1", timeZone: Fixture.newYork) == 2)
        #expect(try nutrition.importLegacyWeights(readings, accountID: "account-1", timeZone: Fixture.newYork) == 0)
        let first = try #require(nutrition.weights(on: LocalDate("2026-10-01")!).first)
        #expect(first.id == NutritionStore.legacyWeightID(accountID: "account-1", date: LocalDate("2026-10-01")!))
        #expect(first.weight == .kg(82.25) && first.bodyFat == 22 && first.source == nil)
        #expect(first.at == WeightTrend.noon(on: first.date, in: Fixture.newYork))
        #expect(nutrition.weights(on: LocalDate("2026-10-02")!).first?.bodyFat == nil)
        #expect(nutrition.weights(on: LocalDate("2026-10-03")!).isEmpty)
        // The same date on another account gets another ID; another device gets the same one.
        #expect(NutritionStore.legacyWeightID(accountID: "account-2", date: first.date) != first.id)
        let other = try store()
        try other.importLegacyWeights(Array(readings.prefix(1)), accountID: "account-1", timeZone: Fixture.utc)
        #expect(other.weights.first?.id == first.id)
        #expect(try NutritionStore(persistence: persistence).weights.count == 2)
    }

    @Test func aLegacyReadingAlreadyLoggedHereIsNotAddedTwice() throws {
        let nutrition = try store()
        let at = WeightTrend.noon(on: LocalDate("2026-10-01")!, in: Fixture.utc)
        try nutrition.logWeight(.kg(82.2), at: at, timeZone: Fixture.utc)
        let added = try nutrition.importLegacyWeights([LegacyWeighIn(date: LocalDate("2026-10-01")!, kilograms: 82.25),
                                                       LegacyWeighIn(date: LocalDate("2026-10-02")!, kilograms: 82.25)],
                                                      accountID: "account-1", timeZone: Fixture.utc)
        #expect(added == 1)
        #expect(nutrition.weights.map(\.date) == [LocalDate("2026-10-01")!, LocalDate("2026-10-02")!])
    }

    @Test func estimatesRunFromTheFirstWeighInWithThePlanBasisAsThePrior() throws {
        let nutrition = try store()
        try nutrition.logWeight(.kg(80), at: WeightTrend.noon(on: start, in: Fixture.utc), timeZone: Fixture.utc)
        try nutrition.logWeight(.kg(79.6), at: WeightTrend.noon(on: start.adding(days: 3), in: Fixture.utc), timeZone: Fixture.utc)
        let estimates = nutrition.weightEstimates(through: start.adding(days: 6))
        #expect(estimates.map(\.date) == (0...6).map { start.adding(days: $0) })
        #expect(estimates.filter { $0.weight != nil }.count == 2)
        #expect(nutrition.weightEstimates(through: start.adding(days: -1)).isEmpty)
        let summary = try #require(WeightTrend.summary(estimates, through: start.adding(days: 6)))
        // Without a plan the starting guess is 31 kcal per kg, ±600.
        #expect(summary.expenditure.error > 500 && !summary.expenditure.isMeasured)
    }
}
