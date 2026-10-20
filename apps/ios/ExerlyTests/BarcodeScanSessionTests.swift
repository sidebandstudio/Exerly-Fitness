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

    private func session(_ transport: BarcodeTransport, workspace existing: TrainingWorkspace? = nil) throws -> (BarcodeScanSession, TrainingWorkspace) {
        let workspace = try existing ?? openWorkspace()
        let api = AccountAPI(accountID: "barcode-account", transport: transport)
        let date = try XCTUnwrap(LocalDate("2026-10-20"))
        return (BarcodeScanSession(workspace: workspace, api: api, date: date, meal: "Lunch", unit: .kilograms, timeZone: .gmt), workspace)
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

    private func settle() async throws { try await Task.sleep(for: .milliseconds(50)) }

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
        session = nil
        try await settle()
        XCTAssertTrue(workspace.barcodes.staged.isEmpty)
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
        XCTAssertTrue(workspace.barcodes.ready.isEmpty && workspace.barcodes.staged.isEmpty)
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
        XCTAssertTrue(workspace.barcodes.staged.isEmpty)
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

    /// An offline scan picked into a meal being built is consumed when that
    /// meal logs, and kept if the meal is cancelled or the food left out.
    func testAMealBuiltWithAnOfflineScanConsumesItOnlyWhenItLogs() async throws {
        let transport = BarcodeTransport(foods: [bar: food(bar, "Synthetic oat bar"), juice: food(juice, "Synthetic apple juice")])
        let (scanner, workspace) = try session(transport)
        let first = try await readyScan(bar, scanner, transport)
        let second = try await readyScan(juice, scanner, transport)
        let library = workspace.barcodes
        let date = try XCTUnwrap(LocalDate("2026-10-20"))
        // Cancelled: the meal goes away unlogged.
        var cancelled: BarcodeStaging? = BarcodeStaging(library: library)
        library.stage(first.id, scope: cancelled!.scope, foodID: food(bar, "").id)
        cancelled = nil
        try await settle()
        XCTAssertEqual(Set(library.ready.map(\.id)), [first.id, second.id])
        // Logged with the bar; the juice was picked, then left out at its portion.
        let meal = BarcodeStaging(library: library)
        library.stage(first.id, scope: meal.scope, foodID: food(bar, "").id)
        library.stage(second.id, scope: meal.scope, foodID: food(juice, "").id)
        let draft = NutritionPlateDraft(store: workspace.nutrition, date: date, meal: "Dinner")
        XCTAssertTrue(draft.add(food(bar, "Synthetic oat bar")))
        XCTAssertEqual(draft.save(consuming: library, scope: meal.scope)?.count, 1)
        XCTAssertEqual(library.ready.map(\.id), [second.id], "Only the scan logged with the meal is consumed")
        XCTAssertTrue(library.staged.isEmpty)
        XCTAssertEqual(try openWorkspace().barcodes.ready.map(\.id), [second.id])
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
