import Foundation

/// What the weight screens show: the current trend and how it moved, chart
/// series, and whether expenditure rests on enough data to call it measured.
/// Pure functions over `EnergyBalance` estimates; see
/// docs/design/007-nutrition.md. Weights are in kilograms throughout.
public enum WeightTrend {
    /// The days judged for expenditure, ending today.
    public static let window = 28
    /// Expenditure counts as measured, rather than mostly the starting guess,
    /// once the window holds this many complete or fasting days and days with a
    /// weigh-in, and its standard deviation is no wider than a check-in accepts.
    public static let minimumLoggedDays = 7
    public static let minimumWeighInDays = 4
    public static var maximumExpenditureError: Double { NutritionCheckIn.maximumError }

    /// One day of a chart.
    public struct Point: Sendable, Hashable, Identifiable {
        public var date: LocalDate
        public var trend: Double
        /// One standard deviation of the trend.
        public var trendError: Double
        public var expenditure: Double
        public var expenditureError: Double
        /// The day's mean reading, if any.
        public var reading: Double?
        public var id: LocalDate { date }

        init(_ estimate: EnergyBalance.Estimate) {
            date = estimate.date
            trend = estimate.trend
            trendError = estimate.trendError
            expenditure = estimate.expenditure
            expenditureError = estimate.expenditureError
            reading = estimate.weight
        }
    }

    /// How far the trend moved between two days.
    public struct Change: Sendable, Hashable {
        public var from: LocalDate
        public var through: LocalDate
        /// The trend at `through` minus the trend at `from`.
        public var kilograms: Double
        public var days: Int { from.days(until: through) }
        /// Per seven days; nil under a week, where a rate is mostly water.
        public var weeklyRate: Double? { days >= 7 ? kilograms / Double(days) * 7 : nil }
    }

    public struct Expenditure: Sendable, Hashable {
        /// In logged kcal a day, with one standard deviation.
        public var kcal: Double
        public var error: Double
        /// Complete or fasting days, and days with a weigh-in, in the window.
        public var loggedDays: Int
        public var weighInDays: Int

        public init(kcal: Double, error: Double, loggedDays: Int, weighInDays: Int) {
            self.kcal = kcal
            self.error = error
            self.loggedDays = loggedDays
            self.weighInDays = weighInDays
        }

        public var isMeasured: Bool {
            loggedDays >= WeightTrend.minimumLoggedDays && weighInDays >= WeightTrend.minimumWeighInDays
                && error <= WeightTrend.maximumExpenditureError
        }
        public var loggedDaysNeeded: Int { max(0, WeightTrend.minimumLoggedDays - loggedDays) }
        public var weighInDaysNeeded: Int { max(0, WeightTrend.minimumWeighInDays - weighInDays) }
    }

    /// The one trend and weekly change that Today, Profile and Progress show.
    public struct Summary: Sendable, Hashable {
        /// The latest estimate's day, normally today.
        public var date: LocalDate
        /// Past the last weigh-in, a forecast: that day's trend moved by each
        /// later day's logged or expected balance. Food logged from that day
        /// on moves only these days.
        public var trend: Double
        public var trendError: Double
        /// The last seven days, and the only figure the screens call "this
        /// week"; nil before a week of history or with fewer than two
        /// weigh-in days in it.
        public var weekChange: Change?
        public var expenditure: Expenditure
        /// Days with a reading, ever.
        public var weighInDays: Int
    }

    /// The state as of `today`, from estimates through it. Nil before the first weigh-in.
    public static func summary(_ estimates: [EnergyBalance.Estimate], through today: LocalDate) -> Summary? {
        let known = estimates.filter { $0.date <= today }
        guard let last = known.last else { return nil }
        let window = known.filter { $0.date > today.adding(days: -Self.window) }
        let expenditure = Expenditure(kcal: last.expenditure, error: last.expenditureError,
                                      loggedDays: window.filter { $0.intake != nil }.count,
                                      weighInDays: window.filter { $0.weight != nil }.count)
        var week = change(known, from: last.date.adding(days: -7), through: last.date)
        if week?.days != 7 { week = nil }
        return Summary(date: last.date, trend: last.trend, trendError: last.trendError, weekChange: week,
                       expenditure: expenditure, weighInDays: known.filter { $0.weight != nil }.count)
    }

    /// The trend's change across a range, starting no earlier than the first
    /// estimate. Nil with fewer than two weigh-in days in the range, or no span.
    public static func change(_ estimates: [EnergyBalance.Estimate], from start: LocalDate, through end: LocalDate) -> Change? {
        let range = estimates.filter { $0.date >= start && $0.date <= end }
        guard let first = range.first, let last = range.last, first.date < last.date,
              range.filter({ $0.weight != nil }).count >= 2 else { return nil }
        return Change(from: first.date, through: last.date, kilograms: last.trend - first.trend)
    }

    /// Every day from `start` through `end` that has an estimate.
    public static func series(_ estimates: [EnergyBalance.Estimate], from start: LocalDate, through end: LocalDate) -> [Point] {
        estimates.filter { $0.date >= start && $0.date <= end }.map(Point.init)
    }

    /// At most `limit` points, evenly spread, always keeping the first and last,
    /// so a line over years stays light to draw. Readings are drawn from the
    /// full series.
    public static func thinned(_ points: [Point], limit: Int) -> [Point] {
        guard limit >= 2, points.count > limit else { return points }
        let stride = Double(points.count - 1) / Double(limit - 1)
        return (0..<limit).map { points[Int((Double($0) * stride).rounded())] }
    }

    /// A stretch of the trend line: measured, or across a gap in the weigh-ins.
    public struct Run: Sendable, Hashable {
        public var points: [Point]
        /// False across a gap, which includes the days after the last weigh-in.
        public var measured: Bool
    }

    /// Days in a row without a weigh-in that make a gap.
    public static let gap = 2

    /// `points`, consecutive days, split where `gap` or more days in a row
    /// have no reading, so a chart can draw the trend across a gap as an
    /// estimate instead of as data. Neighbouring runs share their edge day,
    /// so drawn in order they make one unbroken line.
    public static func runs(_ points: [Point], gap: Int = gap) -> [Run] {
        var inGap = Array(repeating: false, count: points.count)
        var index = 0
        while index < points.count {
            guard points[index].reading == nil else { index += 1; continue }
            var end = index
            while end < points.count, points[end].reading == nil { end += 1 }
            if points[index].date.days(until: points[end - 1].date) + 1 >= gap {
                for day in index..<end { inGap[day] = true }
            }
            index = end
        }
        var runs: [Run] = []
        var current: [Point] = []
        for (index, point) in points.enumerated() {
            if index > 0, inGap[index] != inGap[index - 1] {
                if inGap[index] {
                    runs.append(Run(points: current, measured: true))
                    current = [current[current.count - 1]]
                } else {
                    current.append(point)
                    runs.append(Run(points: current, measured: false))
                    current = []
                }
            }
            current.append(point)
        }
        if let last = inGap.last { runs.append(Run(points: current, measured: !last)) }
        // A lone reading between gaps leaves a one-point run; the gaps either side join.
        return runs.filter { $0.points.count >= 2 }.reduce(into: []) { joined, run in
            if let last = joined.last, last.measured == run.measured {
                joined[joined.count - 1].points += run.points.dropFirst()
            } else {
                joined.append(run)
            }
        }
    }

    /// The chart's lowest and highest values, in kilograms: readings and the
    /// trend's band, with a little room, and at least `minimumSpan` tall.
    public static func domain(_ points: [Point], minimumSpan: Double) -> ClosedRange<Double>? {
        let values = points.flatMap { [$0.trend - $0.trendError, $0.trend + $0.trendError] + ($0.reading.map { [$0] } ?? []) }
        guard let low = values.min(), let high = values.max() else { return nil }
        let pad = max((high - low) * 0.12, (minimumSpan - (high - low)) / 2, 0)
        return (low - pad)...(high + pad)
    }

    // MARK: Entry

    /// The ruler's step: 0.1 kg or 0.1 lb, so any reading a scale shows is a step away.
    public static func step(for unit: MassUnit) -> Double { 0.1 }

    /// What a new weigh-in starts at, in `unit`, to one decimal: the latest
    /// reading as entered when it was in that unit, otherwise converted; the
    /// trend when there is no reading. Nil with neither.
    public static func suggestedReading(latest: Mass?, trend: Double?, unit: MassUnit) -> Double? {
        let value = latest.map { $0.value(in: unit) } ?? trend.map { Mass.kg($0).value(in: unit) }
        return value.map { ($0 * 10).rounded() / 10 }
    }

    /// `time`'s time of day on `date`, both as seen in `timeZone`, so a weigh-in
    /// moved to another day keeps its clock time. A time the clocks skip moves
    /// forward with them, and the result is always on `date`.
    public static func instant(on date: LocalDate, timeOf time: Date, in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let clock = calendar.dateComponents([.hour, .minute, .second], from: time)
        let parts = DateComponents(year: date.year, month: date.month, day: date.day,
                                   hour: clock.hour, minute: clock.minute, second: clock.second)
        if let instant = calendar.date(from: parts), LocalDate(instant, in: timeZone) == date {
            return instant.roundedToMilliseconds
        }
        return noon(on: date, in: timeZone)
    }

    /// Midday on `date` in `timeZone`: an instant no time-zone rule moves to another day.
    public static func noon(on date: LocalDate, in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day, hour: 12))!
            .roundedToMilliseconds
    }
}

/// A weigh-in saved by an earlier version of Exerly, which kept one a day by date.
public struct LegacyWeighIn: Sendable, Hashable {
    public var date: LocalDate
    public var kilograms: Double
    public var bodyFat: Double?

    public init(date: LocalDate, kilograms: Double, bodyFat: Double? = nil) {
        self.date = date
        self.kilograms = kilograms
        self.bodyFat = bodyFat
    }
}

extension NutritionStore {
    nonisolated static let legacyWeightNamespace = UUID(uuidString: "9D4C3E11-121E-46AC-B400-95CB44A26974")!

    /// Trend and expenditure for every day from the first weigh-in through
    /// `end`, with the first plan's basis as the starting expenditure.
    public func weightEstimates(through end: LocalDate) -> [EnergyBalance.Estimate] {
        guard let first = weights.map(\.date).min(), first <= end else { return [] }
        let prior = plans.first?.basis.map { (mean: $0.expenditure, error: $0.expenditureError) }
        return EnergyBalance.estimate(energyBalanceDays(from: first, through: end), prior: prior)
    }

    /// A date's weigh-ins, earliest first.
    public func weights(on date: LocalDate) -> [WeightEntry] { weights.filter { $0.date == date } }

    /// Changes a weigh-in entered in Exerly: its weight, body fat, instant or date.
    public func updateWeight(_ entry: WeightEntry) throws {
        guard let saved = weights.first(where: { $0.id == entry.id }) else { throw StoreError.notFound }
        guard saved.source != .appleHealth else {
            throw StoreError.invalid(["This weigh-in comes from Apple Health. Change it in the Health app and Exerly will follow."])
        }
        var entry = entry
        entry.at = entry.at.roundedToMilliseconds
        entry.source = saved.source
        guard entry.problems.isEmpty else { throw StoreError.invalid(entry.problems) }
        let publish = try prepareWrite(kind: Self.weightKind, id: entry.id.uuidString, payload: ExerlyJSON.canonical(entry))
        publish()
    }

    /// The ID a legacy weigh-in gets: the same for an account and date on every device.
    public nonisolated static func legacyWeightID(accountID: String, date: LocalDate) -> UUID {
        UUID(named: "\(accountID)/legacy-weight/\(date)", in: legacyWeightNamespace)
    }

    /// Adds weigh-ins an earlier version saved, all or none, at midday on their
    /// dates. IDs come from the account and date, so importing again, here or on
    /// another device, adds nothing twice. A date that already has a reading
    /// within 0.1 kg is skipped as the same weigh-in, and so is a weight out of
    /// range; a body fat out of range is dropped. Returns how many were added.
    @discardableResult
    public func importLegacyWeights(_ readings: [LegacyWeighIn], accountID: String, timeZone: TimeZone) throws -> Int {
        var existing = Set(weights.map(\.id))
        var added: [WeightEntry] = []
        for reading in readings {
            let id = Self.legacyWeightID(accountID: accountID, date: reading.date)
            guard !existing.contains(id),
                  !weights(on: reading.date).contains(where: { abs($0.weight.kilograms - reading.kilograms) < 0.1 })
            else { continue }
            var entry = WeightEntry(id: id, at: WeightTrend.noon(on: reading.date, in: timeZone), date: reading.date,
                                    weight: .kg(reading.kilograms), bodyFat: reading.bodyFat)
            if !entry.problems.isEmpty { entry.bodyFat = nil }
            guard entry.problems.isEmpty else { continue }
            existing.insert(id)
            added.append(entry)
        }
        guard !added.isEmpty else { return 0 }
        var publish: [() -> Void] = []
        try persistence.performAtomically {
            publish = try added.map { try prepareWrite(kind: Self.weightKind, id: $0.id.uuidString, payload: ExerlyJSON.canonical($0)) }
        }
        publish.forEach { $0() }
        return added.count
    }
}
