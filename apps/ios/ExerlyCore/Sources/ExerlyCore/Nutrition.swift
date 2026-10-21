import Foundation

public enum FoodSource: String, Sendable, Codable, Hashable, CaseIterable {
    case custom, recipe, usda, openFoodFacts, fatSecret, imported
}

/// A named portion, such as "1 cup" weighing 240 g.
public struct Serving: Sendable, Codable, Hashable {
    public var name: String
    public var grams: Double

    public init(_ name: String, grams: Double) {
        self.name = name
        self.grams = grams
    }

    /// How many of this serving weigh `grams`: the inverse of `grams *
    /// quantity`, so switching an amount to this serving keeps it. 180 g of
    /// a 240 g cup is 0.75.
    public func quantity(grams amount: Double) -> Double { amount / grams }
}

/// What a log entry keeps of a food, so editing the food later doesn't
/// rewrite history.
public struct FoodSnapshot: Sendable, Codable, Hashable {
    public var foodID: String
    public var name: String
    public var brand: String?
    public var source: FoodSource
    public var per100g: NutrientAmounts
    /// The food's volume basis, so a label per 100 ml and its assumed density
    /// stay with the history.
    public var volume: VolumeBasis?
    /// True when the person changed this entry's nutrients. The food it came
    /// from, and its source, are unchanged.
    public var edited: Bool?
    /// True when the portion wasn't weighed: `per100g` holds the whole
    /// portion's nutrients and the entry's 100 g is nominal, not a weight. A
    /// quick add, or a Shortcuts item of unknown weight. Show no weight.
    public var unweighed: Bool?
}

public struct RecipeIngredient: Sendable, Codable, Hashable {
    public var food: FoodSnapshot
    public var grams: Double
    /// The serving it was entered in, and how many, so "2 eggs" stays 2 eggs.
    public var serving: Serving?
    public var quantity: Double?

    public init(food: FoodSnapshot, grams: Double, serving: Serving? = nil, quantity: Double? = nil) {
        self.food = food
        self.grams = grams
        self.serving = serving
        self.quantity = quantity
    }
}

/// How a food labelled per volume converts to grams.
public struct VolumeBasis: Sendable, Codable, Hashable {
    /// Grams per millilitre.
    public var density: Double
    /// True when the density is typical for the kind of food rather than this product's.
    public var assumed: Bool
    /// Where the density came from, to show beside the food.
    public var note: String?

    public init(density: Double, assumed: Bool, note: String? = nil) {
        self.density = density
        self.assumed = assumed
        self.note = note
    }

    public func grams(milliliters: Double) -> Double { milliliters * density }

    /// The volume a logged weight was, to reopen an amount entered in millilitres.
    public func milliliters(grams: Double) -> Double { grams / density }

    var problems: [String] {
        density.isFinite && density > 0.3 && density < 3 ? [] : ["the density must be between 0.3 and 3 g/ml"]
    }
}

/// A custom food, a recipe, or a database food the person keeps.
public struct Food: Sendable, Codable, Hashable, Identifiable {
    /// A UUID for custom foods and recipes; "usda:<fdcId>" or "off:<barcode>" for database foods.
    public var id: String
    public var name: String
    public var brand: String?
    public var source: FoodSource
    public var per100g: NutrientAmounts
    public var servings: [Serving]
    public var barcode: String?
    /// For recipes.
    public var ingredients: [RecipeIngredient]?
    /// A recipe's cooked weight, when it differs from its ingredients'.
    public var yieldGrams: Double?
    /// How many servings a recipe makes; see `recipeServing`.
    public var servingCount: Double?
    /// How a recipe is made.
    public var preparation: String?
    /// The web page a recipe was imported from, kept to credit it.
    public var sourceURL: String?
    public var favorite: Bool
    public var createdAt: Date
    public var archivedAt: Date?
    /// For a food labelled per volume: `per100g` and gram servings were
    /// converted with this density, and `per100ml` gives the label back.
    public var volume: VolumeBasis?

    public init(id: String = UUID().uuidString, name: String, brand: String? = nil, source: FoodSource = .custom,
                per100g: NutrientAmounts, servings: [Serving] = [], barcode: String? = nil, favorite: Bool = false,
                createdAt: Date = Date().roundedToMilliseconds) {
        self.id = id
        self.name = name
        self.brand = brand
        self.source = source
        self.per100g = per100g
        self.servings = servings
        self.barcode = barcode
        self.favorite = favorite
        self.createdAt = createdAt
    }

    /// A recipe from ingredients. Its nutrients per 100 g come from their total
    /// over the cooked weight, or over the ingredients' weight without one.
    public static func recipe(id: String = UUID().uuidString, name: String, ingredients: [RecipeIngredient],
                              yieldGrams: Double? = nil, servingCount: Double? = nil, preparation: String? = nil,
                              servings: [Serving] = [], createdAt: Date = Date().roundedToMilliseconds) -> Food {
        var food = Food(id: id, name: name, source: .recipe, per100g: NutrientAmounts(), servings: servings,
                        createdAt: createdAt)
        food.servingCount = servingCount
        food.preparation = preparation
        return food.withIngredients(ingredients, yieldGrams: yieldGrams)
    }

    /// The recipe with new ingredients or a new cooked weight, its nutrients
    /// recalculated. Everything else is kept.
    public func withIngredients(_ ingredients: [RecipeIngredient], yieldGrams: Double?) -> Food {
        var food = self
        food.ingredients = ingredients
        food.yieldGrams = yieldGrams
        food.per100g = Self.per100g(ingredients, yield: yieldGrams)
        return food
    }

    /// A recipe's whole weight: its cooked weight, or its ingredients' without one.
    public var recipeGrams: Double? {
        guard let ingredients, !ingredients.isEmpty else { return nil }
        return yieldGrams ?? ingredients.reduce(0) { $0 + $1.grams }
    }

    /// One of a recipe's `servingCount` equal servings. It follows the
    /// recipe's weight, so it isn't kept in `servings`.
    public var recipeServing: Serving? {
        guard let servingCount, servingCount.isFinite, servingCount > 0, let whole = recipeGrams else { return nil }
        return Serving("1 serving", grams: whole / servingCount)
    }

    static func per100g(_ ingredients: [RecipeIngredient], yield: Double?) -> NutrientAmounts {
        let total = ingredients.reduce(NutrientAmounts()) { $0 + $1.food.per100g.scaled(by: $1.grams / 100) }
        let weight = yield ?? ingredients.reduce(0) { $0 + $1.grams }
        return weight > 0 ? total.scaled(by: 100 / weight) : NutrientAmounts()
    }

    /// The label's amounts per 100 ml, for a food labelled per volume.
    public var per100ml: NutrientAmounts? { volume.map { per100g.scaled(by: $0.density) } }

    /// Grams for a volume, for a food labelled per volume.
    public func grams(milliliters: Double) -> Double? { volume?.grams(milliliters: milliliters) }

    /// Millilitres for a weight, for a food labelled per volume.
    public func milliliters(grams: Double) -> Double? { volume?.milliliters(grams: grams) }

    /// Nutrients per 100 g from a label's amounts for one serving of `servingGrams`.
    public static func per100g(fromLabel amounts: NutrientAmounts, servingGrams: Double) throws -> NutrientAmounts {
        var problems = amounts.problems
        if !(servingGrams.isFinite && servingGrams > 0) { problems.append("the label's serving needs a positive weight") }
        guard problems.isEmpty else { throw NutritionStore.StoreError.invalid(problems) }
        return amounts.scaled(by: 100 / servingGrams)
    }

    public var snapshot: FoodSnapshot {
        FoodSnapshot(foodID: id, name: name, brand: brand, source: source, per100g: per100g, volume: volume)
    }

    var problems: [String] {
        var problems = per100g.problems
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("name is empty") }
        if servings.contains(where: { !($0.grams.isFinite && $0.grams > 0) || $0.name.isEmpty }) {
            problems.append("each serving needs a name and a positive weight")
        }
        if let yieldGrams, !(yieldGrams.isFinite && yieldGrams > 0) { problems.append("the yield must be positive") }
        if let servingCount, !(servingCount.isFinite && servingCount > 0) {
            problems.append("the serving count must be positive")
        }
        if source == .recipe && (ingredients ?? []).isEmpty { problems.append("a recipe needs ingredients") }
        if (ingredients ?? []).contains(where: { !($0.grams.isFinite && $0.grams > 0) || $0.quantity.map { !($0.isFinite && $0 > 0) } == true
            || $0.serving.map { !($0.grams.isFinite && $0.grams > 0) } == true }) {
            problems.append("each ingredient needs a positive weight")
        }
        problems += volume?.problems ?? []
        return problems
    }
}

/// One logged food.
public struct FoodEntry: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    /// The day it counts toward, in the person's calendar.
    public var date: LocalDate
    public var meal: String
    public var loggedAt: Date
    public var food: FoodSnapshot
    public var grams: Double
    /// The serving it was entered in, and how many.
    public var serving: Serving?
    public var quantity: Double?
    /// True once its amount was changed after it was logged. A food's
    /// remembered amount comes from entries as logged, so correcting one
    /// entry doesn't change what the next tap logs.
    public var amountChanged: Bool?
    /// True when the time of day isn't known, as for a day's total or a row
    /// imported without a time: `loggedAt` is a stand-in, not when it was eaten.
    public var timeUnknown: Bool?

    public init(id: UUID = UUID(), date: LocalDate, meal: String, loggedAt: Date, food: FoodSnapshot, grams: Double,
                serving: Serving? = nil, quantity: Double? = nil) {
        self.id = id
        self.date = date
        self.meal = meal
        self.loggedAt = loggedAt
        self.food = food
        self.grams = grams
        self.serving = serving
        self.quantity = quantity
    }

    public var nutrients: NutrientAmounts { food.per100g.scaled(by: grams / 100) }

    /// The entry with its nutrients corrected for this entry only. Changing
    /// the amount later scales the corrected nutrients.
    public func editingNutrients(_ nutrients: NutrientAmounts) -> FoodEntry {
        var entry = self
        entry.food.per100g = nutrients.scaled(by: 100 / grams)
        entry.food.edited = true
        return entry
    }

    var problems: [String] {
        var problems = food.per100g.problems + (food.volume?.problems ?? [])
        if !(grams.isFinite && grams > 0 && grams <= 100_000) { problems.append("the amount must be a positive weight") }
        if meal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || meal.count > 40 {
            problems.append("the meal needs a name up to 40 characters")
        }
        if let quantity, !(quantity.isFinite && quantity > 0) { problems.append("the quantity must be positive") }
        return problems
    }
}

/// How complete a day's food log is. Expenditure trusts complete and fasting days.
public enum DayStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case unlogged, partial, complete, fasting
}

public struct NutritionDay: Sendable, Codable, Hashable, Identifiable {
    /// The date, `YYYY-MM-DD`, so every device names the same day the same way.
    public var id: String { date.description }
    public var date: LocalDate
    public var status: DayStatus
    public var notes: String
    /// Labels for analysis ("travel", "creatine"), lowercased, sorted and unique.
    public var tags: [String]

    public init(date: LocalDate, status: DayStatus = .unlogged, notes: String = "", tags: [String] = []) {
        self.date = date
        self.status = status
        self.notes = notes
        self.tags = tags
    }

    enum CodingKeys: String, CodingKey { case id, date, status, notes, tags }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(LocalDate.self, forKey: .date)
        status = try c.decode(DayStatus.self, forKey: .status)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(date, forKey: .date)
        try c.encode(status, forKey: .status)
        try c.encode(notes, forKey: .notes)
        if !tags.isEmpty { try c.encode(tags, forKey: .tags) }
    }
}

public struct WeightEntry: Sendable, Codable, Hashable, Identifiable {
    /// Where a weigh-in came from; nil when it was entered in Exerly.
    public enum Source: String, Sendable, Codable, Hashable {
        /// Read from Apple Health. Its ID is the Health sample's, and Health
        /// stays its source of truth, so it isn't written back there.
        case appleHealth
        /// Imported from MacroFactor's export. Its ID comes from the export's
        /// row, so importing the file again adds nothing.
        case macroFactor
        /// Imported from Hevy's or Strong's measurement export, the same way.
        case hevy, strong
    }

    public var id: UUID
    public var at: Date
    public var date: LocalDate
    public var weight: Mass
    /// Body fat, in percent, when the scale reports it.
    public var bodyFat: Double?
    public var source: Source?

    public init(id: UUID = UUID(), at: Date, date: LocalDate, weight: Mass, bodyFat: Double? = nil, source: Source? = nil) {
        self.id = id
        self.at = at
        self.date = date
        self.weight = weight
        self.bodyFat = bodyFat
        self.source = source
    }

    var problems: [String] {
        var problems: [String] = []
        if !(weight.value.isFinite && weight.kilograms >= 20 && weight.kilograms <= 400) {
            problems.append("weight must be 20 to 400 kg")
        }
        if let bodyFat, !(bodyFat.isFinite && bodyFat > 1 && bodyFat < 75) { problems.append("body fat must be 1 to 75 %") }
        return problems
    }
}

/// A day's food in numbers, so screens never add entries up themselves.
public struct NutritionSummary: Sendable, Hashable {
    public var date: LocalDate
    public var status: DayStatus
    public var totals: NutrientAmounts
    public var byMeal: [String: NutrientAmounts]
    public var entries: Int
    /// How many of the entries report each nutrient: a total from fewer
    /// than `entries` may be low.
    public var reporting: [Nutrient: Int] = [:]

    /// The share of energy each macro provides, from Atwater factors.
    public var energyShares: [Nutrient: Double] {
        let parts = [Nutrient.protein, .carbohydrate, .fat, .alcohol].compactMap { nutrient -> (Nutrient, Double)? in
            guard let grams = totals[nutrient], let factor = nutrient.kilocaloriesPerGram else { return nil }
            return (nutrient, grams * factor)
        }
        let total = parts.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return [:] }
        return Dictionary(uniqueKeysWithValues: parts.map { ($0.0, $0.1 / total) })
    }
}

/// One food's share of a nutrient on a day.
public struct Contributor: Sendable, Hashable {
    public var entryID: UUID
    public var name: String
    public var amount: Double
    public var share: Double
}

/// A food usually logged around a time of day, with the amount and meal last
/// used, from `NutritionStore.suggestions(at:timeZone:)`.
public struct FoodSuggestion: Sendable, Hashable {
    public var food: FoodSnapshot
    public var meal: String
    public var grams: Double
    public var serving: Serving?
    public var quantity: Double?
    /// Days in the window it was logged near this time.
    public var days: Int
}

/// An amount of a food as `NutritionStore.log` records it.
public struct LoggedAmount: Sendable, Hashable {
    public var grams: Double
    public var nutrients: NutrientAmounts
    public var serving: Serving?
    public var quantity: Double?
}

/// One nutrient's intake against its target on a day, for a progress bar and
/// "x left". Values are unrounded; format them for display.
public struct NutrientProgress: Sendable, Hashable {
    public var nutrient: Nutrient
    /// The total of the entries that report it.
    public var consumed: Double
    /// Entries that don't report it, so the total may be low.
    public var unreported: Int
    public var target: Double?

    public init(nutrient: Nutrient, consumed: Double, unreported: Int, target: Double?) {
        self.nutrient = nutrient
        self.consumed = consumed
        self.unreported = unreported
        self.target = target
    }

    /// The target minus consumed, never below zero; nil without a target.
    public var remaining: Double? { target.map { max(0, $0 - consumed) } }
    /// Consumed minus the target when above it, else zero; nil without a target.
    public var over: Double? { target.map { max(0, consumed - $0) } }
    /// Consumed over the target: 1 is exactly on target. Nil without a positive target.
    public var fraction: Double? { target.flatMap { $0 > 0 ? consumed / $0 : nil } }
}

/// The day's energy and macros against the targets in force.
public struct DayProgress: Sendable, Hashable {
    public var date: LocalDate
    public var energy: NutrientProgress
    public var protein: NutrientProgress
    public var fat: NutrientProgress
    public var carbohydrate: NutrientProgress
    public var hasTargets: Bool { energy.target != nil }
}

extension NutritionStore {
    /// The day's intake against `targets(on:)`.
    public func progress(on date: LocalDate) -> DayProgress {
        let logged = entries(on: date)
        let targets = targets(on: date)
        func progress(_ nutrient: Nutrient, _ target: Double?) -> NutrientProgress {
            NutrientProgress(nutrient: nutrient, consumed: logged.compactMap { $0.nutrients[nutrient] }.reduce(0, +),
                             unreported: logged.filter { $0.nutrients[nutrient] == nil }.count, target: target)
        }
        return DayProgress(date: date, energy: progress(.energy, targets?.energy), protein: progress(.protein, targets?.protein),
                           fat: progress(.fat, targets?.fat), carbohydrate: progress(.carbohydrate, targets?.carbohydrate))
    }
}
