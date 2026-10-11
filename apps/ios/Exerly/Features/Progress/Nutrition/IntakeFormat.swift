import ExerlyCore
import SwiftUI

/// Amounts, spans and hours as Progress → Nutrition writes and speaks them.
enum IntakeFormat {
    /// The span picker's label; this month is its short name, "Oct".
    static func title(_ range: IntakeRange, today: LocalDate) -> String {
        switch range {
        case .yesterday: "Yesterday"
        case .week: "1W"
        case .thisMonth: BodyDates.anchor(today).formatted(Date.FormatStyle(timeZone: BodyDates.utc).month(.abbreviated))
        case .month: "1M"
        case .quarter: "3M"
        case .year: "1Y"
        }
    }

    static func spoken(_ range: IntakeRange) -> String {
        switch range {
        case .yesterday: "Yesterday"
        case .week: "1 week"
        case .thisMonth: "This month"
        case .month: "1 month"
        case .quarter: "3 months"
        case .year: "1 year"
        }
    }

    /// "Calories" for energy, "Carbs" where space is short.
    static func name(_ nutrient: Nutrient, short: Bool = false) -> String {
        switch nutrient {
        case .energy: "Calories"
        case .carbohydrate: short ? "Carbs" : "Carbohydrate"
        default: nutrient.name
        }
    }

    /// Whole numbers from 10, a decimal from 1, two below. With `like`, as
    /// many decimals as that figure shows too, so two read side by side add
    /// up: "32.9 / 35 g" beside "2.1 g to go", not "33 / 35 g".
    static func number(_ value: Double, _ unit: Nutrient.Unit, like other: Double? = nil) -> String {
        func decimals(_ value: Double) -> Int { unit == .kilocalories || abs(value) >= 10 ? 0 : abs(value) >= 1 ? 1 : 2 }
        return value.formatted(.number.precision(.fractionLength(0...max(decimals(value), other.map(decimals) ?? 0))))
    }

    static func amount(_ value: Double, _ nutrient: Nutrient) -> String {
        "\(number(value, nutrient.unit)) \(nutrient.unit.rawValue)"
    }

    static func spokenAmount(_ value: Double, _ nutrient: Nutrient) -> String {
        "\(number(value, nutrient.unit)) \(unitName(nutrient.unit))"
    }

    static func unitName(_ unit: Nutrient.Unit) -> String {
        switch unit {
        case .kilocalories: "kilocalories"
        case .grams: "grams"
        case .milligrams: "milligrams"
        case .micrograms: "micrograms"
        }
    }

    /// "+110 kcal", "−60 g", with a true minus sign.
    static func signed(_ value: Double, _ nutrient: Nutrient) -> String {
        let text = number(abs(value), nutrient.unit)
        let sign = text == number(0, nutrient.unit) ? "" : value > 0 ? "+" : "−"
        return "\(sign)\(text) \(nutrient.unit.rawValue)"
    }

    static func spokenSigned(_ value: Double, _ nutrient: Nutrient) -> String {
        let text = number(abs(value), nutrient.unit)
        guard text != number(0, nutrient.unit) else { return "on target" }
        return "\(text) \(unitName(nutrient.unit)) \(value > 0 ? "over" : "under")"
    }

    static func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }
    static func spokenPercent(_ share: Double) -> String { "\(Int((share * 100).rounded())) percent" }

    /// "Sep 9 – Oct 8", or one day's name; with years when the span leaves this year.
    static func span(_ from: LocalDate, _ through: LocalDate, today: LocalDate) -> String {
        from == through ? BodyFormat.day(from, today: today) : "\(date(from, today: today, span: (from, through))) – \(date(through, today: today, span: (from, through)))"
    }

    static func spokenSpan(_ from: LocalDate, _ through: LocalDate, today: LocalDate) -> String {
        from == through ? BodyFormat.day(from, today: today) : "\(date(from, today: today, span: (from, through))) to \(date(through, today: today, span: (from, through)))"
    }

    private static func date(_ date: LocalDate, today: LocalDate, span: (LocalDate, LocalDate)) -> String {
        guard span.0.year != today.year || span.1.year != today.year else { return BodyFormat.shortDate(date) }
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        style.timeZone = BodyDates.utc
        return BodyDates.anchor(date).formatted(style)
    }

    /// "7 AM" or "19", in the person's clock style.
    static func hour(_ hour: Int) -> String {
        let anchor = BodyDates.calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: hour % 24))!
        var style = Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .abbreviated))
        style.timeZone = BodyDates.utc
        return anchor.formatted(style)
    }

    static func hours(_ start: Int, _ end: Int) -> String { "\(hour(start))–\(hour(end))" }

    static func spokenHours(_ start: Int, _ end: Int) -> String { "\(hour(start)) to \(hour(end))" }

    /// How a goal reads: "Target 35 g · floor 25 g", "Limit 2,300 mg".
    static func goal(_ goal: NutrientGoal, _ nutrient: Nutrient) -> String {
        var parts: [String] = []
        if let target = goal.target { parts.append("target \(amount(target, nutrient))") }
        if let floor = goal.floor { parts.append("floor \(amount(floor, nutrient))") }
        if let ceiling = goal.ceiling { parts.append("limit \(amount(ceiling, nutrient))") }
        let text = parts.joined(separator: " · ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func spokenGoal(_ goal: NutrientGoal, _ nutrient: Nutrient) -> String {
        var parts: [String] = []
        if let target = goal.target { parts.append("target \(spokenAmount(target, nutrient))") }
        if let floor = goal.floor { parts.append("at least \(spokenAmount(floor, nutrient))") }
        if let ceiling = goal.ceiling { parts.append("up to \(spokenAmount(ceiling, nutrient))") }
        return parts.joined(separator: ", ")
    }

    /// A goal in the editor's words: "At least 28 g", "At least 25 g, about 35 g".
    static func goalSummary(_ goal: NutrientGoal, _ nutrient: Nutrient, spoken: Bool = false) -> String {
        let amount = spoken ? spokenAmount : self.amount
        var parts: [String] = []
        if let floor = goal.floor { parts.append("at least \(amount(floor, nutrient))") }
        if let target = goal.target { parts.append("about \(amount(target, nutrient))") }
        if let ceiling = goal.ceiling { parts.append("at most \(amount(ceiling, nutrient))") }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// A pinned nutrient's standing as its amount and words, for the amount
    /// to stand out: (10, "to go"), (1060, "left"), (240, "over"),
    /// (nil, "Goal met"). Nil without an amount and a goal.
    static func standingParts(_ day: NutrientDay) -> (amount: Double?, words: String)? {
        guard let eaten = day.amount, let goal = day.goal, let standing = day.standing else { return nil }
        switch standing {
        case .short(let toGo): return (toGo, "to go")
        case .over(let over): return (over, "over")
        case .met(let left?): return (left, "left")
        case .met(nil):
            if goal.floor != nil, let target = goal.target, eaten < target { return (target - eaten, "to target") }
            return (nil, "Goal met")
        }
    }

    /// How a pinned nutrient's day stands: "10 g to go", "1,060 mg left",
    /// "240 mg over", or its goal when nothing reports it.
    static func standing(_ day: NutrientDay, spoken: Bool = false) -> String {
        guard let goal = day.goal else { return "No goal" }
        guard let parts = standingParts(day) else { return goalSummary(goal, day.nutrient, spoken: spoken) }
        guard let value = parts.amount else { return parts.words }
        return "\((spoken ? spokenAmount : amount)(value, day.nutrient)) \(parts.words)"
    }

    /// What's eaten against the amount the standing counts to, as the macros
    /// put it: "8.9 / 25 g", or "8.9 of 25 grams eaten". Nil without an
    /// amount and a goal.
    static func eatenOfGoal(_ day: NutrientDay, spoken: Bool = false) -> String? {
        guard let eaten = day.amount, let goal = day.goal, let standing = day.standing else { return nil }
        let bound: Double = switch standing {
        case .short(let toGo): eaten + toGo
        case .over(let over): eaten - over
        case .met(let left?): eaten + left
        case .met(nil): goal.target ?? goal.floor ?? goal.ceiling ?? eaten
        }
        let text = number(eaten, day.nutrient.unit, like: standingParts(day)?.amount)
        return spoken ? "\(text) of \(spokenAmount(bound, day.nutrient)) eaten" : "\(text) / \(amount(bound, day.nutrient))"
    }

    /// The denominator behind a day's total, when some foods didn't report
    /// the nutrient: "From 3 of 5 foods". Nil when all or none did.
    static func completeness(reporting: Int, entries: Int, spoken: Bool = false) -> String? {
        guard reporting > 0, reporting < entries else { return nil }
        return "From \(reporting) of \(entries) foods\(spoken ? " that report it" : "")"
    }

    static func days(_ count: Int) -> String { count == 1 ? "1 day" : "\(count) days" }
    static func entries(_ count: Int) -> String { count == 1 ? "1 entry" : "\(count) entries" }

    /// The colour each of energy and the macros is drawn in, as on Today.
    static func color(_ nutrient: Nutrient) -> Color {
        switch nutrient {
        case .protein: .exPrimaryText
        case .carbohydrate: .exAccent
        case .fat: .exSecondary
        case .alcohol: .exTextMuted
        default: .exPrimary
        }
    }

    static func group(_ group: Nutrient.Group) -> String {
        switch group {
        case .energy, .macros: "Energy and macros"
        case .carbohydrates: "Carbohydrate detail"
        case .fats: "Fats"
        case .vitamins: "Vitamins"
        case .minerals: "Minerals"
        case .aminoAcids: "Amino acids"
        case .other: "Other"
        }
    }
}

extension View {
    /// Charts read dates in UTC, where `BodyDates` anchors each local date.
    func intakeChartDates() -> some View {
        environment(\.timeZone, BodyDates.utc).environment(\.calendar, BodyDates.calendar)
    }
}
