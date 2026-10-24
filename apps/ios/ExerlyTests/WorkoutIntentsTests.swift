import ExerlyCore
import XCTest
@testable import Exerly

/// What the workout intents do to the workout in progress, and say.
@MainActor
final class WorkoutIntentsTests: XCTestCase {
    private func account() throws -> IntentAccess.Account {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return IntentAccess.Account(workspace: try TrainingWorkspace(accountID: "workout-intents", root: root), unit: .pounds, timeZone: .gmt)
    }

    private func invalid(_ error: Error) -> String? {
        if case .invalid(let message) = error as? LoggingIntentError { return message }
        return nil
    }

    func testTheNextSetLogsWithItsValuesThenRestsAndSaysWhenItWasTheLast() throws {
        let account = try account()
        let store = account.workspace.store
        XCTAssertThrowsError(try WorkoutIntentActions.logNextSet(in: account)) { error in
            XCTAssertEqual(self.invalid(error), "There's no workout in progress. Start today's workout first.")
        }
        try store.startSession(name: "Upper A", bodyweight: nil)
        let bench = try store.addExercise("barbell-bench-press")
        try store.addSet(to: bench)
        for var set in try XCTUnwrap(store.activeSession?.exercises.first?.sets) {
            set.primary = Effort(reps: 7, load: .lb(160))
            try store.updateSet(set, in: bench)
        }
        let pullUp = try store.addExercise("pull-up")

        var (text, content) = try WorkoutIntentActions.logNextSet(in: account)
        XCTAssertEqual(text, "Logged Barbell Bench Press set 1, 160 pounds, 7 reps. Rest 2 minutes, 30 seconds.")
        XCTAssertEqual(content?.state.completedSets, 1)
        XCTAssertNotNil(content?.state.rest, "The Live Activity shows the rest")
        (text, _) = try WorkoutIntentActions.logNextSet(in: account)
        XCTAssertTrue(text.hasPrefix("Logged Barbell Bench Press set 2, "), text)
        XCTAssertThrowsError(try WorkoutIntentActions.logNextSet(in: account)) { error in
            XCTAssertEqual(self.invalid(error), "Set 1 of Pull-Up has no values yet. Fill it in in Exerly.")
        }
        var set = try XCTUnwrap(store.activeSession?.exercises.last?.sets.first)
        set.primary = Effort(reps: 9)
        try store.updateSet(set, in: pullUp)
        (text, _) = try WorkoutIntentActions.logNextSet(in: account)
        XCTAssertTrue(text.hasSuffix(" That was the last set."), text)
        XCTAssertNil(store.restTimer)
        XCTAssertThrowsError(try WorkoutIntentActions.logNextSet(in: account)) { error in
            XCTAssertEqual(self.invalid(error), "Every set of this workout is logged.")
        }
    }

    func testRestStartsOrExtendsOnlyInAWorkout() throws {
        let account = try account()
        let store = account.workspace.store
        XCTAssertThrowsError(try WorkoutIntentActions.rest(nil, in: account)) { error in
            XCTAssertEqual(self.invalid(error), "There's no workout in progress. Start today's workout first.")
        }
        try store.startSession(name: "Upper A", bodyweight: nil)
        let now = Date()
        var (text, content) = try WorkoutIntentActions.rest(nil, in: account, now: now)
        XCTAssertEqual(text, "Resting 2 minutes.", "Before any set, the rest between exercises")
        XCTAssertNotNil(content?.state.rest)
        (text, _) = try WorkoutIntentActions.rest(nil, in: account, now: now)
        XCTAssertEqual(text, "Added 30 seconds. 2 minutes, 30 seconds left.")
        XCTAssertEqual(store.restTimer?.duration, 150)
        XCTAssertThrowsError(try WorkoutIntentActions.rest(0, in: account, now: now)) { error in
            XCTAssertEqual(self.invalid(error), "Enter 1 second to 30 minutes.")
        }
    }
}
