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

    func performAtomically(_ body: () throws -> Void) throws {
        try disk.performAtomically {
            try body()
            if failNextCommit {
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
        let entries = try library.log([NutritionStore.PlateItem(Self.food(code), grams: 40)], consuming: [first.id], to: store,
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
            try library.log(plate, consuming: [scan.id], to: store, on: scan.date, meal: scan.meal)
        }
        #expect(store.entries.isEmpty && library.ready.map(\.id) == [scan.id], "Memory is untouched")
        #expect(try NutritionStore(persistence: disk).entries.isEmpty && BarcodeLibrary(persistence: disk).ready.map(\.id) == [scan.id],
                "So is the disk")
        try library.log(plate, consuming: [scan.id], to: store, on: scan.date, meal: scan.meal)
        #expect(store.entries.count == 1 && library.pending.isEmpty)
        #expect(try NutritionStore(persistence: disk).entries.count == 1 && BarcodeLibrary(persistence: disk).pending.isEmpty)
    }

    @Test func oneTransactionNeedsOneStore() async throws {
        let library = BarcodeLibrary(persistence: InMemoryTrainingPersistence())
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence())
        #expect(throws: BarcodeLibrary.LogError.self) {
            try library.log([NutritionStore.PlateItem(Self.food(Self.codes[0]), grams: 40)], consuming: [], to: store,
                            on: Self.days[0], meal: "Lunch")
        }
        #expect(store.entries.isEmpty)
    }

    /// 1,000 seeded random runs of what the app does with offline scans:
    /// scan offline, resolve, put a scan on the scanner's plate or a meal being
    /// built, cancel its portion, remove its row, log or discard either plate,
    /// log one alone, quit and relaunch, and fail a commit then retry. Every
    /// offline scan ends either still pending with its meal, day and time, or
    /// logged exactly once: never both, never neither.
    @Test func everyOfflineScanEndsPendingOrLoggedExactlyOnce() async throws {
        for seed in 0..<1_000 {
            try await run(seed: UInt64(seed))
        }
    }

    private func run(seed: UInt64) async throws {
        var random = ModelRandom(seed: seed)
        let disk = CommitFailingPersistence()
        let clock = Clock()
        var library = BarcodeLibrary(persistence: disk, now: { clock.now })
        var store = try NutritionStore(persistence: disk, now: { clock.now })
        var intents: [UUID: (meal: String, date: LocalDate, scannedAt: Date)] = [:]
        var logged: [UUID: Int] = [:]
        var entries = 0
        var plates: [[Row]] = [[], []]
        var offline = true
        let missing = Self.codes[5]

        func onAPlate() -> Set<UUID> { Set(plates.flatMap { $0.flatMap(\.pending) }) }
        func readyToAdd() -> [BarcodeLibrary.Pending] { library.ready.filter { !onAPlate().contains($0.id) } }
        func fetch(_ gtin: GTIN) -> BarcodeLibrary.Fetched {
            offline ? .unavailable : gtin == missing ? .missing : .found(Self.food(gtin), attribution: "OFF")
        }
        func relaunch() throws {
            library = BarcodeLibrary(persistence: disk, now: { clock.now })
            store = try NutritionStore(persistence: disk, now: { clock.now })
            plates = [[], []]
        }
        /// Logs, sometimes failing the commit first; after a failure the app may
        /// retry, or be killed before it can.
        func log(_ rows: [Row], date: LocalDate, meal: String) throws -> Bool {
            let items = rows.map { NutritionStore.PlateItem($0.food, grams: 40) }
            let ids = Set(rows.flatMap(\.pending))
            if random.next(4) == 0 {
                let before = (library.pending, store.entries.count)
                disk.failNextCommit = true
                #expect(throws: CommitFailingPersistence.CommitFailed.self) {
                    try library.log(items, consuming: ids, to: store, on: date, meal: meal)
                }
                #expect(library.pending == before.0 && store.entries.count == before.1, "seed \(seed): a failed commit changed memory")
                if random.next(3) == 0 { try relaunch(); return false }
            }
            try library.log(items, consuming: ids, to: store, on: date, meal: meal)
            for id in ids { logged[id, default: 0] += 1 }
            entries += items.count
            return true
        }

        for _ in 0..<40 {
            clock.now += 61
            let plate = random.next(2)
            switch random.next(12) {
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
                guard let scan = random.pick(readyToAdd()), let product = library.usable(scan.gtin) else { continue }
                if let index = plates[plate].firstIndex(where: { $0.food.id == product.food.id }), random.next(2) == 0 {
                    plates[plate][index].pending.insert(scan.id)
                } else {
                    plates[plate].append(Row(food: product.food, pending: [scan.id]))
                }
            case 6:
                // Picked, then cancelled at its portion: nothing joins.
                _ = random.pick(readyToAdd())
            case 7:
                // A food that isn't a scan.
                plates[plate].append(Row(food: Self.food(Self.codes[random.next(5)]), pending: []))
            case 8:
                guard !plates[plate].isEmpty else { continue }
                plates[plate].remove(at: random.next(plates[plate].count))
            case 9:
                guard !plates[plate].isEmpty, let meal = random.pick(Self.meals) else { continue }
                if try log(plates[plate], date: Self.days[0], meal: meal) { plates[plate] = [] }
            case 10:
                if random.next(2) == 0 {
                    plates[plate] = []
                } else if let scan = random.pick(readyToAdd()), let product = library.usable(scan.gtin) {
                    // Logged alone, to the meal and time it was scanned for.
                    _ = try log([Row(food: product.food, pending: [scan.id])], date: scan.date, meal: scan.meal)
                }
            default:
                try relaunch()
            }
        }

        try relaunch()
        for (id, intent) in intents {
            let times = logged[id] ?? 0
            let record = library.pending.first { $0.id == id }
            #expect(times <= 1, "seed \(seed): \(id) logged \(times) times")
            #expect((record != nil) != (times == 1), "seed \(seed): \(id) is pending \(record != nil), logged \(times)")
            if let record {
                #expect(record.meal == intent.meal && record.date == intent.date && record.scannedAt == intent.scannedAt,
                        "seed \(seed): \(id) lost its intent")
            }
        }
        #expect(library.pending.allSatisfy { intents[$0.id] != nil }, "seed \(seed): a pending scan nobody made")
        #expect(store.entries.count == entries, "seed \(seed): \(store.entries.count) entries, expected \(entries)")
    }
}
