import ExerlyCore
import XCTest
@testable import Exerly

/// Answers barcode lookups from a table, and can hold one open until released,
/// as a slow network does.
private final class BarcodeTransport: SessionTransport, @unchecked Sendable {
    private struct Response: Encodable {
        var food: ExerlyCore.Food
        var attribution: String
    }

    private let foods: [String: ExerlyCore.Food]
    private let lock = NSLock()
    private var holding: Set<String>
    private var isOffline = false
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]

    init(foods: [GTIN: ExerlyCore.Food], holding: Set<GTIN> = []) {
        self.foods = Dictionary(uniqueKeysWithValues: foods.map { ($0.key.key, $0.value) })
        self.holding = Set(holding.map(\.key))
    }

    func send(_ method: String, path: String, body: Data?, headers: [String: String],
              as accountID: String) async throws -> (status: Int, data: Data) {
        if lock.withLock({ isOffline }) { throw URLError(.notConnectedToInternet) }
        let key = String(path.split(separator: "/").last?.split(separator: "?").first ?? "")
        let held = lock.withLock { holding.contains(key) }
        if held { await withCheckedContinuation { continuation in lock.withLock { waiting[key] = continuation } } }
        guard let food = foods[key] else { return (404, Data(#"{"message":"No food has that barcode"}"#.utf8)) }
        return (200, try ExerlyJSON.canonical(Response(food: food, attribution: "Synthetic Open Food Facts attribution, ODbL")))
    }

    func release(_ gtin: GTIN) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            holding.remove(gtin.key)
            return waiting.removeValue(forKey: gtin.key)
        }
        continuation?.resume()
    }

    func isWaiting(_ gtin: GTIN) -> Bool { lock.withLock { waiting[gtin.key] != nil } }

    func setOffline(_ offline: Bool) { lock.withLock { isOffline = offline } }
}

@MainActor
final class BarcodeScanSessionTests: XCTestCase {
    private let bar = GTIN("0012345678905")!
    private let juice = GTIN("0049000000450")!
    private let cola = GTIN("0049000000443")!
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("barcode-session-\(UUID().uuidString)")
    }

    private var opened: [TrainingWorkspace] = []

    /// This account's workspace, as a launch opens it; closed before its files go.
    private func openWorkspace() throws -> TrainingWorkspace {
        let workspace = try TrainingWorkspace(accountID: "barcode-account", root: root)
        opened.append(workspace)
        return workspace
    }

    override func tearDown() async throws {
        for workspace in opened { await workspace.close() }
        opened = []
        try? FileManager.default.removeItem(at: root)
    }

    private func food(_ gtin: GTIN, _ name: String) -> ExerlyCore.Food {
        ExerlyCore.Food(id: "off:\(gtin.openFoodFacts)", name: name, source: .openFoodFacts,
                        per100g: NutrientAmounts([.energy: 400]), servings: [Serving("1 pack", grams: 40)])
    }

    private func session(_ transport: BarcodeTransport, workspace existing: TrainingWorkspace? = nil,
                         excluded: @escaping () -> Set<UUID> = { [] }) throws -> (BarcodeScanSession, TrainingWorkspace) {
        let workspace = try existing ?? openWorkspace()
        let api = AccountAPI(accountID: "barcode-account", transport: transport)
        let date = try XCTUnwrap(LocalDate("2026-10-20"))
        return (BarcodeScanSession(workspace: workspace, api: api, date: date, meal: "Lunch", unit: .kilograms, timeZone: .gmt,
                                   excluded: excluded), workspace)
    }

    /// Two foods on the plate, then Log on a past scan: it joins the plate,
    /// nothing is logged alone, and the plate isn't lost.
    func testAPastScanJoinsAPlateThatHasFoods() async throws {
        let transport = BarcodeTransport(foods: [bar: food(bar, "Synthetic oat bar"), juice: food(juice, "Synthetic apple juice"),
                                                 cola: food(cola, "Synthetic cola")])
        let (session, workspace) = try session(transport)
        await session.scanned(ScannedCode(gtin: cola, symbology: .ean13))
        session.plate.remove(try XCTUnwrap(session.plate.rows.first))
        await session.scanned(ScannedCode(gtin: bar, symbology: .ean13))
        await session.scanned(ScannedCode(gtin: juice, symbology: .ean13))
        XCTAssertEqual(session.plate.rows.count, 2)
        let past = try XCTUnwrap(session.pastScans.first { $0.gtin == cola })
        guard case .addedToPlate = session.use(past) else { return XCTFail("A past scan should join the plate") }
        XCTAssertEqual(session.plate.rows.map(\.food.name), ["Synthetic oat bar", "Synthetic apple juice", "Synthetic cola"])
        XCTAssertTrue(workspace.nutrition.entries.isEmpty, "Nothing is logged until the plate is")
        XCTAssertEqual(session.logAll()?.count, 3)
    }

    /// With nothing on the plate, Log on a past scan logs it at once.
    func testAPastScanLogsAloneOnAnEmptyPlate() async throws {
        let (session, workspace) = try session(BarcodeTransport(foods: [bar: food(bar, "Synthetic oat bar")]))
        await session.scanned(ScannedCode(gtin: bar, symbology: .ean13))
        session.plate.remove(try XCTUnwrap(session.plate.rows.first))
        guard case .logged(let entry) = session.use(try XCTUnwrap(session.pastScans.first)) else { return XCTFail("Logs at once") }
        XCTAssertEqual(entry.meal, "Lunch")
        XCTAssertEqual(workspace.nutrition.entries.map(\.food.name), ["Synthetic oat bar"])
    }

    /// Cached A on the plate, then B still being looked up: the plate can't be
    /// logged until B has joined it, so B is never left behind.
    func testThePlateWaitsForAScanStillBeingLookedUp() async throws {
        let transport = BarcodeTransport(foods: [bar: food(bar, "Synthetic oat bar"), juice: food(juice, "Synthetic apple juice")],
                                         holding: [juice])
        let (session, workspace) = try session(transport)
        await session.scanned(ScannedCode(gtin: bar, symbology: .ean13))
        XCTAssertTrue(session.canLog)
        let lookup = Task { await session.scanned(ScannedCode(gtin: juice, symbology: .ean13)) }
        let deadline = Date().addingTimeInterval(5)
        while !transport.isWaiting(juice), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(session.lookingUp, 1)
        XCTAssertFalse(session.canLog)
        XCTAssertNil(session.logAll(), "Log waits for the lookup")
        XCTAssertTrue(workspace.nutrition.entries.isEmpty)
        transport.release(juice)
        await lookup.value
        XCTAssertEqual(session.lookingUp, 0)
        XCTAssertEqual(session.plate.rows.map(\.food.name), ["Synthetic oat bar", "Synthetic apple juice"])
        XCTAssertEqual(session.logAll()?.count, 2)
        XCTAssertEqual(workspace.nutrition.entries.count, 2)
    }

    /// Scanned offline, then found: a ready scan whose food is `gtin`'s.
    private func readyScan(_ gtin: GTIN, _ session: BarcodeScanSession, _ transport: BarcodeTransport) async throws -> BarcodeLibrary.Pending {
        transport.setOffline(true)
        await session.scanned(ScannedCode(gtin: gtin, symbology: .ean13))
        transport.setOffline(false)
        await session.resolveWaiting()
        return try XCTUnwrap(session.library.ready.last { $0.gtin == gtin })
    }

    /// An offline scan added to a plate with another food stays recorded until
    /// the plate logs: discarding the plate, or quitting before logging, keeps
    /// it ready with its meal and time.
    func testAnOfflineScanOnAPlateSurvivesDiscardingIt() async throws {
        let transport = BarcodeTransport(foods: [bar: food(bar, "Synthetic oat bar"), juice: food(juice, "Synthetic apple juice")])
        let workspace = try openWorkspace()
        var session: BarcodeScanSession? = try self.session(transport, workspace: workspace).0
        let ready = try await readyScan(bar, session!, transport)
        await session!.scanned(ScannedCode(gtin: juice, symbology: .ean13))
        guard case .addedToPlate = session!.use(.pending(ready)) else { return XCTFail("Joins the plate with the juice") }
        XCTAssertEqual(session!.plate.rows.count, 2)
        XCTAssertFalse(session!.pastScans.contains(.pending(ready)), "Not offered twice while it's on the plate")
        // Quitting before logging: a fresh launch reads only what's saved.
        let relaunched = try openWorkspace()
        XCTAssertEqual(relaunched.barcodes.ready.map(\.id), [ready.id])
        XCTAssertEqual(relaunched.barcodes.ready.first?.meal, ready.meal)
        // Discarding the plate.
        session!.discard()
        session = nil
        XCTAssertEqual(workspace.barcodes.ready.map(\.id), [ready.id])
        XCTAssertTrue(workspace.nutrition.entries.isEmpty)
    }

    /// The plate logs, and the offline scan on it is consumed with it.
    func testLoggingAPlateConsumesTheOfflineScanOnIt() async throws {
        let transport = BarcodeTransport(foods: [bar: food(bar, "Synthetic oat bar"), juice: food(juice, "Synthetic apple juice")])
        let (session, workspace) = try session(transport)
        let ready = try await readyScan(bar, session, transport)
        await session.scanned(ScannedCode(gtin: juice, symbology: .ean13))
        _ = session.use(.pending(ready))
        XCTAssertEqual(session.logAll()?.count, 2)
        XCTAssertTrue(workspace.barcodes.ready.isEmpty)
        XCTAssertTrue(try openWorkspace().barcodes.ready.isEmpty)
        XCTAssertEqual(workspace.nutrition.entries.count, 2)
    }

    /// A past scan whose food can't join the plate isn't staged or consumed.
    func testAnOfflineScanThatCantJoinThePlateIsKept() async throws {
        var broken = food(cola, "Synthetic broken label")
        broken.per100g = NutrientAmounts([.energy: -5])
        let transport = BarcodeTransport(foods: [cola: broken, juice: food(juice, "Synthetic apple juice")])
        let (session, workspace) = try session(transport)
        let ready = try await readyScan(cola, session, transport)
        await session.scanned(ScannedCode(gtin: juice, symbology: .ean13))
        guard case .failed = session.use(.pending(ready)) else { return XCTFail("It can't join") }
        XCTAssertTrue(session.plate.pending.isEmpty)
        XCTAssertEqual(workspace.barcodes.ready.map(\.id), [ready.id])
    }

    /// An empty plate with a scan still being looked up: a past scan joins and
    /// waits for it, rather than logging alone and leaving the scan behind.
    func testAPastScanWaitsForAnAcceptedLookupOnAnEmptyPlate() async throws {
        let transport = BarcodeTransport(foods: [bar: food(bar, "Synthetic oat bar"), juice: food(juice, "Synthetic apple juice")],
                                         holding: [juice])
        let (session, workspace) = try session(transport)
        await session.scanned(ScannedCode(gtin: bar, symbology: .ean13))
        session.plate.remove(try XCTUnwrap(session.plate.rows.first))
        let lookup = Task { await session.scanned(ScannedCode(gtin: juice, symbology: .ean13)) }
        let deadline = Date().addingTimeInterval(5)
        while !transport.isWaiting(juice), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(session.plate.rows.isEmpty && session.pastScansJoinThePlate)
        guard case .addedToPlate = session.use(try XCTUnwrap(session.pastScans.first { $0.gtin == bar })) else {
            return XCTFail("Joins the plate and waits")
        }
        XCTAssertTrue(workspace.nutrition.entries.isEmpty)
        XCTAssertNil(session.logAll())
        transport.release(juice)
        await lookup.value
        XCTAssertEqual(session.plate.rows.map(\.food.name), ["Synthetic oat bar", "Synthetic apple juice"])
        XCTAssertEqual(session.logAll()?.count, 2)
    }

    /// Two offline scans of one product into a meal being built: the first
    /// joins, the second is cancelled at its portion. Logging the meal
    /// consumes the first only. Adding both and removing one row does the same.
    func testAMealConsumesOnlyTheScansOfTheRowsItLogs() async throws {
        let transport = BarcodeTransport(foods: [bar: food(bar, "Synthetic oat bar")])
        let (scanner, workspace) = try session(transport)
        // Three offline scans of the same bar, before any lookup could answer.
        transport.setOffline(true)
        for _ in 0..<3 { await scanner.scanned(ScannedCode(gtin: bar, symbology: .ean13)) }
        transport.setOffline(false)
        await scanner.resolveWaiting()
        let scans = workspace.barcodes.ready
        XCTAssertEqual(scans.count, 3)
        let (first, second, third) = (scans[0], scans[1], scans[2])
        let library = workspace.barcodes, date = try XCTUnwrap(LocalDate("2026-10-20"))
        let portion = try NutritionStore.preview(food(bar, ""), grams: 40)
        let cancelledOne = NutritionPlateDraft(store: workspace.nutrition, date: date, meal: "Dinner")
        XCTAssertTrue(cancelledOne.stage(food(bar, "Synthetic oat bar"), amount: portion, pending: first.id))
        // The second's portion step is cancelled: it never reaches the draft.
        XCTAssertEqual(cancelledOne.save(consuming: library)?.count, 1)
        XCTAssertEqual(library.ready.map(\.id), [second.id, third.id], "The cancelled scan stays ready")

        let removedOne = NutritionPlateDraft(store: workspace.nutrition, date: date, meal: "Dinner")
        XCTAssertTrue(removedOne.stage(food(bar, "Synthetic oat bar"), amount: portion, pending: second.id))
        XCTAssertTrue(removedOne.stage(food(bar, "Synthetic oat bar"), amount: portion, pending: third.id))
        XCTAssertTrue(removedOne.remove(try XCTUnwrap(removedOne.rows.last)))
        XCTAssertEqual(removedOne.save(consuming: library)?.count, 1)
        XCTAssertEqual(library.ready.map(\.id), [third.id], "The removed row's scan stays ready")
        XCTAssertEqual(try openWorkspace().barcodes.ready.map(\.id), [third.id])
    }

    /// A meal builder's scanner, opened twice: the offline scan picked the
    /// first time isn't offered the second, isn't counted or dismissed as
    /// ready, and can't be staged onto a second row. The meal logs it once.
    func testAScanOnTheMealIsntOfferedToItsScannerAgain() async throws {
        let transport = BarcodeTransport(foods: [bar: food(bar, "Synthetic oat bar")])
        let (first, workspace) = try session(transport)
        let scan = try await readyScan(bar, first, transport)
        let meal = NutritionPlateDraft(store: workspace.nutrition, date: try XCTUnwrap(LocalDate("2026-10-20")), meal: "Dinner")
        // What NutritionPlateView gives its picker.
        let onPickScan = { (food: ExerlyCore.Food, amount: LoggedAmount, pending: UUID) in meal.stage(food, amount: amount, pending: pending) }
        let portion = try NutritionStore.preview(food(bar, ""), grams: 40)
        let (picking, _) = try session(transport, workspace: workspace, excluded: { meal.pending })
        XCTAssertTrue(picking.pastScans.contains(.pending(scan)))
        XCTAssertTrue(onPickScan(food(bar, "Synthetic oat bar"), portion, scan.id))

        let (again, _) = try session(transport, workspace: workspace, excluded: { meal.pending })
        XCTAssertFalse(again.pastScans.contains(.pending(scan)), "The scan on the meal isn't offered again")
        await again.resolveWaiting()
        XCTAssertNil(again.notice, "Nothing else is ready")
        again.dismissReady()
        XCTAssertEqual(workspace.barcodes.ready.map(\.id), [scan.id], "Not needed keeps the scan on the meal")
        XCTAssertFalse(onPickScan(food(bar, "Synthetic oat bar"), portion, scan.id), "A second row can't hold the same scan")
        XCTAssertEqual(meal.rows.count, 1)
        XCTAssertEqual(meal.save(consuming: workspace.barcodes)?.count, 1)
        XCTAssertEqual(workspace.nutrition.entries.count, 1)
        XCTAssertTrue(workspace.barcodes.pending.isEmpty)
    }

    /// Undo after a log made from offline scans, alone from Recent scans or
    /// as a meal, deletes what it logged and puts each scan back with the
    /// meal, day and time it was scanned for, across a relaunch.
    func testUndoPutsBackTheOfflineScansALogConsumed() async throws {
        let transport = BarcodeTransport(foods: [bar: food(bar, "Synthetic oat bar"), juice: food(juice, "Synthetic apple juice")])
        let (scanner, workspace) = try session(transport)
        let alone = try await readyScan(bar, scanner, transport)
        guard case .logged(let entry) = scanner.use(.pending(alone)) else { return XCTFail("Logs alone on an empty plate") }
        XCTAssertTrue(workspace.barcodes.pending.isEmpty)
        XCTAssertEqual(try workspace.barcodes.unlog([entry], from: workspace.nutrition), [entry])
        XCTAssertEqual(workspace.barcodes.pending, [alone], "Back as it was scanned")
        XCTAssertTrue(workspace.nutrition.entries.isEmpty)

        let other = try await readyScan(juice, scanner, transport)
        let meal = NutritionPlateDraft(store: workspace.nutrition, date: try XCTUnwrap(LocalDate("2026-10-21")), meal: "Snacks")
        let portion = try NutritionStore.preview(food(bar, ""), grams: 40)
        XCTAssertTrue(meal.stage(food(bar, "Synthetic oat bar"), amount: portion, pending: alone.id))
        XCTAssertTrue(meal.stage(food(juice, "Synthetic apple juice"), amount: portion, pending: other.id))
        let entries = try XCTUnwrap(meal.save(consuming: workspace.barcodes))
        XCTAssertTrue(workspace.barcodes.pending.isEmpty)
        try workspace.barcodes.unlog(entries, from: workspace.nutrition)
        XCTAssertEqual(Set(workspace.barcodes.pending), [alone, other])
        XCTAssertTrue(workspace.nutrition.entries.isEmpty)
        let relaunched = try openWorkspace()
        // Saved times keep milliseconds, so compare what was meant.
        XCTAssertEqual(Set(relaunched.barcodes.pending.map { [$0.id.uuidString, $0.meal, "\($0.date)"] }),
                       Set([alone, other].map { [$0.id.uuidString, $0.meal, "\($0.date)"] }))
        XCTAssertTrue(relaunched.nutrition.entries.isEmpty)
    }

    /// Two plates hold one offline scan and the first logs it: the second
    /// isn't logged, says which food was already logged, and keeps that food
    /// as a plain food, so logging again adds it once more on purpose.
    func testAPlateWhoseScanWasLoggedElsewhereSaysSo() async throws {
        let transport = BarcodeTransport(foods: [bar: food(bar, "Synthetic oat bar")])
        let (scanner, workspace) = try session(transport)
        let scan = try await readyScan(bar, scanner, transport)
        let date = try XCTUnwrap(LocalDate("2026-10-20")), portion = try NutritionStore.preview(food(bar, ""), grams: 40)
        let (first, second) = (NutritionPlateDraft(store: workspace.nutrition, date: date, meal: "Lunch"),
                               NutritionPlateDraft(store: workspace.nutrition, date: date, meal: "Dinner"))
        for plate in [first, second] { XCTAssertTrue(plate.stage(food(bar, "Synthetic oat bar"), amount: portion, pending: scan.id)) }
        XCTAssertEqual(first.save(consuming: workspace.barcodes)?.count, 1)
        XCTAssertNil(second.save(consuming: workspace.barcodes))
        XCTAssertEqual(second.error?.hasPrefix("Synthetic oat bar was already logged"), true, second.error ?? "no error")
        XCTAssertEqual(workspace.nutrition.entries.count, 1)
        XCTAssertTrue(second.pending.isEmpty && second.rows.count == 1)
        XCTAssertEqual(second.save(consuming: workspace.barcodes)?.count, 1)
        XCTAssertEqual(workspace.nutrition.entries.count, 2)
    }

    /// The commit fails: the draft isn't marked logged and nothing changed, so
    /// trying again writes the entry and consumes the scan, once.
    func testAFailedCommitCanBeRetriedWithoutLosingTheScan() async throws {
        let disk = CommitFailingStore()
        let library = BarcodeLibrary(persistence: disk)
        let store = try NutritionStore(persistence: disk)
        _ = await library.resolve(bar, meal: "Lunch", date: try XCTUnwrap(LocalDate("2026-10-20"))) { _ in .unavailable }
        await library.resolveWaiting { [self] gtin in .found(food(gtin, "Synthetic oat bar"), attribution: "OFF") }
        let scan = try XCTUnwrap(library.ready.first)
        let draft = NutritionPlateDraft(store: store, date: scan.date, meal: scan.meal)
        XCTAssertTrue(draft.stage(food(bar, "Synthetic oat bar"), amount: try NutritionStore.preview(food(bar, ""), grams: 40), pending: scan.id))
        disk.failNextCommit = true
        XCTAssertNil(draft.save(consuming: library))
        XCTAssertTrue(store.entries.isEmpty && library.ready.map(\.id) == [scan.id])
        XCTAssertEqual(draft.save(consuming: library)?.count, 1, "The retry writes it")
        let relaunched = (try NutritionStore(persistence: disk), BarcodeLibrary(persistence: disk))
        XCTAssertEqual(relaunched.0.entries.count, 1)
        XCTAssertTrue(relaunched.1.pending.isEmpty)
    }

    /// Discarded while a lookup still holds the session: the plate's offline
    /// scan is offered again at once, there and in a new scanner.
    func testADiscardedPlateFreesItsScanWhileALookupRuns() async throws {
        let transport = BarcodeTransport(foods: [bar: food(bar, "Synthetic oat bar"), juice: food(juice, "Synthetic apple juice")],
                                         holding: [juice])
        let (session, workspace) = try session(transport)
        let ready = try await readyScan(bar, session, transport)
        let lookup = Task { await session.scanned(ScannedCode(gtin: juice, symbology: .ean13)) }
        let deadline = Date().addingTimeInterval(5)
        while !transport.isWaiting(juice), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard case .addedToPlate = session.use(.pending(ready)) else { return XCTFail("Joins and waits") }
        XCTAssertFalse(session.pastScans.contains(.pending(ready)))
        session.discard()
        XCTAssertTrue(session.pastScans.contains(.pending(ready)))
        let (next, _) = try self.session(transport, workspace: workspace)
        XCTAssertTrue(next.pastScans.contains(.pending(ready)), "Offered in a new scanner while the old lookup still runs")
        transport.release(juice)
        await lookup.value
        XCTAssertEqual(workspace.barcodes.ready.map(\.id), [ready.id])
    }

    /// 1,000 seeded runs of 40 steps through real scanner sessions: the
    /// scanner's plate, and a meal being built that picks only what its own
    /// scanner offers. Scans offline and online, picks and re-picks from a
    /// scanner opened again, cancels at a portion, merges, removes rows, logs
    /// alone or as a plate with commits that fail and are edited and retried,
    /// undoes all or part of a log, says Not needed, removes history,
    /// discards, and relaunches. Every offline scan ends exactly one way:
    /// pending with its meal, day and time, logged once, or dismissed.
    func testRandomPlateHistoriesNeverLoseOrDoubleAScan() async throws {
        for seed in 0..<1_000 { try await randomPlateHistory(seed: UInt64(seed)) }
    }

    private struct ModelLog {
        var entries: [FoodEntry]
        /// The scans each food's rows came from.
        var scans: [String: Set<UUID>]
    }

    private func randomPlateHistory(seed: UInt64) async throws {
        var random = PlateRandom(seed: seed)
        let disk = CommitFailingStore(), clock = PlateClock()
        let transport = BarcodeTransport(foods: [bar: food(bar, "Synthetic oat bar"), juice: food(juice, "Synthetic apple juice"),
                                                 cola: food(cola, "Synthetic cola")])
        let api = AccountAPI(accountID: "barcode-account", transport: transport)
        let date = try XCTUnwrap(LocalDate("2026-10-20"))
        let codes = [bar, juice, cola], meals = ["Breakfast", "Lunch", "Snacks"]
        let portions = [try NutritionStore.preview(food(bar, ""), grams: 40), try NutritionStore.preview(food(bar, ""), grams: 80)]
        var library = BarcodeLibrary(persistence: disk, now: { clock.now })
        var store = try NutritionStore(persistence: disk)
        var intents: [UUID: (meal: String, at: Date)] = [:]
        var logged: [UUID: Int] = [:]
        var dismissed: Set<UUID> = []
        var entries = 0
        var lastLog: ModelLog?
        var offline = true
        func session(excluding excluded: @escaping () -> Set<UUID> = { [] }) -> BarcodeScanSession {
            BarcodeScanSession(library: library, store: store, api: api, date: date, meal: "Lunch", unit: .kilograms, timeZone: .gmt,
                               excluded: excluded)
        }
        var scanner = session()
        var meal = NutritionPlateDraft(store: store, date: date, meal: "Dinner")
        var mealScanner: BarcodeScanSession?
        func relaunch() throws {
            library = BarcodeLibrary(persistence: disk, now: { clock.now })
            store = try NutritionStore(persistence: disk)
            scanner = session()
            meal = NutritionPlateDraft(store: store, date: date, meal: "Dinner")
            mealScanner = nil
            lastLog = nil
        }
        /// The offline scans a scanner offers that can be used now.
        func offered(_ session: BarcodeScanSession) -> [BarcodeLibrary.Pending] {
            session.pastScans.compactMap { past -> BarcodeLibrary.Pending? in
                guard case .pending(let scan) = past, session.library.usable(scan.gtin) != nil else { return nil }
                return scan
            }
        }
        func record(_ rows: [(food: String, pending: Set<UUID>)], _ written: [FoodEntry]) {
            var scans: [String: Set<UUID>] = [:]
            for row in rows {
                for id in row.pending { logged[id, default: 0] += 1 }
                scans[row.food, default: []].formUnion(row.pending)
            }
            entries += written.count
            lastLog = ModelLog(entries: written, scans: scans)
        }
        transport.setOffline(offline)
        for _ in 0..<40 {
            clock.now += 60
            switch random.next(15) {
            case 0, 1:
                // A scan for a meal; offline, it's saved with that meal.
                let chosen = meals[random.next(3)]
                scanner.plate.meal = chosen
                let before = Set(library.pending.map(\.id))
                await scanner.scanned(ScannedCode(gtin: codes[random.next(3)], symbology: .ean13))
                for scan in library.pending where !before.contains(scan.id) { intents[scan.id] = (chosen, clock.now) }
            case 2:
                offline.toggle()
                transport.setOffline(offline)
                if !offline { await scanner.resolveWaiting() }
            case 3, 4:
                // The scanner's Recent scans: joins its plate, or logs alone.
                guard let scan = offered(scanner).randomElement(using: &random), let product = library.usable(scan.gtin) else { continue }
                if !scanner.pastScansJoinThePlate, random.next(4) == 0 {
                    disk.failNextCommit = true
                    guard case .failed = scanner.use(.pending(scan)) else { return XCTFail("seed \(seed): a failed commit logs nothing") }
                    continue
                }
                switch scanner.use(.pending(scan)) {
                case .logged(let entry):
                    XCTAssertEqual(entry.meal, intents[scan.id]?.meal, "seed \(seed)")
                    record([(product.food.id, [scan.id])], [entry])
                case .addedToPlate: break
                case .failed: XCTFail("seed \(seed): a scan the scanner offers can be used")
                }
            case 5, 6:
                // The meal's scanner, sometimes opened again for a re-pick.
                if mealScanner == nil || random.next(3) == 0 {
                    let draft = meal
                    mealScanner = session { draft.pending }
                }
                guard let picker = mealScanner, let scan = offered(picker).randomElement(using: &random),
                      let product = library.usable(scan.gtin) else { continue }
                // Cancelled at its portion step: nothing reaches the meal.
                if random.next(4) == 0 { continue }
                XCTAssertTrue(meal.stage(product.food, amount: portions[random.next(2)], pending: scan.id),
                              "seed \(seed): a scan the meal's scanner offers joins the meal")
            case 7:
                let plate = random.next(2) == 0 ? scanner.plate : meal
                if let row = plate.rows.randomElement(using: &random) { XCTAssertTrue(plate.remove(row)) }
            case 8, 9:
                // Logs either plate; a failed commit is edited, then retried.
                let onScanner = random.next(2) == 0
                let plate = onScanner ? scanner.plate : meal
                guard !plate.rows.isEmpty else { continue }
                if random.next(3) == 0 {
                    disk.failNextCommit = true
                    XCTAssertNil(onScanner ? scanner.logAll() : plate.save(consuming: library), "seed \(seed)")
                    // A scan logged elsewhere stops it before it commits.
                    disk.failNextCommit = false
                    if let row = plate.rows.randomElement(using: &random) {
                        XCTAssertTrue(plate.stage(row.food, amount: portions[random.next(2)], replacing: row))
                    }
                }
                let rows = plate.rows.map { (food: $0.food.id, pending: $0.pending) }
                guard let written = onScanner ? scanner.logAll() : plate.save(consuming: library) else {
                    // Only a scan logged elsewhere stops it; the food stays to log on purpose.
                    XCTAssertEqual(plate.error?.contains("already logged"), true, "seed \(seed): \(plate.error ?? "")")
                    continue
                }
                record(rows, written)
                if onScanner {
                    scanner = session()
                } else {
                    meal = NutritionPlateDraft(store: store, date: date, meal: "Dinner")
                    mealScanner = nil
                }
            case 10:
                // Undo, all of the last log or one food of it, sometimes failing.
                guard var last = lastLog else { continue }
                let foods = Set(last.entries.map(\.food.foodID))
                let only = random.next(2) == 0 ? foods : [foods.randomElement(using: &random)!]
                let undone = last.entries.filter { only.contains($0.food.foodID) }
                if random.next(4) == 0 {
                    disk.failNextCommit = true
                    XCTAssertThrowsError(try library.unlog(undone, from: store), "seed \(seed)")
                    continue
                }
                XCTAssertEqual(try library.unlog(undone, from: store).count, undone.count, "seed \(seed)")
                for food in only { for id in last.scans[food] ?? [] { logged[id, default: 0] -= 1 } }
                entries -= undone.count
                last.entries.removeAll { only.contains($0.food.foodID) }
                for food in only { last.scans[food] = nil }
                lastLog = last.entries.isEmpty ? nil : last
            case 11:
                // Not needed, on either scanner: resolved scans not on its plates go.
                let onMeal = random.next(2) == 0 && mealScanner != nil
                let chosen = onMeal ? mealScanner! : scanner
                let held = chosen.plate.pending.union(onMeal ? meal.pending : [])
                for scan in library.pending where scan.state != .waiting && !held.contains(scan.id) { dismissed.insert(scan.id) }
                chosen.dismissReady()
            case 12:
                // Removed from the history; offline scans of it stay.
                if let scan = library.history.randomElement(using: &random) { library.remove(scan.gtin) }
            case 13:
                if random.next(2) == 0 { scanner.discard() } else { meal.discard() }
            default:
                try relaunch()
            }
        }
        try relaunch()
        for (id, intent) in intents {
            let times = logged[id] ?? 0
            let record = library.pending.first { $0.id == id }
            XCTAssertTrue(times == 0 || times == 1, "seed \(seed): logged \(times) times")
            let ends = [record != nil, times == 1, dismissed.contains(id)].filter { $0 }.count
            XCTAssertEqual(ends, 1, "seed \(seed): pending \(record != nil), logged \(times), dismissed \(dismissed.contains(id))")
            if let record {
                XCTAssertTrue(record.meal == intent.meal && record.date == date && record.scannedAt == intent.at, "seed \(seed)")
            }
        }
        XCTAssertEqual(store.entries.count, entries, "seed \(seed)")
    }

    /// Open Food Facts's licence line goes with its foods; a food the person
    /// entered has none.
    func testDatabaseFoodsCarryTheirAttribution() async throws {
        let (session, _) = try session(BarcodeTransport(foods: [bar: food(bar, "Synthetic oat bar")]))
        await session.scanned(ScannedCode(gtin: bar, symbology: .ean13))
        XCTAssertEqual(session.plateAttributions, ["Synthetic Open Food Facts attribution, ODbL"])
        XCTAssertEqual(session.attributions(for: session.pastScans), ["Synthetic Open Food Facts attribution, ODbL"])
        let mine = ExerlyCore.Food(name: "Synthetic deli salad", per100g: NutrientAmounts([.energy: 150]))
        session.library.remember(mine, for: GTIN("20123451")!, attribution: "Your food")
        session.add(mine)
        XCTAssertEqual(session.plateAttributions, ["Synthetic Open Food Facts attribution, ODbL"])
    }
}

/// Storage whose next transaction fails at its commit and rolls back.
@MainActor
private final class CommitFailingStore: TrainingPersistence, DocumentPersistence {
    struct CommitFailed: Error {}
    let disk = InMemoryTrainingPersistence()
    var failNextCommit = false

    func loadSessions() throws -> [WorkoutSession] { try disk.loadSessions() }
    func loadCustomExercises() throws -> [ExerlyCore.Exercise] { try disk.loadCustomExercises() }
    func save(_ session: WorkoutSession) throws { try disk.save(session) }
    func deleteSession(_ id: UUID) throws { try disk.deleteSession(id) }
    func save(_ exercise: ExerlyCore.Exercise) throws { try disk.save(exercise) }
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

private final class PlateClock { var now = Date(timeIntervalSinceReferenceDate: 810_000_000) }

private struct PlateRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0xC0FFEE }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
}
