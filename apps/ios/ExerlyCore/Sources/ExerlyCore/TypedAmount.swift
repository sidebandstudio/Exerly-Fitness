import Foundation

/// An amount typed with a food in search: "500 g ground beef", "2 eggs",
/// "1 can kidney beans", "chicken 8 oz". `FoodSearch.amount(in:)` reads it
/// and `Food.portion(_:)` makes it an amount of a particular food.
public struct TypedAmount: Sendable, Hashable {
    public enum Unit: Sendable, Hashable {
        case grams, kilograms, ounces, pounds, milliliters, liters, fluidOunces, cups, tablespoons, teaspoons
        /// A serving a food may name: "can", "slice", "large".
        case serving(String)
    }

    public var quantity: Double
    /// Nil for a count of the food itself: "2 eggs".
    public var unit: Unit?

    public init(_ quantity: Double, _ unit: Unit? = nil) {
        self.quantity = quantity
        self.unit = unit
    }

    static let measures: [String: Unit] = [
        "g": .grams, "gr": .grams, "gram": .grams, "grams": .grams,
        "kg": .kilograms, "kgs": .kilograms, "kilo": .kilograms, "kilos": .kilograms, "kilogram": .kilograms, "kilograms": .kilograms,
        "oz": .ounces, "ounce": .ounces, "ounces": .ounces,
        "lb": .pounds, "lbs": .pounds, "pound": .pounds, "pounds": .pounds,
        "ml": .milliliters, "milliliter": .milliliters, "milliliters": .milliliters, "millilitre": .milliliters, "millilitres": .milliliters,
        "l": .liters, "liter": .liters, "liters": .liters, "litre": .liters, "litres": .liters,
        "floz": .fluidOunces,
        "cup": .cups, "cups": .cups,
        "tbsp": .tablespoons, "tbs": .tablespoons, "tablespoon": .tablespoons, "tablespoons": .tablespoons,
        "tsp": .teaspoons, "teaspoon": .teaspoons, "teaspoons": .teaspoons
    ]

    /// Containers, which a package size answers for any of them.
    static let packages: Set<String> = ["can", "tin", "jar", "bottle", "pack", "package", "packet", "bag", "box", "carton",
                                        "container", "tub", "pouch"]
    /// Sizes, which mean a count of the food when it names no such size.
    static let sizes: Set<String> = ["large", "medium", "small", "whole"]
    static let servings = packages.union(sizes).union(["slice", "piece", "scoop", "serving", "clove", "stick", "strip"])

    /// More than this many of something is more likely a name, as in "100 Grand".
    static let largestCount = 50.0
}

extension FoodSearch {
    /// The amount typed before or after the food, and the words left to
    /// search for. A count needs nothing after its number ("2 eggs"); an
    /// amount after the food needs a unit ("chicken 200 g"), so "Omega 3"
    /// stays a name. Without an amount the whole query is the food.
    public static func amount(in query: String) -> (amount: TypedAmount?, food: String) {
        let tokens = query.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return (nil, "") }
        if let (amount, used) = leadingAmount(tokens) {
            var rest = tokens.dropFirst(used)
            if amount.unit != nil, rest.first?.lowercased() == "of" { rest = rest.dropFirst() }
            return (amount, rest.joined(separator: " "))
        }
        if let (amount, used) = trailingAmount(tokens) {
            return (amount, tokens.dropLast(used).joined(separator: " "))
        }
        return (nil, tokens.joined(separator: " "))
    }

    private static func leadingAmount(_ tokens: [Substring]) -> (TypedAmount, Int)? {
        guard let (number, attached) = number(tokens[0]) else { return nil }
        var value = number, used = 1
        var unit: TypedAmount.Unit?
        if !attached.isEmpty {
            guard let measure = TypedAmount.measures[attached.lowercased()] else { return nil }
            unit = measure
        } else {
            if used < tokens.count, value == value.rounded(), let (fraction, rest) = self.number(tokens[used]), rest.isEmpty,
               fraction < 1 {
                value += fraction
                used += 1
            }
            if let (found, count) = self.unit(tokens[used...]) {
                unit = found
                used += count
            }
        }
        return valid(value, unit).map { ($0, used) }
    }

    private static func trailingAmount(_ tokens: [Substring]) -> (TypedAmount, Int)? {
        guard tokens.count > 1 else { return nil }
        if let (value, attached) = number(tokens[tokens.count - 1]), !attached.isEmpty {
            guard let measure = TypedAmount.measures[attached.lowercased()] else { return nil }
            return valid(value, measure).map { ($0, 1) }
        }
        for count in [2, 1] where tokens.count > count + 1 {
            guard let (unit, length) = unit(tokens.suffix(count)), length == count,
                  let (number, rest) = number(tokens[tokens.count - count - 1]), rest.isEmpty else { continue }
            var value = number, used = count + 1
            if number < 1, tokens.count > used + 1, let (whole, rest) = self.number(tokens[tokens.count - used - 1]), rest.isEmpty,
               whole == whole.rounded() {
                value += whole
                used += 1
            }
            return valid(value, unit).map { ($0, used) }
        }
        return nil
    }

    private static func valid(_ value: Double, _ unit: TypedAmount.Unit?) -> TypedAmount? {
        guard value.isFinite, value > 0, value <= 100_000, unit != nil || value <= TypedAmount.largestCount else { return nil }
        return TypedAmount(value, unit)
    }

    /// A unit at the start of `tokens` and how many tokens it took: a
    /// measure, "fl oz", or a serving word, singular or plural.
    private static func unit(_ tokens: ArraySlice<Substring>) -> (TypedAmount.Unit, Int)? {
        guard let first = tokens.first?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) else { return nil }
        if ["fl", "fluid"].contains(first), let next = tokens.dropFirst().first?.lowercased(),
           ["oz", "oz.", "ounce", "ounces"].contains(next) { return (.fluidOunces, 2) }
        if let measure = TypedAmount.measures[first] { return (measure, 1) }
        return servingWord(first).map { (.serving($0), 1) }
    }

    /// The serving word in its singular: "cans" is "can", "boxes" "box".
    static func servingWord(_ word: String) -> String? {
        [word, String(word.dropLast()), String(word.dropLast(2))].first { TypedAmount.servings.contains($0) }
    }

    /// The number at the start of `token` and what follows it: "150g" is
    /// (150, "g"), "1½" (1.5, ""), "1/2" or "1⁄2" (0.5, ""), "1,5" 1.5 and "1,500" 1500.
    static func number(_ token: Substring) -> (Double, Substring)? {
        let fractions: [Character: Double] = ["½": 0.5, "¼": 0.25, "¾": 0.75, "⅓": 1.0 / 3, "⅔": 2.0 / 3, "⅛": 0.125, "⅜": 0.375,
                                              "⅝": 0.625, "⅞": 0.875, "⅙": 1.0 / 6, "⅚": 5.0 / 6, "⅕": 0.2, "⅖": 0.4, "⅗": 0.6, "⅘": 0.8]
        // "⁄" is the fraction slash recipe pages write between digits.
        let digits = token.prefix { ($0.isASCII && ($0.isNumber || $0 == "." || $0 == "," || $0 == "/")) || $0 == "⁄" }
        var rest = token.dropFirst(digits.count)
        var value: Double?
        if digits.contains("/") || digits.contains("⁄") {
            let parts = digits.split(omittingEmptySubsequences: false) { $0 == "/" || $0 == "⁄" }
            guard parts.count == 2, let top = Double(parts[0]), let bottom = Double(parts[1]), bottom > 0 else { return nil }
            value = top / bottom
        } else if !digits.isEmpty {
            let groups = digits.split(separator: ",", omittingEmptySubsequences: false)
            let thousands = groups.count == 2 && groups[1].count == 3 && !digits.contains(".")
            guard let parsed = Double(digits.replacingOccurrences(of: ",", with: thousands ? "" : ".")) else { return nil }
            value = parsed
        }
        if let first = rest.first, let fraction = fractions[first] {
            value = (value ?? 0) + fraction
            rest = rest.dropFirst()
        }
        return value.map { ($0, rest) }
    }
}

extension Food {
    /// This food at an amount typed in search, and whether it's exactly what
    /// was typed. Exact: a weight; a volume, by a measure the food names
    /// ("1 cup") or its density; a serving it names ("1 can", "1 large
    /// breast"), or for any container its package size; a count of its own
    /// countable serving (see `countServing`). Otherwise a count of its first
    /// serving to check, for a size it doesn't name or a count of a measure
    /// ("2 × 1 cup"), or nil when the unit means nothing for it.
    public func portion(_ typed: TypedAmount) -> (amount: LoggedAmount, exact: Bool)? {
        let count = typed.quantity
        func amount(grams: Double? = nil, _ serving: Serving? = nil, _ quantity: Double? = nil, exact: Bool = true)
            -> (amount: LoggedAmount, exact: Bool)? {
            (try? NutritionStore.preview(self, grams: grams, serving: serving, quantity: quantity)).map { ($0, exact) }
        }
        /// By a measure the food names, else by its density: its label's
        /// own measures for millilitres and fluid ounces, grams without one.
        func byVolume(_ milliliters: Double, named: String? = nil) -> (amount: LoggedAmount, exact: Bool)? {
            if let named, let serving = servings.first(where: { Self.isMeasure($0.name, named) }) { return amount(serving, count) }
            guard let density = gramsPerMilliliter else { return nil }
            guard let named else {
                return volume == nil ? amount(grams: count * milliliters * density)
                    : amount(Serving("ml", grams: density), count * milliliters)
            }
            return amount(Serving(named == "fl oz" && volume != nil ? "fl oz" : "1 \(named)", grams: milliliters * density), count)
        }
        switch typed.unit {
        case .grams: return amount(grams: count)
        case .kilograms: return amount(grams: count * 1000)
        case .ounces: return amount(Serving("oz", grams: USUnits.gramsPerOunce), count)
        case .pounds: return amount(Serving("oz", grams: USUnits.gramsPerOunce), count * 16)
        case .milliliters: return byVolume(1)
        case .liters: return byVolume(1000)
        case .fluidOunces: return byVolume(USUnits.millilitersPerFluidOunce, named: "fl oz")
        case .cups: return byVolume(USUnits.millilitersPerFluidOunce * 8, named: "cup")
        case .tablespoons: return byVolume(USUnits.millilitersPerFluidOunce / 2, named: "tbsp")
        case .teaspoons: return byVolume(USUnits.millilitersPerFluidOunce / 6, named: "tsp")
        case .serving(let word):
            if let serving = serving(named: word) { return amount(serving, count) }
            guard TypedAmount.sizes.contains(word) else { return nil }
            return countServing.map { amount($0, count, exact: false) } ?? firstServing.flatMap { amount($0, count, exact: false) }
        case nil:
            if let serving = countServing { return amount(serving, count) }
            return firstServing.flatMap { amount($0, count, exact: false) }
        }
    }

    /// The serving a count of this food means: one named after the food
    /// ("1 egg", "1 bar (40 g)"), else a whole one ("1 whole", "1 medium"),
    /// else its first serving (a recipe's serving without one) unless that
    /// is a measure such as "1 cup", which a count can't mean.
    public var countServing: Serving? {
        let named = Set(FoodSearch.words(name).map(Self.singular))
        let noun = { (serving: Serving) in
            serving.name.lowercased().split(separator: " ").dropFirst().first.map { Self.singular(String($0)) }
        }
        if let serving = servings.first(where: { noun($0).map(named.contains) == true }) { return serving }
        if let serving = servings.first(where: { ["whole", "medium", "each", "piece", "item"].contains(noun($0) ?? "") }) {
            return serving
        }
        return firstServing.flatMap { serving in
            let word = noun(serving) ?? ""
            return TypedAmount.measures[word] != nil || ["fl", "fluid"].contains(word) ? nil : serving
        }
    }

    private var firstServing: Serving? { servings.first ?? recipeServing }

    /// The serving named by `word`, or for a container its package size:
    /// "can" finds "1 can (15 oz)" or "1 can", "large" "1 large breast". One
    /// whose name starts with the word comes first.
    private func serving(named word: String) -> Serving? {
        let words = { (serving: Serving) in FoodSearch.words(serving.name).map(Self.singular) }
        let synonyms: Set<String> = word == "can" || word == "tin" ? ["can", "tin"]
            : TypedAmount.packages.contains(word) ? TypedAmount.packages.subtracting(["can", "tin"]) : [word]
        let matching = (servings + recipePortions).filter { !synonyms.isDisjoint(with: words($0)) }
        return matching.first { words($0).dropFirst().first.map(synonyms.contains) == true } ?? matching.first
    }

    /// Grams in a millilitre: the label's density, or one from a measure it
    /// names, such as a cup of milk weighing 244 g.
    var gramsPerMilliliter: Double? {
        if let volume { return volume.density }
        let measures = [("cup", 8.0), ("fl oz", 1), ("tbsp", 0.5), ("tsp", 1.0 / 6)]
        for (name, fluidOunces) in measures {
            if let serving = servings.first(where: { Self.isMeasure($0.name, name, exactly: true) }) {
                return serving.grams / USUnits.milliliters(fluidOunces: fluidOunces)
            }
        }
        return nil
    }

    /// Whether a serving is one of a measure: "1 cup", or "1 cup, diced"
    /// unless `exactly`.
    private static func isMeasure(_ serving: String, _ measure: String, exactly: Bool = false) -> Bool {
        let name = serving.lowercased()
        return name == "1 \(measure)" || !exactly && (name.hasPrefix("1 \(measure),") || name.hasPrefix("1 \(measure) ("))
    }

    static func singular(_ word: String) -> String {
        if word.count > 3 && word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.count > 3 && word.hasSuffix("oes") { return String(word.dropLast(2)) }
        if word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }
}
