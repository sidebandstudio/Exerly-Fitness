import Foundation
import Testing
@testable import ExerlyCore

@Suite struct WorkoutShortcutsTests {
    let library = Fixture.library
    let policy = RestPolicy()

    /// Squats, then bench: two sets each.
    func session() throws -> WorkoutSession {
        var session = WorkoutSession(startedAt: Fixture.instant(), timeZone: Fixture.utc)
        let squat = try session.addExercise("back-squat", library: library)
        try session.addSet(to: squat)
        let bench = try session.addExercise("barbell-bench-press", library: library)
        try session.addSet(to: bench)
        for exercise in session.exercises.indices {
            for set in session.exercises[exercise].sets.indices { session.exercises[exercise].sets[set].primary = Effort(reps: 5, load: .kg(100)) }
        }
        return session
    }

    @Test func restExtendsOneRunningElseStartsThePolicysRest() throws {
        var session = try session()
        let now = Fixture.instant(minutes: 10)
        func rest(_ seconds: Double?, running: RestTimer? = nil) -> WorkoutShortcuts.RestAction? {
            WorkoutShortcuts.rest(seconds: seconds, running: running, now: now, session: session, policy: policy, library: library)
        }
        #expect(rest(nil) == .start(seconds: policy.betweenExercises), "no set done yet")
        let squats = session.exercises[0].sets.map(\.id)
        try session.completeSet(squats[0], at: Fixture.instant(minutes: 5), library: library)
        #expect(rest(nil) == .start(seconds: 180), "after a squat set, a squat's rest")
        try session.completeSet(squats[1], at: Fixture.instant(minutes: 8), library: library)
        #expect(rest(nil) == .start(seconds: 120), "squats done, then bench")
        #expect(rest(45) == .start(seconds: 45))

        let running = RestTimer(startedAt: Fixture.instant(minutes: 9), duration: 120)
        #expect(rest(nil, running: running) == .extend(by: 30))
        #expect(rest(60, running: running) == .extend(by: 60))
        let finished = RestTimer(startedAt: Fixture.instant(minutes: 1), duration: 60)
        #expect(rest(nil, running: finished) == .start(seconds: 120), "a rest that has ended is started again")

        for bad in [0, -10, .nan, .infinity, 31 * 60] as [Double] { #expect(rest(bad) == nil) }
    }
}
