import ExerlyCore
import XCTest
@testable import Exerly

/// What Today's customizable layout keeps, and how its newer cards read.
@MainActor
final class TodayPresentationTests: XCTestCase {
    func testTheLayoutKeepsItsOrderAndHiddenCardsAndPlacesNewOnes() {
        XCTAssertEqual(TodayLayout("").order, TodayLayout.Card.allCases, "Nothing saved: the standard layout")
        let saved = TodayLayout("meals,-quickActions,nutrition,training,weight,water")
        XCTAssertEqual(saved.visible, [.meals, .nutrition, .training, .weight, .water])
        XCTAssertEqual(TodayLayout(saved.text), saved, "Saved and read back unchanged")
        // A card the saved text doesn't name, from a later version, goes after
        // the card before it in the standard order; unknown names drop out.
        let older = TodayLayout("meals,nutrition,-training,weight,meditation,meals")
        XCTAssertEqual(older.order, [.quickActions, .meals, .nutrition, .training, .weight, .water])
        XCTAssertEqual(older.hidden, [.training])
        XCTAssertEqual(TodayLayout.standard.moving(.water, by: -1).order, [.quickActions, .nutrition, .training, .water, .weight, .meals])
        XCTAssertEqual(TodayLayout.standard.moving(.quickActions, by: -1), .standard, "The first card can't move up")
        XCTAssertEqual(TodayLayout.standard.moving(.meals, by: 1), .standard, "The last can't move down")
        XCTAssertNotEqual(TodayLayout.key(accountID: "a"), TodayLayout.key(accountID: "b"), "Each account keeps its own")
    }

    func testWaterReadsDrinksFirstAndFoodApart() {
        let day = WaterDay(drinks: 1250, food: 190, reporting: 1, entries: 3, goal: 2000)
        XCTAssertEqual(TodayWaterCard.spoken(day, imperial: false),
                       "1,250 ml logged, 750 ml to go of 2,000 ml, plus 190 ml in food, not counted toward the goal")
        XCTAssertEqual(TodayWaterCard.spoken(WaterDay(drinks: 2100, food: 0, reporting: 0, entries: 0, goal: 2000), imperial: false),
                       "2,100 ml logged, goal of 2,000 ml reached")
        XCTAssertEqual(TodayWaterCard.amount(473.2, imperial: true), "16 fl oz")
        XCTAssertEqual(WaterServing.glass.milliliters(imperial: false), 250)
        XCTAssertEqual(WaterServing.bottle.milliliters(imperial: true), 500, "A 16.9 fl oz bottle")
    }

    func testCheckInsNameFastsAndPartialDays() {
        XCTAssertEqual(TargetsCheckInCard.coverage(complete: 5, fasting: 0, partial: 0, weighIns: 4),
                       "5 of the last 7 days fully logged. 4 with a weigh-in.")
        XCTAssertEqual(TargetsCheckInCard.coverage(complete: 5, fasting: 1, partial: 2, weighIns: 4),
                       "5 of the last 7 days fully logged, 1 of them a fast; 2 partial days left out. 4 with a weigh-in.")
    }

    func testTheCalendarSaysWhatEachDayRecorded() {
        let day = LocalDate("2026-10-08")!
        XCTAssertEqual(NutritionDateView.spoken(HabitDay(date: day, food: .fasted, weighedIn: true)), "Fasted, weighed in")
        XCTAssertEqual(NutritionDateView.spoken(HabitDay(date: day, food: .missing, weighedIn: false)), "Not logged")
        XCTAssertEqual(NutritionDateView.first(of: day), LocalDate("2026-10-01"))
        XCTAssertEqual(NutritionDateView.last(of: LocalDate("2028-02-01")!), LocalDate("2028-02-29"))
    }
}
