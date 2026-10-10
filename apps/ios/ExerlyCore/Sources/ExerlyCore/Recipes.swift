import Foundation

// A recipe is a food made of other foods' snapshots; see `Food.recipe`. Its
// totals add up what its ingredients report, as a day's totals do, so a
// recipe logged whole counts the same as its ingredients logged one by one.

extension RecipeIngredient {
    /// This amount's nutrients. Nutrients its food doesn't report stay missing.
    public var nutrients: NutrientAmounts { food.per100g.scaled(by: grams / 100) }
}

extension Food {
    /// The name of the serving that is the whole recipe.
    public static let wholeRecipe = "whole recipe"

    /// The whole recipe as one serving, so a share of the pot logs as a
    /// fraction of it: 0.25 of a 1,200 g pot is 300 g.
    public var recipeWhole: Serving? { recipeGrams.map { Serving(Self.wholeRecipe, grams: $0) } }

    /// A recipe's own portions: one of its servings, when it has a count, then the whole recipe.
    public var recipePortions: [Serving] { [recipeServing, recipeWhole].compactMap { $0 } }

    /// All its ingredients' nutrients together, whatever the cooked weight.
    public var recipeTotal: NutrientAmounts? {
        ingredients.map { $0.reduce(NutrientAmounts()) { $0 + $1.nutrients } }
    }

    /// One serving's nutrients; nil without a serving count.
    public var perRecipeServing: NutrientAmounts? { recipeServing.map { per100g.scaled(by: $0.grams / 100) } }

    /// For each nutrient some ingredients report and others leave out, the
    /// names of those that leave it out: the recipe counts only the ones that
    /// report it, so its amount may be low. A nutrient no ingredient reports
    /// isn't listed; the recipe leaves it unknown, never zero.
    public var recipeGaps: [Nutrient: [String]] {
        guard let ingredients else { return [:] }
        var gaps: [Nutrient: [String]] = [:]
        for nutrient in Set(ingredients.flatMap(\.food.per100g.values.keys)) {
            let missing = ingredients.filter { $0.food.per100g[nutrient] == nil }.map(\.food.name)
            if !missing.isEmpty { gaps[nutrient] = missing }
        }
        return gaps
    }

    /// Its ingredients scaled to a portion of `grams` of the recipe, with
    /// their serving counts, so logging them adds up to that portion.
    public func ingredients(inPortion grams: Double) -> [RecipeIngredient] {
        guard let ingredients, let whole = recipeGrams, whole > 0 else { return [] }
        return ingredients.map { ingredient in
            var part = ingredient
            part.grams *= grams / whole
            part.quantity = ingredient.quantity.map { $0 * grams / whole }
            return part
        }
    }

    /// A copy to vary: a new food with the same label and ingredients, not a
    /// favorite, archived or tied to a barcode.
    public func duplicated(now: Date = Date()) -> Food {
        var copy = self
        copy.id = UUID().uuidString
        copy.name = "\(name) copy"
        copy.favorite = false
        copy.archivedAt = nil
        copy.barcode = nil
        copy.createdAt = now.roundedToMilliseconds
        return copy
    }

    /// One serving made of logged entries, each ingredient with the snapshot
    /// and amount it was logged with. Entries without a weight (quick adds)
    /// are left out: they have nothing to weigh.
    public static func recipe(from entries: [FoodEntry], name: String = "") -> Food {
        recipe(name: name, ingredients: entries.filter { $0.food.unweighed != true }.map {
            RecipeIngredient(food: $0.food, grams: $0.grams, serving: $0.serving, quantity: $0.quantity)
        }, servingCount: 1)
    }
}

extension NutritionStore {
    /// Saved recipes that belong to `meal`: ones made of the foods logged to
    /// it on a day in the `days` up to `date`, as saving a meal as a recipe
    /// makes them, or ones logged to it in that time. So a meal saved as a
    /// recipe is offered where it was eaten. Recipes the person hid aren't.
    public func recipes(for meal: String, through date: LocalDate, days: Int = 14) -> [Food] {
        let recent = entries.filter { $0.meal == meal && $0.date <= date && $0.date >= date.adding(days: -days) }
        let meals = Set(Dictionary(grouping: recent.filter { $0.food.unweighed != true }, by: \.date).values.map { Set($0.map(\.food.foodID)) })
        let logged = Set(recent.map(\.food.foodID))
        let hidden = Set(hiddenSuggestions.map(\.id))
        return foods.filter { food in
            guard !hidden.contains(food.id), food.source == .recipe, food.archivedAt == nil, let ingredients = food.ingredients, !ingredients.isEmpty else { return false }
            return logged.contains(food.id) || meals.contains(Set(ingredients.map(\.food.foodID)))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
