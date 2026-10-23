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
}
