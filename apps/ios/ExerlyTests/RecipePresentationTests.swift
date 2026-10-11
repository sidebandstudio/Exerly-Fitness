import ExerlyCore
import XCTest
@testable import Exerly

@MainActor
final class RecipePresentationTests: XCTestCase {
    let oats = ExerlyCore.Food(name: "Synthetic oats", per100g: NutrientAmounts([.energy: 380, .protein: 13]),
                               servings: [Serving("1/2 cup", grams: 40)])
    let milk = ExerlyCore.Food(name: "Synthetic milk", per100g: NutrientAmounts([.energy: 60]))

    func testANewRecipeAddsFoodsAtTheirTapPortionAndTakesTheCookedWeightInOunces() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let draft = RecipeDraft(store: store, unit: .pounds)
        XCTAssertFalse(draft.hasChanges)
        XCTAssertFalse(draft.canSave)
        XCTAssertTrue(draft.add(oats))
        XCTAssertTrue(draft.add(milk))
        XCTAssertEqual(draft.rows.first?.ingredient.serving, Serving("1/2 cup", grams: 40), "A food's first serving, as one tap logs it")
        XCTAssertEqual(draft.rows.last?.ingredient.serving?.name, "oz")
        XCTAssertTrue(draft.hasChanges)

        draft.cookedWeight.text = "8"
        draft.servings.text = "2"
        let recipe = try XCTUnwrap(draft.preview)
        XCTAssertEqual(try XCTUnwrap(recipe.yieldGrams), USUnits.grams(ounces: 8), accuracy: 1e-9)
        XCTAssertEqual(recipe.recipeServing?.grams ?? 0, USUnits.grams(ounces: 4), accuracy: 1e-9)
        draft.cookedWeight.text = "eight"
        XCTAssertNil(draft.preview, "An unreadable weight shows no totals rather than wrong ones")
        draft.cookedWeight.text = ""
        XCTAssertNil(try XCTUnwrap(draft.preview).yieldGrams)

        draft.name = "  Synthetic porridge "
        XCTAssertTrue(draft.canSave)
        let saved = try XCTUnwrap(draft.save())
        XCTAssertEqual(saved.name, "Synthetic porridge")
        XCTAssertEqual(store.food(saved.id)?.source, .recipe)
        XCTAssertFalse(draft.add(saved), "A recipe can't include itself")
    }

    func testAnIngredientLeftAtItsDefaultMustBeCheckedBeforeSaving() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let onion = ExerlyCore.Food(name: "Synthetic onion", per100g: NutrientAmounts([.energy: 40]),
                                    servings: [Serving("1 slice", grams: 15), Serving("1 whole", grams: 148)])
        let draft = RecipeDraft(store: store, unit: .kilograms)
        draft.name = "Synthetic chili"
        let chosen = try NutritionStore.preview(oats, grams: 500)
        XCTAssertTrue(draft.add(oats, amount: .chosen(chosen, oats.snapshot)))
        XCTAssertEqual(draft.rows.first?.ingredient.grams, 500, "The amount chosen in the portion step")
        XCTAssertTrue(draft.add(onion, amount: .unchecked))
        XCTAssertEqual(draft.rows.last?.ingredient.serving?.name, "1 slice", "Its default, the first serving")
        XCTAssertEqual(draft.rows.last?.food?.servings.count, 2, "With every serving, for the portion step")
        let unchecked = try XCTUnwrap(draft.unchecked)
        XCTAssertNil(draft.save())
        XCTAssertEqual(draft.errors, ["Check the amount of Synthetic onion before saving. It came in at a default."])
        XCTAssertNil(store.food(draft.preview?.id ?? ""))
        // Looking at it, even without a change, checks it.
        draft.update(unchecked.id, to: try NutritionStore.preview(onion, serving: onion.servings[1], quantity: 1), food: onion.snapshot)
        XCTAssertNil(draft.unchecked)
        XCTAssertNotNil(draft.save())
    }

    func testEditingKeepsTheSavedRecipesIdentityAndRefusesAStaleDraft() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        var recipe = ExerlyCore.Food.recipe(name: "Synthetic porridge", ingredients: [RecipeIngredient(food: oats.snapshot, grams: 80)],
                                            yieldGrams: 200, servingCount: 2)
        recipe.favorite = true
        try store.saveFood(recipe)
        let draft = RecipeDraft(store: store, unit: .pounds, editing: recipe)
        XCTAssertFalse(draft.hasChanges, "Opening in ounces doesn't round the saved cooked weight")
        XCTAssertEqual(draft.preview?.yieldGrams, 200)
        let row = try XCTUnwrap(draft.rows.first)
        draft.update(row.id, to: try NutritionStore.preview(oats, serving: oats.servings[0], quantity: 3), food: oats.snapshot)
        XCTAssertEqual(draft.rows.first?.ingredient.quantity, 3)
        XCTAssertTrue(draft.hasChanges)

        var elsewhere = recipe
        elsewhere.preparation = "Changed on another device"
        try store.saveFood(elsewhere)
        XCTAssertNil(draft.save())
        XCTAssertEqual(store.food(recipe.id)?.preparation, "Changed on another device")

        let fresh = RecipeDraft(store: store, unit: .kilograms, editing: elsewhere)
        fresh.remove(try XCTUnwrap(fresh.rows.first).id)
        XCTAssertFalse(fresh.canSave)
        XCTAssertTrue(fresh.add(milk))
        let saved = try XCTUnwrap(fresh.save())
        XCTAssertEqual(saved.id, recipe.id)
        XCTAssertTrue(saved.favorite)
        XCTAssertEqual(saved.ingredients?.map(\.food.name), ["Synthetic milk"])
    }

    func testAnImportedRecipeFillsTheDraftAndSavesOnlyOnceEachLineIsResolved() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let page = WebRecipe(name: "Synthetic porridge", ingredients: ["80 g synthetic oats", "Synthetic milk", "1 pinch saffron"],
                             servings: 2, instructions: "1. Simmer.", url: "https://recipes.example/porridge")
        let imported = RecipeImport(page: page, own: [oats, milk], database: [nil, nil, nil], unit: .kilograms)
        let draft = RecipeDraft(store: store, unit: .kilograms, imported: imported)
        XCTAssertEqual(draft.name, "Synthetic porridge")
        XCTAssertEqual(draft.rows.map(\.ingredient.grams), [80, 100], "Milk had no amount: its default")
        XCTAssertEqual(draft.rows.map(\.checked), [true, false], "A guessed amount is marked to check")
        XCTAssertEqual(draft.rows.first?.line, "80 g synthetic oats")
        XCTAssertEqual(draft.unmatched, ["1 pinch saffron"])
        XCTAssertEqual(draft.servings.text, "2")
        XCTAssertEqual(draft.preparation, "1. Simmer.")
        XCTAssertTrue(draft.hasChanges)

        XCTAssertNil(draft.save())
        XCTAssertEqual(draft.errors, ["Search for \u{201C}1 pinch saffron\u{201D} or skip it before saving."])
        XCTAssertTrue(store.foods.isEmpty, "Nothing saved before review")
        draft.settle("1 pinch saffron")
        XCTAssertNil(draft.save(), "The milk's amount still to check")
        let milkRow = try XCTUnwrap(draft.unchecked)
        draft.update(milkRow.id, to: try NutritionStore.preview(milk, grams: 250), food: milk.snapshot)
        let saved = try XCTUnwrap(draft.save())
        XCTAssertEqual(saved.sourceURL, "https://recipes.example/porridge", "Kept to credit the page")
        XCTAssertEqual(saved.servingCount, 2)
        XCTAssertEqual(store.food(saved.id)?.sourceURL, "https://recipes.example/porridge")
    }

    func testImportingIntoANamedRecipeKeepsItsNameAndAddsAfterItsIngredients() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let draft = RecipeDraft(store: store, unit: .kilograms)
        draft.name = "My porridge"
        XCTAssertTrue(draft.add(oats))
        draft.apply(RecipeImport(name: "Their porridge", ingredients: [RecipeImport.Ingredient(ingredient: RecipeIngredient(food: milk.snapshot, grams: 200))]))
        XCTAssertEqual(draft.name, "My porridge")
        XCTAssertEqual(draft.rows.map(\.ingredient.food.name), ["Synthetic oats", "Synthetic milk"])
    }

    func testAPastedLinkIsFoundAloneOrInAMessage() {
        XCTAssertEqual(RecipeImportView.webLink(in: " https://recipes.example/chili?x=1 "), "https://recipes.example/chili?x=1")
        XCTAssertEqual(RecipeImportView.webLink(in: "recipes.example/chili"), "https://recipes.example/chili")
        XCTAssertEqual(RecipeImportView.webLink(in: "Try this one: https://recipes.example/chili, it's great"), "https://recipes.example/chili")
        XCTAssertNil(RecipeImportView.webLink(in: "ftp://recipes.example/chili"))
        XCTAssertNil(RecipeImportView.webLink(in: "chili"))
        XCTAssertNil(RecipeImportView.webLink(in: ""))
    }

    func testASharedRecipeSummarySaysWhatItIsAndHowToOpenIt() throws {
        var recipe = ExerlyCore.Food.recipe(name: "Synthetic porridge", ingredients: [RecipeIngredient(food: oats.snapshot, grams: 80)],
                                            servingCount: 2, preparation: "Simmer.")
        recipe.sourceURL = "https://recipes.example/porridge"
        let summary = RecipeShareItem.summary(recipe, unit: .kilograms)
        XCTAssertTrue(summary.hasPrefix("Synthetic porridge\nMakes 2 servings, each 152 kcal, 5.2 g protein"), summary)
        XCTAssertTrue(summary.contains("\u{2022} Synthetic oats, 80 g"), summary)
        XCTAssertTrue(summary.contains("Preparation\nSimmer.") && summary.contains("Source: https://recipes.example/porridge"), summary)
        XCTAssertTrue(summary.hasSuffix("Open the attached .exerlyrecipe file in Exerly to add a copy to your recipes."))
    }
}
