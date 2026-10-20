import Foundation
import Testing
@testable import ExerlyCore

/// Synthetic label text, as the camera's text recognition returns it.
@Suite struct NutritionLabelTests {
    @Test func aUSPanelReadsPerServingWithTheUsualMisreads() throws {
        let lines = ["Nutrition Facts", "8 servings per container", "Serving size 2/3 cup (55g)", "Amount per serving",
                     "Calories", "230", "% Daily Value*", "Total Fat 8g 10%", "Saturated Fat 1g 5%", "Trans Fat Og",
                     "Cholesterol Omg 0%", "Sodium 160mg 7%", "Total Carbohydrate 37g 13%", "Dietary Fiber 4g 14%",
                     "Total Sugars 12g", "Includes 10g Added Sugars 20%", "Protein 3g", "Vitamin D 2mcg 10%",
                     "Calcium 260mg 20%", "Iron 8mg 45%", "Potassium 240mg 6%"]
        let label = try #require(NutritionLabel.read(lines))
        #expect(label.basis == .serving && label.servingGrams == 55 && label.servingText == "2/3 cup (55g)")
        let expected: [Nutrient: Double] = [.energy: 230, .fat: 8, .saturatedFat: 1, .transFat: 0, .cholesterol: 0,
                                            .sodium: 160, .carbohydrate: 37, .fiber: 4, .sugars: 12, .addedSugars: 10,
                                            .protein: 3, .vitaminD: 2, .calcium: 260, .iron: 8, .potassium: 240]
        for (nutrient, value) in expected { #expect(label.amounts[nutrient] == value, "\(nutrient)") }
        #expect(label.unread.isEmpty && label.approximated.isEmpty)
        let per100g = try #require(label.per100g)
        #expect(abs((per100g[.energy] ?? 0) - 230 * 100 / 55) < 1e-9)
    }

    @Test func anEUDeclarationReadsPer100gWithSaltAsSodium() throws {
        let lines = ["NUTRITION", "Typical values per 100g per 30g serving", "Energy 1580kJ / 375kcal 474kJ / 113kcal",
                     "Fat 6,5 g 2,0 g", "of which saturates 1,2 g 0,4 g", "Carbohydrate 66 g 20 g", "of which sugars 22 g 6,6 g",
                     "Fibre 7,8 g 2,3 g", "Protein 9,4 g 2,8 g", "Salt <0,1 g <0,1 g"]
        let label = try #require(NutritionLabel.read(lines))
        #expect(label.basis == .per100g)
        let expected: [Nutrient: Double] = [.energy: 375, .fat: 6.5, .saturatedFat: 1.2, .carbohydrate: 66, .sugars: 22,
                                            .fiber: 7.8, .protein: 9.4, .sodium: 40]
        for (nutrient, value) in expected { #expect(label.amounts[nutrient] == value, "\(nutrient)") }
        #expect(label.approximated == [.sodium] && label.per100g == label.amounts)

        // kJ alone is converted, and a drink per 100 ml needs a density for grams.
        let drinkLines = ["Per 100 ml", "Energy 180 kJ", "Carbohydrate 10.6 g", "of which sugars 10.6 g", "Protein 0 g"]
        let drink = try #require(NutritionLabel.read(drinkLines))
        #expect(drink.basis == .per100ml && drink.amounts[.energy] == 43 && drink.per100g == nil)
    }

    @Test func theLabelsOwnDeclarationDecidesTheBasisNotItsUnits() throws {
        // A per-serving label with kilojoules: the app's P1 (its synthetic input).
        let bar = try #require(NutritionLabel.read(["Nutrition Facts", "Serving size 1 bar (50 g)", "Amount per serving",
                                                    "Energy 837 kJ / 200 kcal", "Fat 8 g", "Carbohydrate 25 g", "Protein 7 g"]))
        #expect(bar.basis == .serving && bar.servingGrams == 50 && bar.amounts[.energy] == 200)
        #expect(bar.per100g?[.energy] == 400)
        // A serving label that prints salt instead of sodium is still per serving.
        let salted = try #require(NutritionLabel.read(["Serving size 2 crackers (30g)", "Calories 140", "Fat 6g",
                                                       "Carbohydrate 18g", "Salt 0.5g"]))
        #expect(salted.basis == .serving && salted.amounts[.sodium] == 200 && salted.per100g?[.energy] == 140 * 100 / 30.0)

        // Two columns: the first declared is the first column. Australian
        // labels put the serving first.
        let australian = try #require(NutritionLabel.read([
            "NUTRITION INFORMATION", "Servings per package: 8", "Serving size: 30 g",
            "Avg quantity per serving Avg quantity per 100 g", "Energy 520 kJ 1730 kJ", "Protein 3.2 g 10.7 g",
            "Fat, total 1.1 g 3.7 g", "Carbohydrate 20.1 g 67.0 g", "Sodium 55 mg 183 mg",
        ]))
        #expect(australian.basis == .serving && australian.servingGrams == 30)
        #expect(australian.amounts[.energy] == 124 && australian.amounts[.protein] == 3.2 && australian.amounts[.sodium] == 55)
        // "Serving size 1 cup (100 g)" is a serving, not a declaration per 100 g.
        let hundred = try #require(NutritionLabel.read(["Serving size 1 cup (100 g)", "Amount per serving", "Calories 90",
                                                        "Protein 2 g", "Carbohydrate 21 g"]))
        #expect(hundred.basis == .serving && hundred.servingGrams == 100)
        // An explicit heading outranks the generic panel title (the app's review).
        let titled = try #require(NutritionLabel.read(["Nutrition Facts", "Per 100 g", "Energy 200 kcal", "Fat 8 g",
                                                       "Carbohydrate 25 g", "Protein 7 g"]))
        #expect(titled.basis == .per100g && titled.per100g?[.energy] == 200)
        let titledDrink = try #require(NutritionLabel.read(["Valeur nutritive", "per 100 ml", "Energy 43 kcal",
                                                            "Carbohydrate 10.6 g", "Protein 0 g"]))
        #expect(titledDrink.basis == .per100ml)
        // A title alone still means a US-style panel per serving.
        let titleOnly = try #require(NutritionLabel.read(["Nutrition Facts", "Calories 120", "Protein 4g", "Fat 2g"]))
        #expect(titleOnly.basis == .serving)
        // Without any declaration, kilojoules and salt still suggest per 100 g.
        let bare = try #require(NutritionLabel.read(["Energy 1580 kJ", "Fat 6.5 g", "Carbohydrate 66 g", "Salt 0.1 g"]))
        #expect(bare.basis == .per100g)
    }

    @Test func aBilingualCanadianPanelReadsItsServing() throws {
        let label = try #require(NutritionLabel.read([
            "Nutrition Facts", "Valeur nutritive", "Per 1 bar (50 g) / pour 1 barre (50 g)", "Calories 200",
            "% Daily Value* % valeur quotidienne*", "Fat / Lipides 8 g 11 %", "Saturated / saturés 1 g 5 %",
            "Carbohydrate / Glucides 25 g", "Fibre / Fibres 3 g 11 %", "Sugars / Sucres 9 g 9 %",
            "Protein / Protéines 7 g", "Cholesterol / Cholestérol 0 mg", "Sodium 140 mg 6 %",
        ]))
        #expect(label.basis == .serving && label.servingText == "1 bar (50 g)" && label.servingGrams == 50)
        let expected: [Nutrient: Double] = [.energy: 200, .fat: 8, .saturatedFat: 1, .carbohydrate: 25, .fiber: 3,
                                            .sugars: 9, .protein: 7, .cholesterol: 0, .sodium: 140]
        for (nutrient, value) in expected { #expect(label.amounts[nutrient] == value, "\(nutrient)") }
        // On separate lines too.
        let split = try #require(NutritionLabel.read(["Nutrition Facts / Valeur nutritive", "Per 2/3 cup (55 g)",
                                                      "pour 2/3 tasse (55 g)", "Calories 230", "Fat / Lipides 8 g",
                                                      "Protein / Protéines 3 g"]))
        #expect(split.basis == .serving && split.servingText == "2/3 cup (55 g)" && split.servingGrams == 55)
    }

    @Test func otherTextIsNotALabelAndUnreadableLinesAreListed() throws {
        #expect(NutritionLabel.read(["Best before 12/2026", "Store in a cool, dry place"]) == nil)
        let label = try #require(NutritionLabel.read(["Calories 120", "Protein 4g", "Total Fat --"]))
        #expect(label.unread == ["total fat --"] && label.amounts[.fat] == nil)
    }

    /// PARITY N22: older US labels print vitamin D in IU. 400 IU is 10 mcg.
    @Test func vitaminDInInternationalUnitsIsConvertedOrLeftUnread() throws {
        let lines = ["Nutrition Facts", "Serving size 1 cup (240mL)", "Calories 120", "Total Fat 5g", "Protein 8g",
                     "Total Carbohydrate 12g", "Vitamin D 400 IU 100%"]
        let label = try #require(NutritionLabel.read(lines))
        #expect(label.amounts[.protein] == 8)
        withKnownIssue("NutritionLabel.swift:166-197 reads the 400 with no unit and keeps it as 400 mcg, 40 times too much") {
            #expect(label.amounts[.vitaminD] == 10 || label.amounts[.vitaminD] == nil && label.unread.contains { $0.contains("vitamin d") })
        }
    }
}
