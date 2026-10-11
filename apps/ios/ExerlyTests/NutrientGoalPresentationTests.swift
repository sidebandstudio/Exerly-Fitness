import XCTest
import ExerlyCore
@testable import Exerly

@MainActor
final class NutrientGoalPresentationTests: XCTestCase {
    func testADraftOpensOnThePresetItsGoalReadsAs() {
        XCTAssertEqual(NutrientGoalDraft(NutrientGoal(floor: 28)).kind, .atLeast)
        XCTAssertEqual(NutrientGoalDraft(NutrientGoal(target: 35)).kind, .about)
        XCTAssertEqual(NutrientGoalDraft(NutrientGoal(ceiling: 2300)).kind, .atMost)
        XCTAssertEqual(NutrientGoalDraft(NutrientGoal(floor: 25, target: 35)).kind, .range)
        XCTAssertEqual(NutrientGoalDraft(nil).kind, .atLeast)
        XCTAssertEqual(NutrientGoalDraft(NutrientGoal(ceiling: 0.9)).ceiling, "0.9")
    }

    func testSwitchingPresetsCarriesTheAmountAndKeepsARange() {
        var draft = NutrientGoalDraft(NutrientGoal(floor: 28))
        draft.choose(.about)
        XCTAssertEqual(draft.goal(.fiber).goal, NutrientGoal(target: 28))
        draft.choose(.atMost)
        XCTAssertEqual(draft.goal(.fiber).goal, NutrientGoal(ceiling: 28))
        draft.choose(.range)
        XCTAssertEqual(draft.goal(.fiber).goal, NutrientGoal(floor: 28, target: 28, ceiling: 28), "Each part kept what was typed")

        var range = NutrientGoalDraft(NutrientGoal(floor: 25, target: 35, ceiling: 70))
        range.choose(.atLeast)
        XCTAssertEqual(range.goal(.fiber).goal, NutrientGoal(floor: 25), "A preset uses only its own part")
        range.choose(.range)
        XCTAssertEqual(range.goal(.fiber).goal, NutrientGoal(floor: 25, target: 35, ceiling: 70))
    }

    func testAnOrderingProblemNamesBothAmountsAndGivesNoGoal() {
        var draft = NutrientGoalDraft(NutrientGoal(floor: 25, target: 35))
        draft.floor = "40"
        let typed = draft.goal(.fiber)
        XCTAssertNil(typed.goal)
        XCTAssertEqual(typed.problem, "The floor, 40 g, can't be above the target, 35 g.")
        draft.target = ""
        draft.ceiling = "2,000"
        XCTAssertEqual(draft.goal(.fiber).problem, "Enter amounts as numbers.")
        draft = NutrientGoalDraft(NutrientGoal(floor: 25))
        draft.floor = ""
        XCTAssertTrue(draft.goal(.fiber) == (nil, nil), "Nothing typed is no goal and no problem yet")
    }

    func testGoalsReadInThePresetsWords() {
        XCTAssertEqual(IntakeFormat.goalSummary(NutrientGoal(floor: 28), .fiber), "At least 28 g")
        XCTAssertEqual(IntakeFormat.goalSummary(NutrientGoal(floor: 25, target: 35), .fiber), "At least 25 g, about 35 g")
        XCTAssertEqual(IntakeFormat.goalSummary(NutrientGoal(ceiling: 2300), .sodium, spoken: true), "At most 2,300 milligrams")
    }

    func testAPinnedDaySaysWhatsLeftAndNeverReadsUnknownAsZero() {
        func day(_ amount: Double?, _ goal: NutrientGoal?, reporting: Int = 2, entries: Int = 2) -> NutrientDay {
            NutrientDay(nutrient: .sodium, amount: amount, goal: goal, entries: entries, reporting: reporting)
        }
        XCTAssertEqual(IntakeFormat.standing(day(1240, NutrientGoal(ceiling: 2300))), "1,060 mg left")
        XCTAssertEqual(IntakeFormat.standing(day(2540, NutrientGoal(ceiling: 2300))), "240 mg over")
        XCTAssertEqual(IntakeFormat.standing(day(400, NutrientGoal(floor: 1500))), "1,100 mg to go")
        XCTAssertEqual(IntakeFormat.standing(day(1600, NutrientGoal(floor: 1500))), "Goal met")
        XCTAssertEqual(IntakeFormat.standing(day(1600, NutrientGoal(floor: 1500, target: 2000))), "400 mg to target")
        XCTAssertEqual(IntakeFormat.standing(day(nil, NutrientGoal(ceiling: 2300), reporting: 0)), "At most 2,300 mg")
        XCTAssertEqual(IntakeFormat.standing(day(300, nil)), "No goal")
        // Eaten against what the standing counts to, as the macros put it.
        XCTAssertEqual(IntakeFormat.eatenOfGoal(day(1240, NutrientGoal(ceiling: 2300))), "1,240 / 2,300 mg")
        XCTAssertEqual(IntakeFormat.eatenOfGoal(day(400, NutrientGoal(floor: 1500, target: 2000))), "400 / 1,500 mg")
        XCTAssertEqual(IntakeFormat.eatenOfGoal(day(1600, NutrientGoal(floor: 1500, target: 2000)), spoken: true),
                       "1,600 of 2,000 milligrams eaten")
        XCTAssertNil(IntakeFormat.eatenOfGoal(day(nil, NutrientGoal(ceiling: 2300), reporting: 0)))
        // Run 6 read "2.1 g to go" beside "33 / 35 g": the eaten figure is as precise as the one beside it.
        let fiber = NutrientDay(nutrient: .fiber, amount: 32.9, goal: NutrientGoal(floor: 35), entries: 2, reporting: 2)
        XCTAssertEqual(IntakeFormat.standing(fiber), "2.1 g to go")
        XCTAssertEqual(IntakeFormat.eatenOfGoal(fiber), "32.9 / 35 g")
        XCTAssertEqual(IntakeFormat.eatenOfGoal(fiber, spoken: true), "32.9 of 35 grams eaten")
        let earlier = NutrientDay(nutrient: .fiber, amount: 20.25, goal: NutrientGoal(floor: 35), entries: 2, reporting: 2)
        XCTAssertEqual(IntakeFormat.standing(earlier), "15 g to go")
        XCTAssertEqual(IntakeFormat.eatenOfGoal(earlier), "20 / 35 g", "Whole figures stay whole")
        XCTAssertTrue(IntakeFormat.standingParts(day(400, NutrientGoal(floor: 1500)))! == (1100, "to go"))
        XCTAssertEqual(IntakeFormat.completeness(reporting: 3, entries: 5), "From 3 of 5 foods")
        XCTAssertEqual(IntakeFormat.completeness(reporting: 3, entries: 5, spoken: true), "From 3 of 5 foods that report it")
        XCTAssertNil(IntakeFormat.completeness(reporting: 5, entries: 5), "Nothing to qualify")
        XCTAssertNil(IntakeFormat.completeness(reporting: 0, entries: 5), "Not reported says it already")
    }

    func testMacrosSayWhatsLeftOrHowFarOverAsTheRingDoes() {
        func left(_ consumed: Double, _ target: Double) -> (String, String, Bool) {
            let result = TodayNutritionCard.left(NutrientProgress(nutrient: .protein, consumed: consumed, unreported: 0, target: target))
            return (result.amount, result.words, result.over)
        }
        XCTAssertTrue(left(75, 132) == ("57", "left", false))
        XCTAssertTrue(left(144.4, 132) == ("12", "over", true))
        XCTAssertTrue(left(132.3, 132) == ("0", "left", false), "Not over until a whole gram over")
    }
}
