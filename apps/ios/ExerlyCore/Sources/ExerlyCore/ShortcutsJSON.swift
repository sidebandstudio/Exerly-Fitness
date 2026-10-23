import Foundation

/// MacroFactor's Shortcuts JSON, read and written, so shortcuts people already
/// have keep working with Exerly: a "Log by JSON" food in, and the today
/// summary out. The format is the public specification at
/// github.com/MacroFactor/apple-shortcuts; this is Exerly's own implementation.
public enum ShortcutsJSON {
    public struct Problem: Error, Equatable, CustomStringConvertible {
        public var messages: [String]
        public var description: String { messages.joined(separator: "; ") }
    }

    /// A food from "Log by JSON", ready to log.
    public struct LoggedFood: Sendable, Hashable {
        public var food: FoodSnapshot
        /// The whole amount the nutrients describe.
        public var grams: Double
        public var serving: Serving?
        public var quantity: Double?
        /// The `source` the shortcut gave, to trace where an entry came from.
        public var source: String
    }

    /// MacroFactor's nutrient names where they differ from Exerly's. Units match.
    static let renamed: [String: Nutrient] = [
        "carbs": .carbohydrate, "sugarsAdded": .addedSugars, "vitaminB1": .thiamin, "vitaminB2": .riboflavin,
        "vitaminB3": .niacin, "vitaminB5": .pantothenicAcid,
    ]

    static func nutrient(named key: String) -> Nutrient? { renamed[key] ?? Nutrient(rawValue: key) }

    /// A JSON number. Foundation reads `true` and `false` as numbers too, which aren't amounts.
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    static func name(of nutrient: Nutrient) -> String {
        renamed.first { $0.value == nutrient }?.key ?? nutrient.rawValue
    }

    /// Grams per unit. Volumes are taken at water's density, as Exerly does
    /// for drinks elsewhere.
    static let grams: [String: Double] = [
        "grams": 1, "ounces": 28.349_523_125, "pounds": 453.592_37, "milliliters": 1,
        "fluidOuncesUS": 29.573_529_562_5, "cupsUS": 236.588_236_5, "tablespoonsUS": 14.786_764_781_25,
        "teaspoonsUS": 4.928_921_593_75,
    ]

    /// Reads a "Log by JSON" food. Its nutrients describe the serving given:
    /// `one` (a whole item of unknown weight, recorded as a nominal 100 g so
    /// the nutrients stay exact), `per100Grams`, `per100ML`, a measured
    /// `{amount, unit}`, or a custom `{amount, label, weight}` in grams.
    public static func food(from data: Data) throws -> LoggedFood {
        guard let json = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any] else {
            throw Problem(messages: ["The JSON must be an object"])
        }
        var problems: [String] = []
        let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty { problems.append("name is required") }
        let source = (json["source"] as? String) ?? ""
        if source.isEmpty { problems.append("source is required, so entries can be traced to the shortcut") }
        var amounts = NutrientAmounts()
        if let nutrients = json["nutrients"] as? [String: Any] {
            for (key, value) in nutrients.sorted(by: { $0.key < $1.key }) {
                guard let nutrient = nutrient(named: key) else {
                    problems.append("\(key) is not a nutrient")
                    continue
                }
                guard let amount = number(value), amount.isFinite, amount >= 0 else {
                    problems.append("\(key) must be a number of 0 or more")
                    continue
                }
                amounts[nutrient] = amount
            }
        } else {
            problems.append("nutrients is required")
        }
        var weight: Double?
        var serving: Serving?
        var quantity: Double?
        var unweighed = false
        switch json["serving"] {
        case let kind as String where kind == "one":
            unweighed = true
            weight = 100
            serving = Serving("1 serving", grams: 100)
            quantity = 1
        case let kind as String where kind == "per100Grams":
            weight = 100
        case let kind as String where kind == "per100ML":
            weight = 100
            serving = Serving("100 ml", grams: 100)
            quantity = 1
        case let measured as [String: Any]:
            let amount = number(measured["amount"]) ?? 0
            if let unit = measured["unit"] as? String {
                if let factor = grams[unit], amount > 0 {
                    weight = amount * factor
                    serving = Serving("\(amount.formatted(.number.precision(.fractionLength(0...2)))) \(unit)", grams: amount * factor)
                    quantity = 1
                } else {
                    problems.append("serving needs a positive amount in one of \(grams.keys.sorted().joined(separator: ", "))")
                }
            } else if let label = measured["label"] as? String, let total = number(measured["weight"]),
                      amount > 0, total > 0, !label.isEmpty {
                weight = total
                serving = Serving(label, grams: total / amount)
                quantity = amount
            } else {
                problems.append("a custom serving needs an amount, a label and a weight in grams")
            }
        default:
            problems.append("serving must be one, per100Grams, per100ML, {amount, unit} or {amount, label, weight}")
        }
        guard problems.isEmpty, let weight else { throw Problem(messages: problems) }
        let brand = (json["brand"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var snapshot = FoodSnapshot(foodID: "shortcut:\(source)", name: name, brand: brand, source: .custom,
                                    per100g: amounts.scaled(by: 100 / weight))
        if unweighed { snapshot.unweighed = true }
        return LoggedFood(food: snapshot, grams: weight, serving: serving, quantity: quantity, source: source)
    }

    /// The today summary: what was consumed, and what remains of each goal's
    /// minimum, target and maximum (negative once passed), keyed by
    /// MacroFactor's nutrient names, in each nutrient's unit.
    public static func todaySummary(consumed: NutrientAmounts, goals: [Nutrient: NutrientGoal]) throws -> Data {
        let round = { (value: Double) in (value * 100).rounded() / 100 }
        var eaten: [String: Double] = [:]
        for (nutrient, amount) in consumed.values { eaten[name(of: nutrient)] = round(amount) }
        var remaining: [String: [String: Double]] = [:]
        for (nutrient, goal) in goals {
            let used = consumed[nutrient] ?? 0
            var left: [String: Double] = [:]
            if let floor = goal.floor { left["minimum"] = round(floor - used) }
            if let target = goal.target { left["target"] = round(target - used) }
            if let ceiling = goal.ceiling { left["maximum"] = round(ceiling - used) }
            if !left.isEmpty { remaining[name(of: nutrient)] = left }
        }
        return try JSONSerialization.data(withJSONObject: ["consumed": eaten, "remaining": remaining],
                                          options: [.sortedKeys, .prettyPrinted])
    }
}

extension NutritionStore {
    /// Logs a "Log by JSON" food from a shortcut.
    @discardableResult
    public func logShortcutFood(_ data: Data, on date: LocalDate, meal: String, at time: Date? = nil) throws -> FoodEntry {
        let logged = try ShortcutsJSON.food(from: data)
        let entry = FoodEntry(date: date, meal: meal, loggedAt: (time ?? Date()).roundedToMilliseconds, food: logged.food,
                              grams: logged.grams, serving: logged.serving, quantity: logged.quantity)
        try saveEntry(entry)
        return entry
    }

    /// The today summary for a date: consumption, and what remains of the
    /// plan's goals. Without a plan, energy and macros have no goal; other
    /// nutrients use their reference intakes.
    public func todaySummaryJSON(on date: LocalDate) throws -> Data {
        let consumed = entries(on: date).reduce(NutrientAmounts()) { $0 + $1.nutrients }
        let plan = plan(on: date)
        var goals: [Nutrient: NutrientGoal] = [:]
        for nutrient in Nutrient.allCases {
            if let plan {
                goals[nutrient] = plan.goal(for: nutrient, on: date)
            } else if ![.energy, .protein, .fat, .carbohydrate].contains(nutrient) {
                goals[nutrient] = NutrientGoal(reference: nutrient)
            }
        }
        return try ShortcutsJSON.todaySummary(consumed: consumed, goals: goals)
    }
}
