import ExerlyCore
import XCTest
@testable import Exerly

/// Every Undo on Today, a chip's second tap or the confirmation's, takes
/// back only what its tap logged, and only while it's unchanged.
final class TodayUndoTests: XCTestCase {
    private func entry(_ grams: Double) -> FoodEntry {
        FoodEntry(date: LocalDate("2026-10-20")!, meal: "Breakfast", loggedAt: Date(timeIntervalSince1970: 1_792_000_000),
                  food: Food(id: UUID().uuidString, name: "Synthetic oats", per100g: NutrientAmounts([.energy: 380]),
                             servings: [], createdAt: Date(timeIntervalSince1970: 1_792_000_000)).snapshot, grams: grams)
    }

    func testAnEntryChangedSinceItWasLoggedIsNotTakenBack() {
        let oats = entry(60), milk = entry(244), deleted = entry(80)
        var edited = milk
        edited.grams = 200
        // Another device changed the milk; the deleted one is gone.
        XCTAssertEqual(TodayUndo.removable([oats, milk, deleted], in: [oats, edited]), [oats.id])
        XCTAssertEqual(TodayUndo.removable([oats, milk], in: [oats, milk]), [oats.id, milk.id])
        XCTAssertTrue(TodayUndo.removable([milk], in: [edited]).isEmpty, "Nothing left this Undo may take back")
    }
}
