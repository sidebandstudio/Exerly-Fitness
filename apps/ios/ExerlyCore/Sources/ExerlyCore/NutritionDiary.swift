import Foundation

/// A day's food by the hour it was eaten, for Today's "By time" view.
public struct FoodTimeline: Sendable, Hashable {
    public struct Hour: Sendable, Hashable, Identifiable {
        /// When the hour starts. Each is its own instant, so the hour that
        /// repeats when clocks go back is two hours here, not one.
        public var start: Date
        /// The hour on the clock, 0 to 23.
        public var hour: Int
        /// The second pass through `hour` on a night clocks go back.
        public var repeated: Bool
        /// Earliest first.
        public var entries: [FoodEntry]

        public var id: Date { start }
        public var energy: Double { entries.reduce(0) { $0 + $1.nutrients.energy } }
    }

    /// Hours with food, earliest first.
    public var hours: [Hour]
    /// Entries whose time on this day isn't known: logged on another day, or
    /// moved here from one, as `timing(from:through:timeZone:)` leaves them out.
    public var untimed: [FoodEntry]
}

/// A day's water: what was logged as drinks, and the water in foods that
/// report it, kept apart so neither is counted twice. The goal counts drinks,
/// since few foods report water.
public struct WaterDay: Sendable, Hashable {
    /// Millilitres logged as water.
    public var drinks: Double
    /// Millilitres of water in the day's foods and other logged drinks, from
    /// those that report it (a gram is a millilitre).
    public var food: Double
    /// Of the day's entries, those that report water.
    public var reporting: Int
    public var entries: Int
    /// Millilitres a day; nil without a goal.
    public var goal: Double?

    public init(drinks: Double, food: Double, reporting: Int, entries: Int, goal: Double?) {
        self.drinks = drinks
        self.food = food
        self.reporting = reporting
        self.entries = entries
        self.goal = goal
    }

    public var total: Double { drinks + food }
    /// The goal minus drinks, never below zero; nil without a goal.
    public var remaining: Double? { goal.map { max(0, $0 - drinks) } }
    /// Drinks over the goal: 1 is exactly on it. Nil without a positive goal.
    public var fraction: Double? { goal.flatMap { $0 > 0 ? drinks / $0 : nil } }

    /// The change a day's water total of `total` ml can take: as asked, or
    /// down to zero and no further, as the server keeps it.
    public static func change(_ delta: Int, to total: Int) -> Int { max(delta, -max(0, total)) }
}

/// One day of the habits calendar.
public struct HabitDay: Sendable, Hashable, Identifiable {
    public enum Food: String, Sendable, Hashable, CaseIterable {
        /// Marked complete, with food logged.
        case complete
        /// Food logged, not marked.
        case recorded
        /// Marked partial: some food is missing, so its intake is unknown.
        case partial
        /// Marked as a fast: a known day of nothing, or of what was logged.
        case fasted
        /// A past day with nothing logged or marked: unknown, not zero.
        case missing
        /// Today with nothing logged yet, or a later day.
        case upcoming
    }

    public var date: LocalDate
    public var food: Food
    public var weighedIn: Bool

    public init(date: LocalDate, food: Food, weighedIn: Bool) {
        self.date = date
        self.food = food
        self.weighedIn = weighedIn
    }

    public var id: LocalDate { date }
}

extension LocalDate {
    /// The same time of day as `instant` on this date in `timeZone`, so
    /// moving an entry's day keeps when it was eaten. A time the clocks skip
    /// on this date moves on by the gap (2:30 becomes 3:30 the night they go
    /// forward); a time they pass twice is the first.
    public func sameTime(as instant: Date, in timeZone: TimeZone) -> Date {
        guard LocalDate(instant, in: timeZone) != self else { return instant }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: instant)
        (parts.year, parts.month, parts.day) = (year, month, day)
        return calendar.date(from: parts)?.roundedToMilliseconds ?? instant
    }
}

extension NutritionStore {
    /// The day's entries by the clock hour they were eaten in `timeZone`.
    public func timeline(on date: LocalDate, timeZone: TimeZone) -> FoodTimeline {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var byHour: [Date: [FoodEntry]] = [:]
        var untimed: [FoodEntry] = []
        for entry in entries(on: date) {
            guard LocalDate(entry.loggedAt, in: timeZone) == date,
                  let start = calendar.dateInterval(of: .hour, for: entry.loggedAt)?.start else {
                untimed.append(entry)
                continue
            }
            byHour[start, default: []].append(entry)
        }
        var seen = Set<Int>()
        let hours = byHour.keys.sorted().map { start in
            let hour = calendar.component(.hour, from: start)
            return FoodTimeline.Hour(start: start, hour: hour, repeated: !seen.insert(hour).inserted,
                                     entries: byHour[start]!.sorted { ($0.loggedAt, $0.id.uuidString) < ($1.loggedAt, $1.id.uuidString) })
        }
        return FoodTimeline(hours: hours, untimed: untimed)
    }

    /// The day's water: `drinks` logged as water, and the water its foods report.
    public func water(on date: LocalDate, drinks: Double, goal: Double?) -> WaterDay {
        let logged = entries(on: date)
        let water = logged.compactMap { $0.nutrients[.water] }
        return WaterDay(drinks: max(0, drinks), food: water.reduce(0, +), reporting: water.count, entries: logged.count, goal: goal)
    }

    /// Each day from `start` through `end` as the habits calendar shows it.
    /// Later days than `today` are upcoming even with food planned on them.
    public func habits(from start: LocalDate, through end: LocalDate, today: LocalDate) -> [HabitDay] {
        guard start <= end else { return [] }
        let logged = Set(entries.lazy.filter { $0.date >= start && $0.date <= end }.map(\.date))
        let weighed = Set(weights.lazy.filter { $0.date >= start && $0.date <= end }.map(\.date))
        return (0...start.days(until: end)).map { offset in
            let date = start.adding(days: offset)
            let food: HabitDay.Food
            if date > today {
                food = .upcoming
            } else {
                switch day(date).status {
                case .fasting: food = .fasted
                case .partial: food = .partial
                case .complete where logged.contains(date): food = .complete
                case _ where logged.contains(date): food = .recorded
                default: food = date == today ? .upcoming : .missing
                }
            }
            return HabitDay(date: date, food: food, weighedIn: weighed.contains(date))
        }
    }
}
