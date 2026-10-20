import Foundation
import Testing
@testable import ExerlyCore

/// Synthetic foods with round numbers, per 100 g.
enum Foods {
    static let oats = Food(id: "4B1D0E4C-0000-4000-8000-000000000001", name: "Rolled oats",
                           per100g: NutrientAmounts([.energy: 380, .protein: 13, .carbohydrate: 67, .fat: 7, .fiber: 10, .iron: 4]),
                           servings: [Serving("1/2 cup", grams: 40)], createdAt: Fixture.instant())
    static let milk = Food(id: "4B1D0E4C-0000-4000-8000-000000000002", name: "Milk", brand: "Synthetic Dairy",
                           per100g: NutrientAmounts([.energy: 60, .protein: 3.3, .carbohydrate: 4.8, .fat: 3.2, .calcium: 120]),
                           servings: [Serving("1 cup", grams: 244)], createdAt: Fixture.instant())
    static let chicken = Food(id: "4B1D0E4C-0000-4000-8000-000000000003", name: "Chicken breast",
                              per100g: NutrientAmounts([.energy: 165, .protein: 31, .fat: 3.6, .iron: 1]),
                              createdAt: Fixture.instant())
}

@MainActor
@Suite struct NutritionStoreTests {
    let monday = LocalDate("2026-10-05")!

    func store(_ persistence: InMemoryTrainingPersistence = InMemoryTrainingPersistence()) throws -> NutritionStore {
        try NutritionStore(persistence: persistence, now: { Fixture.instant() })
    }

    @Test func loggingByWeightOrServingScalesNutrientsAndSummarisesTheDay() throws {
        let nutrition = try store()
        try nutrition.log(Foods.oats, serving: Foods.oats.servings[0], quantity: 2, on: monday, meal: "Breakfast")
        try nutrition.log(Foods.milk, grams: 244, on: monday, meal: "Breakfast")
        try nutrition.log(Foods.chicken, grams: 150, on: monday, meal: "Lunch")
        let summary = nutrition.summary(on: monday)
        #expect(summary.entries == 3)
        #expect(close(summary.totals.energy, 380 * 0.8 + 60 * 2.44 + 165 * 1.5))
        #expect(close(summary.totals[.protein], 13 * 0.8 + 3.3 * 2.44 + 31 * 1.5))
        #expect(close(summary.byMeal["Lunch"]?[.protein], 46.5))
        #expect(summary.totals[.calcium].map { close($0, 120 * 2.44) } == true)
        let shares = summary.energyShares
        #expect(close(shares.values.reduce(0, +), 1))
        // Entries logged at the same moment are ordered by ID, so find the oats.
        let oats = nutrition.entries(on: monday).first { $0.food.name == Foods.oats.name }
        #expect(oats?.quantity == 2 && oats?.grams == 80)

        let iron = nutrition.contributors(of: .iron, on: monday)
        #expect(iron.map(\.name) == ["Rolled oats", "Chicken breast"])
        #expect(close(iron.reduce(0) { $0 + $1.share }, 1))
    }

    /// PARITY N25: an omega-3 total and its parts are separate fields. A day's
    /// total adds only the totals foods report, never the parts again.
    @Test func omega3TotalsAndTheirPartsAddUpSeparately() throws {
        let nutrition = try store()
        let salmon = Food(name: "Synthetic salmon", per100g: NutrientAmounts([
            .energy: 200, .fat: 12, .omega3: 2, .omega3ALA: 0.1, .omega3EPA: 0.7, .omega3DHA: 1.2, .saturatedFat: 2.5,
        ]))
        let flax = Food(name: "Synthetic flax", per100g: NutrientAmounts([.energy: 530, .fat: 42, .omega3ALA: 22]))
        try nutrition.log(salmon, grams: 100, on: monday, meal: "Dinner")
        try nutrition.log(flax, grams: 10, on: monday, meal: "Breakfast")
        let summary = nutrition.summary(on: monday)
        #expect(summary.totals[.omega3] == 2, "Flax reports only ALA, so the total isn't 4.3")
        #expect(close(summary.totals[.omega3ALA], 2.3) && summary.totals[.omega3EPA] == 0.7 && summary.totals[.omega3DHA] == 1.2)
        #expect(summary.reporting[.omega3] == 1 && summary.reporting[.omega3ALA] == 2)
        #expect(summary.totals[.omega6] == nil && summary.totals[.monounsaturatedFat] == nil, "Unreported fats stay unknown")
        #expect(summary.totals[.saturatedFat] == 2.5)
    }

    /// PARITY N05: a quick add is removed like any entry, and the day's totals follow.
    @Test func aRemovedQuickAddLeavesTheDaysTotals() throws {
        let nutrition = try store()
        try nutrition.log(Foods.oats, grams: 80, on: monday, meal: "Breakfast")
        let quick = try nutrition.quickAdd(NutrientAmounts([.energy: 450, .protein: 30]), name: "Restaurant lunch", on: monday, meal: "Lunch")
        #expect(close(nutrition.summary(on: monday).totals.energy, 304 + 450))
        try nutrition.deleteEntry(quick.id)
        let summary = nutrition.summary(on: monday)
        #expect(summary.entries == 1 && close(summary.totals.energy, 304) && summary.byMeal["Lunch"] == nil)
        #expect(nutrition.foods.isEmpty && nutrition.recentFoods().map(\.foodID) == [Foods.oats.id])
    }

    @Test func recipesComputeTheirNutrientsFromIngredientsAndYield() throws {
        let porridge = Food.recipe(name: "Porridge", ingredients: [RecipeIngredient(food: Foods.oats.snapshot, grams: 80),
                                                                   RecipeIngredient(food: Foods.milk.snapshot, grams: 300)],
                                   yieldGrams: 400)
        #expect(close(porridge.per100g.energy, (380 * 0.8 + 60 * 3) / 4))
        let nutrition = try store()
        try nutrition.saveFood(porridge)
        let entry = try nutrition.log(porridge, grams: 200, on: monday, meal: "Breakfast")
        #expect(close(entry.nutrients.energy, (380 * 0.8 + 60 * 3) / 2))
        #expect(throws: NutritionStore.StoreError.self) {
            try nutrition.saveFood(Food.recipe(name: "Nothing", ingredients: []))
        }
    }

    @Test func aRecipeMakesEqualServingsAndRecalculatesWhenItsIngredientsChange() throws {
        let nutrition = try store()
        var porridge = Food.recipe(name: "Porridge", ingredients: [RecipeIngredient(food: Foods.oats.snapshot, grams: 80),
                                                                   RecipeIngredient(food: Foods.milk.snapshot, grams: 300)],
                                   servingCount: 2, preparation: "Simmer 5 minutes, stirring.")
        #expect(porridge.recipeGrams == 380 && porridge.recipeServing == Serving("1 serving", grams: 190))
        porridge.favorite = true
        try nutrition.saveFood(porridge)
        let bowl = try nutrition.log(porridge, serving: porridge.recipeServing, on: monday, meal: "Breakfast")
        #expect(close(bowl.nutrients.energy, (380 * 0.8 + 60 * 3) / 2))

        // Reordered, one ingredient changed, and cooked down: the serving follows the new weight.
        let edited = porridge.withIngredients([RecipeIngredient(food: Foods.milk.snapshot, grams: 400),
                                               RecipeIngredient(food: Foods.oats.snapshot, grams: 80)], yieldGrams: 360)
        try nutrition.saveFood(edited)
        let saved = try #require(nutrition.food(porridge.id))
        #expect(saved.favorite && saved.preparation == "Simmer 5 minutes, stirring." && saved.servingCount == 2)
        #expect(saved.ingredients?.map(\.food.name) == ["Milk", "Rolled oats"])
        #expect(saved.recipeServing?.grams == 180 && close(saved.per100g.energy, (60 * 4 + 380 * 0.8) / 3.6))
        #expect(nutrition.entries(on: monday).first?.nutrients.energy == bowl.nutrients.energy, "history is kept")
        #expect(try ExerlyJSON.decoder.decode(Food.self, from: ExerlyJSON.canonical(saved)) == saved)

        var none = porridge
        none.servingCount = 0
        #expect(none.recipeServing == nil)
        #expect(throws: NutritionStore.StoreError.invalid(["the serving count must be positive"])) {
            try nutrition.saveFood(none)
        }
        #expect(Foods.oats.recipeGrams == nil && Foods.oats.recipeServing == nil)
    }

    @Test func aQuickAddLogsWholePortionNutrientsWithoutAFoodOrAWeight() throws {
        let nutrition = try store()
        try nutrition.saveFood(Foods.oats)
        _ = try nutrition.log(Foods.oats, grams: 80, on: monday, meal: "Breakfast")
        let quick = try nutrition.quickAdd(NutrientAmounts([.energy: 450, .protein: 30, .fat: 15]), name: "  Restaurant lunch ",
                                           on: monday, meal: "Lunch")
        #expect(quick.nutrients == NutrientAmounts([.energy: 450, .protein: 30, .fat: 15]))
        #expect(quick.nutrients[.carbohydrate] == nil, "an unknown macro stays unknown")
        #expect(quick.food.unweighed == true && quick.food.name == "Restaurant lunch" && quick.serving == nil)
        #expect(quick.food.foodID == "quick:\(quick.id.uuidString)" && nutrition.food(quick.food.foodID) == nil)
        #expect(nutrition.foods.count == 1, "no reusable food is created")
        #expect(nutrition.recentFoods().map(\.foodID) == [Foods.oats.id])
        #expect(try nutrition.quickAdd(NutrientAmounts([.energy: 200]), name: " ", on: monday, meal: "Snacks").food.name == "Quick add")

        let corrected = quick.editingNutrients(NutrientAmounts([.energy: 500, .protein: 30, .fat: 15]))
        try nutrition.saveEntry(corrected)
        #expect(nutrition.entries(on: monday).first { $0.id == quick.id }?.nutrients[.energy] == 500)
        #expect(try ExerlyJSON.decoder.decode(FoodEntry.self, from: ExerlyJSON.canonical(corrected)) == corrected)
        let copied = try nutrition.copy([quick.id], to: monday.adding(days: 1))
        #expect(copied.first?.food.unweighed == true && copied.first?.nutrients[.energy] == 500)

        #expect(throws: NutritionStore.StoreError.invalid(["give calories or a macronutrient"])) {
            try nutrition.quickAdd(NutrientAmounts([.sodium: 300]), on: monday, meal: "Lunch")
        }
        #expect(throws: NutritionStore.StoreError.self) {
            try nutrition.quickAdd(NutrientAmounts([.energy: -10]), on: monday, meal: "Lunch")
        }
    }

    @Test func switchingAnAmountToANamedServingKeepsTheAmount() throws {
        let soup = Food(name: "Synthetic soup", per100g: NutrientAmounts([.energy: 50, .sodium: 300]),
                        servings: [Serving("1 cup", grams: 240)])
        let cup = soup.servings[0]
        let entered = try NutritionStore.preview(soup, grams: 180)
        let quantity = cup.quantity(grams: entered.grams)
        #expect(quantity == 0.75)
        let switched = try NutritionStore.preview(soup, serving: cup, quantity: quantity)
        #expect(switched.grams == 180 && switched.quantity == 0.75 && switched.serving == cup)
        #expect(switched.nutrients == entered.nutrients)
        #expect(switched.nutrients[.protein] == nil, "an unknown nutrient stays unknown")
        for tenths in 1...100 {
            let grams = Double(tenths) * 7.3
            #expect(abs(cup.quantity(grams: grams) * cup.grams - grams) < 1e-9)
        }
    }

    @Test func anEntrysNutrientsCanBeCorrectedWithoutChangingItsFood() throws {
        let nutrition = try store()
        try nutrition.saveFood(Foods.oats)
        let entry = try nutrition.log(Foods.oats, grams: 80, on: monday, meal: "Breakfast")
        let corrected = entry.editingNutrients(NutrientAmounts([.energy: 320, .protein: 12]))
        try nutrition.saveEntry(corrected)
        let saved = try #require(nutrition.entries(on: monday).first)
        #expect(close(saved.nutrients.energy, 320) && close(saved.nutrients[.protein], 12) && saved.nutrients[.fat] == nil)
        #expect(saved.food.edited == true && saved.food.foodID == Foods.oats.id && saved.food.source == .custom)
        #expect(nutrition.food(Foods.oats.id)?.per100g == Foods.oats.per100g, "the library keeps its label")
        var doubled = saved
        doubled.grams = 160
        #expect(close(doubled.nutrients.energy, 640))
        #expect(try ExerlyJSON.decoder.decode(FoodEntry.self, from: ExerlyJSON.canonical(saved)) == saved)
        #expect(entry.food.edited == nil)
    }

    @Test func editingAFoodLeavesItsHistoryAlone() throws {
        let nutrition = try store()
        try nutrition.saveFood(Foods.oats)
        let entry = try nutrition.log(Foods.oats, grams: 100, on: monday, meal: "Breakfast")
        var changed = Foods.oats
        changed.per100g[.energy] = 999
        try nutrition.saveFood(changed)
        #expect(nutrition.entries(on: monday).first?.nutrients.energy == 380)
        #expect(nutrition.food(Foods.oats.id)?.per100g.energy == 999)
        try nutrition.archiveFood(Foods.oats.id)
        #expect(nutrition.food(Foods.oats.id)?.archivedAt != nil)
        #expect(nutrition.entries(on: monday).map(\.id) == [entry.id])
    }

    @Test func aMealCopiesToAnotherDayAsNewEntries() throws {
        let nutrition = try store()
        try nutrition.log(Foods.oats, grams: 80, on: monday, meal: "Breakfast")
        try nutrition.log(Foods.chicken, grams: 150, on: monday, meal: "Lunch")
        let tuesday = monday.adding(days: 1)
        let copied = try nutrition.copy(from: monday, meal: "Breakfast", to: tuesday)
        #expect(copied.count == 1 && copied[0].date == tuesday && copied[0].food.name == "Rolled oats")
        #expect(nutrition.entries(on: tuesday).map(\.id) == copied.map(\.id))
        #expect(nutrition.recentFoods().map(\.name) == ["Rolled oats", "Chicken breast"])
    }

    @Test func aPlateLogsAllOrNoneAndEntriesCopyAndMove() throws {
        let nutrition = try store()
        let plate = try nutrition.log([.init(Foods.oats, serving: Foods.oats.servings[0], quantity: 2), .init(Foods.milk, grams: 244)],
                                      on: monday, meal: "Breakfast")
        #expect(plate.map(\.grams) == [80, 244] && nutrition.entries(on: monday).count == 2)
        #expect(throws: NutritionStore.StoreError.invalid(["Chicken breast: the amount must be a positive weight"])) {
            try nutrition.log([.init(Foods.oats, grams: 50), .init(Foods.chicken, grams: 0)], on: monday, meal: "Lunch")
        }
        #expect(nutrition.entries(on: monday).count == 2, "Nothing from a refused plate is saved")

        let tuesday = monday.adding(days: 1)
        let copied = try nutrition.copy([plate[0].id], to: tuesday, meal: "Snacks")
        #expect(copied.count == 1 && copied[0].id != plate[0].id && copied[0].meal == "Snacks" && copied[0].grams == 80)
        try nutrition.move([plate[1].id], to: tuesday)
        let moved = try #require(nutrition.entries.first { $0.id == plate[1].id })
        #expect(moved.date == tuesday && moved.meal == "Breakfast" && moved.loggedAt == plate[1].loggedAt)
        #expect(throws: NutritionStore.StoreError.notFound) { try nutrition.move([copied[0].id, UUID()], to: monday) }
        #expect(nutrition.entries(on: tuesday).count == 2, "Nothing moves when one entry is missing")
        #expect(throws: NutritionStore.StoreError.invalid(["the meal needs a name up to 40 characters"])) {
            try nutrition.copy(from: tuesday, meal: nil, to: monday, meal: " ")
        }
    }

    @Test func aRecipePortionLogsAsItsScaledIngredients() throws {
        let nutrition = try store()
        let porridge = Food.recipe(name: "Porridge", ingredients: [RecipeIngredient(food: Foods.oats.snapshot, grams: 80),
                                                                   RecipeIngredient(food: Foods.milk.snapshot, grams: 300)],
                                   yieldGrams: 400, servings: [Serving("1 bowl", grams: 200)])
        let parts = try nutrition.logIngredients(of: porridge, serving: porridge.servings[0], on: monday, meal: "Breakfast")
        #expect(parts.map(\.food.name) == ["Rolled oats", "Milk"] && parts.map(\.grams) == [40, 150])
        let whole = try NutritionStore.preview(porridge, grams: 200).nutrients
        #expect(close(parts.reduce(0) { $0 + $1.nutrients.energy }, whole.energy))
        #expect(throws: NutritionStore.StoreError.invalid(["Rolled oats has no ingredients"])) {
            try nutrition.logIngredients(of: Foods.oats, grams: 100, on: monday, meal: "Breakfast")
        }
    }

    @Test func suggestionsAreTheFoodsUsuallyLoggedAroundThisTimeOfDay() throws {
        let nutrition = try store()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Fixture.newYork
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        let today = LocalDate("2026-10-12")!
        for day in 5...9 { try nutrition.log(Foods.oats, serving: Foods.oats.servings[0], on: LocalDate("2026-10-0\(day)")!, meal: "Breakfast", at: at(day, 8)) }
        for day in 8...9 { try nutrition.log(Foods.milk, grams: 200, on: LocalDate("2026-10-0\(day)")!, meal: "Breakfast", at: at(day, 8, 30)) }
        for day in 5...10 { try nutrition.log(Foods.chicken, grams: 150, on: LocalDate("2026-10-\(String(format: "%02d", day))")!, meal: "Lunch", at: at(day, 13)) }
        // Logged on the 10th for the 9th: when it was eaten is unknown.
        let late = try nutrition.log(Foods.milk, grams: 100, on: LocalDate("2026-10-09")!, meal: "Breakfast", at: at(10, 7))

        let morning = nutrition.suggestions(at: at(12, 7, 45), timeZone: Fixture.newYork)
        #expect(morning.map(\.food.name) == ["Rolled oats", "Milk"] && morning.map(\.days) == [5, 2])
        #expect(morning[0].serving == Foods.oats.servings[0] && morning[0].meal == "Breakfast" && morning[1].grams == 200)
        #expect(!morning.contains { $0.grams == late.grams })
        #expect(nutrition.suggestions(at: at(12, 13, 20), timeZone: Fixture.newYork).map(\.food.name) == ["Chicken breast"])

        // A saved food's current nutrients, and nothing already logged today or archived.
        var richer = Foods.oats
        richer.per100g[.energy] = 400
        try nutrition.saveFood(richer)
        try nutrition.saveFood(Foods.milk)
        let current = try #require(nutrition.suggestions(at: at(12, 7, 45), timeZone: Fixture.newYork).first)
        #expect(current.food.per100g.energy == 400)
        try nutrition.archiveFood(Foods.milk.id)
        let logged = try nutrition.log(current, on: today)
        #expect(logged.meal == "Breakfast" && logged.grams == 40 && logged.food.per100g.energy == 400)
        #expect(nutrition.suggestions(at: at(12, 7, 45), timeZone: Fixture.newYork).isEmpty)
    }

    @Test func invalidEntriesAndWeighInsAreRefused() throws {
        let nutrition = try store()
        #expect(throws: NutritionStore.StoreError.self) { try nutrition.log(Foods.oats, grams: 0, on: monday, meal: "Breakfast") }
        #expect(throws: NutritionStore.StoreError.self) { try nutrition.log(Foods.oats, grams: 10, on: monday, meal: " ") }
        var bad = Foods.oats
        bad.per100g[.protein] = -1
        #expect(throws: NutritionStore.StoreError.invalid(["protein must be a number of 0 or more"])) { try nutrition.saveFood(bad) }
        #expect(throws: NutritionStore.StoreError.self) { try nutrition.logWeight(.kg(5), timeZone: Fixture.utc) }
        // 23:30 in New York is the next day in UTC; the weigh-in counts for the local day.
        let late = try nutrition.logWeight(.lb(180), at: Date(timeIntervalSince1970: 1_791_257_400), timeZone: Fixture.newYork)
        #expect(late.date == LocalDate("2026-10-05"))
    }

    @Test func everythingPersistsAndDaysMergeFieldByField() async throws {
        let persistence = InMemoryTrainingPersistence()
        let nutrition = try store(persistence)
        try nutrition.saveFood(Foods.milk)
        try nutrition.log(Foods.milk, grams: 244, on: monday, meal: "Breakfast")
        try nutrition.setStatus(.complete, on: monday)
        try nutrition.logWeight(.kg(80.4), timeZone: Fixture.utc)
        let reopened = try store(persistence)
        #expect(reopened.foods == nutrition.foods && reopened.entries == nutrition.entries)
        #expect(reopened.day(monday).status == .complete && reopened.weights == nutrition.weights)

        // Two devices: one marks the day fasting, the other adds a note.
        let server = FakeDocumentServer()
        let phoneStore = InMemoryTrainingPersistence(), tabletStore = InMemoryTrainingPersistence()
        let phone = try store(phoneStore), tablet = try store(tabletStore)
        let phoneSync = SyncEngine(hosts: [phone], state: phoneStore, api: server)
        let tabletSync = SyncEngine(hosts: [tablet], state: tabletStore, api: server)
        try phone.log(Foods.oats, grams: 40, on: monday, meal: "Breakfast")
        try phone.setNotes("Travel day", on: monday)
        try await phoneSync.sync()
        try await tabletSync.sync()
        #expect(tablet.entries(on: monday).count == 1 && tablet.day(monday).notes == "Travel day")
        try phone.setStatus(.partial, on: monday)
        try tablet.setNotes("Travel day, hotel breakfast", on: monday)
        try await phoneSync.sync()
        try await tabletSync.sync()
        try await phoneSync.sync()
        #expect(phone.day(monday) == tablet.day(monday))
        #expect(phone.day(monday).status == .partial && phone.day(monday).notes == "Travel day, hotel breakfast")
    }
}
