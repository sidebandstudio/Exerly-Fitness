import XCTest
import ExerlyCore
@testable import Exerly

@MainActor
final class BodyPresentationTests: XCTestCase {
    func testChangesUseATrueMinusAndTheDisplayUnit() {
        XCTAssertEqual(BodyFormat.change(-0.5443, .pounds), "−1.2 lb")
        XCTAssertEqual(BodyFormat.change(0.4, .kilograms), "+0.4 kg")
        XCTAssertEqual(BodyFormat.change(0.01, .kilograms), "0.0 kg")
        XCTAssertEqual(BodyFormat.change(-0.4536, .pounds, digits: 2, suffix: "/wk"), "−1.00 lb/wk")
        XCTAssertEqual(BodyFormat.spokenChange(-0.5443, .pounds), "down 1.2 pounds")
        XCTAssertEqual(BodyFormat.spokenChange(0.001, .kilograms), "no change")
    }

    func testReadingsShowAsEnteredInTheirOwnUnitAndConvertOtherwise() {
        XCTAssertEqual(BodyFormat.reading(.lb(184.6), .pounds), "184.6 lb")
        XCTAssertEqual(BodyFormat.reading(.kg(72.25), .kilograms), "72.25 kg")
        XCTAssertEqual(BodyFormat.reading(.kg(80), .pounds), "176.4 lb")
        XCTAssertEqual(BodyFormat.reading(.lb(180), .kilograms), "81.6 kg")
        XCTAssertEqual(BodyFormat.spokenReading(.kg(72.25), .kilograms), "72.25 kilograms")
        XCTAssertEqual(BodyFormat.weight(80, .kilograms), "80.0 kg")
        XCTAssertEqual(BodyFormat.kcal(2_487), "2,490")
    }

    /// Review round 1: two readings on one day were read alike. VoiceOver
    /// hears each one's time, body fat and source.
    func testAWeighInIsReadWithItsTimeBodyFatAndSource() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let day = try XCTUnwrap(LocalDate("2026-10-19"))
        let morning = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-19T11:11:00Z"))
        let time = BodyFormat.time(morning, in: zone)
        let scale = WeightEntry(at: morning, date: day, weight: .lb(177), bodyFat: 21.5, source: .appleHealth)
        XCTAssertEqual(BodyFormat.spokenWeighIn(scale, day: "Yesterday", unit: .pounds, timeZone: zone),
                       "Weigh-in, Yesterday at \(time), 177.0 pounds, 21.5 percent body fat, from Apple Health")
        let typed = WeightEntry(at: morning.addingTimeInterval(3600), date: day, weight: .lb(177))
        XCTAssertEqual(BodyFormat.spokenWeighIn(typed, day: "Yesterday", unit: .pounds, timeZone: zone),
                       "Weigh-in, Yesterday at \(BodyFormat.time(typed.at, in: zone)), 177.0 pounds")
        XCTAssertNotEqual(time, BodyFormat.time(typed.at, in: zone))
    }

    func testDaysAreRelativeNearTodayAndCarryTheYearOtherwise() throws {
        let today = try XCTUnwrap(LocalDate("2026-10-09"))
        XCTAssertEqual(BodyFormat.day(today, today: today), "Today")
        XCTAssertEqual(BodyFormat.day(today.adding(days: -1), today: today), "Yesterday")
        XCTAssertEqual(BodyFormat.day(today.adding(days: -3), today: today), "Tue, Oct 6")
        XCTAssertEqual(BodyFormat.day(try XCTUnwrap(LocalDate("2025-12-31")), today: today), "Dec 31, 2025")
    }

    func testChartAnchorsKeepTheLocalDateInEveryZone() throws {
        let date = try XCTUnwrap(LocalDate("2026-03-08"))
        XCTAssertEqual(BodyDates.date(BodyDates.anchor(date)), date)
        for zone in ["Pacific/Kiritimati", "Pacific/Pago_Pago", "America/New_York"] {
            let instant = BodyDates.anchor(date)
            XCTAssertEqual(LocalDate(instant, in: BodyDates.utc), date, zone)
        }
    }

    func testTheRulerStepsOnItsGridAndStaysInRange() {
        let pounds = WeightRuler.range(for: .pounds)
        XCTAssertEqual(pounds.lowerBound, 44.1, accuracy: 1e-9)
        XCTAssertEqual(pounds.upperBound, 881.8, accuracy: 1e-9)
        XCTAssertEqual(WeightRuler.range(for: .kilograms), 20...400)
        XCTAssertEqual(WeightRuler.nudged(184.6, by: 1, unit: .pounds, range: pounds), 184.7)
        // 160.2 is five steps down from 160.7, not out of reach between 0.2 lb ticks.
        XCTAssertEqual(WeightRuler.nudged(160.7, by: -5, unit: .pounds, range: pounds), 160.2)
        // A typed value between ticks moves to its neighbour, not a whole step past it.
        XCTAssertEqual(WeightRuler.nudged(184.55, by: 1, unit: .pounds, range: pounds), 184.6)
        XCTAssertEqual(WeightRuler.nudged(184.55, by: -1, unit: .pounds, range: pounds), 184.5)
        XCTAssertEqual(WeightRuler.nudged(72.3, by: 1, unit: .kilograms, range: 20...400), 72.4)
        XCTAssertEqual(WeightRuler.nudged(72.3, by: -3, unit: .kilograms, range: 20...400), 72)
        XCTAssertEqual(WeightRuler.nudged(400, by: 1, unit: .kilograms, range: 20...400), 400)
        XCTAssertEqual(WeightRuler.snapped(184.76, unit: .pounds, range: pounds), 184.8)
        XCTAssertEqual(WeightRuler.snapped(5, unit: .kilograms, range: 20...400), 20)
    }

    func testRangesEndTodayAndAllStartsAtTheFirstWeighIn() throws {
        let today = try XCTUnwrap(LocalDate("2026-10-09"))
        let first = try XCTUnwrap(LocalDate("2025-01-02"))
        XCTAssertEqual(BodyRange.week.start(today: today, first: first), LocalDate("2026-10-02"),
                       "A week's change spans the seven days of the summary's \"this week\"")
        XCTAssertEqual(BodyRange.month.start(today: today, first: first), today.adding(days: -30))
        XCTAssertEqual(BodyRange.all.start(today: today, first: first), first)
        XCTAssertEqual(BodyRange.all.start(today: today, first: nil), today)
        let start = BodyRange.quarter.start(today: today, first: first)
        XCTAssertEqual(BodyRange.quarter.phrase(start: start, firstShown: start), "past 3 months")
        XCTAssertEqual(BodyRange.quarter.phrase(start: start, firstShown: nil), "past 3 months")
        XCTAssertEqual(BodyRange.quarter.phrase(start: start, firstShown: LocalDate("2026-09-13")), "since Sep 13",
                       "A chart whose data starts late says so")
    }

    func testExpenditureSaysWhatItStillNeeds() {
        func expenditure(logged: Int, weighed: Int, error: Double = 300) -> WeightTrend.Expenditure {
            WeightTrend.Expenditure(kcal: 2400, error: error, loggedDays: logged, weighInDays: weighed)
        }
        XCTAssertEqual(BodyCopy.expenditureWaiting(expenditure(logged: 6, weighed: 2)),
                       "Expenditure appears after 1 more fully logged day.")
        XCTAssertEqual(BodyCopy.expenditureWaiting(expenditure(logged: 9, weighed: 1)),
                       "Expenditure appears after 3 more weigh-ins.")
        XCTAssertEqual(BodyCopy.expenditureWaiting(expenditure(logged: 9, weighed: 9)),
                       "Expenditure is still settling. Keep logging full days.")
        XCTAssertTrue(expenditure(logged: 9, weighed: 9, error: 200).isMeasured)
    }

    func testEstimatesAreReusedUntilTheirInputsChange() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let today = LocalDate(Date(), in: zone)
        XCTAssertTrue(BodyEstimates.shared.estimates(store, through: today).isEmpty)
        try store.logWeight(.kg(80), at: WeightTrend.noon(on: today.adding(days: -3), in: zone), timeZone: zone)
        let first = BodyEstimates.shared.estimates(store, through: today)
        XCTAssertEqual(first.count, 4)
        XCTAssertEqual(BodyEstimates.shared.estimates(store, through: today), first)
        try store.logWeight(.kg(79), timeZone: zone)
        let second = BodyEstimates.shared.estimates(store, through: today)
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(second.last?.weight, 79)
    }
}
