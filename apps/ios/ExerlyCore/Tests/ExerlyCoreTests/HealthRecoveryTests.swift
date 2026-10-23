import Foundation
import Testing
@testable import ExerlyCore

@Suite struct HealthRecoveryTests {
    let newYork = TimeZone(identifier: "America/New_York")!
    let watch = "com.apple.health.81E5A1B0"
    let sleepApp = "com.example.sleep"

    /// A local time in New York, `day` days into October 2026.
    func at(_ day: Int, _ hour: Int, _ minute: Int = 0, in zone: TimeZone? = nil) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone ?? newYork
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func asleep(_ start: Date, _ end: Date, _ source: String, zone: TimeZone? = nil) -> HealthSleepReading {
        HealthSleepReading(start: start, end: end, kind: .asleep, source: source, timeZone: zone)
    }

    @Test func aNightCountsForTheMorningYouWakeAndOverlapsCountOnce() {
        let sleep = [
            // The night before Oct 12: 23:00–03:00 and 02:30–06:30 (overlapping stages), then awake in bed.
            asleep(at(11, 23), at(12, 3), watch), asleep(at(12, 2, 30), at(12, 6, 30), watch),
            HealthSleepReading(start: at(12, 6, 30), end: at(12, 7, 30), kind: .notAsleep, source: watch),
            // A nap at 19:00 on Oct 12 counts for the night that follows it.
            asleep(at(12, 19), at(12, 19, 30), watch),
        ]
        let days = HealthRecovery.days([LocalDate("2026-10-12")!, LocalDate("2026-10-13")!, LocalDate("2026-10-14")!],
                                       sleep: sleep, hrv: [], restingHeartRate: [], timeZone: newYork)
        #expect(days.map(\.sleepHours) == [7.5, 0.5, nil], "in bed and awake don't count; a night with nothing is missing, not zero")
    }

    @Test func aNightIsGroupedInTheZoneItWasRecordedIn() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        // Asleep 22:00–06:00 in Tokyo: 09:00–17:00 the day before in New York,
        // which would otherwise put most of it on the wrong night.
        let sleep = [asleep(at(14, 22, in: tokyo), at(15, 6, in: tokyo), watch, zone: tokyo)]
        let days = HealthRecovery.days([LocalDate("2026-10-14")!, LocalDate("2026-10-15")!], sleep: sleep, hrv: [],
                                       restingHeartRate: [], timeZone: newYork)
        #expect(days.map(\.sleepHours) == [nil, 8])
    }

    /// A local time, in `zone`.
    func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func aNightAcrossAClockChangeCountsItsRealHoursForTheMorningYouWake() {
        // 22:00 to 06:30 by the clock: an hour shorter when clocks go forward, an hour longer when they go back.
        let spring = [asleep(local(2026, 3, 7, 22, in: newYork), local(2026, 3, 8, 6, 30, in: newYork), watch)]
        #expect(HealthRecovery.days([LocalDate("2026-03-07")!, LocalDate("2026-03-08")!], sleep: spring, hrv: [], restingHeartRate: [],
                                    timeZone: newYork).map(\.sleepHours) == [nil, 7.5])
        let fall = [asleep(local(2026, 10, 31, 22, in: newYork), local(2026, 11, 1, 6, 30, in: newYork), watch)]
        #expect(HealthRecovery.days([LocalDate("2026-10-31")!, LocalDate("2026-11-01")!], sleep: fall, hrv: [], restingHeartRate: [],
                                    timeZone: newYork).map(\.sleepHours) == [nil, 9.5])
    }

    @Test func anEveningNapCountsForTheNextNightEvenWhereClocksChangeAtMidnight() {
        // Santiago's clocks go back at midnight on 4 April 2026, and forward at midnight on 6 September.
        let santiago = TimeZone(identifier: "America/Santiago")!
        for (day, month) in [(4, 4), (5, 9)] {
            let nap = asleep(local(2026, month, day, 18, in: santiago), local(2026, month, day, 18, 30, in: santiago), watch, zone: santiago)
            let before = asleep(local(2026, month, day, 17, in: santiago), local(2026, month, day, 17, 30, in: santiago), watch, zone: santiago)
            let dates = [LocalDate(year: 2026, month: month, day: day)!, LocalDate(year: 2026, month: month, day: day + 1)!]
            #expect(HealthRecovery.days(dates, sleep: [nap], hrv: [], restingHeartRate: [], timeZone: newYork).map(\.sleepHours) == [nil, 0.5])
            #expect(HealthRecovery.days(dates, sleep: [before], hrv: [], restingHeartRate: [], timeZone: newYork).map(\.sleepHours) == [0.5, nil])
        }
    }

    @Test func eachNightUsesItsBestSourceOnly() {
        let sleep = [
            asleep(at(11, 23), at(12, 7), watch), asleep(at(11, 22, 30), at(12, 7, 15), sleepApp),
            asleep(at(12, 23), at(13, 6), sleepApp),
        ]
        let hrv = [HealthHeartReading(at: at(12, 4), value: 40, source: watch), HealthHeartReading(at: at(12, 5), value: 50, source: watch),
                   HealthHeartReading(at: at(12, 5), value: 90, source: sleepApp)]
        let resting = [HealthHeartReading(at: at(12, 12), value: 58, source: watch), HealthHeartReading(at: at(12, 12), value: 70, source: sleepApp)]
        let dates = [LocalDate("2026-10-12")!, LocalDate("2026-10-13")!]
        var days = HealthRecovery.days(dates, sleep: sleep, hrv: hrv, restingHeartRate: resting, timeZone: newYork)
        #expect(days[0] == RecoveryDay(date: dates[0], sleepHours: 8, hrv: 45, restingHeartRate: 58), "the watch, as Health ranks it")
        #expect(days[1].sleepHours == 7, "the only source that night")

        days = HealthRecovery.days(dates, sleep: sleep, hrv: hrv, restingHeartRate: resting, timeZone: newYork, preferred: [sleepApp])
        #expect(days[0] == RecoveryDay(date: dates[0], sleepHours: 8.75, hrv: 90, restingHeartRate: 70), "the person's own order first")
    }

    @Test func sourcesRankByChoiceThenAppleThenCountThenName() {
        let counts = ["com.b": 5, "com.a": 5, "com.c": 9, watch: 1]
        #expect(HealthSourcePriority.order(counts) == [watch, "com.c", "com.a", "com.b"])
        #expect(HealthSourcePriority.order(counts, preferred: ["com.b"]) == ["com.b", watch, "com.c", "com.a"])
        let resolved = HealthSourcePriority.resolve([("com.a", 1), ("com.c", 1), ("com.a", 2)], order: ["com.c", "com.a"],
                                                    source: \.0, group: \.1)
        #expect(resolved.kept.map(\.0) == ["com.c", "com.a"] && resolved.leftOut == 1)
    }
}
