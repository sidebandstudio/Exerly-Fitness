import Foundation
import Testing
@testable import ExerlyCore

@Suite struct TypedAmountTests {
    func parse(_ query: String) -> (TypedAmount?, String) {
        let parsed = FoodSearch.amount(in: query)
        return (parsed.amount, parsed.food)
    }

    @Test func anAmountBeforeTheFoodIsReadAndTheRestSearched() {
        #expect(parse("500 g ground beef") == (TypedAmount(500, .grams), "ground beef"))
        #expect(parse("150g greek yogurt") == (TypedAmount(150, .grams), "greek yogurt"))
        #expect(parse("2 eggs") == (TypedAmount(2), "eggs"))
        #expect(parse("1 can kidney beans") == (TypedAmount(1, .serving("can")), "kidney beans"))
        #expect(parse("2 cans of diced tomatoes") == (TypedAmount(2, .serving("can")), "diced tomatoes"))
        #expect(parse("1.5 cups milk") == (TypedAmount(1.5, .cups), "milk"))
        #expect(parse("8 oz chicken") == (TypedAmount(8, .ounces), "chicken"))
        #expect(parse("2 large eggs") == (TypedAmount(2, .serving("large")), "eggs"))
        #expect(parse("1 lb ground turkey") == (TypedAmount(1, .pounds), "ground turkey"))
        #expect(parse("0.5 kg rice") == (TypedAmount(0.5, .kilograms), "rice"))
        #expect(parse("250 ML Oat Milk") == (TypedAmount(250, .milliliters), "Oat Milk"))
        #expect(parse("1 l water") == (TypedAmount(1, .liters), "water"))
        #expect(parse("2 tbsp peanut butter") == (TypedAmount(2, .tablespoons), "peanut butter"))
        #expect(parse("1 tsp honey") == (TypedAmount(1, .teaspoons), "honey"))
        #expect(parse("12 fl oz cola") == (TypedAmount(12, .fluidOunces), "cola"))
        #expect(parse("3 slices bacon") == (TypedAmount(3, .serving("slice")), "bacon"))
        #expect(parse("2 boxes raisins") == (TypedAmount(2, .serving("box")), "raisins"))
    }

    @Test func fractionsAndDecimalCommasAreNumbers() {
        #expect(parse("1/2 cup oats") == (TypedAmount(0.5, .cups), "oats"))
        #expect(parse("1 1/2 cups milk") == (TypedAmount(1.5, .cups), "milk"))
        #expect(parse("½ avocado") == (TypedAmount(0.5), "avocado"))
        #expect(parse("1½ cups rice") == (TypedAmount(1.5, .cups), "rice"))
        #expect(parse("1,5 kg potatoes") == (TypedAmount(1.5, .kilograms), "potatoes"))
        #expect(parse("1,500 g flour") == (TypedAmount(1500, .grams), "flour"))
    }

    @Test func anAmountAfterTheFoodNeedsAUnit() {
        #expect(parse("chicken breast 200g") == (TypedAmount(200, .grams), "chicken breast"))
        #expect(parse("greek yogurt 150 g") == (TypedAmount(150, .grams), "greek yogurt"))
        #expect(parse("kidney beans 1 can") == (TypedAmount(1, .serving("can")), "kidney beans"))
        #expect(parse("milk 1 1/2 cups") == (TypedAmount(1.5, .cups), "milk"))
        #expect(parse("Omega 3") == (nil, "Omega 3"), "A bare number after the food is part of its name")
        #expect(parse("vitamin b12") == (nil, "vitamin b12"))
    }

    @Test func namesThatStartWithNumbersStayNames() {
        #expect(parse("7up") == (nil, "7up"))
        #expect(parse("2% milk") == (nil, "2% milk"))
        #expect(parse("0% greek yogurt") == (nil, "0% greek yogurt"))
        #expect(parse("100 grand bar") == (nil, "100 grand bar"), "More than 50 of something is a name")
        #expect(parse("  greek   yogurt ") == (nil, "greek yogurt"))
        #expect(parse("200 g") == (TypedAmount(200, .grams), ""), "An amount still waiting for its food")
        #expect(parse("") == (nil, ""))
    }

    // Servings as USDA's generic foods and Open Food Facts give them.
    let beef = Food(name: "Beef, ground, raw", per100g: NutrientAmounts([.energy: 254]), servings: [Serving("1 cup", grams: 225)])
    let egg = Food(name: "Egg, whole, raw", per100g: NutrientAmounts([.energy: 143]),
                   servings: [Serving("1 egg", grams: 50), Serving("1 cup", grams: 245)])
    let onion = Food(name: "Onions, raw", per100g: NutrientAmounts([.energy: 40]),
                     servings: [Serving("1 slice", grams: 15), Serving("1 cup", grams: 160), Serving("1 whole", grams: 148)])
    let milk = Food(name: "Milk, whole", per100g: NutrientAmounts([.energy: 61]),
                    servings: [Serving("1 cup", grams: 244), Serving("1 fl oz", grams: 30.5)])
    let canned = Food(name: "Synthetic red kidney beans", per100g: NutrientAmounts([.energy: 84]),
                      servings: [Serving("1/2 cup (130 g)", grams: 130), Serving("1 can", grams: 425)])
    let chicken = Food(name: "Chicken breast, roasted", per100g: NutrientAmounts([.energy: 165]),
                       servings: [Serving("1 cup, cooked, diced", grams: 135), Serving("1 small breast", grams: 110),
                                  Serving("1 large breast", grams: 145)])

    func portion(_ food: Food, _ typed: TypedAmount) -> (grams: Double, serving: Serving?, quantity: Double?, exact: Bool)? {
        food.portion(typed).map { ($0.amount.grams, $0.amount.serving, $0.amount.quantity, $0.exact) }
    }

    @Test func weightsAlwaysMapAndOuncesStayOunces() throws {
        let grams = try #require(portion(beef, TypedAmount(500, .grams)))
        #expect(grams.grams == 500 && grams.serving == nil && grams.exact)
        #expect(close(try #require(beef.portion(TypedAmount(500, .grams))).amount.nutrients.energy, 1270))
        let ounces = try #require(portion(beef, TypedAmount(8, .ounces)))
        #expect(ounces.serving == Serving("oz", grams: USUnits.gramsPerOunce) && ounces.quantity == 8 && close(ounces.grams, 226.796185))
        let pound = try #require(portion(beef, TypedAmount(1, .pounds)))
        #expect(pound.quantity == 16 && close(pound.grams, 453.59237))
        #expect(portion(beef, TypedAmount(0.5, .kilograms))?.grams == 500)
    }

    @Test func aCountIsTheFoodsOwnServingOrAWholeOne() throws {
        let eggs = try #require(portion(egg, TypedAmount(2)))
        #expect(eggs.serving == Serving("1 egg", grams: 50) && eggs.quantity == 2 && eggs.grams == 100 && eggs.exact)
        let one = try #require(portion(onion, TypedAmount(1)))
        #expect(one.serving == Serving("1 whole", grams: 148) && one.exact, "A whole onion, not a slice")
        let bar = Food(name: "Synthetic oat bar", per100g: NutrientAmounts([.energy: 412]), servings: [Serving("1 bar (40 g)", grams: 40)])
        #expect(portion(bar, TypedAmount(2))?.grams == 80)
        let porridge = Food.recipe(name: "Porridge", ingredients: [RecipeIngredient(food: Foods.oats.snapshot, grams: 400)], servingCount: 4)
        #expect(portion(porridge, TypedAmount(1))?.serving == Serving("1 serving", grams: 100), "A recipe's serving")
        // A count of a measure is a guess to check; a food without servings has nothing to count.
        let guess = try #require(portion(beef, TypedAmount(2)))
        #expect(guess.serving == Serving("1 cup", grams: 225) && guess.quantity == 2 && !guess.exact)
        #expect(portion(Foods.chicken, TypedAmount(2)) == nil)
    }

    @Test func aNamedServingOrAPackageSizeMapsAndAMissingOneDoesNot() throws {
        let can = try #require(portion(canned, TypedAmount(1, .serving("can"))))
        #expect(can.serving == Serving("1 can", grams: 425) && can.grams == 425 && can.exact)
        #expect(portion(canned, TypedAmount(2, .serving("tin")))?.grams == 850, "A tin is a can")
        let package = Food(name: "Synthetic salsa", per100g: NutrientAmounts([.energy: 30]), servings: [Serving("1 package", grams: 454)])
        #expect(portion(package, TypedAmount(1, .serving("jar")))?.grams == 454, "Any container is the package")
        #expect(portion(beef, TypedAmount(1, .serving("can"))) == nil, "No can size: the portion step instead")
        let breasts = try #require(portion(chicken, TypedAmount(2, .serving("large"))))
        #expect(breasts.serving == Serving("1 large breast", grams: 145) && breasts.grams == 290 && breasts.exact)
        // A size the food doesn't name counts the food, to check.
        let large = try #require(portion(egg, TypedAmount(2, .serving("large"))))
        #expect(large.serving == Serving("1 egg", grams: 50) && large.quantity == 2 && !large.exact)
    }

    @Test func volumesUseAMeasureTheFoodNamesOrItsDensity() throws {
        let cups = try #require(portion(milk, TypedAmount(1.5, .cups)))
        #expect(cups.serving == Serving("1 cup", grams: 244) && cups.quantity == 1.5 && cups.grams == 366 && cups.exact)
        let ounces = try #require(portion(milk, TypedAmount(12, .fluidOunces)))
        #expect(ounces.serving == Serving("1 fl oz", grams: 30.5) && ounces.grams == 366)
        // Millilitres from the cup's weight, as grams.
        let milliliters = try #require(portion(milk, TypedAmount(250, .milliliters)))
        #expect(milliliters.serving == nil && close(milliliters.grams, 250 * 244 / (USUnits.millilitersPerFluidOunce * 8)))
        // A label per volume logs in its own millilitres.
        var juice = Foods.chicken
        juice.volume = VolumeBasis(density: 1.04, assumed: false)
        let glass = try #require(portion(juice, TypedAmount(0.25, .liters)))
        #expect(glass.serving == Serving("ml", grams: 1.04) && glass.quantity == 250 && close(glass.grams, 260))
        let tablespoon = try #require(portion(juice, TypedAmount(2, .tablespoons)))
        #expect(tablespoon.serving?.name == "1 tbsp" && tablespoon.quantity == 2 && close(tablespoon.grams, 2 * 1.04 * 14.78676478125))
        #expect(portion(beef, TypedAmount(250, .milliliters)) != nil, "A cup of beef weighs something, so a volume does too")
        #expect(portion(Foods.chicken, TypedAmount(1, .cups)) == nil, "Nothing to convert a volume with")
    }
}
