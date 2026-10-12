import Foundation
import Testing
@testable import ExerlyCore

@Suite struct RecipeImportTests {
    func read(_ text: String) -> (TypedAmount?, String) {
        let line = IngredientLine(text)
        return (line.amount, line.food)
    }

    @Test func recipeLinesReadAsTypedAmountsWithTheirNotesSetAside() {
        #expect(read("2 cups flour") == (TypedAmount(2, .cups), "flour"))
        #expect(read("½ tsp salt") == (TypedAmount(0.5, .teaspoons), "salt"))
        #expect(read("1 ½ cups whole milk") == (TypedAmount(1.5, .cups), "whole milk"))
        #expect(read("1⁄2 cup sugar") == (TypedAmount(0.5, .cups), "sugar"), "The fraction slash recipe pages write")
        #expect(read("⅓ cup olive oil") == (TypedAmount(1.0 / 3, .cups), "olive oil"))
        #expect(read("⅞ cup water") == (TypedAmount(0.875, .cups), "water"))
        #expect(read("3 cloves garlic, minced") == (TypedAmount(3, .serving("clove")), "garlic"))
        #expect(read("1 lime, juiced") == (TypedAmount(1), "lime"))
        #expect(read("2 large eggs") == (TypedAmount(2, .serving("large")), "eggs"))
        #expect(read("2 tablespoons extra-virgin olive oil") == (TypedAmount(2, .tablespoons), "olive oil"))
        #expect(read("2 boneless, skinless chicken breasts") == (TypedAmount(2), "chicken breasts"),
                "A comma before the food isn't where its notes start")
        #expect(read("about 2 cups chopped onion") == (TypedAmount(2, .cups), "onion"))
        #expect(read("1 cup butter or margarine") == (TypedAmount(1, .cups), "butter"))
        #expect(read("1,5 kg potatoes") == (TypedAmount(1.5, .kilograms), "potatoes"), "A decimal comma isn't a note")
        #expect(read("Salt and pepper, to taste") == (nil, "Salt and pepper"))
        #expect(read("salt to taste") == (nil, "salt"))
        #expect(read("400g chickpeas") == (TypedAmount(400, .grams), "chickpeas"))
    }

    // Lines as real recipe pages write them, where the first reading went wrong.
    @Test func servingsAfterTheFoodContainersAfterAWeightAndServingNotesAreSetAside() {
        #expect(read("2 garlic cloves") == (TypedAmount(2, .serving("clove")), "garlic"))
        #expect(read("4 strips bacon") == (TypedAmount(4, .serving("strip")), "bacon"))
        #expect(read("410g can red kidney beans") == (TypedAmount(410, .grams), "red kidney beans"))
        let can = IngredientLine("1 14-oz can whole tomatoes")
        #expect(can.amount == TypedAmount(1, .serving("can")) && can.size == TypedAmount(14, .ounces) && can.food == "whole tomatoes")
        #expect(read("500g lean minced beef") == (TypedAmount(500, .grams), "lean minced beef"), "Minced beef is ground beef, not beef")
        #expect(read("1 heaped tsp hot chilli powder") == (TypedAmount(1, .teaspoons), "hot chilli powder"))
        #expect(read("soured cream to serve") == (nil, "soured cream"))
        #expect(read("2 lemons") == (TypedAmount(2), "lemons"), "Only serving words move")
    }

    @Test func aSizeInParenthesesIsEachContainersWeightOrTheWholeAmounts() {
        let can = IngredientLine("1 (15 oz) can black beans, drained and rinsed")
        #expect(can.amount == TypedAmount(1, .serving("can")) && can.food == "black beans")
        #expect(can.size == TypedAmount(15, .ounces))
        #expect(can.query == "1 can black beans", "What search is given to resolve it")
        #expect(IngredientLine("2 (15-ounce) cans kidney beans").size == TypedAmount(15, .ounces))
        let cups = IngredientLine("2 cups (250 g) all-purpose flour")
        #expect(cups.amount == TypedAmount(2, .cups) && cups.size == TypedAmount(250, .grams) && cups.food == "all-purpose flour")
        #expect(IngredientLine("1 cup (about 2 medium) onion").size == nil, "Not a weight")
        #expect(IngredientLine("1 cup milk (optional)").size == nil)

        let beans = Food(name: "Black beans, from canned, no added fat", source: .usda, per100g: NutrientAmounts([.energy: 134]),
                         servings: [Serving("1 cup", grams: 180)])
        // Drained and rinsed: 60 % of the can's 425 g, about 340 kcal rather than 570, to check.
        let one = can.portion(of: beans)
        #expect(can.drained)
        #expect(one?.amount.serving == Serving("1 can, drained (9 oz)", grams: 9 * USUnits.gramsPerOunce))
        #expect(one?.amount.quantity == 1 && one?.exact == false)
        #expect(one.map { ($0.amount.grams * 1.34).rounded() } == 342)
        let two = IngredientLine("2 (15 oz) cans black beans").portion(of: beans)
        #expect(two.map { abs($0.amount.grams - 30 * USUnits.gramsPerOunce) < 0.001 && $0.exact } == true, "Undrained, the label's weight")
        #expect(!IngredientLine("1 (14 oz) can tomatoes, undrained").drained)
        let flour = Food(name: "Flour", per100g: NutrientAmounts([.energy: 364]))
        #expect(cups.portion(of: flour).map { ($0.amount.grams, $0.amount.serving, $0.exact) } ?? (0, nil, false) == (250, nil, true),
                "The weight beats a cup of flour by density")
    }

    @Test func aRangeReadsAsItsFirstNumberToCheck() {
        let garlic = IngredientLine("2-3 cloves garlic")
        #expect(garlic.amount == TypedAmount(2, .serving("clove")) && garlic.range)
        #expect(IngredientLine("2 to 3 tbsp honey").amount == TypedAmount(2, .tablespoons))
        let mixed = IngredientLine("1-1/2 cups water")
        #expect(mixed.amount == TypedAmount(1.5, .cups) && !mixed.range, "One and a half, not one to a half")
        let clove = Food(name: "Garlic, raw", source: .usda, per100g: NutrientAmounts([.energy: 143]), servings: [Serving("1 clove", grams: 3)])
        #expect(garlic.portion(of: clove)?.exact == false)
        #expect(IngredientLine("2 cloves garlic").portion(of: clove)?.exact == true)
    }

    let beans = Food(name: "Black beans, NFS", source: .usda, per100g: NutrientAmounts([.energy: 181, .protein: 11]),
                     servings: [Serving("1 cup", grams: 185)])
    let rice = Food(name: "Rice, cooked, NFS", source: .usda, per100g: NutrientAmounts([.energy: 129]), servings: [Serving("1 cup, cooked", grams: 158)])
    let mine = Food(name: "Rice cooked", per100g: NutrientAmounts([.energy: 130]), servings: [Serving("1 cup", grams: 160)])

    @Test func linesMatchTheirOwnFoodByNameFirstThenTheDatabase() throws {
        let page = WebRecipe(name: "Bean bowl", ingredients: ["1 (15 oz) can black beans, drained", "1 cup cooked rice", "½ tsp salt",
                                                              "black beans"],
                             servings: 2, instructions: "1. Warm.\n2. Serve.", url: "https://recipes.example/bowl")
        let imported = RecipeImport(page: page, own: [mine], database: [beans, rice, nil, beans], unit: .kilograms)
        #expect(imported.name == "Bean bowl" && imported.servingCount == 2 && imported.preparation == "1. Warm.\n2. Serve.")
        #expect(imported.sourceURL == "https://recipes.example/bowl")
        #expect(imported.unmatched == ["½ tsp salt"])
        try #require(imported.ingredients.count == 3)
        #expect(imported.ingredients[0].ingredient.food.foodID == beans.id && !imported.ingredients[0].exact, "Drained, to check")
        #expect(imported.ingredients[0].line == "1 (15 oz) can black beans, drained")
        #expect(imported.ingredients[1].ingredient.food.foodID == mine.id, "Their own rice, by the same words")
        #expect(imported.ingredients[1].ingredient.serving == Serving("1 cup", grams: 160))
        // No amount: the food's first serving, marked to check.
        #expect(imported.ingredients[2].ingredient.serving == Serving("1 cup", grams: 185) && !imported.ingredients[2].exact)
    }

    @Test func aCanIsMatchedAsCannedFood() {
        #expect(IngredientLine("1 (15 oz) can black beans, drained and rinsed").match == "black beans canned")
        #expect(IngredientLine("2 cans chickpeas").match == "chickpeas canned")
        #expect(IngredientLine("1 can canned tomatoes").match == "canned tomatoes")
        #expect(IngredientLine("1 cup black beans").match == "black beans")
    }

    /// Code-blind run 7: "2 tbsp olive oil" matched the person's own olive
    /// oil, which names no serving, and came in as 4 oz (about 1,000 kcal).
    @Test func spoonsOfAnOilOrAWaterLikeLiquidWeighByItsDensity() throws {
        let oil = Food(name: "Olive oil", per100g: NutrientAmounts([.energy: 884, .fat: 100]))
        let page = WebRecipe(name: "Dressing", ingredients: ["2 tbsp olive oil", "1 cup kale", "1/2 cup chicken broth"],
                             url: "https://recipes.example/dressing")
        let kale = Food(name: "Kale", per100g: NutrientAmounts([.energy: 35]))
        let broth = Food(name: "Chicken broth", per100g: NutrientAmounts([.energy: 6]))
        let imported = RecipeImport(page: page, own: [oil, kale, broth], database: [nil, nil, nil], unit: .pounds)
        try #require(imported.ingredients.count == 3)
        // 2 × 14.79 ml × 0.91 g/ml = 26.9 g, 238 kcal.
        let olive = imported.ingredients[0]
        #expect(olive.exact && !olive.needsWeight)
        #expect(abs(olive.ingredient.grams - 26.9) < 0.1 && olive.ingredient.quantity == 2)
        #expect((olive.ingredient.grams * 8.84).rounded() == 238)
        // No density for a cup of kale: no weight is guessed, the person enters one.
        #expect(!imported.ingredients[1].exact && imported.ingredients[1].needsWeight)
        // Broth weighs like water: half a cup is 118 g.
        #expect(abs(imported.ingredients[2].ingredient.grams - 118.3) < 0.1 && imported.ingredients[2].exact)
    }

    @Test func spelledOutMeasuresAndKitchenMeasuresForLiquids() {
        // USDA spells its measures out; its own tablespoon is used.
        let usda = Food(name: "Olive oil", source: .usda, per100g: NutrientAmounts([.energy: 900]),
                        servings: [Serving("1 cup", grams: 224), Serving("1 tablespoon", grams: 14)])
        #expect(usda.portion(TypedAmount(2, .tablespoons))?.amount.serving == Serving("1 tablespoon", grams: 14))
        #expect(usda.kitchenMeasures.map { "\($0.name) \(($0.grams * 10).rounded() / 10)" } == ["1 tsp 4.7"], "It names a tablespoon and a cup already")
        let honey = Food(name: "Honey", source: .usda, per100g: NutrientAmounts([.energy: 304]), servings: [Serving("1 tablespoon", grams: 21)])
        #expect(honey.portion(TypedAmount(1, .cups)).map { ($0.amount.grams).rounded() } == 336, "Density from its tablespoon")
        #expect(honey.kitchenMeasures.isEmpty, "Not a liquid by name or label")

        let mine = Food(name: "Olive oil", per100g: NutrientAmounts([.energy: 884]))
        #expect(mine.kitchenMeasures.map { "\($0.name) \(($0.grams * 10).rounded() / 10)" } == ["1 tbsp 13.5", "1 tsp 4.5", "1 cup 215.3"])
        #expect(mine.portion(TypedAmount(2, .tablespoons))?.amount.serving == mine.kitchenMeasures.first, "Typed, it's the same serving")
        #expect(Food.typicalDensity(name: "Oil, sesame") == 0.91)
        #expect(Food.typicalDensity(name: "Vinegar, cider") == 1)
        #expect(Food.typicalDensity(name: "Almond milk, unsweetened") == 1)
        for other in ["Tuna in oil", "Milk, dry", "Orange juice, frozen concentrate", "Peanut butter", "Chicken breast", "Olive oil spray"] {
            #expect(Food.typicalDensity(name: other) == nil, "\(other)")
        }
    }

    @Test func anArchivedFoodOrADifferentNameDoesNotMatch() {
        var archived = mine
        archived.archivedAt = Date()
        let page = WebRecipe(name: "Rice", ingredients: ["1 cup cooked rice", "2 cups rice cooked in broth", "2 cups"], url: "https://recipes.example/rice")
        let imported = RecipeImport(page: page, own: [archived], database: [nil, nil, rice], unit: .kilograms)
        #expect(imported.unmatched == ["1 cup cooked rice", "2 cups rice cooked in broth", "2 cups"], "An amount alone names no food")
    }

    @Test func aSharedRecipeFileCarriesOnlyTheRecipeAndReadsBackAsACopy() throws {
        var recipe = Food.recipe(name: "Bean bowl", ingredients: [
            RecipeIngredient(food: beans.snapshot, grams: 425, serving: Serving("1 can (15 oz)", grams: 425), quantity: 1),
            RecipeIngredient(food: rice.snapshot, grams: 158)
        ], yieldGrams: 550, servingCount: 2, preparation: "Warm and serve.")
        recipe.sourceURL = "https://recipes.example/bowl"
        recipe.favorite = true
        recipe.brand = "Private label"
        let data = try RecipeFile.data(for: recipe)
        let keys = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]).keys.sorted()
        #expect(keys == ["format", "ingredients", "name", "preparation", "servingCount", "sourceURL", "version", "yieldGrams"],
                "No ID, favorite, brand, dates or barcode")

        let copy = try RecipeFile.read(data)
        #expect(copy.name == "Bean bowl" && copy.servingCount == 2 && copy.yieldGrams == 550)
        #expect(copy.preparation == "Warm and serve." && copy.sourceURL == "https://recipes.example/bowl" && copy.unmatched.isEmpty)
        #expect(copy.ingredients.map(\.ingredient) == recipe.ingredients)
        #expect(copy.ingredients.allSatisfy { $0.exact })
    }

    @Test func aRecipeFileThatIsNotOneIsRefused() throws {
        func file(_ json: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: json) }
        let ingredient: [String: Any] = ["food": ["foodID": "usda:1", "name": "Beans", "source": "usda", "per100g": ["energy": 181]], "grams": 100]
        let valid: [String: Any] = ["format": "exerly.recipe", "version": 1, "name": "Beans", "ingredients": [ingredient]]
        #expect(throws: Never.self) { try RecipeFile.read(try file(valid)) }
        for broken in [["format": "something.else"], ["version": 2], ["ingredients": []], ["name": " "],
                       ["sourceURL": "javascript:alert(1)"],
                       ["ingredients": [["food": ["foodID": "x", "name": "Bad", "source": "usda", "per100g": ["energy": -5]], "grams": 100]]],
                       ["ingredients": [["food": ["foodID": "x", "name": "Bad", "source": "usda", "per100g": ["energy": 5]], "grams": 0]]]] {
            #expect(throws: RecipeFile.Failure.unreadable) { try RecipeFile.read(try file(valid.merging(broken) { $1 })) }
        }
        #expect(throws: RecipeFile.Failure.unreadable) { try RecipeFile.read(Data("not json".utf8)) }
        #expect(throws: RecipeFile.Failure.unreadable) { try RecipeFile.read(Data(count: RecipeFile.maximumSize + 1)) }
    }
}
