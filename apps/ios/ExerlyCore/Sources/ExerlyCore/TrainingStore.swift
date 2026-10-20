import Foundation
import Observation

/// The training state screens bind to: the exercise library, finished
/// history, the session in progress and its rest timer. Every change is
/// validated by ExerlyCore and written to persistence before returning.
@MainActor
@Observable
public final class TrainingStore {
    public enum StoreError: Error, Equatable {
        case noActiveSession
        case sessionInProgress
        case sessionNotFound(UUID)
        case invalidCustomExercise([String])
        /// A whole-session edit changed the session's ID.
        case identityChanged
        /// A past-session correction removed the end time.
        case sessionNotFinished
        case edit(WorkoutSession.EditError)
    }

    /// What finishing a session returns: the saved session and the records it set.
    public struct FinishedSession: Sendable {
        public var session: WorkoutSession
        public var records: [PersonalRecord]
    }

    public private(set) var library: ExerciseLibrary
    /// Finished sessions.
    public private(set) var history: TrainingHistory
    public private(set) var activeSession: WorkoutSession?
    /// Survives relaunch; cleared when the session finishes or is discarded.
    public private(set) var restTimer: RestTimer?
    /// Change with `setRestPolicy(_:)`, which saves it.
    public private(set) var restPolicy: RestPolicy
    /// The rest the workout's last set earned but didn't start, since nothing
    /// was left to do. Adding a set or an exercise starts it after all.
    @ObservationIgnored private var heldRest: RestTimer?

    @ObservationIgnored let persistence: TrainingPersistence
    @ObservationIgnored private let now: () -> Date
    private static let restPolicyKey = "training.restPolicy"
    static let restTimerKey = "training.restTimer"

    public init(
        persistence: TrainingPersistence, library: ExerciseLibrary = .bundled,
        restPolicy: RestPolicy = RestPolicy(), now: @escaping () -> Date = Date.init
    ) throws {
        self.persistence = persistence
        // Whole milliseconds, so dates survive a round trip through the server exactly.
        self.now = { now().roundedToMilliseconds }
        self.restPolicy = try persistence.loadValue(forKey: Self.restPolicyKey)
            .map { try JSONDecoder().decode(RestPolicy.self, from: $0) } ?? restPolicy
        var library = library
        for exercise in try persistence.loadCustomExercises() where library.exercise(exercise.id) == nil {
            library = try library.adding(exercise)
        }
        self.library = library
        let sessions = try persistence.loadSessions()
        history = TrainingHistory(sessions: sessions.filter(\.isFinished), library: library)
        activeSession = sessions.filter { !$0.isFinished }.max { $0.startedAt < $1.startedAt }
        if activeSession != nil {
            restTimer = try persistence.loadValue(forKey: Self.restTimerKey)
                .map { try JSONDecoder().decode(RestTimer.self, from: $0) }
        }
    }

    // MARK: The session in progress

    @discardableResult
    public func startSession(name: String, bodyweight: Mass?, timeZone: TimeZone = .current) throws -> WorkoutSession {
        guard activeSession == nil else { throw StoreError.sessionInProgress }
        let session = WorkoutSession(name: name, startedAt: now(), timeZone: timeZone, bodyweight: bodyweight)
        try persistence.save(session)
        activeSession = session
        return session
    }

    /// Starts a session from a plan: each exercise with its planned sets
    /// prefilled and not yet completed, linked to the program day.
    @discardableResult
    public func startSession(from plan: WorkoutPlan, bodyweight: Mass?, timeZone: TimeZone = .current) throws -> WorkoutSession {
        guard activeSession == nil else { throw StoreError.sessionInProgress }
        let exercises = plan.exercises.map { planned in
            PerformedExercise(exerciseID: planned.exerciseID,
                              sets: planned.recommendation.sets.map { PerformedSet(kind: $0.kind, efforts: [$0.effort], rir: $0.rir) },
                              notes: planned.notes, supersetID: planned.supersetID, restOverride: planned.target.rest,
                              slotID: planned.slotID)
        }
        let session = WorkoutSession(name: plan.name, startedAt: now(), timeZone: timeZone, bodyweight: bodyweight,
                                     exercises: exercises, program: plan.program)
        try validated(session)
        try persistence.save(session)
        activeSession = session
        return session
    }

    /// Adds an exercise prefilled from its last performance.
    @discardableResult
    public func addExercise(_ exerciseID: ExerciseID, at index: Int? = nil) throws -> UUID {
        let previous = history.lastPerformance(of: exerciseID)
        let id = try edit { try $0.addExercise(exerciseID, at: index, previous: previous, library: library) }
        try resumeHeldRest()
        return id
    }

    @discardableResult
    public func addSet(to performedID: UUID, kind: SetKind? = nil) throws -> UUID {
        let id = try edit { try $0.addSet(to: performedID, kind: kind) }
        try resumeHeldRest()
        return id
    }

    public func updateSet(_ set: PerformedSet, in performedID: UUID, propagate: Bool = false) throws {
        try edit { try $0.updateSet(set, in: performedID, propagate: propagate) }
    }

    /// Completes a set and starts the rest timer the policy picks, saving both
    /// as one unit. The workout's last set starts none, and stops one that's
    /// running: there's nothing left to rest for.
    public func completeSet(_ setID: UUID) throws {
        let date = now()
        let (session, _) = try prepare { try $0.completeSet(setID, at: date, library: library) }
        let rest = RestTimer(startedAt: date, duration: restPolicy.rest(after: setID, in: session, library: library))
        let timer = session.isEverySetCompleted ? nil : rest
        try persistence.performAtomically {
            try persistence.save(session)
            try persistence.saveValue(timer.map { try JSONEncoder().encode($0) }, forKey: Self.restTimerKey)
        }
        activeSession = session
        restTimer = timer
        heldRest = timer == nil ? rest : nil
    }

    public func reopenSet(_ setID: UUID) throws { try edit { try $0.reopenSet(setID) } }
    public func removeSet(_ setID: UUID) throws { try edit { try $0.removeSet(setID) } }
    public func removeExercise(_ performedID: UUID) throws { try edit { try $0.removeExercise(performedID) } }
    public func moveExercise(_ performedID: UUID, to index: Int) throws { try edit { try $0.moveExercise(performedID, to: index) } }

    /// Swaps an exercise for another before any of its sets is done, prefilled
    /// from the new one's last performance.
    public func replaceExercise(_ performedID: UUID, with exerciseID: ExerciseID) throws {
        let previous = history.lastPerformance(of: exerciseID)
        try edit { try $0.replaceExercise(performedID, with: exerciseID, previous: previous, library: library) }
    }

    @discardableResult
    public func makeSuperset(_ performedIDs: [UUID]) throws -> UUID {
        try edit { try $0.makeSuperset(performedIDs) }
    }

    public func removeFromSuperset(_ performedID: UUID) throws { try edit { try $0.removeFromSuperset(performedID) } }

    /// Changes the session's name, notes, bodyweight or exercise notes. The
    /// result is validated like every other edit, and the ID cannot change.
    public func updateActiveSession(_ change: (inout WorkoutSession) -> Void) throws {
        try edit { change(&$0) }
    }

    /// Totals for a session, with the duration measured to now for one in progress.
    public func summary(of session: WorkoutSession) -> WorkoutSummary {
        WorkoutSummary(session: session, library: library, at: now())
    }

    /// Sets from the last performance of this exercise, to show beside the
    /// current ones.
    public func previousSets(for performedID: UUID) -> [PerformedSet] {
        guard let performed = activeSession?.exercises.first(where: { $0.id == performedID }) else { return [] }
        return history.lastPerformance(of: performed.exerciseID)?.sets ?? []
    }

    /// Ends the session, saving it and clearing the rest timer as one unit.
    @discardableResult
    public func finishSession(discardIncompleteSets: Bool = true) throws -> FinishedSession {
        guard var session = activeSession else { throw StoreError.noActiveSession }
        session.finish(at: now(), discardIncompleteSets: discardIncompleteSets)
        try validated(session)
        try persistence.performAtomically {
            try persistence.save(session)
            try persistence.saveValue(nil, forKey: Self.restTimerKey)
        }
        let records = history.records(in: session)
        history = TrainingHistory(sessions: history.sessions + [session], library: library)
        activeSession = nil
        restTimer = nil
        heldRest = nil
        return FinishedSession(session: session, records: records)
    }

    /// Deletes the session in progress and its rest timer as one unit.
    public func discardSession() throws {
        guard let session = activeSession else { throw StoreError.noActiveSession }
        try persistence.performAtomically {
            try persistence.deleteSession(session.id)
            try persistence.saveValue(nil, forKey: Self.restTimerKey)
        }
        activeSession = nil
        restTimer = nil
        heldRest = nil
    }

    // MARK: Rest

    public func startRest(seconds: Double) throws { try setRestTimer(RestTimer(startedAt: now(), duration: seconds)) }

    public func extendRest(by seconds: Double) throws {
        guard var timer = restTimer else { return }
        timer.extend(by: seconds)
        try setRestTimer(timer)
    }

    public func skipRest() throws { try setRestTimer(nil) }

    public func setRestPolicy(_ policy: RestPolicy) throws {
        try persistence.saveValue(JSONEncoder().encode(policy), forKey: Self.restPolicyKey)
        restPolicy = policy
    }

    private func setRestTimer(_ timer: RestTimer?) throws {
        try persistence.saveValue(timer.map { try JSONEncoder().encode($0) }, forKey: Self.restTimerKey)
        restTimer = timer
        heldRest = nil
    }

    /// Starts the rest held back after the last set, from when that set was
    /// completed, unless it has already run out.
    private func resumeHeldRest() throws {
        guard let held = heldRest, restTimer == nil else { return }
        heldRest = nil
        if !held.isFinished(at: now()) { try setRestTimer(held) }
    }

    // MARK: History

    /// Replaces a finished session, for corrections after the fact.
    public func saveSession(_ session: WorkoutSession) throws {
        guard history.session(session.id) != nil else { throw StoreError.sessionNotFound(session.id) }
        guard session.isFinished else { throw StoreError.sessionNotFinished }
        try validated(session)
        try persistence.save(session)
        history = TrainingHistory(sessions: history.sessions.map { $0.id == session.id ? session : $0 }, library: library)
    }

    /// Adds finished sessions, such as an import or a workout logged after the
    /// fact (PARITY T20). One whose ID is already in the history is left as it
    /// is, so importing a file twice adds nothing. All are checked first, then
    /// saved together. Returns how many were added.
    @discardableResult
    public func importSessions(_ sessions: [WorkoutSession]) throws -> Int {
        var seen = Set<UUID>()
        let added = sessions.filter { history.session($0.id) == nil && seen.insert($0.id).inserted }
        for session in added {
            guard session.isFinished else { throw StoreError.sessionNotFinished }
            try validated(session)
        }
        try persistence.performAtomically {
            for session in added { try persistence.save(session) }
        }
        history = TrainingHistory(sessions: history.sessions + added, library: library)
        return added.count
    }

    public func deleteSession(_ id: UUID) throws {
        guard history.session(id) != nil else { throw StoreError.sessionNotFound(id) }
        try persistence.deleteSession(id)
        history = TrainingHistory(sessions: history.sessions.filter { $0.id != id }, library: library)
    }

    // MARK: Library

    public func addCustomExercise(_ exercise: Exercise) throws {
        guard exercise.id.isCustom else { throw StoreError.invalidCustomExercise(["custom IDs start with custom-"]) }
        let updated: ExerciseLibrary
        do {
            updated = try library.adding(exercise)
        } catch let ExerciseLibrary.Error.invalid(_, problems) {
            throw StoreError.invalidCustomExercise(problems)
        } catch {
            throw StoreError.invalidCustomExercise(["\(error)"])
        }
        try persistence.save(exercise)
        library = updated
        history = TrainingHistory(sessions: history.sessions, library: updated)
    }

    // MARK: Documents

    func session(withID id: UUID) -> WorkoutSession? {
        activeSession?.id == id ? activeSession : history.session(id)
    }

    /// Persists a session from another device, a merge or an accepted
    /// proposal, without the single-active-session rule. Returns the publish
    /// step: a finished session joins history; an unfinished one becomes
    /// active unless another one is.
    func stageSession(_ session: WorkoutSession) throws -> () -> Void {
        let endsActive = session.isFinished && activeSession?.id == session.id
        try persistence.save(session)
        if endsActive { try persistence.saveValue(nil, forKey: Self.restTimerKey) }
        return { [self] in
            let others = history.sessions.filter { $0.id != session.id }
            if session.isFinished {
                history = TrainingHistory(sessions: others + [session], library: library)
                if endsActive {
                    activeSession = nil
                    restTimer = nil
                    heldRest = nil
                }
            } else {
                if history.session(session.id) != nil { history = TrainingHistory(sessions: others, library: library) }
                if activeSession == nil || activeSession?.id == session.id { activeSession = session }
            }
        }
    }

    /// Saves finished sessions, nil removing one, and rebuilds the history
    /// once when published.
    func stageFinishedSessions(_ sessions: [(id: UUID, session: WorkoutSession?)]) throws -> () -> Void {
        for (id, session) in sessions {
            if let session { try persistence.save(session) } else { try persistence.deleteSession(id) }
        }
        let touched = Set(sessions.map(\.id))
        let added = sessions.compactMap(\.session)
        return { [self] in
            history = TrainingHistory(sessions: history.sessions.filter { !touched.contains($0.id) } + added, library: library)
        }
    }

    func stageSessionRemoval(_ id: UUID) throws -> () -> Void {
        let wasActive = activeSession?.id == id
        try persistence.deleteSession(id)
        if wasActive { try persistence.saveValue(nil, forKey: Self.restTimerKey) }
        return { [self] in
            if wasActive {
                activeSession = nil
                restTimer = nil
                heldRest = nil
            }
            if history.session(id) != nil {
                history = TrainingHistory(sessions: history.sessions.filter { $0.id != id }, library: library)
            }
        }
    }

    func stageExercise(_ exercise: Exercise) throws -> () -> Void {
        _ = try library.replacing(exercise)
        try persistence.save(exercise)
        return { [self] in
            // Built from the library at publish time, so several exercises
            // staged in one unit all land. It was validated above.
            library = (try? library.replacing(exercise)) ?? library
            history = TrainingHistory(sessions: history.sessions, library: library)
        }
    }

    // MARK: Private

    /// Applies a change to a copy, validates the result, saves it, and only
    /// then publishes it. A failed change leaves memory and disk untouched.
    private func edit<T>(_ change: (inout WorkoutSession) throws -> T) throws -> T {
        let (session, result) = try prepare(change)
        try persistence.save(session)
        activeSession = session
        return result
    }

    /// The changed, validated copy of the active session. Nothing is saved or published.
    private func prepare<T>(_ change: (inout WorkoutSession) throws -> T) throws -> (WorkoutSession, T) {
        guard let original = activeSession else { throw StoreError.noActiveSession }
        var session = original
        let result: T
        do {
            result = try change(&session)
        } catch let error as WorkoutSession.EditError {
            throw StoreError.edit(error)
        }
        guard session.id == original.id else { throw StoreError.identityChanged }
        try validated(session)
        return (session, result)
    }

    private func validated(_ session: WorkoutSession) throws {
        do {
            try session.validate(library: library)
        } catch let error as WorkoutSession.EditError {
            throw StoreError.edit(error)
        }
    }
}
