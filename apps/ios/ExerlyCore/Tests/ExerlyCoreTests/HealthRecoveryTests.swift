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
