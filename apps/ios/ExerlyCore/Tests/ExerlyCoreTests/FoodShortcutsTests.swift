import Foundation
import Testing
@testable import ExerlyCore

@MainActor
@Suite struct FoodShortcutsTests {
    let monday = LocalDate("2026-10-05")!

    @Test func aTypedBarcodeFindsTheirOwnFoodHoweverItsWritten() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence(), now: { Fixture.instant() })
        // A saved custom food with a UPC-A, and a database food logged once.
        let bar = Food(name: "Synthetic bar", per100g: NutrientAmounts([.energy: 400]), barcode: "036000291452")
        try store.saveFood(bar)
        let yogurt = Food(id: "off:0012345678905", name: "Synthetic yogurt", source: .openFoodFacts,
                          per100g: NutrientAmounts([.energy: 60]))
        try store.log(yogurt, grams: 150, on: monday, meal: "Breakfast")

        #expect(store.ownFoodID(barcode: "036000291452") == bar.id)
        #expect(store.ownFoodID(barcode: "00036000291452") == bar.id, "leading zeros")
        #expect(store.ownFoodID(barcode: "0360 0029 1452") == bar.id, "spaces")
        #expect(store.ownFoodID(barcode: "012345678905") == yogurt.id, "logged before, not saved")
        #expect(store.ownFoodID(barcode: "036000291453") == nil, "wrong check digit")
        #expect(store.ownFoodID(barcode: "4006381333931") == nil, "not one of theirs")
        #expect(store.ownFoodID(barcode: "bar") == nil)

        try store.archiveFood(bar.id)
        #expect(store.ownFoodID(barcode: "036000291452") == nil, "archived foods aren't offered")
    }
}
