import Foundation
import Testing
@testable import ExerlyCore

/// One device's training: its store, its conflicts and its sync engine.
@MainActor
final class TrainingDevice {
    let disk = InMemoryTrainingPersistence()
    let store: TrainingStore
    let conflicts: SyncConflictStore
    let sync: SyncEngine

    init(_ name: String, server: FakeDocumentServer, clock: TickingClock) throws {
        store = try TrainingStore(persistence: disk)
        conflicts = SyncConflictStore(state: disk, hosts: [store], deviceName: name, now: clock.now)
        sync = SyncEngine(hosts: [store], state: disk, api: server, conflicts: conflicts, now: clock.now)
    }

    func session(_ id: UUID) -> WorkoutSession? { store.history.session(id) }
}

/// Review round 1 of conflict review: what a later conflict, a later edit,
/// another device's resolution, a clean deletion and a reorder must keep.
@MainActor
@Suite struct SyncConflictReviewTests {
    let monday = LocalDate("2026-10-05")!

    private func devices(_ clock: TickingClock = TickingClock()) throws -> (AccountDevice, AccountDevice) {
        let server = FakeDocumentServer()
        return (try AccountDevice("iPhone", server: server, clock: clock), try AccountDevice("iPad", server: server, clock: clock))
    }

    /// Both devices change one entry's amount, each to its own value, and sync.
    private func clash(_ phone: AccountDevice, _ tablet: AccountDevice, _ id: UUID, phone mine: Double, tablet theirs: Double,
                       meal: String? = nil) async throws {
        var onPhone = try #require(phone.entry(id)), onTablet = try #require(tablet.entry(id))
        onPhone.grams = mine
        onTablet.grams = theirs
        if let meal { onTablet.meal = meal }
        try phone.nutrition.saveEntry(onPhone)
        try tablet.nutrition.saveEntry(onTablet)
        for device in [phone, tablet, phone] { try await device.sync.sync() }
    }

    private func grams(_ version: JSONValue?) -> Double? {
        guard case .object(let fields)? = version, case .number(let grams)? = fields["grams"] else { return nil }
        return grams
    }

    // MARK: Tidying

    /// Review round 2: a settled conflict is removed everywhere 30 days
    /// after the device that settled it synced it, and not before; the one
    /// Undo would reopen stays while it can, on every device.
    @Test func settledConflictsAreRemovedEverywhereAfterThirtyDays() async throws {
        let clock = TickingClock()
        let (phone, tablet) = try devices(clock)
        let logged = try phone.nutrition.log(Foods.oats, grams: 40, on: monday, meal: "Breakfast")
        let other = try phone.nutrition.log(Foods.oats, grams: 50, on: monday, meal: "Lunch")
        for device in [phone, tablet] { try await device.sync.sync() }
        try await clash(phone, tablet, logged.id, phone: 60, tablet: 90)
        try await clash(phone, tablet, other.id, phone: 70, tablet: 80)
        for device in [tablet, phone] { try await device.sync.sync() }
        let conflicts = phone.conflicts.unresolved
        #expect(conflicts.count == 2)
        try phone.conflicts.resolve(conflicts[0].id, .local)
        try phone.conflicts.resolve(conflicts[1].id, .local)
        for device in [phone, tablet] { try await device.sync.sync() }
        clock.advance(29 * 24 * 3600)
        for device in [phone, tablet] { try await device.sync.sync() }
        #expect(phone.conflicts.conflicts.count == 2 && tablet.conflicts.conflicts.count == 2, "Kept for 30 days")
        clock.advance(2 * 24 * 3600)
        for device in [phone, tablet, phone] { try await device.sync.sync() }
        #expect(phone.conflicts.conflicts.map(\.id) == [conflicts[1].id], "Undo can still reopen the last one")
        #expect(tablet.conflicts.conflicts.map(\.id) == [conflicts[1].id])
        try phone.conflicts.undo()
        #expect(phone.conflicts.unresolved.map(\.id) == [conflicts[1].id])
    }

    /// Review round 3, finding 5: resolved offline and synced 40 days later,
    /// a conflict is kept 30 days from when the server took it, not removed
    /// on the next sync.
    @Test func pruningCountsFromWhenTheServerTookTheSettledConflict() async throws {
        let clock = TickingClock()
        let server = FakeDocumentServer()
        let phone = try AccountDevice("iPhone", server: server, clock: clock), tablet = try AccountDevice("iPad", server: server, clock: clock)
        let logged = try phone.nutrition.log(Foods.oats, grams: 40, on: monday, meal: "Breakfast")
        for device in [phone, tablet] { try await device.sync.sync() }
        try await clash(phone, tablet, logged.id, phone: 60, tablet: 90)
        let conflict = try #require(phone.conflicts.unresolved.first)
        server.offline = true
        try phone.conflicts.resolve(conflict.id, .local)
        clock.advance(40 * 24 * 3600)
        server.offline = false
        // Weeks later the app has been relaunched, so Undo is long gone.
        let later = try AccountDevice("iPhone", server: server, clock: clock, disk: phone.disk)
        try await later.sync.sync()
        try await later.sync.sync()
        #expect(later.conflicts.conflict(conflict.id) != nil, "Removed on the first sync after it reached the server")
        clock.advance(29 * 24 * 3600)
        try await later.sync.sync()
        #expect(later.conflicts.conflict(conflict.id) != nil)
        clock.advance(2 * 24 * 3600)
        try await later.sync.sync()
        #expect(later.conflicts.conflict(conflict.id) == nil, "Removed 30 days after the server took it")
    }

    /// Review round 4, finding 4: resolved and synced, then undone and
    /// resolved again offline, and synced 31 days later: the new resolution
    /// is kept 30 days from when the server took it, not the first one.
    @Test func aResolutionMadeAgainOfflineRestartsTheThirtyDays() async throws {
        let clock = TickingClock()
        let server = FakeDocumentServer()
        let phone = try AccountDevice("iPhone", server: server, clock: clock), tablet = try AccountDevice("iPad", server: server, clock: clock)
        let logged = try phone.nutrition.log(Foods.oats, grams: 40, on: monday, meal: "Breakfast")
        for device in [phone, tablet] { try await device.sync.sync() }
        try await clash(phone, tablet, logged.id, phone: 60, tablet: 90)
        let conflict = try #require(phone.conflicts.unresolved.first)
        try phone.conflicts.resolve(conflict.id, .local)
        try await phone.sync.sync()
        server.offline = true
        try phone.conflicts.undo()
        try phone.conflicts.resolve(conflict.id, .remote)
        clock.advance(31 * 24 * 3600)
        server.offline = false
        let later = try AccountDevice("iPhone", server: server, clock: clock, disk: phone.disk)
        try await later.sync.sync()
        try await later.sync.sync()
        #expect(later.conflicts.conflict(conflict.id)?.resolution?.choice == .remote, "The new resolution was removed at once")
        clock.advance(31 * 24 * 3600)
        try await later.sync.sync()
        #expect(later.conflicts.conflict(conflict.id) == nil, "Removed 30 days after the server took the new resolution")
    }

    /// Review round 2: a clash about an entry later deleted everywhere is
    /// settled by sync, which the review says, on both devices.
    @Test func aConflictAboutARecordDeletedEverywhereSettlesItself() async throws {
        let (phone, tablet) = try devices()
        let logged = try phone.nutrition.log(Foods.oats, grams: 40, on: monday, meal: "Breakfast")
        for device in [phone, tablet] { try await device.sync.sync() }
        try await clash(phone, tablet, logged.id, phone: 60, tablet: 90)
        try await tablet.sync.sync()
        #expect(phone.conflicts.unresolved.count == 1 && tablet.conflicts.unresolved.count == 1)
        try tablet.nutrition.deleteEntry(logged.id)
        for device in [tablet, phone, tablet] { try await device.sync.sync() }
        for device in [phone, tablet] {
            #expect(device.conflicts.unresolved.isEmpty, "\(device.conflicts.device.name) still asks")
            #expect(device.conflicts.settledForYou.count == 1 && device.entry(logged.id) == nil)
        }
        #expect(phone.conflicts.conflicts == tablet.conflicts.conflicts)
    }

    // MARK: 1. A later conflict

    /// An unresolved 60 g against 90 g, then 120 g against 150 g: the first
    /// pair still waits for a decision on both devices.
    @Test func aLaterConflictKeepsTheVersionsStillAwaitingReview() async throws {
        let (phone, tablet) = try devices()
        let logged = try phone.nutrition.log(Foods.oats, grams: 40, on: monday, meal: "Breakfast")
        for device in [phone, tablet] { try await device.sync.sync() }
        try await clash(phone, tablet, logged.id, phone: 60, tablet: 90)
        try await tablet.sync.sync()
        try await clash(phone, tablet, logged.id, phone: 120, tablet: 150)
        for device in [tablet, phone] { try await device.sync.sync() }
        for device in [phone, tablet] {
            let held = Set(device.conflicts.unresolved.flatMap { [grams($0.local), grams($0.remote)] }.compactMap { $0 })
            #expect(held == [60, 90, 120, 150], "\(device.conflicts.device.name) holds \(held.sorted())")
        }
        #expect(phone.conflicts.conflicts == tablet.conflicts.conflicts)
    }

    /// The same conflict resolved on one device and undone on another at
    /// once: the later change stands, and its versions stay as found.
    @Test func mergingTwoCopiesOfAConflictTakesTheLaterResolutionOnly() throws {
        let store = SyncConflictStore(state: InMemoryTrainingPersistence(), hosts: [])
        let device = SyncDevice(id: UUID(), name: "iPad")
        let found = SyncConflict(kind: "food_entry", documentID: UUID().uuidString, device: device, detectedAt: Fixture.instant(),
                                 base: .object(["grams": .number(40)]), local: .object(["grams": .number(60)]),
                                 remote: .object(["grams": .number(90)]), fields: ["grams"])
        var resolved = found
        resolved.resolution = .init(choice: .remote, at: Fixture.instant(minutes: 2), device: device)
        resolved.changedAt = Fixture.instant(minutes: 2)
        var reopened = found
        reopened.changedAt = Fixture.instant(minutes: 1)
        for (mine, theirs) in [(resolved, reopened), (reopened, resolved)] {
            let merged = try ExerlyJSON.decoder.decode(SyncConflict.self, from: store.merge(
                kind: SyncConflictStore.kind, base: nil, local: ExerlyJSON.canonical(mine), remote: ExerlyJSON.canonical(theirs)))
            #expect(merged == resolved)
        }
    }

    // MARK: 2. A later edit

    /// The tablet's meal change to Lunch merged while the amount clashed.
    /// The phone then moves the entry to Dinner and keeps the tablet's
    /// amount: it stays at Dinner. Undo after another move keeps that move.
    @Test func resolvingSetsOnlyTheConflictingFieldsAndUndoKeepsLaterChanges() async throws {
        let (phone, tablet) = try devices()
        let logged = try phone.nutrition.log(Foods.oats, grams: 40, on: monday, meal: "Breakfast")
        for device in [phone, tablet] { try await device.sync.sync() }
        try await clash(phone, tablet, logged.id, phone: 60, tablet: 90, meal: "Lunch")
        let conflict = try #require(phone.conflicts.unresolved.first)
        #expect(phone.entry(logged.id)?.meal == "Lunch" && conflict.fields == ["grams"])
        var moved = try #require(phone.entry(logged.id))
        moved.meal = "Dinner"
        try phone.nutrition.saveEntry(moved)
        let tablets = try #require(conflict.choices.first { grams(conflict.version($0)) == 90 })
        try phone.conflicts.resolve(conflict.id, tablets)
        #expect(phone.entry(logged.id)?.grams == 90 && phone.entry(logged.id)?.meal == "Dinner")
        try phone.conflicts.undo()
        try phone.conflicts.resolve(conflict.id, tablets == .local ? .remote : .local)
        #expect(phone.entry(logged.id)?.grams == 60 && phone.entry(logged.id)?.meal == "Dinner")
        var again = try #require(phone.entry(logged.id))
        again.meal = "Snacks"
        try phone.nutrition.saveEntry(again)
        try phone.conflicts.undo()
        #expect(phone.entry(logged.id)?.grams == 90 && phone.entry(logged.id)?.meal == "Snacks")
    }

    /// A set's reps clash while the tablet renamed the workout; the phone
    /// renames it again, then keeps the tablet's reps: only the reps change.
    @Test func resolvingAWorkoutSetChangesOnlyThatSet() async throws {
        let server = FakeDocumentServer(), clock = TickingClock()
        let phone = try TrainingDevice("iPhone", server: server, clock: clock), tablet = try TrainingDevice("iPad", server: server, clock: clock)
        let session = Fixture.session([("barbell-bench-press", [Fixture.set(5, 100), Fixture.set(5, 100)])])
        try phone.store.importSessions([session])
        for device in [phone, tablet] { try await device.sync.sync() }
        var mine = try #require(phone.session(session.id)), theirs = try #require(tablet.session(session.id))
        mine.exercises[0].sets[1].efforts[0].reps = 6
        theirs.exercises[0].sets[1].efforts[0].reps = 4
        theirs.name = "Push"
        try phone.store.saveSession(mine)
        try tablet.store.saveSession(theirs)
        for device in [tablet, phone, tablet] { try await device.sync.sync() }
        let conflict = try #require(phone.conflicts.unresolved.first)
        #expect(phone.session(session.id)?.name == "Push" && phone.session(session.id)?.exercises[0].sets[1].primary.reps == 6)
        let setID = session.exercises[0].sets[1].id.uuidString
        #expect(conflict.fields == ["exercises[\(session.exercises[0].id.uuidString)].sets[\(setID)].efforts"])
        var renamed = try #require(phone.session(session.id))
        renamed.name = "Push day"
        try phone.store.saveSession(renamed)
        let four = try #require(conflict.choices.first { choice in
            conflict.version(choice).map { (try? $0.decode(WorkoutSession.self))?.exercises[0].sets[1].primary.reps } == 4
        })
        try phone.conflicts.resolve(conflict.id, four)
        #expect(phone.session(session.id)?.name == "Push day" && phone.session(session.id)?.exercises[0].sets[1].primary.reps == 4)
    }

    /// Review round 2, finding 4: a set's reps clash, then the phone removes
    /// that set but keeps the workout. Neither version is marked as shown,
    /// the card says the set was removed, and the choices bring it back with
    /// a version's reps or leave it removed, doing what they say.
    @Test func aSetRemovedSinceIsNeitherVersionAndCanBeBroughtBack() async throws {
        let server = FakeDocumentServer(), clock = TickingClock()
        let phone = try TrainingDevice("iPhone", server: server, clock: clock), tablet = try TrainingDevice("iPad", server: server, clock: clock)
        let session = Fixture.session([("barbell-bench-press", [Fixture.set(5, 100), Fixture.set(5, 100)])])
        try phone.store.importSessions([session])
        for device in [phone, tablet] { try await device.sync.sync() }
        var mine = try #require(phone.session(session.id)), theirs = try #require(tablet.session(session.id))
        mine.exercises[0].sets[1].efforts[0].reps = 6
        theirs.exercises[0].sets[1].efforts[0].reps = 4
        try phone.store.saveSession(mine)
        try tablet.store.saveSession(theirs)
        for device in [tablet, phone, tablet] { try await device.sync.sync() }
        let conflict = try #require(phone.conflicts.unresolved.first)
        var removed = try #require(phone.session(session.id))
        removed.exercises[0].sets.remove(at: 1)
        try phone.store.saveSession(removed)

        let summary = phone.conflicts.summary(of: conflict, unit: .kilograms, timeZone: .gmt, locale: Locale(identifier: "en_GB"))
        #expect(!summary.local.shown && !summary.remote.shown, "A removed set is neither version")
        #expect(summary.now == "Barbell Bench Press: set removed")
        #expect(summary.options.map { $0.title } == ["Bring the set back as this iPhone's", "Bring the set back as the other device's",
                                                 "Leave it removed"])
        let four = try #require(conflict.choices.first { choice in
            conflict.version(choice).map { (try? $0.decode(WorkoutSession.self))?.exercises[0].sets[1].primary.reps } == 4
        })
        try phone.conflicts.resolve(conflict.id, four)
        #expect(phone.session(session.id)?.exercises[0].sets.map(\.primary.reps) == [5, 4], "The set is back with 4 reps")
        try phone.conflicts.undo()
        #expect(phone.session(session.id)?.exercises[0].sets.count == 1)
        try phone.conflicts.resolve(conflict.id, .current)
        #expect(phone.session(session.id)?.exercises[0].sets.count == 1 && phone.conflicts.unresolved.isEmpty)
    }

    /// A workout of about `bytes` as JSON: bench press first, then rows.
    private func workout(bytes: Int) throws -> WorkoutSession {
        var session = Fixture.session([("barbell-bench-press", [Fixture.set(5, 100), Fixture.set(5, 100)])])
        while try ExerlyJSON.canonical(session).count < bytes {
            session.exercises += Fixture.session([("barbell-row", (0..<20).map { Fixture.set(8, 60 + Double($0)) })]).exercises
        }
        return session
    }

    /// Review round 2, finding 5: a set clash in a workout of 100 KB, well
    /// within the API's limit, makes a conflict that still syncs, holding
    /// what it clashed on, and the next unrelated push goes through.
    @Test func aConflictAboutALargeWorkoutSyncsAndSyncCarriesOn() async throws {
        let server = FakeDocumentServer(), clock = TickingClock()
        server.maxPayloadBytes = 256 * 1024
        let phone = try TrainingDevice("iPhone", server: server, clock: clock), tablet = try TrainingDevice("iPad", server: server, clock: clock)
        let session = try workout(bytes: 100_000), other = Fixture.session(days: 1, [("barbell-curl", [Fixture.set(10, 30)])])
        try phone.store.importSessions([session, other])
        for device in [phone, tablet] { try await device.sync.sync() }
        var mine = try #require(phone.session(session.id)), theirs = try #require(tablet.session(session.id))
        mine.exercises[0].sets[1].efforts[0].reps = 6
        theirs.exercises[0].sets[1].efforts[0].reps = 4
        try phone.store.saveSession(mine)
        try tablet.store.saveSession(theirs)
        for device in [tablet, phone, tablet] { try await device.sync.sync() }
        let conflict = try #require(phone.conflicts.unresolved.first)
        let stored = try #require(server.stored(SyncConflictStore.kind, conflict.id.uuidString)?.payload, "The conflict syncs")
        #expect(stored.count < 200_000)
        #expect(tablet.conflicts.conflict(conflict.id) == conflict)
        let four = try #require(conflict.choices.first { choice in
            conflict.version(choice).map { (try? $0.decode(WorkoutSession.self))?.exercises[0].sets[1].primary.reps } == 4
        })
        try tablet.conflicts.resolve(conflict.id, four)
        #expect(tablet.session(session.id)?.exercises.count == session.exercises.count)
        #expect(tablet.session(session.id)?.exercises[0].sets[1].primary.reps == 4)
        var renamed = try #require(phone.session(other.id))
        renamed.name = "Legs"
        try phone.store.saveSession(renamed)
        try await phone.sync.sync()
        #expect(server.revision(TrainingStore.sessionKind, other.id.uuidString) == 2)
    }

    /// Changed here and deleted there, a workout so large its conflict can't
    /// be sent stays as a conflict on this device only, which its card says,
    /// and the rest syncs.
    @Test func aConflictTooLargeToSyncStaysOnThisDeviceAndSyncCarriesOn() async throws {
        let server = FakeDocumentServer(), clock = TickingClock()
        server.maxPayloadBytes = 256 * 1024
        let phone = try TrainingDevice("iPhone", server: server, clock: clock), tablet = try TrainingDevice("iPad", server: server, clock: clock)
        let session = try workout(bytes: 230_000), other = Fixture.session(days: 1, [("barbell-curl", [Fixture.set(10, 30)])])
        try phone.store.importSessions([session, other])
        for device in [phone, tablet] { try await device.sync.sync() }
        var mine = try #require(phone.session(session.id))
        mine.name = "Heavy day"
        try phone.store.saveSession(mine)
        try tablet.store.deleteSession(session.id)
        try await tablet.sync.sync()
        try await phone.sync.sync()
        let conflict = try #require(phone.conflicts.unresolved.first)
        #expect(conflict.tooLarge == true && server.stored(SyncConflictStore.kind, conflict.id.uuidString) == nil)
        let summary = phone.conflicts.summary(of: conflict, unit: .kilograms, timeZone: .gmt)
        #expect(summary.note == "Too large to sync, so it's only on this iPhone.")
        #expect(summary.local.value.hasPrefix("Barbell Bench Press: 2 sets, Barbell Row: 20 sets, Barbell Row: 20 sets and "),
                "A whole workout reads as its exercises, not \(summary.local.value)")
        var renamed = try #require(phone.session(other.id))
        renamed.name = "Legs"
        try phone.store.saveSession(renamed)
        try await phone.sync.sync()
        #expect(server.revision(TrainingStore.sessionKind, other.id.uuidString) == 2)
        try phone.conflicts.resolve(conflict.id, try #require(conflict.choices.first { conflict.version($0) != nil }))
        #expect(phone.session(session.id)?.name == "Heavy day")
    }

    // MARK: 4. A clean deletion of the workout in progress

    /// The phone syncs its workout in progress and changes nothing since;
    /// the tablet discards it. The phone keeps it and its rest timer, and
    /// the deletion waits for review.
    @Test func aCleanWorkoutInProgressStaysWhenDeletedElsewhere() async throws {
        let server = FakeDocumentServer(), clock = TickingClock()
        let phone = try TrainingDevice("iPhone", server: server, clock: clock), tablet = try TrainingDevice("iPad", server: server, clock: clock)
        try phone.store.startSession(name: "Pull", bodyweight: nil)
        try phone.store.addExercise("deadlift")
        try phone.store.startRest(seconds: 90)
        let id = try #require(phone.store.activeSession?.id)
        try await phone.sync.sync()
        try await tablet.sync.sync()
        try tablet.store.discardSession()
        try await tablet.sync.sync()
        try await phone.sync.sync()
        #expect(phone.store.activeSession?.id == id && phone.store.restTimer != nil)
        let conflict = try #require(phone.conflicts.unresolved.first)
        #expect(conflict.documentID == id.uuidString && conflict.remote == nil && conflict.local != nil)
        try phone.conflicts.resolve(conflict.id, .remote)
        #expect(phone.store.activeSession == nil, "Keeping it deleted ends it here too")
    }

    // MARK: 5. A reorder

    @Test func aOneSidedReorderIsTakenAndTwoDifferentReordersAreReported() {
        let a = PerformedExercise(exerciseID: "barbell-bench-press"), b = PerformedExercise(exerciseID: "back-squat"),
            c = PerformedExercise(exerciseID: "deadlift")
        let base = WorkoutSession(name: "Full", startedAt: Fixture.instant(), timeZone: Fixture.utc, exercises: [a, b, c])
        var reordered = base, noted = base
        reordered.exercises = [c, a, b]
        noted.notes = "Felt strong"
        for (local, remote) in [(noted, reordered), (reordered, noted)] {
            let merged = Merge.session(base: base, local: local, remote: remote, preferring: .local)
            #expect(merged.merged.exercises.map(\.id) == [c, a, b].map(\.id) && merged.merged.notes == "Felt strong")
            #expect(merged.conflicts.isEmpty)
        }
        var other = base
        other.exercises = [b, a, c]
        let both = Merge.session(base: base, local: reordered, remote: other, preferring: .local)
        #expect(both.conflicts == ["exercises[]"] && both.merged.exercises.map(\.id) == [c, a, b].map(\.id))
        #expect(Merge.session(base: base, local: reordered, remote: other, preferring: .remote).merged.exercises.map(\.id)
            == [b, a, c].map(\.id))
        // An exercise added on one side joins the other side's order.
        var added = base
        added.exercises.append(PerformedExercise(exerciseID: "barbell-row"))
        #expect(Merge.session(base: base, local: added, remote: reordered).exercises.map(\.id) == [c, a, b, added.exercises[3]].map(\.id))
    }

    /// The tablet reorders while the phone changes the notes: the phone
    /// takes the order, reports nothing, and both end in the tablet's order.
    @Test func aReorderOnTheOtherDeviceSurvivesSync() async throws {
        let server = FakeDocumentServer(), clock = TickingClock()
        let phone = try TrainingDevice("iPhone", server: server, clock: clock), tablet = try TrainingDevice("iPad", server: server, clock: clock)
        let session = Fixture.session([("barbell-bench-press", [Fixture.set(5, 100)]), ("back-squat", [Fixture.set(5, 140)])])
        try phone.store.importSessions([session])
        for device in [phone, tablet] { try await device.sync.sync() }
        var mine = try #require(phone.session(session.id)), theirs = try #require(tablet.session(session.id))
        theirs.exercises.reverse()
        mine.notes = "Felt strong"
        try tablet.store.saveSession(theirs)
        try phone.store.saveSession(mine)
        for device in [tablet, phone, tablet] { try await device.sync.sync() }
        for device in [phone, tablet] {
            #expect(device.session(session.id)?.exercises.map(\.id) == theirs.exercises.map(\.id))
            #expect(device.session(session.id)?.notes == "Felt strong" && device.conflicts.conflicts.isEmpty)
        }
    }

    // MARK: Undo of a delete

    /// Deleted and pushed, then Undo: it comes back on both devices.
    @Test func undoingAWorkoutDeleteAfterItsPushBringsItBack() async throws {
        let server = FakeDocumentServer(), clock = TickingClock()
        let phone = try TrainingDevice("iPhone", server: server, clock: clock), tablet = try TrainingDevice("iPad", server: server, clock: clock)
        let session = Fixture.session([("barbell-bench-press", [Fixture.set(5, 100)])])
        try phone.store.importSessions([session])
        for device in [phone, tablet] { try await device.sync.sync() }
        let snapshot = try #require(phone.session(session.id))
        try phone.store.deleteSession(session.id)
        try await phone.sync.sync()
        try phone.conflicts.restore(snapshot)
        for device in [phone, tablet] { try await device.sync.sync() }
        #expect(phone.session(session.id) == snapshot && tablet.session(session.id) == snapshot)
        #expect(phone.conflicts.conflicts.isEmpty && tablet.conflicts.conflicts.isEmpty)
    }

    /// The phone deletes a workout; before Undo it pulls the tablet's new
    /// notes, kept in a conflict. Undo brings back the workout with the
    /// tablet's notes, settles that conflict, and the tablet keeps them.
    @Test func undoingAWorkoutDeleteKeepsAnEditPulledSince() async throws {
        let server = FakeDocumentServer(), clock = TickingClock()
        let phone = try TrainingDevice("iPhone", server: server, clock: clock), tablet = try TrainingDevice("iPad", server: server, clock: clock)
        let session = Fixture.session([("barbell-bench-press", [Fixture.set(5, 100)])])
        try phone.store.importSessions([session])
        for device in [phone, tablet] { try await device.sync.sync() }
        var edited = try #require(tablet.session(session.id))
        edited.notes = "Felt strong"
        try tablet.store.saveSession(edited)
        try await tablet.sync.sync()
        let snapshot = try #require(phone.session(session.id))
        try phone.store.deleteSession(session.id)
        try await phone.sync.sync()
        #expect(phone.conflicts.unresolved.count == 1, "The tablet's notes wait for review")
        try phone.conflicts.restore(snapshot)
        #expect(phone.session(session.id)?.notes == "Felt strong" && phone.conflicts.unresolved.isEmpty)
        for device in [phone, tablet, phone] { try await device.sync.sync() }
        #expect(tablet.session(session.id)?.notes == "Felt strong" && tablet.conflicts.unresolved.isEmpty)
        #expect(phone.session(session.id) == tablet.session(session.id))
    }

    /// The same for a food entry, the Undo the diary offers after a delete.
    @Test func undoingAFoodDeleteKeepsAnEditPulledSince() async throws {
        let (phone, tablet) = try devices()
        let logged = try phone.nutrition.log(Foods.oats, grams: 40, on: monday, meal: "Breakfast")
        for device in [phone, tablet] { try await device.sync.sync() }
        var moved = try #require(tablet.entry(logged.id))
        moved.meal = "Lunch"
        try tablet.nutrition.saveEntry(moved)
        try await tablet.sync.sync()
        let snapshot = try #require(phone.entry(logged.id))
        try phone.nutrition.deleteEntry(logged.id)
        try await phone.sync.sync()
        try phone.conflicts.restore(snapshot)
        for device in [phone, tablet, phone] { try await device.sync.sync() }
        #expect(phone.entry(logged.id)?.meal == "Lunch" && tablet.entry(logged.id)?.meal == "Lunch")
        #expect(phone.conflicts.unresolved.isEmpty && tablet.conflicts.unresolved.isEmpty)
    }

    // MARK: Words

    /// A set's load and a plan's goal read as what they are, and the
    /// version this device shows now is the one marked.
    @Test func setsAndGoalsReadAsTheirValuesAndTheShownVersionIsMarked() throws {
        let device = SyncDevice(id: UUID(), name: "iPhone")
        let set = Fixture.set(5, 100)
        var heavier = set
        heavier.efforts[0].load = .kg(102.5)
        let exercise = PerformedExercise(exerciseID: "barbell-bench-press", sets: [set])
        let base = WorkoutSession(name: "Push", startedAt: Fixture.instant(), timeZone: Fixture.utc, exercises: [exercise])
        var mine = base, theirs = base
        mine.exercises[0].sets[0] = heavier
        theirs.exercises[0].sets[0].efforts[0].reps = 6
        let path = "exercises[\(exercise.id.uuidString)].sets[\(set.id.uuidString)].efforts"
        let workout = SyncConflict(kind: "workout_session", documentID: base.id.uuidString, device: device, detectedAt: Fixture.instant(),
                                   base: try JSONValue(data: ExerlyJSON.canonical(base)), local: try JSONValue(data: ExerlyJSON.canonical(mine)),
                                   remote: try JSONValue(data: ExerlyJSON.canonical(theirs)), fields: [path])
        let words = workout.summary(on: device, unit: .kilograms, timeZone: Fixture.utc, locale: Locale(identifier: "en_US"),
                                    current: workout.remote)
        #expect(words.local.value == "Barbell Bench Press: 102.5 kg × 5" && words.remote.value == "Barbell Bench Press: 100 kg × 6")
        #expect(words.explanation == "Both devices changed the sets.")
        #expect(!words.local.shown && words.remote.shown)
        #expect(workout.summary(on: device, unit: .pounds, timeZone: Fixture.utc, locale: Locale(identifier: "en_US"),
                                current: workout.local).local.value == "Barbell Bench Press: 226 lb × 5")

        let plan = try NutritionPlan(startDate: monday, goal: NutritionGoal(.lose, weeklyRate: 0.005))
            .computed(from: PlanBasis(expenditure: 2500, expenditureError: 400, trendWeight: 80))
        var lose = plan, keep = plan
        lose.goal = NutritionGoal(.lose, weeklyRate: 0.0075)
        keep.goal = NutritionGoal(.maintain)
        let goal = SyncConflict(kind: "nutrition_plan", documentID: plan.id.uuidString, device: device, detectedAt: Fixture.instant(),
                                base: try JSONValue(data: ExerlyJSON.canonical(plan)), local: try JSONValue(data: ExerlyJSON.canonical(lose)),
                                remote: try JSONValue(data: ExerlyJSON.canonical(keep)), fields: ["goal"])
        let goals = goal.summary(on: device, unit: .kilograms, timeZone: Fixture.utc, locale: Locale(identifier: "en_US"), current: goal.local)
        #expect(goals.local.value == "Lose 0.75% a week" && goals.remote.value == "Maintain")
        #expect(goals.local.shown && !goals.remote.shown)
    }
}
