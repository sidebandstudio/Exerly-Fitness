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
}
