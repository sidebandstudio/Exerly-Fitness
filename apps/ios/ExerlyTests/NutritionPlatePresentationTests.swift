import ExerlyCore
import XCTest
@testable import Exerly

@MainActor
final class NutritionPlatePresentationTests: XCTestCase {
    func testStagedPlateUsesUSPortionsAndCoreTotalsWithoutWritingAccountRecords() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-07"))
        let first = ExerlyCore.Food(name: "Synthetic pear", per100g: NutrientAmounts([.energy: 100, .sodium: 0]))
        let second = ExerlyCore.Food(name: "Synthetic oats", per100g: NutrientAmounts([.energy: 200, .protein: 10]))
        let draft = NutritionPlateDraft(store: store, date: date, meal: "Lunch")
        XCTAssertTrue(draft.add(first))
        XCTAssertTrue(draft.add(second))
        XCTAssertEqual(draft.rows.count, 2)
        // A food without a serving starts at four ounces in U.S. units.
        XCTAssertEqual(try XCTUnwrap(draft.rows.first?.amount.grams), USUnits.grams(ounces: 4), accuracy: 1e-9)
        XCTAssertEqual(draft.rows.first?.amount.serving?.name, "oz")
        XCTAssertEqual(draft.rows.first?.amount.quantity, 4)
        XCTAssertEqual(try XCTUnwrap(draft.summary?.totals[.energy]), 3 * USUnits.grams(ounces: 4), accuracy: 0.000_000_001)
        XCTAssertEqual(draft.summary?.totals[.sodium], 0)
        XCTAssertNil(draft.summary?.totals[.vitaminD])
        XCTAssertEqual(draft.progress?.protein.unreported, 1)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.foods.isEmpty)
    }

    func testPortionEditingAndRemovalKeepOtherRowsAndRejectStaleOrInvalidReviews() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-07"))
        let food = ExerlyCore.Food(name: "Synthetic meal food", per100g: NutrientAmounts([.energy: 123.45]))
        let draft = NutritionPlateDraft(store: store, date: date, meal: "Lunch")
        XCTAssertTrue(draft.add(food))
        XCTAssertTrue(draft.add(food))
        let original = try XCTUnwrap(draft.rows.first)
        let other = try XCTUnwrap(draft.rows.last)
        XCTAssertNotEqual(original.id, other.id, "Choosing a second portion is deliberate")
        let portion = try NutritionStore.preview(food, grams: 75.123456789)
        XCTAssertTrue(draft.stage(food, amount: portion, replacing: original))
        XCTAssertEqual(draft.rows.last, other)
        XCTAssertEqual(draft.rows.first?.id, original.id)
        XCTAssertFalse(draft.stage(food, amount: portion, replacing: original))
        XCTAssertFalse(draft.remove(original))
        var invalid = portion
        invalid.grams = -1
        XCTAssertFalse(draft.stage(food, amount: invalid))
        XCTAssertEqual(draft.rows.count, 2)
        XCTAssertTrue(draft.remove(other))
        XCTAssertEqual(draft.rows.count, 1)
        XCTAssertEqual(draft.rows.first?.amount.grams, 75.123456789)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testSaveKeepsReviewedSnapshotsAndDateAndRepeatedConfirmationCannotDuplicate() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-07"))
        var food = ExerlyCore.Food(name: "Original synthetic food", source: .usda, per100g: NutrientAmounts([.energy: 100]))
        try store.saveFood(food)
        let time = Date(timeIntervalSince1970: 1_791_378_000)
        let draft = NutritionPlateDraft(store: store, date: date, meal: "Lunch", now: time)
        XCTAssertTrue(draft.add(food))
        XCTAssertTrue(draft.add(food))
        food.name = "Later library name"
        food.per100g[.energy] = 999
        try store.saveFood(food)
        draft.date = try XCTUnwrap(LocalDate("2026-10-08"))
        draft.meal = " Dinner "
        let saved = try XCTUnwrap(draft.save())
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(saved.first?.food.name, "Original synthetic food")
        XCTAssertEqual(saved.first?.food.per100g[.energy], 100)
        XCTAssertEqual(saved.first?.food.source, .usda)
        XCTAssertEqual(saved.first?.date, draft.date)
        XCTAssertEqual(saved.first?.meal, "Dinner")
        XCTAssertEqual(saved.first?.loggedAt, store.usualTime(of: "Dinner", on: draft.date, timeZone: .current),
                       "A time no one set follows the meal")
        XCTAssertEqual(draft.save(), saved)
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertFalse(draft.add(food), "A saved draft cannot append an unsaved row")
    }

    func testMovingAMealsDayKeepsItsTime() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let morning = Date(timeIntervalSince1970: 1_791_637_260) // 9:01 AM in New York, Saturday
        let draft = NutritionPlateDraft(store: store, date: try XCTUnwrap(LocalDate("2026-10-10")), meal: "Breakfast",
                                        now: morning, timeZone: zone)
        XCTAssertTrue(draft.add(ExerlyCore.Food(name: "Synthetic toast", per100g: NutrientAmounts([.energy: 250]))))
        draft.eatenAt = morning.addingTimeInterval(-86_400)
        let saved = try XCTUnwrap(draft.save())
        XCTAssertEqual(saved.first?.date, LocalDate("2026-10-09"))
        XCTAssertEqual(saved.first?.loggedAt, morning.addingTimeInterval(-86_400))
    }

    func testRepeatedNamedPortionWithoutARecordedQuantityUsesItsExactWeight() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-07"))
        let serving = Serving("Cup", grams: 240)
        let food = ExerlyCore.Food(name: "Synthetic grain", per100g: NutrientAmounts([.energy: 99]), servings: [serving])
        try store.saveEntry(FoodEntry(date: date, meal: "Breakfast", loggedAt: Date(), food: food.snapshot, grams: 180, serving: serving, quantity: nil))
        let draft = NutritionPlateDraft(store: store, date: date, meal: "Lunch")
        XCTAssertTrue(draft.add(food))
        XCTAssertEqual(draft.rows.first?.amount.grams, 180)
        XCTAssertEqual(draft.rows.first?.amount.quantity, 0.75)
        XCTAssertEqual(draft.save()?.first?.quantity, 0.75)
        XCTAssertEqual(store.entries.count, 2)
    }

    func testMetricFoodAndVolumeDefaultsStayMetricAndEmptyOrInvalidMealsDoNotSave() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        let date = try XCTUnwrap(LocalDate("2026-10-07"))
        var food = ExerlyCore.Food(name: "Synthetic liquid", per100g: NutrientAmounts([.energy: 200]))
        food.volume = VolumeBasis(density: 0.92, assumed: false)
        let draft = NutritionPlateDraft(store: store, date: date, meal: "Lunch", unit: .kilograms)
        XCTAssertNil(draft.save())
        XCTAssertTrue(draft.add(food))
        XCTAssertEqual(draft.rows.first?.amount.serving?.name, "ml")
        XCTAssertEqual(draft.rows.first?.amount.quantity, 100)
        XCTAssertEqual(draft.rows.first?.amount.grams, 92)
        draft.meal = " "
        XCTAssertNil(draft.save())
        XCTAssertEqual(draft.rows.count, 1)
        XCTAssertTrue(store.entries.isEmpty)
        draft.meal = "Lunch"
        XCTAssertEqual(draft.save()?.count, 1)
    }

    func testStorageFailureKeepsEveryDraftRowWithoutPartiallyLoggingTheMeal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try TrainingWorkspace(accountID: UUID().uuidString, root: root)
        let date = try XCTUnwrap(LocalDate("2026-10-07"))
        let food = ExerlyCore.Food(name: "Synthetic food", per100g: NutrientAmounts([.energy: 100]))
        let draft = NutritionPlateDraft(store: workspace.nutrition, date: date, meal: "Dinner")
        XCTAssertTrue(draft.add(food))
        XCTAssertTrue(draft.add(food))
        let reviewed = draft.rows
        await workspace.close()
        XCTAssertNil(draft.save())
        XCTAssertNotNil(draft.error)
        XCTAssertEqual(draft.rows, reviewed)
        XCTAssertEqual(draft.date, date)
        XCTAssertEqual(draft.meal, "Dinner")
        XCTAssertTrue(workspace.nutrition.entries.isEmpty)
    }
}
