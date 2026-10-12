import ExerlyCore
import XCTest
@testable import Exerly

@MainActor
final class NutritionPresentationTests: XCTestCase {
    func testReopeningAVolumeEntryDoesNotOfferItsSyntheticUnitAsALabelPortion() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-07"))
        let scoop = Serving("Scoop", grams: 42.123456789)
        var food = ExerlyCore.Food(name: "Liquid", per100g: NutrientAmounts([.energy: 120]), servings: [scoop])
        food.volume = VolumeBasis(density: 0.92, assumed: true)
        try store.saveFood(food)
        let draft = NutritionEntryDraft(store: store, food: food, date: date, meal: "Lunch")
        XCTAssertTrue(draft.selectMeasure(.fluidOunces))
        draft.amount.text = "2.5"
        let entry = try XCTUnwrap(draft.save())
        let reopened = NutritionEntryDraft(store: store, food: entry.food.foodForLogging(serving: entry.serving),
                                          date: date, meal: "Lunch", editing: entry)
        // Its label's scoop, then a liquid's spoons and cups; never the synthetic fl oz.
        XCTAssertEqual(reopened.publishedServings, [scoop] + food.kitchenMeasures)
        XCTAssertEqual(food.kitchenMeasures.map(\.name), ["1 tbsp", "1 tsp", "1 cup"])
        XCTAssertEqual(reopened.measure, .fluidOunces)
        XCTAssertEqual(try reopened.preview().grams, entry.grams)
        XCTAssertFalse(reopened.selectPortion(try XCTUnwrap(entry.serving)))
        XCTAssertEqual(reopened.save(), entry)
    }

    func testDiaryPortionMatchesTheSearchRowInTheAccountUnit() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-07"))
        let banana = Serving("1 banana", grams: 126)
        let food = ExerlyCore.Food(name: "Banana, raw", per100g: NutrientAmounts([.energy: 97]), servings: [banana])
        let one = try store.log(food, serving: banana, quantity: 1, on: date, meal: "Snacks")
        XCTAssertEqual(NutritionFormat.portion(one, unit: .pounds), "1 banana · 4.4 oz")
        XCTAssertEqual(NutritionFormat.portion(one, unit: .kilograms), "1 banana · 126 g")
        let portion = QuickPortion(food: one.food, grams: one.grams, serving: one.serving, quantity: one.quantity, repeated: true)
        XCTAssertEqual(NutritionFormat.portion(one, unit: .pounds), FoodFormat.portion(portion, unit: .pounds))
        let two = try store.log(food, serving: banana, quantity: 2, on: date, meal: "Snacks")
        XCTAssertEqual(NutritionFormat.portion(two, unit: .kilograms), "2 × 1 banana · 252 g")
        let half = try store.log(food, serving: banana, quantity: 0.5, on: date, meal: "Snacks")
        XCTAssertEqual(NutritionFormat.portion(half, unit: .kilograms), "0.5 banana · 63 g", "Not 0.5 × 1 banana")
        let recipe = Serving("1 serving", grams: 298)
        let stew = ExerlyCore.Food(name: "Beef chili", per100g: NutrientAmounts([.energy: 128]), servings: [recipe])
        let bowl = try store.log(stew, serving: recipe, quantity: 0.5, on: date, meal: "Dinner")
        XCTAssertEqual(NutritionFormat.portion(bowl, unit: .pounds), "0.5 serving · 5.3 oz")
        let pot = try store.log(stew, serving: recipe, quantity: 2, on: date, meal: "Dinner")
        XCTAssertEqual(NutritionFormat.portion(pot, unit: .kilograms), "2 servings · 596 g")
        let weighed = try store.log(food, grams: 150, on: date, meal: "Snacks")
        XCTAssertEqual(NutritionFormat.portion(weighed, unit: .pounds), "150 g")
    }

    func testANamedServingStartsAtOneOnlyWhileTheAmountIsADefault() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-10"))
        let onion = ExerlyCore.Food(name: "Synthetic onion", per100g: NutrientAmounts([.energy: 40]),
                                    servings: [Serving("1 slice", grams: 15), Serving("1 whole", grams: 148)])
        let draft = NutritionEntryDraft(store: store, food: onion, date: date, meal: "Dinner", preferredUnit: .kilograms)
        XCTAssertTrue(draft.amountIsDefault)
        XCTAssertTrue(draft.selectMeasure(.grams))
        XCTAssertTrue(draft.amountIsDefault, "Converting the default leaves it a default")
        draft.amount.text = "100"
        XCTAssertFalse(draft.amountIsDefault, "An amount the person entered")
        let logged = try store.log(onion, grams: 50, on: date, meal: "Dinner")
        let again = NutritionEntryDraft(store: store, food: onion, date: date, meal: "Dinner", repeating: logged, preferredUnit: .kilograms)
        XCTAssertFalse(again.amountIsDefault, "An amount logged before isn't a default")
    }

    func testAServingAddedInThePortionStepIsSavedWithThePersonsFoodAtTheCountTyped() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-10"))
        let eggs = ExerlyCore.Food(name: "Eggs, scrambled", per100g: NutrientAmounts([.energy: 149]))
        try store.saveFood(eggs)
        let draft = NutritionEntryDraft(store: store, food: eggs, date: date, meal: "Breakfast", preferredUnit: .pounds)
        XCTAssertTrue(draft.canAddServing)
        XCTAssertFalse(draft.addServing(named: "egg", grams: "none", count: 2))
        XCTAssertEqual(draft.errors, ["Enter the serving's weight in grams."])
        XCTAssertTrue(draft.addServing(named: "egg", grams: "50", count: 2))
        let egg = Serving("1 egg", grams: 50)
        XCTAssertEqual(store.food(eggs.id)?.servings, [egg], "Saved with the food; a name without a count is one")
        XCTAssertEqual(draft.measure, .serving(egg))
        XCTAssertEqual(draft.amount.text, "2", "The count typed with the food")
        XCTAssertEqual(try draft.preview().grams, 100)
        XCTAssertFalse(draft.canAddServing, "It has one now")
        let entry = try XCTUnwrap(draft.save())
        XCTAssertEqual(entry.serving, egg)
        XCTAssertEqual(entry.quantity, 2)
        // Database foods and foods never saved aren't the person's to change.
        let banana = ExerlyCore.Food(id: "usda:2709224", name: "Banana, raw", source: .usda, per100g: NutrientAmounts([.energy: 97]))
        try store.saveFood(banana)
        XCTAssertFalse(NutritionEntryDraft(store: store, food: banana, date: date, meal: "Snacks").canAddServing)
        let unsaved = ExerlyCore.Food(name: "Synthetic toast", per100g: NutrientAmounts([.energy: 252]))
        XCTAssertFalse(NutritionEntryDraft(store: store, food: unsaved, date: date, meal: "Snacks").canAddServing)
    }

    func testExplicitLabelPortionReplacesInvalidInputAndPersistsWithoutChangingTheDefault() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = UUID().uuidString
        let workspace = try TrainingWorkspace(accountID: account, root: root)
        let serving = Serving("1/2 cup", grams: 37.123456789)
        let food = ExerlyCore.Food(name: "Label cereal", per100g: NutrientAmounts([.energy: 380, .fat: 0]), servings: [serving])
        let date = try XCTUnwrap(LocalDate("2026-10-07"))
        let draft = NutritionEntryDraft(store: workspace.nutrition, food: food, date: date, meal: "Breakfast")
        XCTAssertEqual(draft.measure, .serving(serving), "A food with a label portion starts on one of it")
        XCTAssertEqual(draft.amount.text, "1")
        XCTAssertTrue(draft.selectMeasure(.ounces))
        draft.amount.text = "not a number"
        XCTAssertTrue(draft.selectPortion(serving))
        XCTAssertEqual(draft.amount.text, "1", "One published half-cup serving is not half of that serving")
        XCTAssertEqual(try draft.preview().grams, serving.grams)
        XCTAssertTrue(workspace.nutrition.entries.isEmpty, "Choosing a portion never writes to the diary")
        let saved = try XCTUnwrap(draft.save())
        XCTAssertEqual(saved.serving, serving)
        XCTAssertEqual(saved.quantity, 1)
        XCTAssertNil(saved.nutrients[.protein])
        XCTAssertEqual(saved.nutrients[.fat], 0)
        await workspace.close()
        let reopened = try TrainingWorkspace(accountID: account, root: root)
        XCTAssertEqual(reopened.nutrition.entries.first, saved)
        let repeated = NutritionEntryDraft(store: reopened.nutrition, food: food, date: date, meal: "Breakfast", repeating: saved)
        XCTAssertEqual(repeated.measure, .serving(serving))
        XCTAssertEqual(try repeated.preview().grams, saved.grams)
        await reopened.close()
    }

    func testExplicitPortionKeepsEditedEntryNutritionAndRejectsAnUnpublishedChoice() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-07"))
        let serving = Serving("1 bar", grams: 45.123456789)
        var food = ExerlyCore.Food(name: "Original bar", per100g: NutrientAmounts([.energy: 300, .sodium: 0]), servings: [serving])
        try store.saveFood(food)
        let original = try store.log(food, grams: 20, on: date, meal: "Snacks")
        let corrected = original.editingNutrients(NutrientAmounts([.energy: 80, .sodium: 0]))
        try store.saveEntry(corrected)
        food.per100g = NutrientAmounts([.energy: 900, .protein: 70])
        try store.saveFood(food)
        let draft = NutritionEntryDraft(store: store, food: food, date: date, meal: "Snacks", editing: corrected)
        XCTAssertTrue(draft.selectPortion(serving))
        let expected = try NutritionStore.preview(corrected.food.foodForLogging(serving: serving), serving: serving, quantity: 1)
        XCTAssertEqual(try draft.preview().nutrients, expected.nutrients)
        XCTAssertFalse(draft.selectPortion(Serving("Unpublished", grams: 200)))
        XCTAssertEqual(try draft.preview().grams, serving.grams)
        XCTAssertEqual(store.entries.first, corrected, "A draft must not rewrite an existing entry")
        let saved = try XCTUnwrap(draft.save())
        XCTAssertEqual(saved.food, corrected.food)
        XCTAssertEqual(saved.nutrients, expected.nutrients)
        XCTAssertEqual(store.entries.count, 1)
    }

    func testRecipePortionUsesThePublishedYieldAndWholePortionEntriesHaveNoChoices() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-07"))
        let ingredient = ExerlyCore.Food(name: "Ingredient", per100g: NutrientAmounts([.energy: 120]))
        let recipe = ExerlyCore.Food.recipe(name: "Recipe", ingredients: [RecipeIngredient(food: ingredient.snapshot, grams: 800)],
                                           yieldGrams: 713.123456789, servingCount: 3)
        let draft = NutritionEntryDraft(store: store, food: recipe, date: date, meal: "Dinner")
        let serving = try XCTUnwrap(recipe.recipeServing)
        let pot = try XCTUnwrap(recipe.recipeWhole)
        XCTAssertEqual(draft.publishedServings, [serving, pot], "One serving, or a share of the whole recipe")
        XCTAssertTrue(draft.selectPortion(serving))
        XCTAssertEqual(try draft.preview().grams, serving.grams)
        XCTAssertTrue(draft.selectMeasure(.serving(pot)))
        XCTAssertEqual(draft.amount.text, TrainingFormat.number(1.0 / 3), "A third of the pot is the same serving")
        let quick = try store.quickAdd(NutrientAmounts([.energy: 500]), on: date, meal: "Dinner")
        let whole = NutritionEntryDraft(store: store, food: quick.food.foodForLogging(), date: date, meal: "Dinner", editing: quick)
        XCTAssertTrue(whole.publishedServings.isEmpty)
        XCTAssertFalse(whole.selectPortion(serving))
        XCTAssertEqual(store.entries, [quick])
    }

    func testUnweighedEntryCorrectionKeepsWholePortionAndNeverCreatesALibraryFood() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-07"))
        let original = try store.quickAdd(NutrientAmounts([.energy: 351.25, .protein: 12.3456789, .sodium: 0]),
                                          name: "Unweighed meal", on: date, meal: "Lunch")
        XCTAssertEqual(NutritionFormat.portion(original, unit: .kilograms), "Whole portion")
        let draft = NutritionEntryDraft(store: store, food: original.food.foodForLogging(), date: date, meal: "Lunch", editing: original)
        let reviewed = try XCTUnwrap(draft.reviewNutrition())
        let correction = reviewed.editingNutrients(NutrientAmounts([.energy: 352.5, .fat: 0, .sodium: 0]))
        try draft.applyNutrition(correction, reviewed: reviewed)
        let saved = try XCTUnwrap(draft.save())
        XCTAssertEqual(saved.food.unweighed, true)
        XCTAssertEqual(saved.grams, original.grams)
        XCTAssertEqual(saved.nutrients[.energy], 352.5)
        XCTAssertEqual(saved.nutrients[.fat], 0)
        XCTAssertNil(saved.nutrients[.protein])
        XCTAssertEqual(NutritionFormat.portion(saved, unit: .kilograms), "Whole portion")
        XCTAssertTrue(store.foods.isEmpty)
    }

    func testNewFoodPortionsUseUSUnitsUnlessTheAccountExplicitlyUsesMetric() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-07"))
        let food = ExerlyCore.Food(name: "Synthetic food", per100g: NutrientAmounts([.energy: 100, .sodium: 0]))
        // A new food opens on what one tap on its row logs: 4 oz in U.S. units.
        let us = NutritionEntryDraft(store: store, food: food, date: date, meal: "Lunch")
        XCTAssertEqual(us.measure, .ounces)
        XCTAssertEqual(us.amount.text, "4")
        XCTAssertEqual(try us.preview().grams, try XCTUnwrap(store.quickPortion(for: food, unit: .pounds)).grams)
        let entry = try XCTUnwrap(us.save())
        XCTAssertEqual(entry.grams, USUnits.grams(ounces: 4), accuracy: 1e-9)
        XCTAssertEqual(entry.serving?.name, "oz")
        XCTAssertEqual(entry.quantity, 4)
        XCTAssertFalse(us.availableMeasures.contains(.fluidOunces), "No density means no volume conversion")
        let metric = NutritionEntryDraft(store: store, food: food, date: date, meal: "Lunch", preferredUnit: .kilograms)
        XCTAssertEqual(metric.measure, .grams)
        XCTAssertEqual(metric.amount.text, "100")
        var liquid = food
        liquid.volume = VolumeBasis(density: 0.92, assumed: false)
        let usLiquid = NutritionEntryDraft(store: store, food: liquid, date: date, meal: "Lunch", preferredUnit: .pounds)
        XCTAssertEqual(usLiquid.measure, .fluidOunces)
        XCTAssertEqual(usLiquid.amount.text, "8")
        XCTAssertEqual(try usLiquid.preview().grams, try XCTUnwrap(liquid.grams(milliliters: USUnits.milliliters(fluidOunces: 8))), accuracy: 1e-9)
        let metricLiquid = NutritionEntryDraft(store: store, food: liquid, date: date, meal: "Lunch", preferredUnit: .kilograms)
        XCTAssertEqual(metricLiquid.measure, .milliliters)
        XCTAssertEqual(metricLiquid.amount.text, "100")
        // A food with a label serving opens on one of it, in either unit system.
        var bar = food
        bar.servings = [Serving("1 bar (40 g)", grams: 40)]
        for unit in [MassUnit.pounds, .kilograms] {
            let draft = NutritionEntryDraft(store: store, food: bar, date: date, meal: "Lunch", preferredUnit: unit)
            XCTAssertEqual(draft.measure, .serving(Serving("1 bar (40 g)", grams: 40)))
            XCTAssertEqual(draft.amount.text, "1")
            XCTAssertEqual(try draft.preview().grams, 40)
        }
    }

    func testRepeatedMeasureSwitchingRetainsExactWeightAndOriginalNutrition() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-07"))
        let cup = Serving("Cup", grams: 42.123456789)
        let food = ExerlyCore.Food(name: "Precise cereal", per100g: NutrientAmounts([.energy: 380.123456789, .sodium: 0]), servings: [cup])
        try store.saveFood(food)
        let original = try store.log(food, grams: 45.123456789, on: date, meal: "Lunch")
        let draft = NutritionEntryDraft(store: store, food: food, date: date, meal: "Lunch", editing: original, preferredUnit: .pounds)
        XCTAssertEqual(draft.measure, .grams, "An existing explicit gram portion stays in grams")
        for _ in 0..<20 {
            for measure in [NutritionPortionMeasure.ounces, .serving(cup), .grams] {
                XCTAssertTrue(draft.selectMeasure(measure))
                let preview = try draft.preview()
                XCTAssertEqual(preview.grams, original.grams)
                XCTAssertEqual(preview.nutrients, original.nutrients)
                XCTAssertNil(preview.nutrients[.protein])
            }
        }
        XCTAssertFalse(draft.hasChanges)
        XCTAssertEqual(draft.save(), original)
        XCTAssertTrue(draft.selectMeasure(.ounces))
        draft.amount.text = "2.5"
        XCTAssertTrue(draft.selectMeasure(.grams))
        XCTAssertEqual(try draft.preview().grams, USUnits.grams(ounces: 2.5))
    }

    func testFluidOuncesKeepTheirDensityAndCanBeReopenedInTheSavedMeasure() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-07"))
        var liquid = ExerlyCore.Food(name: "Synthetic liquid", source: .openFoodFacts, per100g: NutrientAmounts([.energy: 80, .fat: 0]))
        liquid.volume = VolumeBasis(density: 1.04, assumed: true, note: "Test density")
        let draft = NutritionEntryDraft(store: store, food: liquid, date: date, meal: "Lunch", preferredUnit: .pounds)
        draft.amount.text = "2,5"
        let saved = try XCTUnwrap(draft.save(locale: Locale(identifier: "de_DE")))
        XCTAssertEqual(saved.grams, liquid.grams(milliliters: USUnits.milliliters(fluidOunces: 2.5))!, accuracy: 0.000_000_001)
        XCTAssertEqual(saved.quantity, 2.5)
        XCTAssertEqual(saved.food.volume, liquid.volume)
        let reopened = NutritionEntryDraft(store: store, food: liquid, date: date, meal: "Lunch", editing: saved, preferredUnit: .kilograms)
        XCTAssertEqual(reopened.measure, .fluidOunces, "Saved explicit units survive a preference change")
        XCTAssertTrue(reopened.selectMeasure(.milliliters))
        XCTAssertEqual(try reopened.preview().grams, saved.grams)
        XCTAssertTrue(reopened.selectMeasure(.fluidOunces))
        XCTAssertEqual(reopened.save(), saved)
        XCTAssertEqual(NutritionFormat.portion(saved, unit: .kilograms), "2.5 fl oz")
    }

    func testUnitSwitchingPreservesMissingQuantityAndRejectsInvalidDraftsWithoutLosingInput() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-07"))
        let serving = Serving("Scoop", grams: 37.123456789)
        let food = ExerlyCore.Food(name: "Imported food", per100g: NutrientAmounts([.energy: 100]), servings: [serving])
        let original = FoodEntry(date: date, meal: "Lunch", loggedAt: Date().roundedToMilliseconds, food: food.snapshot,
                                 grams: 45.123456789, serving: serving, quantity: nil)
        try store.saveEntry(original)
        let draft = NutritionEntryDraft(store: store, food: food, date: date, meal: "Lunch", editing: original, preferredUnit: .pounds)
        XCTAssertTrue(draft.selectMeasure(.grams))
        XCTAssertTrue(draft.selectMeasure(.serving(serving)))
        XCTAssertFalse(draft.hasChanges)
        XCTAssertEqual(draft.save(), original)
        for text in ["", "bad", "-1", "1e999"] {
            draft.amount.text = text
            XCTAssertFalse(draft.selectMeasure(.ounces))
            XCTAssertEqual(draft.amount.text, text)
            XCTAssertEqual(draft.measure, .serving(serving))
            XCTAssertEqual(store.entries.first, original)
        }
        draft.amount.text = "1"
        XCTAssertFalse(draft.selectMeasure(.fluidOunces))
        XCTAssertEqual(draft.amount.text, "1")
    }

    func testEntryCorrectionStaysInTheDraftAndPreservesTheLibrarySourceAndOtherEntries() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-07"))
        let food = ExerlyCore.Food(id: "usda:2709224", name: "Measured banana", source: .usda,
                                   per100g: NutrientAmounts([.energy: 89.123456789, .protein: 1.23456789, .sodium: 0]))
        try store.saveFood(food)
        let original = try store.log(food, grams: 45.123456789, on: date, meal: "Breakfast")
        let other = try store.log(food, grams: 90, on: date, meal: "Lunch")
        let draft = NutritionEntryDraft(store: store, food: food, date: date, meal: original.meal, editing: original)
        let reviewed = try XCTUnwrap(draft.reviewNutrition())
        let correction = NutritionEntryNutrientsDraft(entry: reviewed)
        correction.fields[.energy]?.text = "100,25"
        correction.fields[.protein]?.text = ""
        let corrected = try correction.correctedEntry(locale: Locale(identifier: "de_DE"))
        try draft.applyNutrition(corrected, reviewed: reviewed)
        XCTAssertTrue(draft.hasChanges)
        XCTAssertEqual(store.entries.first(where: { $0.id == original.id }), original, "Apply must not write before the entry's Save")
        let saved = try XCTUnwrap(draft.save())
        XCTAssertEqual(saved.id, original.id)
        XCTAssertEqual(saved.food.source, .usda)
        XCTAssertEqual(saved.food.foodID, food.id)
        XCTAssertEqual(saved.food.edited, true)
        XCTAssertEqual(saved.grams, original.grams)
        XCTAssertEqual(saved.loggedAt, original.loggedAt)
        XCTAssertEqual(try XCTUnwrap(saved.nutrients[.energy]), 100.25, accuracy: 0.000_000_001)
        XCTAssertNil(saved.nutrients[.protein])
        XCTAssertEqual(saved.nutrients[.sodium], 0)
        XCTAssertEqual(store.food(food.id), food)
        XCTAssertEqual(store.entries.first(where: { $0.id == other.id }), other)

        let reopened = NutritionEntryDraft(store: store, food: food, date: date, meal: saved.meal, editing: saved)
        reopened.amount.text = "90.246913578"
        let doubled = try XCTUnwrap(reopened.save())
        XCTAssertEqual(try XCTUnwrap(doubled.nutrients[.energy]), 200.5, accuracy: 0.000_000_001)
        XCTAssertTrue(doubled.food.edited == true)
        XCTAssertNil(doubled.nutrients[.protein])
    }

    func testOpeningEntryNutritionWithoutChangesPreservesExactValuesAndOptionalQuantity() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-07"))
        let food = ExerlyCore.Food(name: "Precise label", per100g: NutrientAmounts([.energy: 380.123456789, .protein: 3.333333333]))
        let original = FoodEntry(date: date, meal: "Lunch", loggedAt: Date().roundedToMilliseconds,
                                 food: food.snapshot, grams: 37.123456789, serving: Serving("Scoop", grams: 37), quantity: nil)
        try store.saveEntry(original)
        let draft = NutritionEntryDraft(store: store, food: food, date: date, meal: original.meal, editing: original)
        let reviewed = try XCTUnwrap(draft.reviewNutrition())
        let correction = NutritionEntryNutrientsDraft(entry: reviewed)
        XCTAssertFalse(correction.hasChanges)
        try draft.applyNutrition(correction.correctedEntry(), reviewed: reviewed)
        XCTAssertFalse(draft.hasChanges)
        XCTAssertEqual(draft.save(), original)
        XCTAssertNil(draft.snapshot.edited)
    }

    func testEntryCorrectionRejectsBadNumbersAndChangedPortionsWithoutLosingInput() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-07"))
        let food = ExerlyCore.Food(name: "Test food", per100g: NutrientAmounts([.energy: 200]))
        let original = try store.log(food, grams: 75, on: date, meal: "Lunch")
        let draft = NutritionEntryDraft(store: store, food: food, date: date, meal: original.meal, editing: original)
        let reviewed = try XCTUnwrap(draft.reviewNutrition())
        let correction = NutritionEntryNutrientsDraft(entry: reviewed)
        for input in ["-1", "not a number", "1e999"] {
            correction.fields[.energy]?.text = input
            XCTAssertThrowsError(try correction.correctedEntry())
            XCTAssertEqual(correction.fields[.energy]?.text, input)
            XCTAssertEqual(store.entries.first, original)
        }
        correction.fields[.energy]?.text = "125"
        let corrected = try correction.correctedEntry()
        draft.amount.text = "100"
        XCTAssertThrowsError(try draft.applyNutrition(corrected, reviewed: reviewed))
        XCTAssertEqual(draft.snapshot, original.food)
        draft.amount.text = "75"
        let freshReview = try XCTUnwrap(draft.reviewNutrition())
        try draft.applyNutrition(corrected, reviewed: freshReview)
        var newer = original
        newer.meal = "Dinner"
        try store.saveEntry(newer)
        XCTAssertNil(draft.save(), "An entry changed by another writer still needs review")
        XCTAssertEqual(store.entries.first, newer)
        XCTAssertEqual(draft.snapshot.edited, true)
    }

    func testRepeatingACorrectedSnapshotKeepsItsMarkButALibraryLabelUsesItsOwnNutrients() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-07"))
        let food = ExerlyCore.Food(name: "Saved label", per100g: NutrientAmounts([.energy: 200]))
        let original = try store.log(food, grams: 50, on: date, meal: "Lunch")
        let corrected = original.editingNutrients(NutrientAmounts([.energy: 70]))
        try store.saveEntry(corrected)
        let recent = NutritionEntryDraft(store: store, food: corrected.food.foodForLogging(), date: date, meal: "Dinner", repeating: corrected)
        XCTAssertEqual(recent.save()?.food.edited, true)
        let library = NutritionEntryDraft(store: store, food: food, date: date, meal: "Dinner", repeating: corrected)
        let repeated = try XCTUnwrap(library.save())
        XCTAssertNil(repeated.food.edited)
        XCTAssertEqual(repeated.food.per100g, food.per100g)
        XCTAssertEqual(repeated.nutrients[.energy], 100)
    }

    func testEmptyDiaryShowsZeroLoggedButMissingLabelValuesStayUnknown() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-07"))
        func amount(_ nutrient: Nutrient) -> Double? {
            NutritionFormat.summaryAmount(nutrient, amounts: store.summary(on: date).totals, progress: store.progress(on: date))
        }
        for nutrient in [Nutrient.energy, .protein, .carbohydrate, .fat] { XCTAssertEqual(amount(nutrient), 0) }
        let food = ExerlyCore.Food(name: "Incomplete label", per100g: NutrientAmounts([.energy: 120, .fat: 0]))
        _ = try store.log(food, grams: 100, on: date, meal: "Lunch")
        XCTAssertEqual(amount(.energy), 120)
        XCTAssertEqual(amount(.fat), 0)
        XCTAssertNil(amount(.protein))
        XCTAssertNil(amount(.carbohydrate))
        XCTAssertNil(amount(.sodium))
    }

    func testWaterEntryUsesUSFluidOuncesAndRejectsInvalidOrUnboundedAmounts() {
        XCTAssertEqual(WaterDisplay.milliliters("8", imperial: true), 237)
        XCTAssertEqual(WaterDisplay.milliliters("12.5", imperial: true), 370)
        XCTAssertEqual(WaterDisplay.amount(237, imperial: true), "8 fl oz")
        XCTAssertEqual(WaterDisplay.amount(607, imperial: true), "20.5 fl oz")
        for text in ["", "0", "-1", "170", "nan", "1e999"] {
            XCTAssertNil(WaterDisplay.milliliters(text, imperial: true))
        }
        XCTAssertEqual(WaterDisplay.milliliters("250", imperial: false), 250)
        XCTAssertNil(WaterDisplay.milliliters("250.5", imperial: false))
        XCTAssertEqual(WaterDisplay.amount(250, imperial: false), "250 ml")
    }

    func testEditingAnEntryKeepsItsVolumeLabelAndEstimatedDensity() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-06"))
        var oil = ExerlyCore.Food(name: "Synthetic oil", source: .openFoodFacts,
                                 per100g: NutrientAmounts([.energy: 900]))
        oil.volume = VolumeBasis(density: 0.92, assumed: true, note: "Typical for oils")
        let entry = try store.log(oil, grams: 13.8, on: date, meal: "Dinner")
        let draft = NutritionEntryDraft(store: store, food: oil, date: date, meal: "Dinner", editing: entry)
        XCTAssertEqual(draft.food.volume, oil.volume)
        draft.amount.text = "27.6"
        let saved = try XCTUnwrap(draft.save())
        XCTAssertEqual(saved.food.volume, oil.volume)
        XCTAssertEqual(saved.food.per100g, entry.food.per100g)
        XCTAssertEqual(saved.grams, 27.6)
    }

    func testNutritionStaysInItsAccountAndClosedWorkspacesCannotWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstID = UUID().uuidString
        let first = try TrainingWorkspace(accountID: firstID, root: root)
        let date = try XCTUnwrap(LocalDate("2026-10-06"))
        let food = ExerlyCore.Food(name: "Account one oats", per100g: NutrientAmounts([.energy: 380]))
        try first.nutrition.saveFood(food)
        let entry = try first.nutrition.log(food, grams: 40, on: date, meal: "Breakfast")
        await first.close()
        XCTAssertThrowsError(try first.nutrition.saveFood(food))
        let second = try TrainingWorkspace(accountID: UUID().uuidString, root: root)
        XCTAssertTrue(second.nutrition.foods.isEmpty)
        XCTAssertTrue(second.nutrition.entries.isEmpty)
        let reopened = try TrainingWorkspace(accountID: firstID, root: root)
        XCTAssertEqual(reopened.nutrition.entries.first?.id, entry.id)
        XCTAssertEqual(reopened.nutrition.foods.first?.name, food.name)
        await reopened.close()
        try TrainingWorkspace.deleteStorage(accountID: firstID, root: root)
        let removed = try TrainingWorkspace(accountID: firstID, root: root)
        XCTAssertTrue(removed.nutrition.foods.isEmpty)
        XCTAssertTrue(removed.nutrition.entries.isEmpty)
        await removed.close()
        await second.close()
    }

    func testAccountExportIncludesOfflineFoodEntryAndDayNotes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = UUID().uuidString
        let first = try TrainingWorkspace(accountID: account, root: root)
        let source = try SQLiteTrainingPersistence(url: first.url)
        let nutrition = try NutritionStore(persistence: source)
        let date = try XCTUnwrap(LocalDate("2026-10-06"))
        let food = ExerlyCore.Food(name: "Synthetic oats", per100g: NutrientAmounts([.energy: 380, .protein: 12, .sodium: 0]))
        try nutrition.saveFood(food)
        let entry = try nutrition.log(food, grams: 42.123456789, on: date, meal: "Breakfast")
        try nutrition.setStatus(.partial, on: date)
        try nutrition.setNotes("Keep this offline note", on: date)
        source.close()
        await first.close()
        let reopened = try TrainingWorkspace(accountID: account, root: root)
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: reopened.export(server: nil)) as? [String: Any])
        let documents = try XCTUnwrap(exported["documents"] as? [[String: Any]])
        let foodRow = try XCTUnwrap(documents.first { $0["kind"] as? String == "saved_food" })
        XCTAssertEqual(foodRow["document_id"] as? String, food.id)
        let entryRow = try XCTUnwrap(documents.first { $0["kind"] as? String == "food_entry" })
        XCTAssertEqual(entryRow["document_id"] as? String, entry.id.uuidString)
        XCTAssertEqual(entryRow["pending_sync"] as? Bool, true)
        let payload = try XCTUnwrap(entryRow["payload"] as? [String: Any])
        XCTAssertEqual(payload["grams"] as? Double, 42.123456789)
        let day = try XCTUnwrap(documents.first { $0["kind"] as? String == "nutrition_day" }?["payload"] as? [String: Any])
        XCTAssertEqual(day["status"] as? String, "partial")
        XCTAssertEqual(day["notes"] as? String, "Keep this offline note")
        await reopened.close()
    }

    func testMealProposalUsesTheAccountHostAndUndoRemovesItsEntry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try TrainingWorkspace(accountID: UUID().uuidString, root: root)
        let date = try XCTUnwrap(LocalDate("2026-10-06"))
        let food = ExerlyCore.Food(name: "Synthetic apple", per100g: NutrientAmounts([.energy: 52, .fiber: 2.4]))
        let entry = FoodEntry(date: date, meal: "Snacks", loggedAt: Date(), food: food.snapshot, grams: 125)
        let proposal = try Proposal(author: AgentIdentity(kind: .mcp, name: "Synthetic meal agent"),
            title: "Review an apple", summary: "Confirm the food and amount before logging.",
            changes: [ProposedChange(kind: "food_entry", id: entry.id.uuidString, before: Optional<FoodEntry>.none, after: entry)],
            evidence: [], confidence: .low, falsifier: "The food or amount is different from what you ate.")
        XCTAssertTrue(workspace.supportsChanges(in: proposal))
        try workspace.agent.file(proposal)
        try workspace.agent.accept(proposal.id)
        let accepted = try XCTUnwrap(JSONSerialization.jsonObject(with: workspace.export(server: nil)) as? [String: Any])
        let records = try XCTUnwrap(accepted["documents"] as? [[String: Any]])
        XCTAssertTrue(records.contains { $0["kind"] as? String == "food_entry" && $0["document_id"] as? String == entry.id.uuidString })
        try workspace.agent.undo(proposal.id)
        XCTAssertEqual(workspace.agent.proposal(proposal.id)?.status, .undone)
        let source = try SQLiteTrainingPersistence(url: workspace.url)
        XCTAssertTrue(try NutritionStore(persistence: source).entries.isEmpty)
        source.close()
        await workspace.close()
    }

    func testEditingFoodMetadataKeepsEveryUnchangedNutrientAndServingExactly() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let amounts = NutrientAmounts(Dictionary(uniqueKeysWithValues: Nutrient.allCases.map { ($0, 12.123456789) }))
        let food = ExerlyCore.Food(name: "Precise food", per100g: amounts, servings: [Serving("Scoop", grams: 33.123456789)])
        try store.saveFood(food)
        let draft = NutritionFoodDraft(store: store, editing: food)
        draft.name = "Renamed food"
        let saved = try XCTUnwrap(draft.save())
        XCTAssertEqual(saved.per100g, amounts)
        XCTAssertEqual(saved.servings, food.servings)
        XCTAssertEqual(saved.id, food.id)
    }

    func testManualLabelUsesCoreConversionAndDistinguishesBlankFromZero() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let draft = NutritionFoodDraft(store: store)
        draft.name = "Synthetic label"
        draft.basis = .perServing
        draft.labelGrams.text = "42,5"
        draft.nutrients[.energy]?.text = "123,75"
        draft.nutrients[.sodium]?.text = "0"
        let saved = try XCTUnwrap(draft.save(locale: Locale(identifier: "de_DE")))
        let expected = try ExerlyCore.Food.per100g(fromLabel: NutrientAmounts([.energy: 123.75, .sodium: 0]), servingGrams: 42.5)
        XCTAssertEqual(saved.per100g, expected)
        XCTAssertNil(saved.per100g[.protein])
        XCTAssertEqual(saved.per100g[.sodium], 0)
        let invalid = NutritionFoodDraft(store: store)
        invalid.name = "Invalid label"
        invalid.nutrients[.energy]?.text = "several"
        XCTAssertNil(invalid.save())
        XCTAssertEqual(store.foods.count, 1)
        XCTAssertEqual(invalid.name, "Invalid label")
        XCTAssertTrue(invalid.errors.first?.contains("Energy") == true)
    }

    func testFoodDraftRefusesToOverwriteAnUpdatedOrArchivedFood() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        var food = ExerlyCore.Food(name: "Original", per100g: NutrientAmounts([.energy: 120]))
        try store.saveFood(food)
        let draft = NutritionFoodDraft(store: store, editing: food)
        draft.name = "My draft"
        food.name = "Updated elsewhere"
        try store.saveFood(food)
        XCTAssertNil(draft.save())
        XCTAssertEqual(store.food(food.id)?.name, "Updated elsewhere")
        XCTAssertEqual(draft.name, "My draft")
        let archivedDraft = NutritionFoodDraft(store: store, editing: food)
        try store.archiveFood(food.id)
        XCTAssertNil(archivedDraft.save())
        XCTAssertNotNil(store.food(food.id)?.archivedAt)
    }

    func testChoosingAnotherMealMovesATimeNoOneSet() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let date = try XCTUnwrap(LocalDate("2026-10-10"))
        let food = ExerlyCore.Food(name: "Synthetic chili", per100g: NutrientAmounts([.energy: 128]))
        let morning = Date(timeIntervalSince1970: 1_791_637_260) // 9:01 AM in New York
        let draft = NutritionEntryDraft(store: store, food: food, date: date, meal: "Breakfast", now: morning, timeZone: zone)
        draft.meal = "Dinner"
        XCTAssertEqual(draft.loggedAt, store.usualTime(of: "Dinner", on: date, timeZone: zone))
        draft.meal = "Breakfast"
        XCTAssertEqual(draft.loggedAt, morning, "Back to the meal it opened with, back to its time")
        // A time the person set stays.
        let chosen = morning.addingTimeInterval(-3600)
        draft.loggedAt = chosen
        draft.meal = "Lunch"
        XCTAssertEqual(draft.loggedAt, chosen)
    }

    /// The portion sheet sets the day and time together: moving the day
    /// keeps the time of day, and a time no one set still follows the meal.
    func testMovingTheDayKeepsTheTimeItWasEaten() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let saturday = try XCTUnwrap(LocalDate("2026-10-10")), sunday = try XCTUnwrap(LocalDate("2026-10-11"))
        let food = ExerlyCore.Food(name: "Synthetic oats", per100g: NutrientAmounts([.energy: 380]))
        let morning = Date(timeIntervalSince1970: 1_791_637_260) // 9:01 AM in New York, Saturday
        let draft = NutritionEntryDraft(store: store, food: food, date: saturday, meal: "Breakfast", now: morning, timeZone: zone)
        XCTAssertEqual(draft.eatenAt, morning)
        draft.eatenAt = morning.addingTimeInterval(86_400)
        XCTAssertEqual(draft.date, sunday)
        XCTAssertEqual(draft.loggedAt, morning.addingTimeInterval(86_400), "Sunday at 9:01, not still Saturday")
        draft.meal = "Dinner"
        XCTAssertEqual(draft.loggedAt, store.usualTime(of: "Dinner", on: sunday, timeZone: zone), "Still follows the meal")
        draft.meal = "Breakfast"
        XCTAssertEqual(draft.loggedAt, morning.addingTimeInterval(86_400), "Back to its time, on the new day")
        // A time the person sets stays when the meal changes.
        let chosen = morning.addingTimeInterval(86_400 - 1_800)
        draft.eatenAt = chosen
        draft.meal = "Lunch"
        XCTAssertEqual(draft.loggedAt, chosen)
        let saved = try XCTUnwrap(draft.save())
        XCTAssertEqual([saved.date, LocalDate(saved.loggedAt, in: zone)], [sunday, sunday])

        // A late snack an import counted for the day before shows on that day and keeps its time when untouched.
        let late = try store.log(food, grams: 40, on: saturday, meal: "Snacks", at: morning.addingTimeInterval(16 * 3_600))
        let reopened = NutritionEntryDraft(store: store, food: food, date: saturday, meal: "Snacks", editing: late, timeZone: zone)
        XCTAssertEqual(LocalDate(reopened.eatenAt, in: zone), saturday)
        XCTAssertFalse(reopened.hasChanges)
    }

    func testEntryMetadataEditUsesItsSnapshotAndKeepsExactPortion() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-06"))
        var food = ExerlyCore.Food(name: "Original oats", per100g: NutrientAmounts([.energy: 380.123456789, .sodium: 0]))
        var entry = try store.log(food, serving: Serving("Scoop", grams: 33.123456789), quantity: 1.23456789, on: date, meal: "Breakfast")
        // Imported records can have a separately precise gram amount.
        entry.grams = 40.123456789
        try store.saveEntry(entry)
        entry = try XCTUnwrap(store.entries.first { $0.id == entry.id })
        food.name = "Updated library oats"
        food.per100g[.energy] = 999
        try store.saveFood(food)
        let draft = NutritionEntryDraft(store: store, food: food, date: date, meal: "Breakfast", editing: entry)
        draft.meal = "Lunch"
        XCTAssertEqual(draft.food.snapshot, entry.food)
        XCTAssertEqual(try draft.preview().nutrients, entry.nutrients)
        let saved = try XCTUnwrap(draft.save())
        XCTAssertEqual(saved.id, entry.id)
        XCTAssertEqual(saved.food, entry.food)
        XCTAssertEqual(saved.grams, entry.grams)
        XCTAssertEqual(saved.quantity, entry.quantity)
        XCTAssertEqual(saved.meal, "Lunch")
        XCTAssertEqual(saved.loggedAt, store.usualTime(of: "Lunch", on: date, timeZone: .current), "An untouched time follows the meal")
    }

    func testServingPreviewMatchesTheSavedEntryWithoutInventingUnknownNutrients() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-06"))
        let food = ExerlyCore.Food(name: "Measured food", per100g: NutrientAmounts([.energy: 380, .sodium: 0]),
                                   servings: [Serving("Cup", grams: 42.123456789)])
        let draft = NutritionEntryDraft(store: store, food: food, date: date, meal: "Lunch")
        XCTAssertTrue(draft.selectMeasure(.serving(food.servings[0])))
        draft.amount.text = "1,25"
        let preview = try draft.preview(locale: Locale(identifier: "de_DE"))
        XCTAssertTrue(store.entries.isEmpty)
        let saved = try XCTUnwrap(draft.save(locale: Locale(identifier: "de_DE")))
        XCTAssertEqual(saved.grams, preview.grams)
        XCTAssertEqual(saved.nutrients, preview.nutrients)
        XCTAssertEqual(saved.quantity, 1.25)
        XCTAssertNil(saved.nutrients[.protein])
        XCTAssertEqual(saved.nutrients[.sodium], 0)
        XCTAssertNotNil(draft.save(locale: Locale(identifier: "de_DE")))
        XCTAssertEqual(store.entries.count, 1)
    }

    func testRepeatingAFoodPrefillsItsPrecisePortionButKeepsTheChosenDateAndMeal() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let oldDate = try XCTUnwrap(LocalDate("2026-10-05"))
        let today = try XCTUnwrap(LocalDate("2026-10-06"))
        var food = ExerlyCore.Food(name: "Synthetic cereal", per100g: NutrientAmounts([.energy: 370]),
                                   servings: [Serving("bowl", grams: 41.123456789)])
        let previous = try store.log(food, serving: food.servings[0], quantity: 1.123456789, on: oldDate, meal: "Breakfast")
        food.per100g[.energy] = 380
        let now = Date(timeIntervalSince1970: 1_791_326_400)
        let draft = NutritionEntryDraft(store: store, food: food, date: today, meal: "Dinner", repeating: previous, now: now)
        let entry = try XCTUnwrap(draft.save())
        XCTAssertNotEqual(entry.id, previous.id)
        XCTAssertEqual(entry.date, today)
        XCTAssertEqual(entry.meal, "Dinner")
        XCTAssertEqual(entry.loggedAt, now)
        XCTAssertEqual(entry.grams, previous.grams)
        XCTAssertEqual(entry.quantity, previous.quantity)
        XCTAssertEqual(entry.serving, previous.serving)
        XCTAssertEqual(entry.food.per100g[.energy], 380)
        XCTAssertEqual(store.entries.first, previous)
    }

    func testInvalidAndStaleEntryDraftsKeepTheirInputAndDoNotWrite() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-06"))
        let food = ExerlyCore.Food(name: "Synthetic food", per100g: NutrientAmounts([.energy: 250]))
        let draft = NutritionEntryDraft(store: store, food: food, date: date, meal: "Lunch")
        draft.amount.text = "0"
        XCTAssertNil(draft.save())
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(draft.amount.text, "0")
        var entry = try store.log(food, grams: 25, on: date, meal: "Lunch")
        let stale = NutritionEntryDraft(store: store, food: food, date: date, meal: "Lunch", editing: entry)
        stale.amount.text = "60"
        entry.grams = 40
        try store.saveEntry(entry)
        XCTAssertNil(stale.save())
        XCTAssertEqual(store.entries.first?.grams, 40)
        XCTAssertEqual(stale.amount.text, "60")
        let deleted = NutritionEntryDraft(store: store, food: food, date: date, meal: "Lunch", editing: entry)
        try store.deleteEntry(entry.id)
        XCTAssertNil(deleted.save())
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testEntryDeletionAndUndoRefuseToOverwriteChangesAfterReview() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-06"))
        let food = ExerlyCore.Food(name: "Synthetic pear", per100g: NutrientAmounts([.energy: 57, .sodium: 0]))
        var entry = try store.log(food, grams: 125.123456789, on: date, meal: "Snacks")
        let actions = NutritionDiaryActions(store: store)
        let reviewed = entry
        entry.meal = "Lunch"
        try store.saveEntry(entry)
        XCTAssertFalse(actions.delete(reviewed))
        XCTAssertEqual(store.entries.first, entry)
        XCTAssertNil(actions.deleted)
        XCTAssertTrue(actions.delete(entry))
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(actions.deleted, entry)
        XCTAssertTrue(actions.undoDeletion())
        XCTAssertEqual(store.entries.first, entry)
        XCTAssertNil(actions.deleted)
        XCTAssertTrue(actions.delete(entry))
        entry.grams = 40
        try store.saveEntry(entry)
        XCTAssertFalse(actions.undoDeletion())
        XCTAssertEqual(store.entries.first, entry)
        XCTAssertNotNil(actions.error)
    }

    func testFailedDeletionKeepsTheEntryAndDoesNotOfferUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try TrainingWorkspace(accountID: UUID().uuidString, root: root)
        let date = try XCTUnwrap(LocalDate("2026-10-06"))
        let food = ExerlyCore.Food(name: "Synthetic pear", per100g: NutrientAmounts([.energy: 57]))
        let entry = try workspace.nutrition.log(food, grams: 125, on: date, meal: "Snacks")
        let actions = NutritionDiaryActions(store: workspace.nutrition)
        await workspace.close()
        XCTAssertFalse(actions.delete(entry))
        XCTAssertEqual(workspace.nutrition.entries.first, entry)
        XCTAssertNil(actions.deleted)
        XCTAssertNotNil(actions.error)
    }
}

@MainActor
final class NutritionDiaryPresentationTests: XCTestCase {
    func testKeepingADatabaseFavoriteDoesNotOverwriteANewerSavedLabel() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let food = ExerlyCore.Food(id: "off:0012345678905", name: "Synthetic oat bar", source: .openFoodFacts,
                                  per100g: NutrientAmounts([.energy: 410, .sodium: 0]))
        let actions = NutritionLibraryActions(store: store)
        XCTAssertTrue(actions.keepFavorite(food, reviewed: nil))
        var saved = try XCTUnwrap(store.food(food.id))
        XCTAssertTrue(saved.favorite)
        XCTAssertEqual(saved.source, .openFoodFacts)
        XCTAssertEqual(saved.per100g, food.per100g)
        let reviewed = saved
        saved.name = "Newer saved label"
        try store.saveFood(saved)
        XCTAssertFalse(actions.keepFavorite(food, reviewed: nil))
        XCTAssertFalse(actions.keepFavorite(food, reviewed: reviewed))
        XCTAssertEqual(store.food(food.id), saved)
    }

    func testLibraryActionsPreserveLoggedSnapshotsAndCanRestoreAnArchivedFood() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-06"))
        let food = ExerlyCore.Food(name: "Synthetic pear", per100g: NutrientAmounts([.energy: 57, .sodium: 0]))
        try store.saveFood(food)
        let entry = try store.log(food, grams: 123.25, on: date, meal: "Dinner")
        let actions = NutritionLibraryActions(store: store)
        XCTAssertTrue(actions.setFavorite(true, reviewed: food))
        let favorite = try XCTUnwrap(store.food(food.id))
        XCTAssertTrue(favorite.favorite)
        XCTAssertTrue(actions.archive(reviewed: favorite))
        let archived = try XCTUnwrap(store.food(food.id))
        XCTAssertNotNil(archived.archivedAt)
        XCTAssertEqual(store.entries, [entry])
        XCTAssertTrue(actions.restore(reviewed: archived))
        XCTAssertNil(store.food(food.id)?.archivedAt)
        XCTAssertEqual(store.entries, [entry])
    }

    func testLibraryActionsRefuseStaleFavoriteArchiveAndRestoreReviews() throws {
        let persistence = InMemoryTrainingPersistence()
        let store = try NutritionStore(persistence: persistence)
        let food = ExerlyCore.Food(name: "Synthetic pear", per100g: NutrientAmounts([.energy: 57]))
        try store.saveFood(food)
        let actions = NutritionLibraryActions(store: store)
        var updated = food
        updated.name = "Updated pear label"
        try store.saveFood(updated)
        XCTAssertFalse(actions.archive(reviewed: food))
        XCTAssertFalse(actions.setFavorite(true, reviewed: food))
        XCTAssertEqual(store.food(food.id), updated)
        XCTAssertNotNil(actions.error)
        try store.archiveFood(food.id)
        let archived = try XCTUnwrap(store.food(food.id))
        var newer = archived
        newer.name = "New archived label"
        try store.saveFood(newer)
        XCTAssertFalse(actions.restore(reviewed: archived))
        XCTAssertEqual(store.food(food.id), newer)
    }

    func testNotesSaveKeepsStatusAndRefusesToOverwriteANewerNote() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-06"))
        try store.setNotes("Original note", on: date)
        let draft = NutritionDayNotesDraft(store: store, date: date)
        draft.text = "Lunch after training"
        try store.setStatus(.partial, on: date)
        XCTAssertTrue(draft.save())
        XCTAssertEqual(store.day(date).notes, "Lunch after training")
        XCTAssertEqual(store.day(date).status, .partial)
        let stale = NutritionDayNotesDraft(store: store, date: date)
        stale.text = "My unsaved note"
        try store.setNotes("Note from another device", on: date)
        XCTAssertFalse(stale.save())
        XCTAssertEqual(stale.text, "My unsaved note")
        XCTAssertEqual(store.day(date).notes, "Note from another device")
    }

    func testDayStatusRefusesAChangedReviewAndNeverDeletesFood() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-06"))
        let food = ExerlyCore.Food(name: "Synthetic apple", per100g: NutrientAmounts([.energy: 52]))
        let entry = try store.log(food, grams: 110, on: date, meal: "Lunch")
        let actions = NutritionDiaryActions(store: store)
        let reviewed = store.day(date)
        XCTAssertTrue(actions.setStatus(.complete, reviewed: reviewed, entries: [entry]))
        XCTAssertEqual(store.entries, [entry])
        XCTAssertFalse(actions.setStatus(.fasting, reviewed: reviewed, entries: [entry]))
        XCTAssertEqual(store.day(date).status, .complete)
        let latest = store.day(date)
        _ = try store.log(food, grams: 20, on: date, meal: "Dinner")
        XCTAssertFalse(actions.setStatus(.fasting, reviewed: latest, entries: [entry]))
        XCTAssertEqual(store.entries.count, 2)
    }

    func testCopyPreservesSnapshotsAndCannotDuplicateOnRepeatedConfirmation() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let source = try XCTUnwrap(LocalDate("2026-10-05"))
        let target = try XCTUnwrap(LocalDate("2026-10-06"))
        let food = ExerlyCore.Food(name: "Synthetic cereal", per100g: NutrientAmounts([.energy: 360, .sodium: 0]))
        let original = try store.log(food, grams: 42.123456789, on: source, meal: "Breakfast")
        let draft = NutritionCopyDraft(store: store, source: source, meal: "Breakfast", target: target)
        draft.targetMeal = "Dinner"
        let copies = try XCTUnwrap(draft.copy())
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(copies.first?.food, original.food)
        XCTAssertEqual(copies.first?.grams, original.grams)
        XCTAssertEqual(copies.first?.date, target)
        XCTAssertEqual(copies.first?.meal, "Dinner")
        XCTAssertNotEqual(copies.first?.id, original.id)
        XCTAssertNil(draft.copy())
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries(on: source), [original])
    }

    func testCopyRefusesChangedSourceEntriesAndKeepsTheDestination() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let source = try XCTUnwrap(LocalDate("2026-10-05"))
        let target = try XCTUnwrap(LocalDate("2026-10-06"))
        let food = ExerlyCore.Food(name: "Synthetic cereal", per100g: NutrientAmounts([.energy: 360]))
        var original = try store.log(food, grams: 40, on: source, meal: "Breakfast")
        let existing = try store.log(food, grams: 80, on: target, meal: "Dinner")
        let draft = NutritionCopyDraft(store: store, source: source, meal: nil, target: target)
        original.grams = 50
        try store.saveEntry(original)
        XCTAssertNil(draft.copy())
        XCTAssertNotNil(draft.error)
        XCTAssertEqual(store.entries(on: target), [existing])
        XCTAssertEqual(draft.entries.first?.grams, 40)
    }
}

@MainActor
final class NutritionSearchTests: XCTestCase {
    func testSubmittedSearchKeepsSourceAndUnknownNutrientsAndSkipsBlankQueries() async throws {
        let transport = NutritionSearchTransport()
        let model = NutritionSearchModel(api: AccountAPI(accountID: "food-account", transport: transport))
        await model.search("  \n ")
        let emptyRequests = await transport.requests()
        XCTAssertTrue(emptyRequests.isEmpty)
        XCTAssertNil(model.request)
        await model.search("  pear + oats  ")
        let requests = await transport.requests()
        XCTAssertEqual(requests.first?.accountID, "food-account")
        XCTAssertEqual(requests.first?.path, "/v1/foods/search?q=pear%20%2B%20oats&limit=20")
        XCTAssertEqual(model.result?.foods.first?.source, .openFoodFacts)
        XCTAssertEqual(model.result?.foods.first?.per100g[.sodium], 0)
        XCTAssertNil(model.result?.foods.first?.per100g[.iron])
        XCTAssertEqual(model.result?.attribution, "Synthetic Open Food Facts attribution")
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.error)
    }

    func testOlderSearchCannotReplaceANewerResult() async throws {
        let began = expectation(description: "First search began")
        let transport = NutritionSearchTransport(onFirstRequest: { began.fulfill() }, holdFirst: true)
        let model = NutritionSearchModel(api: AccountAPI(accountID: "food-account", transport: transport))
        let first = Task { await model.search("old") }
        await fulfillment(of: [began], timeout: 3)
        await model.search("new")
        XCTAssertEqual(model.result?.foods.first?.name, "Synthetic new food")
        await transport.finishFirst()
        await first.value
        XCTAssertEqual(model.result?.foods.first?.name, "Synthetic new food")
        XCTAssertFalse(model.isLoading)
    }

    func testClosedSearchCannotRepopulateAfterAnAccountSwitch() async throws {
        let began = expectation(description: "Search began")
        let transport = NutritionSearchTransport(onFirstRequest: { began.fulfill() }, holdFirst: true)
        let model = NutritionSearchModel(api: AccountAPI(accountID: "old-account", transport: transport))
        let pending = Task { await model.search("old") }
        await fulfillment(of: [began], timeout: 3)
        model.close()
        await transport.finishFirst()
        await pending.value
        XCTAssertNil(model.result)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isLoading)
        await model.search("new")
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 1)
    }

    func testTypingSearchesOnceAfterAPauseAndReusesEarlierAnswers() async throws {
        let transport = NutritionSearchTransport()
        let model = NutritionSearchModel(api: AccountAPI(accountID: "food-account", transport: transport), pause: .milliseconds(40))
        for text in ["p", "pe", "pea", "pear", "pear "] { model.type(text) }
        try await Task.sleep(for: .milliseconds(300))
        var paths = await transport.requests().map(\.path)
        XCTAssertEqual(paths, ["/v1/foods/search?q=pear&limit=20"], "One request for a word, after typing pauses")
        XCTAssertEqual(model.shownQuery, "pear")
        model.type("pears")
        try await Task.sleep(for: .milliseconds(300))
        model.type("pear")
        XCTAssertEqual(model.shownQuery, "pear", "An answer already fetched shows at once")
        await model.search("pear")
        paths = await transport.requests().map(\.path)
        XCTAssertEqual(paths.count, 2, "Going back to, or submitting, a shown search costs no request")
        model.type("pe")
        XCTAssertNil(model.result)
        XCTAssertNil(model.request)
        try await Task.sleep(for: .milliseconds(300))
        let finalCount = await transport.requests().count
        XCTAssertEqual(finalCount, 2, "Two letters don't search the database")
    }

    func testANewerKeystrokeDropsAStaleTypedSearch() async throws {
        let began = expectation(description: "First search began")
        let transport = NutritionSearchTransport(onFirstRequest: { began.fulfill() }, holdFirst: true)
        let model = NutritionSearchModel(api: AccountAPI(accountID: "food-account", transport: transport), pause: .milliseconds(20))
        model.type("old")
        await fulfillment(of: [began], timeout: 3)
        XCTAssertTrue(model.isLoading)
        model.type("newer")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.result?.foods.first?.name, "Synthetic new food")
        XCTAssertEqual(model.shownQuery, "newer")
        await transport.finishFirst()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.result?.foods.first?.name, "Synthetic new food", "The stale answer never replaces the newer one")
        XCTAssertFalse(model.isLoading)
    }

    func testCompactBarcodeKeepsTheCameraFormatAndDoesNotGuessManualDigits() async throws {
        let transport = NutritionSearchTransport()
        let model = NutritionSearchModel(api: AccountAPI(accountID: "food-account", transport: transport))
        await model.lookup(" 04252614 ", symbology: .upcE)
        await model.lookup("04252614", symbology: .ean8)
        await model.lookup("04252614")
        let paths = await transport.requests().map(\.path)
        XCTAssertEqual(paths, ["/v1/foods/barcode/04252614?symbology=upce",
                               "/v1/foods/barcode/04252614?symbology=ean8",
                               "/v1/foods/barcode/04252614"])
    }

    func testBarcodeNotFoundIsDifferentFromUnavailableAndCanBeRetried() async throws {
        let transport = NutritionSearchTransport()
        let model = NutritionSearchModel(api: AccountAPI(accountID: "food-account", transport: transport))
        await model.lookup("00000000")
        XCTAssertNotNil(model.request)
        XCTAssertNil(model.result)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isLoading)
        await model.lookup("11111111")
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.result)
        await model.lookup("22222222")
        XCTAssertNil(model.error)
        XCTAssertEqual(model.result?.foods.count, 1)
        model.clear()
        XCTAssertNil(model.request)
        XCTAssertNil(model.result)
    }

    func testInvalidBarcodeAndBusyProviderKeepTheirActionableMessages() async throws {
        let model = NutritionSearchModel(api: AccountAPI(accountID: "food-account", transport: NutritionSearchTransport()))
        await model.lookup("33333333")
        XCTAssertEqual(model.error, "Choose EAN-8 or UPC-E for an eight-digit code.")
        await model.lookup("44444444")
        XCTAssertEqual(model.error, "Food lookups are busy. Try again shortly.")
        XCTAssertFalse(model.isLoading)
    }
}

private actor NutritionSearchTransport: SessionTransport {
    struct Request: Sendable {
        let accountID: String
        let path: String
    }
    private var received: [Request] = []
    private let onFirstRequest: @Sendable () -> Void
    private var holdFirst: Bool
    private var pending: CheckedContinuation<Void, Never>?

    init(onFirstRequest: @escaping @Sendable () -> Void = {}, holdFirst: Bool = false) {
        self.onFirstRequest = onFirstRequest
        self.holdFirst = holdFirst
    }
    func requests() -> [Request] { received }
    func finishFirst() { holdFirst = false; pending?.resume(); pending = nil }

    func send(_ method: String, path: String, body: Data?, headers: [String: String],
              as accountID: String) async throws -> (status: Int, data: Data) {
        received.append(Request(accountID: accountID, path: path))
        if received.count == 1 {
            onFirstRequest()
            if holdFirst { await withCheckedContinuation { pending = $0 } }
        }
        if path.hasSuffix("00000000") { return (404, Data("{}".utf8)) }
        if path.hasSuffix("11111111") { throw URLError(.notConnectedToInternet) }
        if path.hasSuffix("33333333") {
            return (400, Data(#"{"message":"Choose EAN-8 or UPC-E for an eight-digit code."}"#.utf8))
        }
        if path.hasSuffix("44444444") {
            return (429, Data(#"{"message":"Food lookups are busy. Try again shortly."}"#.utf8))
        }
        let name = path.contains("q=old") ? "Synthetic old food" : "Synthetic new food"
        let food = ExerlyCore.Food(id: "off:22222222", name: name, source: .openFoodFacts,
                                   per100g: NutrientAmounts([.energy: 55, .sodium: 0]))
        let row = try JSONSerialization.jsonObject(with: ExerlyJSON.canonical(food))
        let payload: [String: Any] = path.contains("/barcode/")
            ? ["food": row, "attribution": "Synthetic Open Food Facts attribution"]
            : ["foods": [row], "attribution": "Synthetic Open Food Facts attribution"]
        return (200, try JSONSerialization.data(withJSONObject: payload))
    }
}
