import XCTest
@testable import Exerly

/// What Today draws in its first frame at launch.
@MainActor
final class TodayLaunchTests: XCTestCase {
    func testTheFirstFrameDrawsTheLoggingToolsWhereverTheyAre() {
        typealias Card = TodayLayout.Card
        XCTAssertEqual(TodayLayout.drawnFirst(TodayLayout.standard.visible), [.quickActions, .nutrition, .training])
        // Customized: the shortcuts, the ring (which Log again follows) and the
        // workout last, after three cards that can wait.
        let late: [Card] = [.meals, .water, .weight, .training, .quickActions, .nutrition]
        XCTAssertTrue(TodayLayout.drawnFirst(late).isSuperset(of: [.quickActions, .nutrition, .training]), "\(TodayLayout.drawnFirst(late))")
        XCTAssertTrue(TodayLayout.drawnFirst(late).isSuperset(of: [.meals, .water, .weight]), "and what's at the top")
        // With the ring hidden, Log again follows the shortcuts, which still come first.
        XCTAssertTrue(TodayLayout.drawnFirst([.meals, .water, .weight, .quickActions]).contains(.quickActions))
    }
}
