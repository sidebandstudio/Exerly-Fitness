import Foundation

/// A portion of a food that one tap logs: the amount last logged for it, or a
/// sensible default for a food never logged. It is shown before it is logged,
/// so what a row says is exactly what the tap records.
public struct QuickPortion: Sendable, Hashable, Identifiable {
    public var id: String { food.foodID }
    public var food: FoodSnapshot
    public var grams: Double
    /// The serving it was entered in, and how many.
    public var serving: Serving?
    public var quantity: Double?
    /// True when the amount repeats one logged before.
    public var repeated: Bool

    public init(food: FoodSnapshot, grams: Double, serving: Serving? = nil, quantity: Double? = nil, repeated: Bool) {
        self.food = food
        self.grams = grams
        self.serving = serving
        self.quantity = quantity
        self.repeated = repeated
    }

    /// A time-of-day suggestion's food and amount.
    public init(_ suggestion: FoodSuggestion) {
        self.init(food: suggestion.food, grams: suggestion.grams, serving: suggestion.serving,
                  quantity: suggestion.quantity, repeated: true)
    }

    /// The portion's nutrients. Nutrients the food doesn't report stay missing.
    public var nutrients: NutrientAmounts { food.per100g.scaled(by: grams / 100) }
}

extension FoodSuggestion {
    /// A portion offered for a meal, with the amount one tap logs.
    public init(_ portion: QuickPortion, meal: String) {
        self.init(food: portion.food, meal: meal, grams: portion.grams, serving: portion.serving,
                  quantity: portion.quantity, days: 0)
    }
}

extension NutritionStore {
    /// The portion one tap logs for `food`. With history, the amount last
    /// logged for it (see `rememberedEntry`); a saved food uses its current label, and a repeated
    /// corrected snapshot keeps its mark, as the portion editor does.
    /// Without history, one of its first named serving (a recipe's serving
    /// when it has none). Failing that, a plain amount in the person's units:
    /// 100 g or 4 oz, or for a food labelled by volume 100 ml or 8 fl oz.
    /// Nil for a food whose label can't be logged, or one only ever logged as
    /// a whole portion.
    public func quickPortion(for food: Food, unit: MassUnit = .kilograms) -> QuickPortion? {
        let label = self.food(food.id) ?? food
        if let last = rememberedEntry(for: food.id) {
            var snapshot = label.snapshot
            if last.food.edited == true, last.food.per100g == snapshot.per100g { snapshot.edited = true }
            return QuickPortion(food: snapshot, grams: last.grams, serving: last.serving, quantity: last.quantity,
                                repeated: true)
        }
        // Only ever logged whole; one whose amounts were all corrected starts again from its default.
        let logged = entries.filter { $0.food.foodID == food.id }
        guard logged.isEmpty || logged.contains(where: { $0.food.unweighed != true }) else { return nil }
        let (serving, quantity) = Self.defaultPortion(label, unit: unit)
        guard let amount = try? Self.preview(label, grams: serving == nil ? quantity : nil, serving: serving,
                                             quantity: serving == nil ? nil : quantity) else { return nil }
        return QuickPortion(food: label.snapshot, grams: amount.grams, serving: amount.serving,
                            quantity: amount.quantity, repeated: false)
    }

    /// The amount to start a food never logged at: one of its first named
    /// serving (a recipe's serving when it has none), else 100 g or 4 oz, or
    /// for a food labelled by volume 100 ml or 8 fl oz. A serving and how
    /// many of it, or, without a serving, grams.
    public nonisolated static func defaultPortion(_ food: Food, unit: MassUnit) -> (serving: Serving?, quantity: Double) {
        if let serving = food.servings.first ?? food.recipeServing { return (serving, 1) }
        if let volume = food.volume {
            return unit == .pounds
                ? (Serving("fl oz", grams: volume.grams(milliliters: USUnits.milliliters(fluidOunces: 1))), 8)
                : (Serving("ml", grams: volume.grams(milliliters: 1)), 100)
        }
        return unit == .pounds ? (Serving("oz", grams: USUnits.grams(ounces: 1)), 4) : (nil, 100)
    }

    /// Foods to log again, most recently logged first, each with the portion
    /// one tap logs. Quick adds, whole portions and archived foods are left out.
    public func recentPortions(limit: Int = 20) -> [QuickPortion] {
        var result: [QuickPortion] = []
        for snapshot in recentFoods(limit: limit) where snapshot.unweighed != true {
            let saved = food(snapshot.foodID)
            guard saved?.archivedAt == nil else { continue }
            guard let last = rememberedEntry(for: snapshot.foodID) else {
                // Every amount it was logged at was corrected later: its default.
                var label = Food(id: snapshot.foodID, name: snapshot.name, brand: snapshot.brand, source: snapshot.source,
                                 per100g: snapshot.per100g)
                label.volume = snapshot.volume
                if let portion = quickPortion(for: saved ?? label) { result.append(portion) }
                continue
            }
            var food = saved?.snapshot ?? last.food
            if saved != nil, last.food.edited == true, last.food.per100g == food.per100g { food.edited = true }
            result.append(QuickPortion(food: food, grams: last.grams, serving: last.serving,
                                       quantity: last.quantity, repeated: true))
        }
        return result
    }

    /// Logs a portion as a new entry.
    @discardableResult
    public func log(_ portion: QuickPortion, on date: LocalDate, meal: String, at time: Date? = nil) throws -> FoodEntry {
        try log(FoodSuggestion(portion, meal: meal), on: date, meal: meal, at: time)
    }

    /// The latest weighed entry of a food at the amount it was logged at:
    /// the amount one tap logs it at again. Entries whose amount was changed
    /// later are skipped.
    public func rememberedEntry(for foodID: String) -> FoodEntry? {
        entries.last { $0.food.foodID == foodID && $0.food.unweighed != true && $0.amountChanged != true }
    }
}

/// A food the person asked not to be suggested ("Don't suggest this"). It
/// stays out of usual foods and Log again, and its recipes stay out of a
/// meal's suggestions, until they let it back. Search and Recent still find
/// it. One synced document per food, its ID the food's.
public struct HiddenSuggestion: Sendable, Codable, Hashable, Identifiable {
    /// The food's ID.
    public var id: String
    public var name: String
    public var hiddenAt: Date

    public init(id: String, name: String, hiddenAt: Date) {
        self.id = id
        self.name = name
        self.hiddenAt = hiddenAt
    }

    var problems: [String] {
        id.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ["a hidden suggestion needs a food and its name"] : []
    }
}

extension NutritionStore {
    /// Stops suggesting a food, from now on and on every device.
    public func hideSuggestion(_ food: FoodSnapshot) throws {
        let hidden = HiddenSuggestion(id: food.foodID, name: food.name, hiddenAt: now())
        guard hidden.problems.isEmpty else { throw StoreError.invalid(hidden.problems) }
        try commit(Self.hiddenKind, hidden.id, hidden)
    }

    /// Suggests a hidden food again.
    public func restoreSuggestion(_ foodID: String) throws {
        guard hiddenSuggestions.contains(where: { $0.id == foodID }) else { throw StoreError.notFound }
        try prepareWrite(kind: Self.hiddenKind, id: foodID, payload: nil)()
    }

    public func isHiddenSuggestion(_ foodID: String) -> Bool { hiddenSuggestions.contains { $0.id == foodID } }
}

extension NutrientAmounts {
    /// The share of energy from protein, carbohydrate, fat and alcohol, by
    /// Atwater factors. Empty when none is reported or they add up to zero.
    public var macroEnergyShares: [Nutrient: Double] {
        let parts = [Nutrient.protein, .carbohydrate, .fat, .alcohol].compactMap { nutrient -> (Nutrient, Double)? in
            guard let grams = self[nutrient], let factor = nutrient.kilocaloriesPerGram else { return nil }
            return (nutrient, grams * factor)
        }
        let total = parts.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return [:] }
        return Dictionary(uniqueKeysWithValues: parts.map { ($0.0, $0.1 / total) })
    }
}
