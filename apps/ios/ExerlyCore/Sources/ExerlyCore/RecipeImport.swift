import Foundation

// A recipe brought in from elsewhere, for the person to review in the recipe
// editor before anything is saved: read from a web page's structured data
// (the API's /v1/recipes/import) and matched to foods here, or a recipe
// another Exerly user shared as a file.

/// A recipe as a web page's structured data describes it.
public struct WebRecipe: Sendable, Hashable, Decodable {
    public var name: String
    public var ingredients: [String]
    public var servings: Double?
    /// Numbered steps, one a line.
    public var instructions: String?
    /// The page, after any redirects.
    public var url: String

    public init(name: String, ingredients: [String], servings: Double? = nil, instructions: String? = nil, url: String) {
        self.name = name
        self.ingredients = ingredients
        self.servings = servings
        self.instructions = instructions
        self.url = url
    }
}

/// An ingredient line from a recipe page: "1 (15 oz) can black beans,
/// drained" is one can of 15 oz of black beans. Its amount is read as food
/// search reads a typed one (`FoodSearch.amount(in:)`), once what pages add
/// around it is set aside: a size in parentheses, a range, notes after a
/// comma, an alternative after "or", and words for how it's prepared.
public struct IngredientLine: Sendable, Hashable {
    /// The line as the page wrote it.
    public var text: String
    public var amount: TypedAmount?
    /// A weight in parentheses: of each container or item ("1 (15 oz) can"),
    /// or of the whole amount when it is a measure ("2 cups (250 g)").
    public var size: TypedAmount?
    /// The food's name, to match.
    public var food: String
    /// True for a range such as "2-3 cloves", read as its first number.
    public var range: Bool
    /// The amount and food as food search would read them typed: "1 can
    /// black beans", without the size or notes.
    public var query: String
    /// True when the line drains the food ("drained and rinsed"), so less of
    /// a can goes in than its label's weight.
    public var drained: Bool

    /// A drained can's share of its label weight: beans, chickpeas, corn and
    /// tomatoes keep about 60 % once their liquid is poured off.
    public static let drainedShare = 0.6

    /// The name to match a database food by: the food, and "canned" for a can
    /// or tin of it, so "1 can black beans" finds canned beans, not cooked dried ones.
    public var match: String {
        guard case .serving(let word)? = amount?.unit, ["can", "tin"].contains(word),
              !FoodSearch.words(food).contains(where: { $0.lowercased() == "canned" }) else { return food }
        return "\(food) canned"
    }

    /// Words that say how a food is prepared or how much is roughly meant,
    /// not which food it is. Not "minced", which in "minced beef" is the food.
    static let preparation: Set<String> = [
        "fresh", "freshly", "chopped", "diced", "sliced", "grated", "shredded", "finely", "roughly", "coarsely",
        "thinly", "peeled", "crushed", "packed", "softened", "melted", "divided", "boneless", "skinless", "extra-virgin",
        "extra", "virgin", "about", "approximately", "approx", "heaping", "heaped", "rounded", "scant", "level"
    ]

    public init(_ text: String) {
        self.text = text
        var line = text.replacingOccurrences(of: "⁄", with: "/")
            .replacing(/(\d)-(?=[A-Za-z])/) { "\($0.output.1) " } // "15-ounce" is 15 ounce
        var size: TypedAmount?
        line = line.replacing(/\(([^()]*)\)/) { match in
            if size == nil { size = Self.weight(String(match.output.1)) }
            return " "
        }
        // A count, then each one's weight: "1 14 oz can", once "14-oz" is "14 oz".
        if size == nil, let match = line.firstMatch(of: /^\s*(\d+)\s+(\d+(?:\.\d+)?\s*(?:oz|ounces?|g|grams?|lbs?|pounds?|kg))\s+(?=[A-Za-z])/.ignoresCase()),
           let weight = Self.weight(String(match.output.2)) {
            size = weight
            line.replaceSubrange(match.range, with: "\(match.output.1) ")
        }
        var range = false
        if let match = line.firstMatch(of: /^\s*(\d+(?:[.\/]\d+)?)\s*(?:-|–|—|to)\s*(\d+(?:[.\/]\d+)?)\b/) {
            let first = FoodSearch.number(match.output.1).map(\.0) ?? 0
            let second = FoodSearch.number(match.output.2).map(\.0) ?? 0
            // "1-1/2" is one and a half; "2-3" is two to three.
            let reading = second < 1 && first == first.rounded() ? "\(match.output.1) \(match.output.2)" : String(match.output.1)
            range = reading == String(match.output.1)
            line.replaceSubrange(match.range, with: reading)
        }
        line = line.replacing(/\b(?:to taste|as needed|if needed|optional|to serve|for serving|to garnish|for garnish)\b/.ignoresCase(), with: "")
        // Notes start at the first comma, "or" or "plus" with a food before it:
        // "2 boneless, skinless chicken breasts" keeps going past "boneless,".
        var reading = Self.reading(line)
        for note in line.matches(of: /,(?!\d)|;|\s(?:or|plus|for)\s/.ignoresCase()) {
            let before = Self.reading(String(line[..<note.range.lowerBound]))
            if !before.food.isEmpty {
                reading = before
                break
            }
        }
        var words = reading.food.split(separator: " ").map(String.init)
        // A serving after its food, "2 garlic cloves", or a container after a
        // weight, "410g can kidney beans", says how much, not which food.
        if let count = reading.amount, count.unit == nil, words.count > 1,
           let word = FoodSearch.servingWord(words[words.count - 1].lowercased()), !TypedAmount.sizes.contains(word) {
            reading.amount = TypedAmount(count.quantity, .serving(word))
            words.removeLast()
        } else if reading.amount?.grams != nil, words.count > 1,
                  TypedAmount.packages.contains(FoodSearch.servingWord(words[0].lowercased()) ?? "") {
            words.removeFirst()
        }
        amount = reading.amount
        self.size = size
        food = words.joined(separator: " ")
        self.range = range && amount != nil
        query = reading.query
        let lowered = text.lowercased()
        drained = lowered.contains("drained") && !lowered.contains("undrained") && !lowered.contains("not drained")
    }

    /// The amount and food in `text`, without words for how it's prepared.
    private static func reading(_ text: String) -> (amount: TypedAmount?, food: String, query: String) {
        let query = text.split(whereSeparator: \.isWhitespace)
            .filter { !preparation.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
            .joined(separator: " ").trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        let (amount, food) = FoodSearch.amount(in: query)
        return (amount, food.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)), query)
    }

    /// A weight such as "15 oz", "15 ounce" or "about 425 g", and nothing else.
    private static func weight(_ text: String) -> TypedAmount? {
        let words = text.split(whereSeparator: \.isWhitespace).filter { !preparation.contains($0.lowercased()) }
        guard let first = words.first, FoodSearch.number(first) != nil,
              let amount = FoodSearch.amount(in: words.joined(separator: " ")).amount, amount.grams != nil else { return nil }
        return amount
    }

    /// This line's amount of `food`, and whether it's exactly what the line
    /// says: a weight in parentheses always is, unless the line drains it
    /// (`drainedShare` of it, to check); otherwise as `Food.portion` reads a
    /// typed amount, and never for a range. Nil without an amount, or one
    /// that means nothing for the food.
    public func portion(of food: Food) -> (amount: LoggedAmount, exact: Bool)? {
        if let size, let grams = size.grams {
            switch amount?.unit {
            case nil, .serving?:
                var word = "each"
                if case .serving(let named)? = amount?.unit { word = named }
                let drains = drained && TypedAmount.packages.contains(word)
                // Grams from the can's own grams; only the label is rounded, so the unit it's given in doesn't change them.
                let serving = drains ? Serving("1 \(word), drained (\(size.scaled(by: Self.drainedShare).label))", grams: grams * Self.drainedShare)
                    : Serving("1 \(word) (\(size.label))", grams: grams)
                return (try? NutritionStore.preview(food, serving: serving, quantity: amount?.quantity ?? 1)).map { ($0, !drains) }
            default:
                return (try? NutritionStore.preview(food, grams: grams)).map { ($0, true) }
            }
        }
        guard let amount, let portion = food.portion(amount) else { return nil }
        return (portion.amount, portion.exact && !range)
    }
}

extension TypedAmount {
    /// Whether it's a volume: millilitres to cups.
    var isVolume: Bool {
        switch unit {
        case .milliliters?, .liters?, .fluidOunces?, .cups?, .tablespoons?, .teaspoons?: true
        default: false
        }
    }

    /// Its weight in grams, for a weight.
    var grams: Double? {
        switch unit {
        case .grams?: quantity
        case .kilograms?: quantity * 1000
        case .ounces?: quantity * USUnits.gramsPerOunce
        case .pounds?: quantity * USUnits.gramsPerOunce * 16
        default: nil
        }
    }

    /// `share` of this weight, to show: whole grams, 0.1 oz, 0.01 kg or lb.
    func scaled(by share: Double) -> TypedAmount {
        let step: Double = switch unit {
        case .kilograms?, .pounds?: 0.01
        case .ounces?: 0.1
        default: 1
        }
        return TypedAmount(((quantity * share / step).rounded() * step * 100).rounded() / 100, unit)
    }

    /// A weight as a serving's name gives it: "15 oz", "400 g".
    var label: String {
        let number = quantity == quantity.rounded() ? String(Int(quantity)) : String(quantity)
        let unit: String = switch self.unit {
        case .kilograms?: "kg"
        case .ounces?: "oz"
        case .pounds?: "lb"
        default: "g"
        }
        return "\(number) \(unit)"
    }
}

/// A recipe to review before saving: its ingredients matched to foods, the
/// lines no food matched, and what the source said about yield and steps.
public struct RecipeImport: Sendable, Hashable {
    public struct Ingredient: Sendable, Hashable {
        public var ingredient: RecipeIngredient
        /// The food it matched, with every named serving, to change the amount in.
        public var food: Food?
        /// The line it came from, to compare with the match.
        public var line: String?
        /// False when the amount is a guess to check: the line gave none, a
        /// range, or one that doesn't fit the food.
        public var exact: Bool
        /// True when the line gives a volume the food has no density for:
        /// its amount only holds the place of a weight the person enters,
        /// and counts for nothing until then.
        public var needsWeight: Bool

        public init(ingredient: RecipeIngredient, food: Food? = nil, line: String? = nil, exact: Bool = true,
                    needsWeight: Bool = false) {
            self.ingredient = ingredient
            self.food = food
            self.line = line
            self.exact = exact
            self.needsWeight = needsWeight
        }
    }

    public var name: String
    public var ingredients: [Ingredient]
    /// Lines no food matched, for the person to search for or skip.
    public var unmatched: [String]
    public var servingCount: Double?
    public var yieldGrams: Double?
    public var preparation: String?
    public var sourceURL: String?

    public init(name: String, ingredients: [Ingredient], unmatched: [String] = [], servingCount: Double? = nil,
                yieldGrams: Double? = nil, preparation: String? = nil, sourceURL: String? = nil) {
        self.name = name
        self.ingredients = ingredients
        self.unmatched = unmatched
        self.servingCount = servingCount
        self.yieldGrams = yieldGrams
        self.preparation = preparation
        self.sourceURL = sourceURL
    }

    /// `page`'s lines matched to foods: one of the person's own with the
    /// same name, else `database`'s for that line (one per line, nil for
    /// none). A line whose amount can't be read, or doesn't fit the food,
    /// comes in at the food's default amount, to check; a volume without a
    /// density, as needing a weight.
    public init(page: WebRecipe, own: [Food], database: [Food?], unit: MassUnit) {
        var ingredients: [Ingredient] = []
        var unmatched: [String] = []
        for (index, text) in page.ingredients.enumerated() {
            let line = IngredientLine(text)
            let name = Self.nameWords(line.food)
            let mine = own.first { $0.archivedAt == nil && !name.isEmpty && Self.nameWords($0.name) == name }
            guard !name.isEmpty, let food = mine ?? (index < database.count ? database[index] : nil) else {
                unmatched.append(text)
                continue
            }
            var exact = true
            var needsWeight = false
            var amount = line.portion(of: food).map { exact = $0.exact; return $0.amount }
            if amount == nil {
                exact = false
                needsWeight = line.amount?.isVolume == true
                let (serving, quantity) = NutritionStore.defaultPortion(food, unit: unit)
                amount = try? NutritionStore.preview(food, grams: serving == nil ? quantity : nil, serving: serving,
                                                     quantity: serving == nil ? nil : quantity)
            }
            guard let amount else { unmatched.append(text); continue }
            ingredients.append(Ingredient(ingredient: RecipeIngredient(food: food.snapshot, grams: amount.grams, serving: amount.serving,
                                                                       quantity: amount.quantity),
                                          food: food, line: text, exact: exact, needsWeight: needsWeight))
        }
        self.init(name: page.name, ingredients: ingredients, unmatched: unmatched, servingCount: page.servings,
                  preparation: page.instructions, sourceURL: page.url)
    }

    /// A name's words in the singular, in any order: "Black beans" is "beans black".
    static func nameWords(_ name: String) -> Set<String> { Set(FoodSearch.words(name).map(FoodSearch.singular)) }
}

/// A recipe shared as a `.exerlyrecipe` file, for someone else to add a copy
/// of: its name, yield, preparation, source and ingredients, each with the
/// nutrition it was saved with. Nothing else of the sender's goes in it, so
/// the copy needs no account of theirs.
public enum RecipeFile {
    public static let fileExtension = "exerlyrecipe"
    /// Larger files aren't read.
    public static let maximumSize = 1_000_000

    public enum Failure: Error, Equatable { case unreadable }

    private struct Contents: Codable {
        var format = "exerly.recipe"
        var version = 1
        var name: String
        var servingCount: Double?
        var yieldGrams: Double?
        var preparation: String?
        var sourceURL: String?
        var ingredients: [RecipeIngredient]
    }

    public static func data(for recipe: Food) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Contents(name: recipe.name, servingCount: recipe.servingCount, yieldGrams: recipe.yieldGrams,
                                           preparation: recipe.preparation, sourceURL: recipe.sourceURL,
                                           ingredients: recipe.ingredients ?? []))
    }

    /// The shared recipe, to review as a new recipe of the person's own. Its
    /// totals are worked out again from the ingredients, not taken from the file.
    public static func read(_ data: Data) throws -> RecipeImport {
        guard data.count <= maximumSize, let contents = try? JSONDecoder().decode(Contents.self, from: data),
              contents.format == "exerly.recipe", contents.version == 1, contents.name.count <= 200,
              (1...200).contains(contents.ingredients.count),
              contents.ingredients.allSatisfy({ $0.food.per100g.problems.isEmpty && ($0.food.volume?.problems ?? []).isEmpty }),
              contents.sourceURL.map({ $0.count <= 2048 && ($0.hasPrefix("https://") || $0.hasPrefix("http://")) }) != false
        else { throw Failure.unreadable }
        let recipe = Food.recipe(name: contents.name, ingredients: contents.ingredients, yieldGrams: contents.yieldGrams,
                                 servingCount: contents.servingCount, preparation: contents.preparation)
        guard recipe.problems.isEmpty else { throw Failure.unreadable }
        return RecipeImport(name: contents.name, ingredients: contents.ingredients.map { RecipeImport.Ingredient(ingredient: $0) },
                            servingCount: contents.servingCount, yieldGrams: contents.yieldGrams, preparation: contents.preparation,
                            sourceURL: contents.sourceURL)
    }
}
