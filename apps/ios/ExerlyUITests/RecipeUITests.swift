import XCTest

/// Recipes: built from food search, saved from a meal, logged like any food,
/// and edited without touching what was logged before.
@MainActor
final class RecipeUITests: ExerlyUITestCase {
    private struct Kitchen {
        let oats = SeedFood(name: "Rolled oats", per100g: ["energy": 380, "protein": 13, "carbohydrate": 67, "fat": 7])
        let milk = SeedFood(name: "Whole milk", per100g: ["energy": 61, "protein": 3.2, "carbohydrate": 4.8, "fat": 3.3])
        let banana = SeedFood(name: "Banana", per100g: ["energy": 89, "protein": 1.1, "carbohydrate": 22.8, "fat": 0.3])
        let recipeID = UUID().uuidString
    }

    /// Three foods logged at yesterday's breakfast and today's, and a recipe
    /// made of them: 80 g oats, 300 g milk and 120 g banana cooked to 450 g,
    /// two servings of 297 kcal.
    private func seedKitchen(token: String) async throws -> Kitchen {
        let kitchen = Kitchen()
        for food in [kitchen.oats, kitchen.milk, kitchen.banana] {
            let payload: [String: Any] = ["id": food.id, "name": food.name, "source": "custom", "per100g": food.per100g,
                                          "servings": [], "favorite": false, "createdAt": "2026-10-01T12:00:00.000Z"]
            _ = try await request("PUT", "/v1/documents/saved_food/\(food.id)", body: ["base_revision": 0, "payload": payload], token: token)
        }
        for days in [1, 0] {
            try await seedEntry(kitchen.oats, grams: 80, daysAgo: days, meal: "Breakfast", token: token)
            try await seedEntry(kitchen.milk, grams: 250, daysAgo: days, meal: "Breakfast", token: token)
            try await seedEntry(kitchen.banana, grams: 120, daysAgo: days, meal: "Breakfast", token: token)
        }
        func ingredient(_ food: SeedFood, _ grams: Double) -> [String: Any] {
            ["food": ["foodID": food.id, "name": food.name, "source": "custom", "per100g": food.per100g], "grams": grams]
        }
        // The ingredients' totals over the 450 g cooked weight.
        let per100g: [String: Double] = ["energy": 131.96, "protein": 4.7378, "carbohydrate": 21.191, "fat": 3.5244]
        let ingredients: [[String: Any]] = [ingredient(kitchen.oats, 80), ingredient(kitchen.milk, 300), ingredient(kitchen.banana, 120)]
        let recipe: [String: Any] = [
            "id": kitchen.recipeID, "name": "Banana oat porridge", "source": "recipe", "servings": [String](), "favorite": false,
            "createdAt": "2026-10-02T12:00:00.000Z", "yieldGrams": 450.0, "servingCount": 2.0,
            "preparation": "Simmer the oats in the milk for five minutes, then stir in the sliced banana.",
            "ingredients": ingredients, "per100g": per100g
        ]
        _ = try await request("PUT", "/v1/documents/saved_food/\(kitchen.recipeID)", body: ["base_revision": 0, "payload": recipe], token: token)
        return kitchen
    }

    /// Today's date where the fixture account lives, and an instant an hour ago.
    private func today() -> (date: String, at: String) {
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.timeZone = TimeZone(identifier: "America/New_York")!
        day.dateFormat = "yyyy-MM-dd"
        let instant = ISO8601DateFormatter()
        instant.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let at = Date().addingTimeInterval(-3600)
        return (day.string(from: at), instant.string(from: at))
    }

    private func entries(_ name: String, in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "nutrition.entry.", name + ","))
    }

    /// Food search's saved foods: a segment, or a menu at the largest text sizes.
    private func showMyFoods(_ app: XCUIApplication) {
        if !app.buttons["My foods"].waitForExistence(timeout: 3) { tap(app.buttons["nutrition.listScope"], in: app) }
        tap(app.buttons["My foods"], in: app)
    }

    private func energy(_ app: XCUIApplication) -> String? {
        let hero = app.descendants(matching: .any)["nutrition.portionEnergy"]
        return hero.waitForExistence(timeout: 5) ? hero.label : nil
    }

    func testARecipeFromThreeIngredientsLogsOneServingWithItsTotals() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "recipe-create")
        let kitchen = try await seedKitchen(token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        tapCount = 0
        tap(app.buttons["nutrition.addFood"], in: app)
        showMyFoods(app)
        tap(app.buttons["nutrition.createRecipeRow"], in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The name is ready to type")
        app.descendants(matching: .any)["recipe.name"].typeText("Banana oat bowl")
        tap(app.buttons["recipe.addIngredients"], in: app)
        for food in [kitchen.oats, kitchen.milk, kitchen.banana] { addAtUsualAmount(food, in: app) }
        XCTAssertEqual(app.buttons["nutrition.reviewPlate"].label, "Review recipe · 3 foods")
        tap(app.buttons["nutrition.reviewPlate"], in: app)
        XCTAssertEqual(energy(app), "563 kilocalories", "One serving is the whole bowl: 304 + 152.5 + 106.8 kcal")
        tap(app.buttons["2"], in: app)
        XCTAssertEqual(energy(app), "282 kilocalories", "Two servings split it")
        XCTAssertTrue(app.descendants(matching: .any)["recipe.per100g"].label.hasPrefix("Per 100 g, 125 kilocalories"),
                      "563.3 kcal over the ingredients' 450 g")
        tap(app.buttons["recipe.save"], in: app)
        XCTAssertEqual(tapCount, 13, "Search, My foods, Create a recipe, Add ingredients, three + and Add, Review, 2 servings, Save")

        // Saving from search goes straight to its portion: one serving.
        XCTAssertTrue(app.buttons["nutrition.saveEntry"].waitForExistence(timeout: 10))
        XCTAssertEqual(energy(app), "282 kilocalories")
        XCTAssertTrue(app.buttons["nutrition.measure.serving.1 serving.225.0"].isSelected)
        tap(app.buttons["nutrition.saveEntry"], in: app)
        XCTAssertEqual(tapCount, 14, "and Log")
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 10))
        let bowl = entries("Banana oat bowl", in: app).firstMatch
        XCTAssertTrue(bowl.waitForExistence(timeout: 5))
        XCTAssertTrue(bowl.label.hasSuffix("1 serving · 225 g, 282 calories"), bowl.label)
    }

    /// A food added to a recipe asks for its amount, starting from the one
    /// usually logged, with the keypad up; Add keeps it.
    private func addAtUsualAmount(_ food: SeedFood, in app: XCUIApplication) {
        tap(app.buttons["nutrition.plateAdd.\(food.id)"], in: app)
        let add = app.buttons["nutrition.pickPortionConfirm"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "\(food.name) asks for its amount")
        tap(add, in: app)
        XCTAssertTrue(add.waitForNonExistence(timeout: 5))
    }

    /// My foods in the picker on top, when another picker is open beneath it.
    private func showMyFoodsOnTop(_ app: XCUIApplication) {
        let scopes = app.descendants(matching: .any).matching(identifier: "nutrition.listScope")
        tap(scopes.element(boundBy: scopes.count - 1).buttons["My foods"], in: app)
    }

    /// Saved foods with named servings that were never logged.
    private func seedPantry(token: String) async throws -> (onion: SeedFood, beans: SeedFood) {
        let onion = SeedFood(name: "Synthetic onion", per100g: ["energy": 40, "protein": 1.1, "carbohydrate": 9.3, "fat": 0.1])
        let beans = SeedFood(name: "Synthetic kidney beans", per100g: ["energy": 135, "protein": 8.7, "carbohydrate": 24.7, "fat": 0.6])
        for (food, servings) in [(onion, [["name": "1 slice", "grams": 15.0], ["name": "1 whole", "grams": 148.0]]),
                                 (beans, [["name": "1 can", "grams": 260.0]])] {
            let payload: [String: Any] = ["id": food.id, "name": food.name, "source": "custom", "per100g": food.per100g,
                                          "servings": servings, "favorite": false, "createdAt": "2026-10-01T12:00:00.000Z"]
            _ = try await request("PUT", "/v1/documents/saved_food/\(food.id)", body: ["base_revision": 0, "payload": payload], token: token)
        }
        return (onion, beans)
    }

    /// Every ingredient asks for its amount as it's added, with the keypad up
    /// and every serving it has: a usual food starts at its usual amount, one
    /// never logged at its default. One left at its default is marked, and
    /// Save asks for it first.
    func testAnIngredientNeverLoggedAsksForItsAmountWithItsServings() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "recipe-ask")
        let kitchen = try await seedKitchen(token: person.token)
        let pantry = try await seedPantry(token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        tap(app.buttons["nutrition.addFood"], in: app)
        showMyFoods(app)
        tap(app.buttons["nutrition.createRecipeRow"], in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.descendants(matching: .any)["recipe.name"].typeText("Synthetic chili")
        tap(app.buttons["recipe.addIngredients"], in: app)

        tapCount = 0
        tap(app.buttons["nutrition.plateAdd.\(kitchen.oats.id)"], in: app)
        XCTAssertTrue(app.buttons["exerly.keypadDone"].waitForExistence(timeout: 5), "A usual food asks too, with the keypad up")
        XCTAssertEqual(app.textFields["nutrition.pickPortionAmount"].value as? String, "80", "Starting at its usual 80 g")
        capture(app, "recipe-ask-usual")
        tap(app.buttons["nutrition.pickPortionConfirm"], in: app)
        XCTAssertEqual(app.buttons["nutrition.reviewPlate"].label, "Review recipe · 1 food")

        showMyFoodsOnTop(app)
        tap(app.buttons["nutrition.plateAdd.\(pantry.onion.id)"], in: app)
        let add = app.buttons["nutrition.pickPortionConfirm"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "A food never logged asks for its amount")
        XCTAssertTrue(app.buttons["exerly.keypadDone"].waitForExistence(timeout: 5), "With the keypad up")
        let whole = app.buttons["nutrition.measure.serving.1 whole.148.0"]
        XCTAssertTrue(whole.exists, "Every serving the food has, not just its first")
        tap(whole, in: app)
        XCTAssertEqual(app.textFields["Number of servings"].value as? String, "1", "One whole onion, not 15 g in wholes")
        capture(app, "recipe-ask-onion")
        tap(add, in: app)
        XCTAssertEqual(app.buttons["nutrition.reviewPlate"].label, "Review recipe · 2 foods")
        XCTAssertEqual(tapCount, 6, "+ and Add for the oats; My foods, + for the onion, 1 whole, Add")

        // Swiped away, the beans still join at their default, marked to check.
        showMyFoodsOnTop(app)
        tap(app.buttons["nutrition.plateAdd.\(pantry.beans.id)"], in: app)
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        let bar = app.navigationBars["Add to recipe"]
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(add.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons["nutrition.reviewPlate"].label, "Review recipe · 3 foods")
        tap(app.buttons["nutrition.reviewPlate"], in: app)
        let onionRow = app.buttons["recipe.ingredient.\(pantry.onion.id)"]
        XCTAssertTrue(onionRow.label.contains("1 whole"), onionRow.label)
        let beansRow = app.buttons["recipe.ingredient.\(pantry.beans.id)"]
        reveal(beansRow, in: app)
        XCTAssertTrue(beansRow.label.hasSuffix("amount not checked yet"), beansRow.label)
        capture(app, "recipe-ask-unchecked")
        tap(app.buttons["recipe.save"], in: app)
        let done = app.buttons["recipe.ingredientConfirm"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Save opens the unchecked amount first")
        tap(done, in: app)
        XCTAssertFalse(app.buttons["recipe.ingredient.\(pantry.beans.id)"].label.contains("not checked"))
        tap(app.buttons["recipe.save"], in: app)
        XCTAssertTrue(app.buttons["nutrition.saveEntry"].waitForExistence(timeout: 10), "Saved, it opens to log")
    }

    /// Focusing an amount selects it, so digits replace it; Delete takes the
    /// last digit even with the caret at the start; and with the keypad up
    /// the sheet's Done is the only Done.
    func testTheAmountKeypadTypesOverTheAmountWithOneDone() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "recipe-keypad")
        let kitchen = try await seedKitchen(token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        tap(app.buttons["nutrition.addFood"], in: app)
        showMyFoods(app)
        tap(app.buttons["nutrition.createRecipeRow"], in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.descendants(matching: .any)["recipe.name"].typeText("Synthetic oats")
        tap(app.buttons["recipe.addIngredients"], in: app)
        addAtUsualAmount(kitchen.oats, in: app)
        tap(app.buttons["nutrition.reviewPlate"], in: app)
        tap(app.buttons["recipe.ingredient.\(kitchen.oats.id)"], in: app)

        let amount = app.textFields["recipe.ingredientAmount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        XCTAssertEqual(amount.value as? String, "80")
        tapCount = 0
        tap(amount, in: app)
        XCTAssertTrue(app.buttons["Hide keypad"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Done")).count, 1, "One Done: the sheet's")
        tap(app.buttons["exerly.keypad.1"], in: app)
        tap(app.buttons["exerly.keypad.5"], in: app)
        tap(app.buttons["exerly.keypad.0"], in: app)
        XCTAssertEqual(amount.value as? String, "150", "The first digit replaced 80")
        // The caret before every digit: Delete still removes the last one.
        amount.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap()
        tap(app.buttons["exerly.keypad.delete"], in: app)
        XCTAssertEqual(amount.value as? String, "15")
        tap(app.buttons["recipe.ingredientConfirm"], in: app)
        XCTAssertEqual(tapCount, 6, "The amount, three digits, Delete and Done: no clearing first")
        XCTAssertTrue(app.buttons["recipe.ingredient.\(kitchen.oats.id)"].label.contains("15 g"))
    }

    /// The meal's "…" menu saves it as a recipe, which the meal then offers.
    func testTheMealMenuSavesARecipeThatTheMealThenOffers() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "recipe-menu")
        _ = try await seedKitchen(token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        let menu = app.buttons["today.mealMenu.breakfast"]
        reveal(menu, in: app)
        XCTAssertEqual(menu.label, "Breakfast options", "A visible menu on the meal, not only a long press")
        tapCount = 0
        tap(menu, in: app)
        tap(app.buttons["Save as recipe"], in: app)
        XCTAssertTrue(app.navigationBars["New recipe"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.descendants(matching: .any)["recipe.name"].typeText("Work breakfast")
        tap(app.buttons["recipe.save"], in: app)
        XCTAssertEqual(tapCount, 3, "The meal's menu, Save as recipe, Save")
        XCTAssertTrue(app.staticTexts["Saved Work breakfast to your recipes"].waitForExistence(timeout: 5))

        tap(app.buttons["nutrition.add.breakfast"], in: app)
        let usual = app.descendants(matching: .any)["nutrition.group.suggested"]
        XCTAssertTrue(usual.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Usual for breakfast"].exists)
        XCTAssertTrue(usual.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Work breakfast")).firstMatch.exists,
                      "Breakfast offers the recipe made from it")
        capture(app, "recipe-menu-offered")
    }

    func testSavingAMealAsARecipeTakesThreeTaps() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "recipe-meal")
        _ = try await seedKitchen(token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        tapCount = 0
        openMealActions("Breakfast", in: app)
        tap(app.buttons["Save as recipe"], in: app)
        XCTAssertTrue(app.navigationBars["New recipe"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.ingredient.")).count, 3)
        XCTAssertEqual(energy(app), "563 kilocalories", "The meal as one serving")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Only the name is left to type")
        app.descendants(matching: .any)["recipe.name"].typeText("Usual breakfast")
        tap(app.buttons["recipe.save"], in: app)
        XCTAssertEqual(tapCount, 3, "Hold the meal, Save as recipe, Save")
        XCTAssertTrue(app.staticTexts["Saved Usual breakfast to your recipes"].waitForExistence(timeout: 5))
        XCTAssertEqual(entries("Rolled oats", in: app).count, 1, "The meal itself stays as it was")

        tap(app.buttons["nutrition.addFood"], in: app)
        let field = app.searchFields.firstMatch
        tap(field, in: app)
        field.typeText("Usual")
        let recipe = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "nutrition.food.", "Usual breakfast"))
        XCTAssertTrue(recipe.firstMatch.waitForExistence(timeout: 5), "The recipe is found like any saved food")
    }

    func testEditingARecipeLeavesTheEarlierEntryAlone() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "recipe-edit")
        let kitchen = try await seedKitchen(token: person.token)
        let (date, at) = today()
        let entryID = UUID().uuidString
        let entry: [String: Any] = [
            "id": entryID, "date": date, "meal": "Dinner", "loggedAt": at, "grams": 225.0, "quantity": 1.0,
            "serving": ["name": "1 serving", "grams": 225.0],
            "food": ["foodID": kitchen.recipeID, "name": "Banana oat porridge", "source": "recipe",
                     "per100g": ["energy": 131.96, "protein": 4.7378, "carbohydrate": 21.191, "fat": 3.5244]]
        ]
        _ = try await request("PUT", "/v1/documents/food_entry/\(entryID)", body: ["base_revision": 0, "payload": entry], token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        let logged = app.buttons["nutrition.entry.\(entryID)"]
        reveal(logged, in: app)
        XCTAssertTrue(logged.label.hasSuffix("297 calories"), logged.label)

        tapCount = 0
        openFoodLibrary(app)
        tap(app.buttons["nutrition.libraryFood.\(kitchen.recipeID)"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["recipe.details"].waitForExistence(timeout: 5))
        tap(app.buttons["nutrition.libraryActions"], in: app)
        tap(app.buttons["recipe.edit"], in: app)
        XCTAssertTrue(app.navigationBars["Edit recipe"].waitForExistence(timeout: 5))
        XCTAssertEqual(energy(app), "297 kilocalories")
        tap(app.buttons["recipe.ingredient.\(kitchen.oats.id)"], in: app)
        replace(app.textFields["recipe.ingredientAmount"], with: "160", in: app)
        tap(app.buttons["recipe.ingredientConfirm"], in: app)
        XCTAssertEqual(energy(app), "449 kilocalories", "Twice the oats: 897.8 kcal over 450 g, 225 g a serving")
        tap(app.buttons["recipe.save"], in: app)
        XCTAssertEqual(tapCount, 9, "Profile, Foods & recipes, the recipe, actions, Edit, the oats, their amount, Done, Save")
        XCTAssertTrue(app.navigationBars["Saved food"].waitForExistence(timeout: 5))

        // A copy to vary starts as a new recipe with the same ingredients.
        tap(app.buttons["nutrition.libraryActions"], in: app)
        tap(app.buttons["recipe.duplicate"], in: app)
        XCTAssertTrue(app.navigationBars["New recipe"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any)["recipe.name"].value as? String, "Banana oat porridge copy")
        XCTAssertEqual(energy(app), "449 kilocalories")
        tap(app.buttons["recipe.save"], in: app)

        tap(app.tabBars.buttons["Today"], in: app)
        reveal(logged, in: app)
        XCTAssertTrue(logged.label.hasSuffix("1 serving · 225 g, 297 calories"), "Logged before the edit, so unchanged: \(logged.label)")
    }

    func testARecipeLogsAsAShareOfThePotOrAsItsIngredients() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "recipe-share")
        let kitchen = try await seedKitchen(token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        tapCount = 0
        tap(app.buttons["nutrition.addFood"], in: app)
        showMyFoods(app)
        tap(app.buttons["nutrition.food.\(kitchen.recipeID)"], in: app)
        XCTAssertEqual(energy(app), "297 kilocalories", "One of two servings")
        tap(app.buttons["nutrition.measure.serving.whole recipe.450.0"], in: app)
        XCTAssertEqual(app.textFields["Share of the recipe"].value as? String, "0.5", "The same 225 g, as a share of the pot")
        tap(app.buttons["0.25"], in: app)
        XCTAssertEqual(energy(app), "148 kilocalories", "A quarter of 593.8 kcal")
        tap(app.buttons["nutrition.saveEntry"], in: app)
        XCTAssertEqual(tapCount, 6, "Search, My foods, the recipe, whole recipe, ¼, Log")
        let share = entries("Banana oat porridge", in: app).firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        XCTAssertTrue(share.label.contains("0.25 × whole recipe") && share.label.hasSuffix("148 calories"), share.label)

        // The same quarter as its ingredients, each a quarter of its amount.
        tap(app.buttons["nutrition.addFood"], in: app)
        showMyFoods(app)
        tap(app.buttons["nutrition.food.\(kitchen.recipeID)"], in: app)
        // The switch itself sits at the row's trailing edge; its label doesn't toggle it.
        let expand = app.switches["nutrition.logIngredients"]
        reveal(expand, in: app)
        expand.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(expand.value as? String, "1")
        tap(app.buttons["nutrition.saveEntry"], in: app)
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 10))
        let oats = entries("Rolled oats", in: app)
        XCTAssertTrue(oats.element(boundBy: 1).waitForExistence(timeout: 5))
        XCTAssertEqual(oats.count, 2, "Breakfast's oats and the recipe's")
        XCTAssertTrue(oats.allElementsBoundByIndex.contains { $0.label == "Rolled oats, 20 g, 76 calories" },
                      oats.allElementsBoundByIndex.map(\.label).joined(separator: "; "))
        XCTAssertEqual(entries("Banana oat porridge", in: app).count, 1)
    }

    /// The chili a code-blind tester took 34 actions to build: each
    /// ingredient's amount typed with it, so one tap adds it. "1 can" is the
    /// package size Open Food Facts gives; "1 onion" a whole one.
    func testAChiliWithTypedAmountsTakesUnderTwentyActions() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "recipe-typed")
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        tapCount = 0
        var typed = 0
        func type(_ text: String) {
            app.typeText(text)
            typed += 1
        }
        tap(app.buttons["nutrition.addFood"], in: app)
        openMoreWaysToLog("nutrition.newRecipe", in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        type("Synthetic chili")
        tap(app.buttons["recipe.addIngredients"], in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Search is ready to type")
        for (query, id) in [("500 g ground beef", "usda:2705853"), ("1 can kidney beans", "off:0041000000016"),
                            ("1 can diced tomatoes", "off:0041000000023"), ("1 onion", "usda:2709795")] {
            type(query)
            let add = app.buttons["nutrition.plateAdd.\(id)"]
            XCTAssertTrue(add.waitForExistence(timeout: 10), query)
            if id == "off:0041000000016" { capture(app, "recipe-typed-can") }
            tap(add, in: app)
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Cleared and ready for the next food")
        }
        XCTAssertEqual(app.buttons["nutrition.reviewPlate"].label, "Review recipe · 4 foods")
        tap(app.buttons["nutrition.reviewPlate"], in: app)
        for (id, amount) in [("usda:2705853", "500 g"), ("off:0041000000016", "1 can · 425 g"), ("off:0041000000023", "1 can · 411 g"),
                             ("usda:2709795", "1 whole · 148 g")] {
            let row = app.buttons["recipe.ingredient.\(id)"]
            XCTAssertTrue(row.label.contains(amount), "\(amount): \(row.label)")
        }
        tap(app.buttons["4"], in: app)
        XCTAssertEqual(energy(app), "392 kilocalories", "1,569 kcal in four servings")
        capture(app, "recipe-typed-chili")
        tap(app.buttons["recipe.save"], in: app)
        XCTAssertTrue(app.buttons["nutrition.saveEntry"].waitForExistence(timeout: 10), "Saved, it opens to log")
        XCTAssertEqual(tapCount, 11, "Search, More, Create a recipe, Add ingredients, four +, Review, 4 servings, Save")
        XCTAssertEqual(tapCount + typed, 16, "Under 20 actions with the name and four foods typed (34 before)")
    }

    /// Usability run 5's overnight oats, typed: 80 g rolled oats, 200 g milk,
    /// 150 g Greek yogurt and 100 g blueberries, two jars, then one logged.
    func testOvernightOatsWithTypedAmountsAndOneJarLogged() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "recipe-oats")
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        tapCount = 0
        var typed = 0
        tap(app.buttons["nutrition.addFood"], in: app)
        openMoreWaysToLog("nutrition.newRecipe", in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("Overnight oats")
        typed += 1
        tap(app.buttons["recipe.addIngredients"], in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        for (query, id) in [("80 g rolled oats", "usda:2708489"), ("200 g milk", "usda:2705384"),
                            ("150 g greek yogurt", "usda:2705422"), ("100 g blueberries", "usda:2709275")] {
            app.typeText(query)
            typed += 1
            let add = app.buttons["nutrition.plateAdd.\(id)"]
            XCTAssertTrue(add.waitForExistence(timeout: 10), query)
            tap(add, in: app)
            XCTAssertFalse(app.buttons["nutrition.pickPortionConfirm"].waitForExistence(timeout: 1), "A typed amount needs no confirming")
        }
        tap(app.buttons["nutrition.reviewPlate"], in: app)
        tap(app.buttons["2"], in: app)
        XCTAssertEqual(energy(app), "306 kilocalories", "303.2 + 104 + 141 + 64 kcal in two jars")
        tap(app.buttons["recipe.save"], in: app)
        let log = app.buttons["nutrition.saveEntry"]
        XCTAssertTrue(log.waitForExistence(timeout: 10))
        XCTAssertEqual(energy(app), "306 kilocalories", "It opens at one jar")
        tap(log, in: app)
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 10))
        let jar = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "nutrition.entry.", "Overnight oats"))
            .firstMatch
        reveal(jar, in: app)
        XCTAssertTrue(jar.label.hasSuffix("306 calories"), jar.label)
        XCTAssertEqual(tapCount, 12, "Search, More, Create a recipe, Add ingredients, four +, Review, 2 jars, Save, Log")
        XCTAssertEqual(tapCount + typed, 17, "51 actions in usability run 5")
    }

    /// A unit the food has no measure for opens its portion step instead.
    func testATypedAmountAFoodCannotTakeAsksForOne() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "recipe-typed-ask")
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        tap(app.buttons["nutrition.addFood"], in: app)
        openMoreWaysToLog("nutrition.buildMeal", in: app)
        tap(app.buttons["Choose foods"], in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("2 cans kidney beans")
        let generic = app.buttons["nutrition.plateAdd.usda:2707379"]
        XCTAssertTrue(generic.waitForExistence(timeout: 10))
        XCTAssertEqual(generic.label, "Choose an amount of Kidney beans, NFS", "USDA gives no can size")
        tap(generic, in: app)
        XCTAssertTrue(app.buttons["nutrition.pickPortionConfirm"].waitForExistence(timeout: 5), "Its portion step, to choose")
        tap(app.buttons["nutrition.pickPortionCancel"], in: app)
        let canned = app.buttons["nutrition.plateAdd.off:0041000000016"]
        XCTAssertTrue(canned.label.hasPrefix("Add 2 × 1 can · 850 g"), "The canned beans take two cans: \(canned.label)")
    }

    /// An option in food search's More menu. Revealing it first would scroll
    /// the menu closed, so it's tapped where it appears, and counted.
    private func openMoreWaysToLog(_ option: String, in app: XCUIApplication) {
        tap(app.buttons["nutrition.moreFoodOptions"], in: app)
        let item = app.buttons[option]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        tapCount += 1
    }

    /// Screens for review, in light and dark, at the default and largest text.
    func testRecipesCapture() async throws {
        guard ProcessInfo.processInfo.environment["EXERLY_DESIGN_CAPTURE"] == "1" else { throw XCTSkip("Opt-in visual review") }
        try await control([:])
        let person = try await createAccount(prefix: "recipe-capture")
        let kitchen = try await seedKitchen(token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        openMealActions("Breakfast", in: app)
        capture(app, "after-01-meal-menu")
        tap(app.buttons["Save as recipe"], in: app)
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        app.descendants(matching: .any)["recipe.name"].typeText("Usual breakfast")
        capture(app, "after-02-meal-recipe")
        tap(app.buttons["recipe.save"], in: app)
        capture(app, "after-03-saved")

        tap(app.buttons["nutrition.addFood"], in: app)
        showMyFoods(app)
        capture(app, "after-04-picker-my-foods")
        tap(app.buttons["nutrition.createRecipeRow"], in: app)
        capture(app, "after-05-new-recipe")
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        app.descendants(matching: .any)["recipe.name"].typeText("Banana oat bowl")
        tap(app.buttons["recipe.addIngredients"], in: app)
        for food in [kitchen.oats, kitchen.milk, kitchen.banana] { addAtUsualAmount(food, in: app) }
        capture(app, "after-06-picking")
        tap(app.buttons["nutrition.reviewPlate"], in: app)
        tap(app.buttons["2"], in: app)
        dismissKeyboard(app)
        app.swipeDown()
        capture(app, "after-07-recipe")
        app.swipeUp()
        capture(app, "after-08-recipe-yield")
        let milk = app.buttons["recipe.ingredient.\(kitchen.milk.id)"]
        revealAbove(milk, in: app)
        tap(milk, in: app)
        capture(app, "after-09-ingredient")
        tap(app.buttons["recipe.ingredientConfirm"], in: app)
        tap(app.buttons["recipe.save"], in: app)
        XCTAssertTrue(app.buttons["nutrition.saveEntry"].waitForExistence(timeout: 10))
        capture(app, "after-10-recipe-portion")
        // At the largest text sizes the measures scroll sideways, past the screen's edge.
        let pot = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "nutrition.measure.serving.whole recipe")).firstMatch
        if !pot.isHittable { app.buttons["nutrition.measure.grams"].swipeLeft() }
        tap(pot, in: app)
        capture(app, "after-11-share-of-pot")
        tap(app.buttons["nutrition.saveEntry"], in: app)

        openFoodLibrary(app)
        capture(app, "after-12-library")
        tap(app.buttons["nutrition.libraryFood.\(kitchen.recipeID)"], in: app)
        capture(app, "after-13-library-recipe")
        app.swipeUp()
        capture(app, "after-14-library-recipe-details")
        tap(app.buttons["nutrition.libraryActions"], in: app)
        capture(app, "after-15-library-actions")
    }
}
