import Foundation

/// A meal, or a whole day, that can be logged again in one tap.
public struct MealRepeat: Sendable, Hashable {
    /// The day the entries come from.
    public var source: LocalDate
    /// The meal repeated; nil for the whole day.
    public var meal: String?
    public var entries: [FoodEntry]
    /// Logged energy of the entries, in kcal.
    public var energy: Double { entries.reduce(0) { $0 + $1.nutrients.energy } }
}

extension NutritionStore {
    /// From 10 PM to 4 AM a clock hour reads oddly as a habit ("usual around
    /// 12 AM"), so foods eaten around then are "usual around now".
    public static func isLateNight(_ time: Date, timeZone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let hour = calendar.component(.hour, from: time)
        return hour >= 22 || hour < 4
    }

    /// The meal a person is most likely logging at a local time.
    ///
    /// A habit wins over the clock: the meal logged most often within 90
    /// minutes of this time of day over the last 28 days, if it was logged on
    /// at least 3 of them. Only entries logged on the day they count for say
    /// when someone eats; a dinner backfilled next morning doesn't.
    public func suggestedMeal(at time: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func minute(_ date: Date) -> Int {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
        let today = LocalDate(time, in: timeZone), now = minute(time)
        var days: [String: Set<LocalDate>] = [:]
        for entry in entries where entry.date >= today.adding(days: -28) && entry.date < today
            && LocalDate(entry.loggedAt, in: timeZone) == entry.date {
            let gap = abs(minute(entry.loggedAt) - now)
            guard min(gap, 24 * 60 - gap) <= 90 else { continue }
            days[entry.meal, default: []].insert(entry.date)
        }
        if let habit = days.filter({ $0.value.count >= 3 })
            .max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) }) {
            return habit.key
        }
        return Self.meal(atMinute: now)
    }

    /// The meal the clock alone suggests at a minute of the local day, before
    /// any habit: breakfast from 4:00, lunch from 10:30 to 14:30, dinner from
    /// 17:00 to 21:30, and snacks otherwise.
    public nonisolated static func meal(atMinute minute: Int) -> String {
        switch minute {
        case 4 * 60..<(10 * 60 + 30): return "Breakfast"
        case (10 * 60 + 30)..<(14 * 60 + 30): return "Lunch"
        case (17 * 60)..<(21 * 60 + 30): return "Dinner"
        default: return "Snacks"
        }
    }

    /// When `meal` is usually eaten on `date`: the median time of day of its
    /// first entry, over the 28 days before, when it was logged on the day it
    /// counts for on at least 3 of them; otherwise a typical time for it.
    public func usualTime(of meal: String, on date: LocalDate, timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var first: [LocalDate: Date] = [:]
        for entry in entries where entry.meal == meal && entry.date < date && entry.date >= date.adding(days: -28)
            && LocalDate(entry.loggedAt, in: timeZone) == entry.date {
            first[entry.date] = min(first[entry.date] ?? entry.loggedAt, entry.loggedAt)
        }
        var (hour, minute) = Self.typicalTime(of: meal)
        if first.count >= 3 {
            let minutes = first.values.map { calendar.component(.hour, from: $0) * 60 + calendar.component(.minute, from: $0) }.sorted()
            let median = minutes[minutes.count / 2]
            (hour, minute) = (median / 60, median % 60)
        }
        return calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day, hour: hour, minute: minute))!
            .roundedToMilliseconds
    }

    /// A typical hour and minute for a meal: breakfast 8:00, lunch 12:30,
    /// dinner 18:30, snacks 15:00, and noon for any other.
    public nonisolated static func typicalTime(of meal: String) -> (hour: Int, minute: Int) {
        switch meal.lowercased() {
        case "breakfast": (8, 0)
        case "lunch": (12, 30)
        case "dinner": (18, 30)
        case "snacks", "snack": (15, 0)
        default: (12, 0)
        }
    }

    /// The latest day before `date`, within `days`, with entries in `meal`
    /// (or any entries, for the whole day), and those entries.
    public func repeatable(_ meal: String?, for date: LocalDate, within days: Int = 7) -> MealRepeat? {
        let earliest = date.adding(days: -days)
        let candidates = entries.filter { $0.date < date && $0.date >= earliest && (meal == nil || $0.meal == meal) }
        guard let source = candidates.map(\.date).max() else { return nil }
        return MealRepeat(source: source, meal: meal, entries: candidates.filter { $0.date == source })
    }

    /// The latest day before `date`, within `days`, as far as `date` hasn't
    /// had it yet: all of it on an empty day, then meal by meal. A meal with
    /// nothing logged gets all of that meal; one holding only portions from it
    /// (a chip tapped first) gets the rest of them; one with anything more
    /// was eaten differently and is left alone. Nil when nothing is left.
    public func repeatableDay(for date: LocalDate, within days: Int = 7) -> MealRepeat? {
        guard var day = repeatable(nil, for: date, within: days) else { return nil }
        let today = Dictionary(grouping: entries(on: date), by: \.meal)
        let earlier = Dictionary(grouping: day.entries, by: \.meal)
        var kept = Set<UUID>()
        for (meal, entries) in earlier {
            let pairing = Self.pair(entries, with: today[meal] ?? [])
            if pairing.unpaired == 0 { kept.formUnion(pairing.left.map(\.id)) }
        }
        day.entries.removeAll { !kept.contains($0.id) }
        return day.entries.isEmpty ? nil : day
    }

    /// What of a repeat isn't on `date` yet, portion by portion: each entry in
    /// the same meal there stands for one of the repeat's portions of that
    /// food, so a second bar is still to come after the first. Nil once all
    /// of it is in, so a repeat offered before one of its foods was logged on
    /// its own never logs that portion twice.
    public func remaining(_ repeated: MealRepeat, on date: LocalDate) -> MealRepeat? {
        let today = Dictionary(grouping: entries(on: date), by: \.meal)
        var left = Set<UUID>()
        for (meal, entries) in Dictionary(grouping: repeated.entries, by: \.meal) {
            left.formUnion(Self.pair(entries, with: today[meal] ?? []).left.map(\.id))
        }
        var rest = repeated
        rest.entries.removeAll { !left.contains($0.id) }
        return rest.entries.isEmpty ? nil : rest
    }

    /// Pairs each of `logged` with one of `earlier`'s portions of the same
    /// food: the same amount first, then the nearest. `left` is `earlier`'s
    /// portions without a partner, in order; `unpaired` counts `logged`'s.
    static func pair(_ earlier: [FoodEntry], with logged: [FoodEntry]) -> (left: [FoodEntry], unpaired: Int) {
        var left = earlier
        var rest: [FoodEntry] = []
        for entry in logged {
            if let index = left.firstIndex(where: { $0.food.foodID == entry.food.foodID && abs($0.grams - entry.grams) < 0.5 }) {
                left.remove(at: index)
            } else { rest.append(entry) }
        }
        var unpaired = 0
        for entry in rest {
            let nearest = left.indices.filter { left[$0].food.foodID == entry.food.foodID }
                .min { abs(left[$0].grams - entry.grams) < abs(left[$1].grams - entry.grams) }
            if let nearest { left.remove(at: nearest) } else { unpaired += 1 }
        }
        return (left, unpaired)
    }

    /// Logs a repeat's entries on `date` as new entries, all or none.
    @discardableResult
    public func apply(_ repeated: MealRepeat, to date: LocalDate) throws -> [FoodEntry] {
        try copy(repeated.entries.map(\.id), to: date)
    }
}
