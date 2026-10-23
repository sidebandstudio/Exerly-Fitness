import Foundation

/// Which app's or device's readings count when two sources in Apple Health
/// record the same thing, such as a watch and a sleep app both recording one
/// night. Health doesn't share the order a person set in it, so Exerly uses
/// the person's own order when they've chosen one, then Apple's devices
/// (Health's own default), then whichever source recorded the most, then the
/// name, so the choice is the same every time.
public enum HealthSourcePriority {
    /// Health's bundle identifier prefix for the iPhone and Apple Watch.
    public static let appleDevicePrefix = "com.apple.health"

    /// Every source, best first.
    public static func order(_ counts: [String: Int], preferred: [String] = []) -> [String] {
        counts.keys.sorted { a, b in
            let ranked = (preferred.firstIndex(of: a) ?? .max, preferred.firstIndex(of: b) ?? .max)
            if ranked.0 != ranked.1 { return ranked.0 < ranked.1 }
            let apple = (a.hasPrefix(appleDevicePrefix), b.hasPrefix(appleDevicePrefix))
            if apple.0 != apple.1 { return apple.0 }
            if counts[a] != counts[b] { return counts[a, default: 0] > counts[b, default: 0] }
            return a < b
        }
    }

    /// Keeps, in each group, only the items from its best source in `order`.
    /// Returns what was kept and how many were left out.
    public static func resolve<T, Key: Hashable>(_ items: [T], order: [String], source: (T) -> String,
                                                 group: (T) -> Key) -> (kept: [T], leftOut: Int) {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        let best = Dictionary(grouping: items, by: group).mapValues { members in
            members.map(source).min { rank[$0, default: .max] < rank[$1, default: .max] }
        }
        let kept = items.filter { best[group($0)] == source($0) }
        return (kept, items.count - kept.count)
    }
}

/// A sleep sample from Apple Health.
public struct HealthSleepReading: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Any stage of sleep: core, deep, REM or unspecified.
        case asleep
        /// In bed or awake, which don't count as sleep.
        case notAsleep
    }

    public var start: Date
    public var end: Date
    public var kind: Kind
    public var source: String
    /// The time zone recorded with the sample, if any.
    public var timeZone: TimeZone?

    public init(start: Date, end: Date, kind: Kind, source: String, timeZone: TimeZone? = nil) {
        self.start = start
        self.end = end
        self.kind = kind
        self.source = source
        self.timeZone = timeZone
    }
}

/// A heart rate variability (SDNN, ms) or resting heart rate (bpm) sample.
public struct HealthHeartReading: Sendable, Hashable {
    public var at: Date
    public var value: Double
    public var source: String
    public var timeZone: TimeZone?

    public init(at: Date, value: Double, source: String, timeZone: TimeZone? = nil) {
        self.at = at
        self.value = value
        self.source = source
        self.timeZone = timeZone
    }
}

public enum HealthRecovery {
    /// The day a night counts for: the day you wake up. A night runs from
    /// 6 PM to 6 PM, by when each sample ends, in the time zone it was
    /// recorded in (else `timeZone`), so a flight doesn't split one night in
    /// two and an evening nap counts for that evening's night. By the clock,
    /// not six hours later, which is off by one where clocks change at midnight.
    public static func night(of end: Date, recordedIn zone: TimeZone?, timeZone: TimeZone) -> LocalDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone ?? timeZone
        let day = LocalDate(end, in: calendar.timeZone)
        return calendar.component(.hour, from: end) >= 18 ? day.adding(days: 1) : day
    }

    /// One `RecoveryDay` for each date in `dates`, missing values left nil:
    /// - sleep: the time asleep that night from its best source, overlapping
    ///   samples counted once;
    /// - HRV: the mean of that night's readings from its best source;
    /// - resting heart rate: the mean of that day's readings from its best source.
    public static func days(_ dates: [LocalDate], sleep: [HealthSleepReading], hrv: [HealthHeartReading],
                            restingHeartRate: [HealthHeartReading], timeZone: TimeZone,
                            preferred: [String] = []) -> [RecoveryDay] {
        let asleep = sleep.filter { $0.kind == .asleep && $0.end > $0.start }
        let sleepByNight = best(asleep, preferred: preferred, source: \.source) {
            night(of: $0.end, recordedIn: $0.timeZone, timeZone: timeZone)
        }
        let hrvByNight = best(hrv, preferred: preferred, source: \.source) { night(of: $0.at, recordedIn: $0.timeZone, timeZone: timeZone) }
        let restingByDay = best(restingHeartRate, preferred: preferred, source: \.source) { LocalDate($0.at, in: $0.timeZone ?? timeZone) }
        return dates.map { date in
            RecoveryDay(date: date,
                        sleepHours: sleepByNight[date].map { hoursAsleep($0) },
                        hrv: hrvByNight[date].map(mean),
                        restingHeartRate: restingByDay[date].map(mean))
        }
    }

    /// The union of the intervals, in hours, so overlapping stages or
    /// samples count once.
    static func hoursAsleep(_ readings: [HealthSleepReading]) -> Double {
        var total: TimeInterval = 0
        var current: (start: Date, end: Date)?
        for reading in readings.sorted(by: { $0.start < $1.start }) {
            if let open = current, reading.start <= open.end {
                current = (open.start, max(open.end, reading.end))
            } else {
                if let open = current { total += open.end.timeIntervalSince(open.start) }
                current = (reading.start, reading.end)
            }
        }
        if let open = current { total += open.end.timeIntervalSince(open.start) }
        return total / 3600
    }

    private static func mean(_ readings: [HealthHeartReading]) -> Double {
        readings.map(\.value).reduce(0, +) / Double(readings.count)
    }

    /// Each date's readings from its best source.
    private static func best<T>(_ items: [T], preferred: [String], source: (T) -> String,
                                date: (T) -> LocalDate) -> [LocalDate: [T]] {
        let order = HealthSourcePriority.order(Dictionary(items.map { (source($0), 1) }, uniquingKeysWith: +), preferred: preferred)
        return Dictionary(grouping: HealthSourcePriority.resolve(items, order: order, source: source, group: date).kept, by: date)
    }
}
