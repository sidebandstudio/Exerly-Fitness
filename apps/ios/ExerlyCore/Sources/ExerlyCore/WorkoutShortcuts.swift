import Foundation

/// What the workout shortcuts do to the workout in progress, decided here so
/// the app's intents only apply it.
public enum WorkoutShortcuts {
    /// What "Rest" does: extends a rest that's running, else starts one.
    public enum RestAction: Equatable, Sendable {
        case extend(by: Double)
        case start(seconds: Double)
    }

    /// Added to a running rest when no length is given, as the Live
    /// Activity's button adds.
    public static let defaultExtension: Double = 30
    /// The longest rest a shortcut starts or adds, so a typo in minutes
    /// doesn't leave a timer running all day.
    public static let longestRest: Double = 30 * 60

    /// With a rest running, adds `seconds` (30 when not given). Otherwise
    /// starts `seconds`, or the rest the policy gives after the set completed
    /// last, or the rest between exercises before any set is done. Nil for a
    /// length that isn't a positive number up to 30 minutes.
    public static func rest(seconds: Double?, running: RestTimer?, now: Date, session: WorkoutSession,
                            policy: RestPolicy, library: ExerciseLibrary) -> RestAction? {
        if let seconds, !(seconds.isFinite && seconds > 0 && seconds <= longestRest) { return nil }
        if let running, !running.isFinished(at: now) { return .extend(by: seconds ?? defaultExtension) }
        if let seconds { return .start(seconds: seconds) }
        let last = session.exercises.flatMap(\.sets).filter(\.isCompleted).max { $0.completedAt! < $1.completedAt! }
        let policyRest = last.map { policy.rest(after: $0.id, in: session, library: library) } ?? 0
        return .start(seconds: policyRest > 0 ? policyRest : policy.betweenExercises)
    }
}
