import Foundation
import Testing
@testable import ExerlyCore

@MainActor
@Suite struct NutritionQuickLogTests {
    let monday = LocalDate("2026-10-05")!

    func store(_ persistence: InMemoryTrainingPersistence = InMemoryTrainingPersistence()) throws -> NutritionStore {
        try NutritionStore(persistence: persistence, now: { Fixture.instant() })
    }

    @Test func aFoodNeverLoggedUsesItsFirstServingThenOneHundredGrams() throws {
        let nutrition = try store()
        let oats = try #require(nutrition.quickPortion(for: Foods.oats))
        #expect(oats.serving == Serving("1/2 cup", grams: 40) && oats.quantity == 1 && oats.grams == 40)
        #expect(!oats.repeated)
        #expect(close(oats.nutrients.energy, 152))
        let chicken = try #require(nutrition.quickPortion(for: Foods.chicken))
        #expect(chicken.grams == 100 && chicken.serving == nil && chicken.quantity == nil)
        // A food that omits a nutrient keeps it unknown, not zero.
        #expect(chicken.nutrients[.carbohydrate] == nil)
        // In U.S. units, four ounces; a food labelled by volume, 100 ml or 8 fl oz.
        let usChicken = try #require(nutrition.quickPortion(for: Foods.chicken, unit: .pounds))
        #expect(usChicken.serving == Serving("oz", grams: USUnits.grams(ounces: 1)) && usChicken.quantity == 4)
        #expect(close(usChicken.grams, USUnits.grams(ounces: 4)))
        var juice = Foods.chicken
        juice.volume = VolumeBasis(density: 1.04, assumed: false)
        let metricJuice = try #require(nutrition.quickPortion(for: juice))
        #expect(metricJuice.serving?.name == "ml" && metricJuice.quantity == 100 && close(metricJuice.grams, 104))
        let usJuice = try #require(nutrition.quickPortion(for: juice, unit: .pounds))
        #expect(usJuice.serving?.name == "fl oz" && usJuice.quantity == 8)
        #expect(close(usJuice.grams, 1.04 * USUnits.milliliters(fluidOunces: 8), tolerance: 1e-9))
    }

    @Test func aRecipeWithoutNamedServingsUsesOneOfItsServings() throws {
        let nutrition = try store()
        let recipe = Food.recipe(name: "Synthetic porridge", ingredients: [
            RecipeIngredient(food: Foods.oats.snapshot, grams: 80), RecipeIngredient(food: Foods.milk.snapshot, grams: 320)
        ], servingCount: 2)
        let portion = try #require(nutrition.quickPortion(for: recipe))
        #expect(portion.serving == Serving("1 serving", grams: 200) && portion.quantity == 1 && portion.grams == 200)
    }

    @Test func aFoodLoggedBeforeRepeatsItsLastAmountWithTheCurrentLabel() throws {
        let nutrition = try store()
        try nutrition.saveFood(Foods.oats)
        try nutrition.log(Foods.oats, grams: 55, on: monday, meal: "Breakfast", at: Fixture.instant(minutes: -60))
        try nutrition.log(Foods.oats, serving: Foods.oats.servings[0], quantity: 1.5, on: monday, meal: "Breakfast")
        var relabelled = Foods.oats
        relabelled.per100g = NutrientAmounts([.energy: 400, .protein: 14])
        try nutrition.saveFood(relabelled)
        let portion = try #require(nutrition.quickPortion(for: Foods.oats))
        #expect(portion.repeated && portion.grams == 60 && portion.quantity == 1.5)
        #expect(portion.serving == Foods.oats.servings[0])
        #expect(portion.food.per100g[.energy] == 400, "A saved food's current label is used")
    }

    @Test func correctingAnEntrysAmountLeavesTheRememberedAmountAlone() throws {
        let nutrition = try store()
        let recipe = Food.recipe(name: "Synthetic chili", ingredients: [
            RecipeIngredient(food: Foods.chicken.snapshot, grams: 400), RecipeIngredient(food: Foods.oats.snapshot, grams: 200)
        ], servingCount: 2)
        try nutrition.saveFood(recipe)
        let serving = try #require(recipe.recipeServing)
        let bowl = try nutrition.log(recipe, serving: serving, quantity: 1, on: monday, meal: "Dinner")
        var half = bowl
        half.quantity = 0.5
        half.grams = serving.grams / 2
        try nutrition.saveEntry(half)
        #expect(nutrition.entries.first?.amountChanged == true && nutrition.entries.first?.grams == 150)
        // Every amount it was logged at was corrected, so it starts from one serving again.
        let portion = try #require(nutrition.quickPortion(for: recipe))
        #expect(portion.quantity == 1 && portion.serving == serving && !portion.repeated)
        #expect(nutrition.recentPortions().first?.quantity == 1)

        try nutrition.log(Foods.oats, grams: 80, on: monday, meal: "Breakfast", at: Fixture.instant(minutes: -60))
        var corrected = try nutrition.log(Foods.oats, grams: 80, on: monday, meal: "Breakfast")
        corrected.grams = 50
        try nutrition.saveEntry(corrected)
        let oats = try #require(nutrition.quickPortion(for: Foods.oats))
        #expect(oats.repeated && oats.grams == 80, "The earlier entry, as logged")
        // Moving an entry to another meal isn't a change to its amount.
        var moved = try #require(nutrition.entries.first { $0.food.foodID == Foods.oats.id && $0.grams == 80 })
        moved.meal = "Snacks"
        try nutrition.saveEntry(moved)
        #expect(nutrition.entries.first { $0.id == moved.id }?.amountChanged == nil)
    }

    @Test func repeatingACorrectedDatabaseFoodKeepsItsMarkAndNutrients() throws {
        let nutrition = try store()
        let bar = Food(id: "off:0012345678905", name: "Synthetic oat bar", source: .openFoodFacts,
                       per100g: NutrientAmounts([.energy: 412, .protein: 9.5]), servings: [Serving("1 bar", grams: 40)])
        let entry = try nutrition.log(bar, grams: 40, on: monday, meal: "Snacks")
        let corrected = entry.editingNutrients(NutrientAmounts([.energy: 150]))
        try nutrition.saveEntry(corrected)
        let recent = try #require(nutrition.recentPortions().first)
        #expect(recent.food.edited == true && recent.food.per100g[.energy] == 375 && recent.grams == 40)
        // A fresh database label differs from the correction, so it is not marked edited.
        let fresh = try #require(nutrition.quickPortion(for: bar))
        #expect(fresh.food.edited == nil && fresh.food.per100g[.energy] == 412 && fresh.grams == 40)
    }

    @Test func recentPortionsSkipQuickAddsWholePortionsAndArchivedFoods() throws {
        let nutrition = try store()
        try nutrition.saveFood(Foods.milk)
        try nutrition.log(Foods.milk, grams: 244, on: monday, meal: "Breakfast")
        try nutrition.log(Foods.chicken, grams: 150, on: monday, meal: "Lunch")
        try nutrition.quickAdd(NutrientAmounts([.energy: 500]), on: monday, meal: "Dinner")
        try nutrition.archiveFood(Foods.milk.id)
        let recent = nutrition.recentPortions()
        #expect(recent.map(\.food.name) == ["Chicken breast"])
        #expect(recent.first?.grams == 150)
    }

    @Test func loggingAPortionRecordsExactlyWhatItShows() throws {
        let nutrition = try store()
        let portion = try #require(nutrition.quickPortion(for: Foods.oats))
        let entry = try nutrition.log(portion, on: monday, meal: "Snacks")
        #expect(entry.meal == "Snacks" && entry.date == monday && entry.grams == 40 && entry.quantity == 1)
        #expect(entry.food == Foods.oats.snapshot && entry.loggedAt == Fixture.instant())
        #expect(entry.nutrients == portion.nutrients)
        #expect(nutrition.entries(on: monday) == [entry])
    }

    @Test func aHiddenFoodIsNoLongerSuggestedUntilItIsLetBack() throws {
        let persistence = InMemoryTrainingPersistence()
        let nutrition = try store(persistence)
        let next = LocalDate("2026-10-06")!
        for days in 0...2 {
            try nutrition.log(Foods.oats, grams: 40, on: monday.adding(days: -days), meal: "Breakfast", at: Fixture.instant(days: -Double(days)))
            try nutrition.log(Foods.milk, grams: 200, on: monday.adding(days: -days), meal: "Breakfast",
                              at: Fixture.instant(days: -Double(days), minutes: 5))
        }
        let porridge = Food.recipe(name: "Synthetic porridge", ingredients: [
            RecipeIngredient(food: Foods.oats.snapshot, grams: 40), RecipeIngredient(food: Foods.milk.snapshot, grams: 200)
        ], servingCount: 1)
        try nutrition.saveFood(porridge)
        let tomorrow = Fixture.instant(days: 1)
        #expect(nutrition.suggestions(at: tomorrow, timeZone: Fixture.utc).map(\.food.name) == ["Milk", "Rolled oats"])
        #expect(nutrition.recipes(for: "Breakfast", through: next).map(\.id) == [porridge.id])

        try nutrition.hideSuggestion(Foods.milk.snapshot)
        try nutrition.hideSuggestion(porridge.snapshot)
        #expect(nutrition.suggestions(at: tomorrow, timeZone: Fixture.utc).map(\.food.name) == ["Rolled oats"])
        #expect(nutrition.recipes(for: "Breakfast", through: next).isEmpty)
        #expect(nutrition.recentPortions().map(\.food.name).contains("Milk"), "Recent still has it: it was eaten")
        #expect(nutrition.hiddenSuggestions.map(\.name).sorted() == ["Milk", "Synthetic porridge"])

        // Kept on the device, and synced like any document.
        let reopened = try store(persistence)
        #expect(reopened.isHiddenSuggestion(Foods.milk.id) && reopened.documentKinds.contains("hidden_suggestion"))
        let payload = try #require(try reopened.payload(kind: "hidden_suggestion", id: Foods.milk.id))
        try reopened.validate(kind: "hidden_suggestion", id: Foods.milk.id, payload: payload)
        #expect(throws: DocumentError.self) { try reopened.validate(kind: "hidden_suggestion", id: "another", payload: payload) }

        try reopened.restoreSuggestion(Foods.milk.id)
        #expect(reopened.suggestions(at: tomorrow, timeZone: Fixture.utc).map(\.food.name) == ["Milk", "Rolled oats"])
        #expect(throws: NutritionStore.StoreError.notFound) { try reopened.restoreSuggestion(Foods.milk.id) }
        #expect(try store(persistence).hiddenSuggestions.map(\.id) == [porridge.id])
    }

    @Test func aSuggestionBecomesTheSamePortion() {
        let suggestion = FoodSuggestion(food: Foods.milk.snapshot, meal: "Breakfast", grams: 244,
                                        serving: Foods.milk.servings[0], quantity: 1, days: 3)
        let portion = QuickPortion(suggestion)
        #expect(portion.repeated && portion.grams == 244 && portion.serving == Foods.milk.servings[0] && portion.id == Foods.milk.id)
    }

    @Test func macroEnergySharesUseAtwaterFactorsAndIgnoreUnknowns() {
        let shares = NutrientAmounts([.protein: 10, .carbohydrate: 10, .fat: 80.0 / 9]).macroEnergyShares
        #expect(close(shares[.protein], 0.25) && close(shares[.carbohydrate], 0.25) && close(shares[.fat], 0.5))
        #expect(NutrientAmounts([.energy: 100]).macroEnergyShares.isEmpty)
        #expect(NutrientAmounts([.protein: 0, .fat: 0]).macroEnergyShares.isEmpty)
    }
}
