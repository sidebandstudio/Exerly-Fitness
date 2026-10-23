import Foundation
import Testing
@testable import ExerlyCore

/// In-memory storage whose next transaction can be made to fail at its
/// commit, as a full disk or an interrupted write would, rolling back.
@MainActor
final class CommitFailingPersistence: TrainingPersistence, DocumentPersistence {
    struct CommitFailed: Error {}
    let disk = InMemoryTrainingPersistence()
    var failNextCommit = false

    func loadSessions() throws -> [WorkoutSession] { try disk.loadSessions() }
    func loadCustomExercises() throws -> [Exercise] { try disk.loadCustomExercises() }
    func save(_ session: WorkoutSession) throws { try disk.save(session) }
    func deleteSession(_ id: UUID) throws { try disk.deleteSession(id) }
    func save(_ exercise: Exercise) throws { try disk.save(exercise) }
    func loadValue(forKey key: String) throws -> Data? { try disk.loadValue(forKey: key) }
    func saveValue(_ value: Data?, forKey key: String) throws { try disk.saveValue(value, forKey: key) }
    func loadDocuments(kind: String) throws -> [Data] { try disk.loadDocuments(kind: kind) }
    func saveDocument(kind: String, id: String, payload: Data) throws { try disk.saveDocument(kind: kind, id: id, payload: payload) }
    func deleteDocument(kind: String, id: String) throws { try disk.deleteDocument(kind: kind, id: id) }

    private var depth = 0

    func afterCommit(_ action: @escaping () -> Void) { disk.afterCommit(action) }

    /// Nested transactions are savepoints; only the outermost commits, so
    /// only it can fail to.
    func performAtomically(_ body: () throws -> Void) throws {
        depth += 1
        defer { depth -= 1 }
        try disk.performAtomically {
            try body()
            if depth == 1, failNextCommit {
                failNextCommit = false
                throw CommitFailed()
            }
        }
    }
}

private struct ModelRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x5EED }
    mutating func next(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(bound))
    }
    mutating func pick<T>(_ values: [T]) -> T? { values.isEmpty ? nil : values[next(values.count)] }
}

@MainActor @Suite struct BarcodeLoggingModelTests {
    static let codes = ["0012345678905", "0049000000443", "0049000000450", "036000291452", "4006381333931", "96385074"]
        .map { GTIN($0)! }
    static let meals = ["Breakfast", "Lunch", "Dinner", "Snacks"]
    static let days = [LocalDate(year: 2026, month: 10, day: 20)!, LocalDate(year: 2026, month: 10, day: 21)!]

    static func food(_ gtin: GTIN) -> Food {
        Food(id: "off:\(gtin.openFoodFacts)", name: "Synthetic food \(gtin.display)", source: .openFoodFacts,
             per100g: NutrientAmounts([.energy: 200]), servings: [Serving("1 pack", grams: 40)])
    }

    final class Clock { var now = Date(timeIntervalSinceReferenceDate: 810_000_000) }

    /// The scanner's plate and a meal being built, as the app keeps them: each
    /// row carries the offline scans it came from.
    struct Row {
        var food: Food
        var pending: Set<UUID>
        var grams = 40.0
    }

    /// Two offline scans of one product: the plate's row came from one, so
    /// logging consumes that one and the other stays pending.
    @Test func logConsumesExactlyTheScansItsRowsCameFrom() async throws {
        let disk = CommitFailingPersistence()
        let library = BarcodeLibrary(persistence: disk)
        let store = try NutritionStore(persistence: disk)
        let code = Self.codes[0]
        _ = await library.resolve(code, meal: "Lunch", date: Self.days[0]) { _ in .unavailable }
        _ = await library.resolve(code, meal: "Dinner", date: Self.days[0]) { _ in .unavailable }
        await library.resolveWaiting { gtin in .found(Self.food(gtin), attribution: "OFF") }
        let (first, second) = (library.ready[0], library.ready[1])
        let entries = try library.log([NutritionStore.PlateItem(Self.food(code), grams: 40)], consuming: [[first.id]], to: store,
                                      on: Self.days[0], meal: "Lunch")
        #expect(entries.count == 1 && store.entries.count == 1)
        #expect(library.pending.map(\.id) == [second.id] && library.pending.first?.meal == "Dinner")
        #expect(BarcodeLibrary(persistence: disk).pending.map(\.id) == [second.id])
    }

    /// The commit fails: nothing is written or published, so the retry writes
    /// the entry and consumes the scan, once.
    @Test func aFailedCommitLeavesEverythingForTheRetry() async throws {
        let disk = CommitFailingPersistence()
        let library = BarcodeLibrary(persistence: disk)
        let store = try NutritionStore(persistence: disk)
        let code = Self.codes[1]
        _ = await library.resolve(code, meal: "Lunch", date: Self.days[0]) { _ in .unavailable }
        await library.resolveWaiting { gtin in .found(Self.food(gtin), attribution: "OFF") }
        let scan = try #require(library.ready.first)
        let plate = [NutritionStore.PlateItem(Self.food(code), grams: 40)]
        disk.failNextCommit = true
        #expect(throws: CommitFailingPersistence.CommitFailed.self) {
            try library.log(plate, consuming: [[scan.id]], to: store, on: scan.date, meal: scan.meal)
        }
        #expect(store.entries.isEmpty && library.ready.map(\.id) == [scan.id], "Memory is untouched")
        #expect(try NutritionStore(persistence: disk).entries.isEmpty && BarcodeLibrary(persistence: disk).ready.map(\.id) == [scan.id],
                "So is the disk")
        try library.log(plate, consuming: [[scan.id]], to: store, on: scan.date, meal: scan.meal)
        #expect(store.entries.count == 1 && library.pending.isEmpty)
        #expect(try NutritionStore(persistence: disk).entries.count == 1 && BarcodeLibrary(persistence: disk).pending.isEmpty)
    }

    /// A log inside a caller's transaction shows nothing until that commits,
    /// and nothing at all if it rolls back.
    @Test func aNestedLogPublishesOnlyAfterTheOuterCommit() async throws {
        let disk = CommitFailingPersistence()
        let library = BarcodeLibrary(persistence: disk)
        let store = try NutritionStore(persistence: disk)
        let code = Self.codes[2]
        _ = await library.resolve(code, meal: "Lunch", date: Self.days[0]) { _ in .unavailable }
        await library.resolveWaiting { gtin in .found(Self.food(gtin), attribution: "OFF") }
        let scan = try #require(library.ready.first)
        let plate = [NutritionStore.PlateItem(Self.food(code), grams: 40)]
        struct Abandoned: Error {}
        #expect(throws: Abandoned.self) {
            try disk.performAtomically {
                try library.log(plate, consuming: [[scan.id]], to: store, on: scan.date, meal: scan.meal)
                throw Abandoned()
            }
        }
        #expect(store.entries.isEmpty && library.ready.map(\.id) == [scan.id], "A rolled-back outer transaction shows nothing")
        try disk.performAtomically {
            try library.log(plate, consuming: [[scan.id]], to: store, on: scan.date, meal: scan.meal)
            #expect(store.entries.isEmpty && library.ready.map(\.id) == [scan.id], "Nothing shows before the outer commit")
        }
        #expect(store.entries.count == 1 && library.pending.isEmpty)
    }

    /// A scan logged once can't be logged again, by any plate.
    @Test func aScanNoLongerPendingIsRefused() async throws {
        let disk = CommitFailingPersistence()
        let library = BarcodeLibrary(persistence: disk)
        let store = try NutritionStore(persistence: disk)
        let code = Self.codes[3]
        _ = await library.resolve(code, meal: "Lunch", date: Self.days[0]) { _ in .unavailable }
        await library.resolveWaiting { gtin in .found(Self.food(gtin), attribution: "OFF") }
        let scan = try #require(library.ready.first)
        let plate = [NutritionStore.PlateItem(Self.food(code), grams: 40)]
        try library.log(plate, consuming: [[scan.id]], to: store, on: scan.date, meal: scan.meal)
        #expect(throws: BarcodeLibrary.LogError.alreadyLogged([scan.id])) {
            try library.log(plate, consuming: [[scan.id]], to: store, on: scan.date, meal: scan.meal)
        }
        #expect(store.entries.count == 1)
    }

    /// Undo deletes the log's entries and puts its offline scans back with
    /// their meal, day and time; a failed commit leaves the log in place.
    @Test func undoPutsTheScansBackWithTheirIntent() async throws {
        let disk = CommitFailingPersistence()
        let clock = Clock()
        let library = BarcodeLibrary(persistence: disk, now: { clock.now })
        let store = try NutritionStore(persistence: disk)
        let code = Self.codes[4]
        _ = await library.resolve(code, meal: "Dinner", date: Self.days[1]) { _ in .unavailable }
        await library.resolveWaiting { gtin in .found(Self.food(gtin), attribution: "OFF") }
        let scan = try #require(library.ready.first)
        let logged = try library.log([NutritionStore.PlateItem(Self.food(code), grams: 40)], consuming: [[scan.id]], to: store,
                                     on: Self.days[0], meal: "Lunch")
        disk.failNextCommit = true
        #expect(throws: CommitFailingPersistence.CommitFailed.self) { try library.undo(Set(logged.map(\.id)), from: store) }
        #expect(store.entries.count == 1 && library.pending.isEmpty)
        try library.undo(Set(logged.map(\.id)), from: store)
        #expect(store.entries.isEmpty && library.pending == [scan])
        let relaunched = BarcodeLibrary(persistence: disk)
        #expect(relaunched.pending == [scan] && relaunched.pending.first?.meal == "Dinner")
        #expect(try NutritionStore(persistence: disk).entries.isEmpty)
    }

    /// Undoing one food of a plate puts back only that food's scans; the
    /// rest of the log can still be undone later.
    @Test func undoingOneFoodPutsBackOnlyItsScans() async throws {
        let disk = CommitFailingPersistence()
        let clock = Clock()
        let library = BarcodeLibrary(persistence: disk, now: { clock.now })
        let store = try NutritionStore(persistence: disk)
        let (a, b) = (Self.codes[0], Self.codes[1])
        for code in [a, b] {
            clock.now += 1
            _ = await library.resolve(code, meal: "Dinner", date: Self.days[1]) { _ in .unavailable }
        }
        await library.resolveWaiting { gtin in .found(Self.food(gtin), attribution: "OFF") }
        let scans = library.ready
        let logged = try library.log([a, b].map { NutritionStore.PlateItem(Self.food($0), grams: 40) }, consuming: scans.map { [$0.id] },
                                     to: store, on: Self.days[0], meal: "Lunch")
        try library.undo([logged[0].id], from: store)
        #expect(library.pending.map(\.gtin) == [a] && store.entries.map(\.id) == [logged[1].id])
        try library.undo([logged[1].id], from: store)
        #expect(library.pending == scans && store.entries.isEmpty)
    }

    /// The phone logs a scan and syncs; the tablet edits that entry while the
    /// phone is offline; the phone undoes it and logs the scan again. After
    /// sync the undone entry stays deleted, so the scan is logged once, and
    /// the tablet's edit waits in a conflict (PARITY I03 and N08). Bringing
    /// it back applies the tablet's 60 g to the entry logged again, so the
    /// scan is still logged once; Undo puts the 40 g back.
    @Test func aScanUndoneHereAndEditedElsewhereIsLoggedOnceAfterSync() async throws {
        let server = FakeDocumentServer()
        let phoneDisk = InMemoryTrainingPersistence(), tabletDisk = InMemoryTrainingPersistence()
        let library = BarcodeLibrary(persistence: phoneDisk)
        let phone = try NutritionStore(persistence: phoneDisk), tablet = try NutritionStore(persistence: tabletDisk)
        let phoneSync = SyncEngine(hosts: [phone], state: phoneDisk, api: server)
        phoneSync.conflicts.effects = ScanConflictEffects(library: library, store: phone)
        let tabletSync = SyncEngine(hosts: [tablet], state: tabletDisk, api: server)
        let code = Self.codes[2]
        _ = await library.resolve(code, meal: "Lunch", date: Self.days[0]) { _ in .unavailable }
        await library.resolveWaiting { gtin in .found(Self.food(gtin), attribution: "OFF") }
        let scan = try #require(library.ready.first)
        let plate = [NutritionStore.PlateItem(Self.food(code), grams: 40)]
        let first = try library.log(plate, consuming: [[scan.id]], to: phone, on: scan.date, meal: scan.meal)
        try await phoneSync.sync()
        try await tabletSync.sync()
        var edited = try #require(tablet.entries.first)
        #expect(edited.id == first[0].id)
        edited.grams = 60
        try tablet.saveEntry(edited)
        try await tabletSync.sync()
        try library.undo(Set(first.map(\.id)), from: phone)
        #expect(phone.entries.isEmpty && library.ready.map(\.id) == [scan.id])
        let again = try library.log(plate, consuming: [[scan.id]], to: phone, on: scan.date, meal: scan.meal)
        try await phoneSync.sync()
        try await tabletSync.sync()
        #expect(phone.entries.map(\.id) == again.map(\.id), "The scan is logged once, not as \(phone.entries.map(\.grams)) g")
        #expect(tablet.entries.map(\.id) == again.map(\.id))
        let conflict = try #require(phoneSync.conflicts.unresolved.first)
        #expect(conflict.documentID == first[0].id.uuidString && conflict.local == nil)
        #expect(phoneSync.conflicts.replacement(for: conflict) == again[0].id.uuidString)

        try phoneSync.conflicts.resolve(conflict.id, .remote)
        #expect(phone.entries.map(\.id) == again.map(\.id) && phone.entries.map(\.grams) == [60])
        try await phoneSync.sync()
        try await tabletSync.sync()
        #expect(tablet.entries.map(\.grams) == [60] && tablet.entries.count == 1)
        try phoneSync.conflicts.undo()
        #expect(phone.entries.map(\.grams) == [40] && library.pending.isEmpty)
    }

    /// When the phone logs the scan again.
    enum Relog: CaseIterable, Sendable { case beforeSync, afterTheTabletResolves, never }

    /// Review round 1, finding 3: the same, but the tablet resolves the
    /// conflict. Its barcode library knows nothing of the phone's scans, yet
    /// the entry logged again says which entry it stands in for, so the
    /// tablet's version becomes that entry's change and the scan is logged
    /// once on both. Logged again only after the tablet brought the original
    /// back, the phone folds the original into it; never logged again, the
    /// original is the scan's log on the phone, and the scan isn't pending.
    @Test(arguments: Relog.allCases)
    func aScanConflictResolvedOnAnotherDeviceLogsTheScanOnce(relog: Relog) async throws {
        let server = FakeDocumentServer(), clock = TickingClock()
        let phoneDisk = InMemoryTrainingPersistence(), tabletDisk = InMemoryTrainingPersistence()
        let library = BarcodeLibrary(persistence: phoneDisk), tabletLibrary = BarcodeLibrary(persistence: tabletDisk)
        let phone = try NutritionStore(persistence: phoneDisk), tablet = try NutritionStore(persistence: tabletDisk)
        let phoneConflicts = SyncConflictStore(state: phoneDisk, hosts: [phone], deviceName: "iPhone", now: clock.now)
        let tabletConflicts = SyncConflictStore(state: tabletDisk, hosts: [tablet], deviceName: "iPad", now: clock.now)
        phoneConflicts.effects = ScanConflictEffects(library: library, store: phone)
        tabletConflicts.effects = ScanConflictEffects(library: tabletLibrary, store: tablet)
        let phoneSync = SyncEngine(hosts: [phone], state: phoneDisk, api: server, conflicts: phoneConflicts, now: clock.now)
        let tabletSync = SyncEngine(hosts: [tablet], state: tabletDisk, api: server, conflicts: tabletConflicts, now: clock.now)
        let code = Self.codes[4]
        _ = await library.resolve(code, meal: "Lunch", date: Self.days[0]) { _ in .unavailable }
        await library.resolveWaiting { gtin in .found(Self.food(gtin), attribution: "OFF") }
        let scan = try #require(library.ready.first)
        let plate = [NutritionStore.PlateItem(Self.food(code), grams: 40)]
        let first = try library.log(plate, consuming: [[scan.id]], to: phone, on: scan.date, meal: scan.meal)
        try await phoneSync.sync()
        try await tabletSync.sync()
        var edited = try #require(tablet.entries.first)
        edited.grams = 60
        try tablet.saveEntry(edited)
        try await tabletSync.sync()
        try library.undo(Set(first.map(\.id)), from: phone)
        var again = first
        if relog == .beforeSync { again = try library.log(plate, consuming: [[scan.id]], to: phone, on: scan.date, meal: scan.meal) }
        try await phoneSync.sync()
        try await tabletSync.sync()
        let conflict = try #require(tabletConflicts.unresolved.first)
        #expect(conflict.documentID == first[0].id.uuidString && conflict.local == nil)
        try tabletConflicts.resolve(conflict.id, .remote)
        if relog == .afterTheTabletResolves {
            again = try library.log(plate, consuming: [[scan.id]], to: phone, on: scan.date, meal: scan.meal)
        }
        for sync in [tabletSync, phoneSync, tabletSync, phoneSync] { try await sync.sync() }
        for store in [phone, tablet] {
            #expect(store.entries.map(\.id) == again.map(\.id), "The scan is logged once, not as \(store.entries.map(\.grams)) g")
            #expect(store.entries.map(\.grams) == [60])
        }
        #expect(library.pending.isEmpty)
        #expect(throws: BarcodeLibrary.LogError.alreadyLogged([scan.id])) {
            try library.log(plate, consuming: [[scan.id]], to: phone, on: scan.date, meal: scan.meal)
        }
    }

    /// Undone and not logged again, the scan is pending; bringing the entry
    /// back logs it, once, and Undo puts the scan back.
    @Test func bringingBackAnUndoneScanLogsItOnce() async throws {
        let server = FakeDocumentServer()
        let phoneDisk = InMemoryTrainingPersistence(), tabletDisk = InMemoryTrainingPersistence()
        let library = BarcodeLibrary(persistence: phoneDisk)
        let phone = try NutritionStore(persistence: phoneDisk), tablet = try NutritionStore(persistence: tabletDisk)
        let phoneSync = SyncEngine(hosts: [phone], state: phoneDisk, api: server)
        phoneSync.conflicts.effects = ScanConflictEffects(library: library, store: phone)
        let tabletSync = SyncEngine(hosts: [tablet], state: tabletDisk, api: server)
        let code = Self.codes[3]
        _ = await library.resolve(code, meal: "Dinner", date: Self.days[1]) { _ in .unavailable }
        await library.resolveWaiting { gtin in .found(Self.food(gtin), attribution: "OFF") }
        let scan = try #require(library.ready.first)
        let first = try library.log([NutritionStore.PlateItem(Self.food(code), grams: 40)], consuming: [[scan.id]], to: phone,
                                    on: scan.date, meal: scan.meal)
        try await phoneSync.sync()
        try await tabletSync.sync()
        var edited = try #require(tablet.entries.first)
        edited.grams = 55
        try tablet.saveEntry(edited)
        try await tabletSync.sync()
        try library.undo(Set(first.map(\.id)), from: phone)
        try await phoneSync.sync()
        let conflict = try #require(phoneSync.conflicts.unresolved.first)
        #expect(phone.entries.isEmpty && library.pending.map(\.id) == [scan.id])
        try phoneSync.conflicts.resolve(conflict.id, .remote)
        #expect(phone.entries.map(\.grams) == [55] && library.pending.isEmpty, "Brought back, the scan is its log")
        #expect(throws: BarcodeLibrary.LogError.alreadyLogged([scan.id])) {
            try library.log([NutritionStore.PlateItem(Self.food(code), grams: 40)], consuming: [[scan.id]], to: phone,
                            on: scan.date, meal: scan.meal)
        }
        try phoneSync.conflicts.undo()
        #expect(phone.entries.isEmpty && library.pending.map(\.id) == [scan.id])
    }

    @Test func oneTransactionNeedsOneStore() async throws {
        let library = BarcodeLibrary(persistence: InMemoryTrainingPersistence())
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        #expect(throws: BarcodeLibrary.LogError.self) {
            try library.log([NutritionStore.PlateItem(Self.food(Self.codes[0]), grams: 40)], consuming: [[]], to: store,
                            on: Self.days[0], meal: "Lunch")
        }
        #expect(store.entries.isEmpty)
    }

    /// Two offline scans of one food, ready to log.
    private func twoScansOfOneFood(_ code: GTIN, on disk: CommitFailingPersistence) async throws
        -> (BarcodeLibrary, NutritionStore, [BarcodeLibrary.Pending]) {
        let clock = Clock()
        let library = BarcodeLibrary(persistence: disk, now: { clock.now })
        let store = try NutritionStore(persistence: disk)
        _ = await library.resolve(code, meal: "Lunch", date: Self.days[0]) { _ in .unavailable }
        clock.now += 1
        _ = await library.resolve(code, meal: "Dinner", date: Self.days[1]) { _ in .unavailable }
        await library.resolveWaiting { gtin in .found(Self.food(gtin), attribution: "OFF") }
        return (library, store, library.ready)
    }

    /// Review round 5, defect 1: two offline scans of one food logged
    /// separately, then the row's Undo takes both entries. No one log holds
    /// both, and once 20 later logs pushed them out of memory none did; each
    /// entry keeps its own scan now, through a relaunch too.
    @Test func anUndoSpanningSeveralLogsPutsBackEveryScan() async throws {
        let disk = CommitFailingPersistence()
        let code = Self.codes[0]
        let setup = try await twoScansOfOneFood(code, on: disk)
        var (library, store) = (setup.0, setup.1)
        let scans = setup.2
        let plate = [NutritionStore.PlateItem(Self.food(code), grams: 40)]
        let first = try library.log(plate, consuming: [[scans[0].id]], to: store, on: Self.days[0], meal: "Lunch")
        let second = try library.log(plate, consuming: [[scans[1].id]], to: store, on: Self.days[0], meal: "Lunch")
        for _ in 0..<21 { try library.log([NutritionStore.PlateItem(Self.food(Self.codes[1]), grams: 40)], consuming: [[]], to: store,
                                          on: Self.days[0], meal: "Snacks") }
        library = BarcodeLibrary(persistence: disk)
        store = try NutritionStore(persistence: disk)
        try library.undo(Set((first + second).map(\.id)), from: store)
        #expect(library.pending == scans, "Both scans are back with their meal, day and time")
        #expect(store.entries.count == 21 && !store.entries.contains { $0.food.foodID == Self.food(code).id })
    }

    /// Review round 5, defect 2: undoing one of two same-food entries put
    /// back both scans, so the other, still logged, could be logged twice.
    @Test func undoingOneOfTwoSameFoodEntriesPutsBackOnlyItsScan() async throws {
        let disk = CommitFailingPersistence()
        let code = Self.codes[1]
        let (library, store, scans) = try await twoScansOfOneFood(code, on: disk)
        let item = NutritionStore.PlateItem(Self.food(code), grams: 40)
        let logged = try library.log([item, item], consuming: scans.map { [$0.id] }, to: store, on: Self.days[0], meal: "Lunch")
        try library.undo([logged[0].id], from: store)
        #expect(library.pending == [scans[0]] && store.entries.map(\.id) == [logged[1].id])
        #expect(throws: BarcodeLibrary.LogError.alreadyLogged([scans[1].id])) {
            try library.log([item], consuming: [[scans[1].id]], to: store, on: Self.days[0], meal: "Lunch")
        }
        #expect(store.entries.count == 1)
    }

    /// Review round 5, defect 3: a sibling transaction that fails took the
    /// publish of one saved before it, so a committed log never showed.
    /// AtomicityTests checks both stores alone.
    @Test func aFailedSiblingKeepsAnEarlierSiblingsLog() async throws {
        struct Injected: Error {}
        let disk = CommitFailingPersistence()
        let code = Self.codes[2]
        let (library, store, scans) = try await twoScansOfOneFood(code, on: disk)
        let plate = [NutritionStore.PlateItem(Self.food(code), grams: 40)]
        try disk.performAtomically {
            try library.log(plate, consuming: [[scans[0].id]], to: store, on: Self.days[0], meal: "Lunch")
            try? disk.performAtomically {
                try library.log(plate, consuming: [[scans[1].id]], to: store, on: Self.days[0], meal: "Lunch")
                throw Injected()
            }
        }
        #expect(store.entries.count == 1 && library.pending == [scans[1]], "Memory shows the saved log")
        #expect(try NutritionStore(persistence: disk).entries.count == 1 && BarcodeLibrary(persistence: disk).pending == [scans[1]])
    }

    /// Review round 5, defect 4: two calls in one caller's transaction read
    /// pending scans from memory, which changes only at the commit. A second
    /// log of the same scan wrote it twice; an Undo after a log put the
    /// logged scan back; a log after an Undo refused the scan it restored.
    @Test func callsInOneTransactionSeeEachOther() async throws {
        let disk = CommitFailingPersistence()
        let code = Self.codes[3]
        let (library, store, scans) = try await twoScansOfOneFood(code, on: disk)
        let plate = [NutritionStore.PlateItem(Self.food(code), grams: 40)]
        try disk.performAtomically {
            try library.log(plate, consuming: [[scans[0].id]], to: store, on: Self.days[0], meal: "Lunch")
            #expect(throws: BarcodeLibrary.LogError.alreadyLogged([scans[0].id])) {
                try library.log(plate, consuming: [[scans[0].id]], to: store, on: Self.days[0], meal: "Lunch")
            }
        }
        #expect(store.entries.count == 1 && library.pending == [scans[1]])
        let first = try #require(store.entries.first)
        try disk.performAtomically {
            try library.log(plate, consuming: [[scans[1].id]], to: store, on: Self.days[0], meal: "Dinner")
            try library.undo([first.id], from: store)
        }
        #expect(library.pending == [scans[0]] && BarcodeLibrary(persistence: disk).pending == [scans[0]], "Only the undone scan is back")
        try disk.performAtomically {
            try library.undo(Set(store.entries.map(\.id)), from: store)
            try library.log(plate, consuming: [[scans[1].id]], to: store, on: Self.days[1], meal: "Dinner")
        }
        #expect(library.pending == [scans[0]] && BarcodeLibrary(persistence: disk).pending == [scans[0]])
        #expect(store.entries.count == 1 && store.entries.first?.meal == "Dinner")
    }

    /// 1,000 seeded random runs of 40 steps of what the app does with offline
    /// scans: scan offline, resolve, put a scan on the scanner's plate or a
    /// meal being built (each offers what isn't on itself, so one scan can
    /// reach both, and a food can take two rows), cancel its portion, remove
    /// its row, log or discard either plate, log one alone, fail a commit then
    /// edit and retry, Undo any entries of any log at any age (a row's across
    /// logs, or one of several of the same food), delete from Today and undo
    /// that, log 21 times in a row, run logs and an Undo in one caller's
    /// transaction beside a sibling that fails, say Not needed, remove
    /// history, quit and relaunch. Every offline scan ends exactly one way:
    /// still pending with its meal, day and time, logged exactly once, or
    /// dismissed. Memory matches the disk after every step.
    @Test func everyOfflineScanEndsPendingOrLoggedExactlyOnce() async throws {
        for seed in 0..<1_000 {
            try await run(seed: UInt64(seed))
        }
    }

    private func run(seed: UInt64) async throws {
        struct Injected: Error {}
        var random = ModelRandom(seed: seed)
        let disk = CommitFailingPersistence()
        let clock = Clock()
        var library = BarcodeLibrary(persistence: disk, now: { clock.now })
        var store = try NutritionStore(persistence: disk, now: { clock.now })
        var intents: [UUID: (meal: String, date: LocalDate, scannedAt: Date)] = [:]
        var logged: [UUID: Int] = [:]
        var dismissed: Set<UUID> = []
        /// Every entry that should be logged, with the scans it came from.
        var alive: [UUID: Set<UUID>] = [:]
        /// Entries deleted from Today, which Undo there can restore.
        var deleted: [(entry: FoodEntry, scans: Set<UUID>)] = []
        var plates: [[Row]] = [[], []]
        var offline = true
        let missing = Self.codes[5]

        func onAPlate() -> Set<UUID> { Set(plates.flatMap { $0.flatMap(\.pending) }) }
        /// What a plate's scanner offers: ready scans not already on it.
        func offered(to plate: Int) -> [BarcodeLibrary.Pending] {
            let on = Set(plates[plate].flatMap(\.pending))
            return library.ready.filter { !on.contains($0.id) }
        }
        func fetch(_ gtin: GTIN) -> BarcodeLibrary.Fetched {
            offline ? .unavailable : gtin == missing ? .missing : .found(Self.food(gtin), attribution: "OFF")
        }
        func relaunch() throws {
            library = BarcodeLibrary(persistence: disk, now: { clock.now })
            store = try NutritionStore(persistence: disk, now: { clock.now })
            plates = [[], []]
        }
        func items(_ rows: [Row]) -> [NutritionStore.PlateItem] { rows.map { NutritionStore.PlateItem($0.food, grams: $0.grams) } }
        func wrote(_ entries: [FoodEntry], from rows: [Row]) {
            for (entry, row) in zip(entries, rows) {
                alive[entry.id] = row.pending
                for id in row.pending { logged[id, default: 0] += 1 }
            }
        }
        func undid(_ ids: Set<UUID>) {
            for id in ids { for scan in alive.removeValue(forKey: id) ?? [] { logged[scan, default: 0] -= 1 } }
        }
        /// Logs, sometimes failing the commit first; after a failure the app may
        /// retry, with an amount edited, or be killed before it can. A scan
        /// logged elsewhere is refused, and its row stays as a plain food.
        /// Returns the rows left on the plate, nil when the app was killed.
        func log(_ rows: [Row], date: LocalDate, meal: String) throws -> [Row]? {
            var rows = rows
            let ids = Set(rows.flatMap(\.pending))
            let gone = ids.subtracting(library.pending.map(\.id))
            guard gone.isEmpty else {
                #expect(throws: BarcodeLibrary.LogError.alreadyLogged(gone)) {
                    try library.log(items(rows), consuming: rows.map(\.pending), to: store, on: date, meal: meal)
                }
                for index in rows.indices { rows[index].pending.subtract(gone) }
                return rows
            }
            if random.next(4) == 0 {
                let before = (library.pending, store.entries.count)
                disk.failNextCommit = true
                #expect(throws: CommitFailingPersistence.CommitFailed.self) {
                    try library.log(items(rows), consuming: rows.map(\.pending), to: store, on: date, meal: meal)
                }
                #expect(library.pending == before.0 && store.entries.count == before.1, "seed \(seed): a failed commit changed memory")
                if random.next(3) == 0 { return nil }
                if let index = random.pick(Array(rows.indices)) { rows[index].grams = 80 }
            }
            wrote(try library.log(items(rows), consuming: rows.map(\.pending), to: store, on: date, meal: meal), from: rows)
            return []
        }
        /// A ready scan logged alone, as a row of its own.
        func row(_ scan: BarcodeLibrary.Pending) -> Row? { library.usable(scan.gtin).map { Row(food: $0.food, pending: [scan.id]) } }

        for _ in 0..<40 {
            clock.now += 61
            let plate = random.next(2)
            switch random.next(19) {
            case 0, 1:
                // Scan a code; offline and uncached, it's kept with its intent.
                guard let code = random.pick(Self.codes), let meal = random.pick(Self.meals), let day = random.pick(Self.days) else { continue }
                if case .queued = await library.resolve(code, meal: meal, date: day, fetch: { fetch($0) }) {
                    let scan = try #require(library.pending.last)
                    intents[scan.id] = (meal, day, clock.now)
                }
            case 2:
                offline.toggle()
            case 3:
                await library.resolveWaiting { fetch($0) }
            case 4, 5:
                // Put a ready scan on a plate, joining its food's row or a new one.
                guard let scan = random.pick(offered(to: plate)), let product = library.usable(scan.gtin) else { continue }
                if let index = plates[plate].firstIndex(where: { $0.food.id == product.food.id }), random.next(2) == 0 {
                    plates[plate][index].pending.insert(scan.id)
                } else {
                    plates[plate].append(Row(food: product.food, pending: [scan.id]))
                }
            case 6:
                // Picked, then cancelled at its portion: nothing joins.
                _ = random.pick(offered(to: plate))
            case 7:
                // A food that isn't a scan.
                plates[plate].append(Row(food: Self.food(Self.codes[random.next(5)]), pending: []))
            case 8:
                guard !plates[plate].isEmpty else { continue }
                plates[plate].remove(at: random.next(plates[plate].count))
            case 9:
                guard !plates[plate].isEmpty, let meal = random.pick(Self.meals) else { continue }
                if let left = try log(plates[plate], date: Self.days[0], meal: meal) { plates[plate] = left } else { try relaunch() }
            case 10:
                if random.next(2) == 0 {
                    plates[plate] = []
                } else if let scan = random.pick(offered(to: plate)), let alone = row(scan) {
                    // Logged alone, to the meal and time it was scanned for.
                    if try log([alone], date: scan.date, meal: scan.meal) == nil { try relaunch() }
                }
            case 11:
                // Undo from any screen, of any log at any age: a row's entries
                // of one food, across logs, or one of several of that food.
                guard let food = random.pick(Set(store.entries.map(\.food.foodID)).sorted()) else { continue }
                let same = store.entries.filter { $0.food.foodID == food }.map(\.id)
                let ids: Set<UUID> = random.next(2) == 0 ? Set(same) : [same[random.next(same.count)]]
                if random.next(4) == 0 {
                    disk.failNextCommit = true
                    #expect(throws: CommitFailingPersistence.CommitFailed.self) { try library.undo(ids, from: store) }
                    continue
                }
                try library.undo(ids, from: store)
                undid(ids)
            case 12:
                // Not needed: resolved scans go, except those on a plate.
                let keeping = onAPlate()
                for scan in library.pending where scan.state != .waiting && !keeping.contains(scan.id) { dismissed.insert(scan.id) }
                library.dismissResolved(keeping: keeping)
            case 13:
                // Removed from the history; offline scans of it stay.
                if let scan = random.pick(library.history) { library.remove(scan.gtin) }
            case 14:
                // Deleted from Today: "I didn't eat it" dismisses its scans.
                guard let entry = random.pick(store.entries), let scans = alive.removeValue(forKey: entry.id) else { continue }
                try store.deleteEntry(entry.id)
                for id in scans { logged[id, default: 0] -= 1 }
                dismissed.formUnion(scans)
                deleted.append((entry, scans))
            case 15:
                // Today's Undo of that delete: the entry is the scans' one log again.
                guard let last = deleted.popLast(), !store.entries.contains(where: { $0.id == last.entry.id }) else { continue }
                try store.saveEntry(last.entry)
                alive[last.entry.id] = last.scans
                for id in last.scans { logged[id, default: 0] += 1 }
                dismissed.subtract(last.scans)
            case 16:
                // 21 logs in a row, more than any recent-log memory held.
                for index in 0..<21 {
                    let rows = [Row(food: Self.food(Self.codes[index % 5]), pending: [])]
                    wrote(try library.log(items(rows), consuming: [[]], to: store, on: Self.days[1], meal: "Snacks"), from: rows)
                }
            case 17:
                // One caller's transaction: a log; a sibling that logs then
                // fails; the same scan again, refused; an Undo of saved
                // entries and a log of a scan it put back. Sometimes the
                // whole transaction fails.
                var effects: [() -> Void] = []
                let ready = library.ready
                let first = random.pick(ready)
                let sibling = random.pick(ready.filter { $0.id != first?.id })
                let undo = random.pick(store.entries).map { Set([$0.id]) } ?? []
                let failing = random.next(4) == 0
                do {
                    try disk.performAtomically {
                        if let first, let alone = row(first) {
                            let entries = try library.log(items([alone]), consuming: [alone.pending], to: store, on: first.date, meal: first.meal)
                            effects.append { wrote(entries, from: [alone]) }
                            if random.next(2) == 0 {
                                #expect(throws: BarcodeLibrary.LogError.alreadyLogged([first.id])) {
                                    try library.log(items([alone]), consuming: [alone.pending], to: store, on: first.date, meal: first.meal)
                                }
                            }
                        }
                        if let sibling, let alone = row(sibling) {
                            try? disk.performAtomically {
                                try library.log(items([alone]), consuming: [alone.pending], to: store, on: sibling.date, meal: sibling.meal)
                                throw Injected()
                            }
                        }
                        if !undo.isEmpty {
                            try library.undo(undo, from: store)
                            effects.append { undid(undo) }
                            let back = undo.flatMap { alive[$0] ?? [] }.sorted { $0.uuidString < $1.uuidString }
                            if let id = random.pick(back), let scan = BarcodeLibrary(persistence: disk).pending.first(where: { $0.id == id }),
                               let alone = row(scan) {
                                let entries = try library.log(items([alone]), consuming: [alone.pending], to: store, on: scan.date,
                                                              meal: scan.meal)
                                effects.append { wrote(entries, from: [alone]) }
                            }
                        }
                        if failing { throw Injected() }
                    }
                    effects.forEach { $0() }
                } catch is Injected {}
            default:
                try relaunch()
            }
            #expect(library.pending == BarcodeLibrary(persistence: disk).pending, "seed \(seed): pending in memory isn't on disk")
            #expect(Set(store.entries.map(\.id)) == Set(alive.keys), "seed \(seed): entries in memory aren't the ones logged")
            #expect(Set(try NutritionStore(persistence: disk).entries.map(\.id)) == Set(alive.keys), "seed \(seed): entries on disk")
        }

        try relaunch()
        for (id, intent) in intents {
            let times = logged[id] ?? 0
            let record = library.pending.first { $0.id == id }
            #expect(times == 0 || times == 1, "seed \(seed): \(id) logged \(times) times")
            #expect([record != nil, times == 1, dismissed.contains(id)].filter { $0 }.count == 1,
                    "seed \(seed): \(id) is pending \(record != nil), logged \(times), dismissed \(dismissed.contains(id))")
            if let record {
                #expect(record.meal == intent.meal && record.date == intent.date && record.scannedAt == intent.scannedAt,
                        "seed \(seed): \(id) lost its intent")
            }
        }
        #expect(library.pending.allSatisfy { intents[$0.id] != nil }, "seed \(seed): a pending scan nobody made")
    }
}
