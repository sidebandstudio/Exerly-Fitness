import Combine
import ExerlyCore
import SwiftUI

extension BarcodeLibrary {
    /// Asks the server for a code by its canonical key. A refusal or a miss
    /// is missing; anything else, offline included, is worth trying again.
    static func fetch(_ api: AccountAPI) -> Fetch {
        { gtin in
            do {
                guard let found = try await api.food(barcode: gtin.key, symbology: .gtin14), let food = found.foods.first else { return .missing }
                return .found(food, attribution: found.attribution)
            } catch ExerlyCore.APIError.server(let status, _) where status == 400 || status == 404 {
                return .missing
            } catch {
                return .unavailable
            }
        }
    }

    /// Deletes entries as they were logged, leaving alone any changed since,
    /// and puts the offline scans they came from back where they were meant
    /// to be logged. Returns those it deleted.
    @discardableResult
    func unlog(_ entries: [FoodEntry], from store: NutritionStore) throws -> [FoodEntry] {
        let current = entries.filter { entry in store.entries.first { $0.id == entry.id } == entry }
        let ids = Set(current.map(\.id))
        if let scans = recentLog(writing: ids) {
            try undo(scans, only: ids, from: store)
        } else {
            for entry in current { try store.deleteEntry(entry.id) }
        }
        return current
    }
}

/// One visit to the scanner: codes it accepts, what each turned out to be,
/// and the plate they build. Several scans in a row land on one plate,
/// which logs in one tap.
@MainActor
final class BarcodeScanSession: ObservableObject {
    /// What the last scan came to, shown under the viewfinder.
    enum Notice: Equatable {
        case added(name: String)
        /// The same pack again: its count went up.
        case again(name: String)
        case looking(GTIN)
        /// Offline and never seen: saved to look up later.
        case queued(GTIN)
        case missing(GTIN)
        case notProduct(GTIN, GTIN.Kind)
        /// Scans saved offline that have resolved.
        case ready(Int)
    }

    @Published private(set) var notice: Notice?
    /// Accepted codes still being looked up. The plate can't be logged until
    /// they've settled, so none is left behind.
    @Published private(set) var lookingUp = 0
    /// Counts that drive haptics.
    @Published private(set) var successes = 0
    @Published private(set) var warnings = 0
    let plate: NutritionPlateDraft
    let library: BarcodeLibrary
    private let api: AccountAPI
    private let store: NutritionStore
    /// Offline scans already on the meal this scanner adds to.
    private let excluded: () -> Set<UUID>
    private var plateChanges: AnyCancellable?

    init(workspace: TrainingWorkspace, api: AccountAPI, date: LocalDate, meal: String, unit: MassUnit, timeZone: TimeZone,
         excluded: @escaping () -> Set<UUID> = { [] }) {
        self.api = api
        self.excluded = excluded
        store = workspace.nutrition
        library = workspace.barcodes
        plate = NutritionPlateDraft(store: workspace.nutrition, date: date, meal: meal, unit: unit, timeZone: timeZone)
        // The tray redraws as the plate changes.
        plateChanges = plate.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var unit: MassUnit { plate.unit }

    // MARK: Scanning

    /// The food for a code, or nil after saying why there isn't one. A
    /// store's own code finds only a food the person entered for it.
    func food(for gtin: GTIN) async -> ExerlyCore.Food? {
        guard gtin.isProduct || library.usable(gtin) != nil else {
            show(.notProduct(gtin, gtin.kind), warning: true)
            return nil
        }
        notice = .looking(gtin)
        lookingUp += 1
        defer { lookingUp -= 1 }
        switch await library.resolve(gtin, meal: plate.meal, date: plate.date, fetch: BarcodeLibrary.fetch(api)) {
        case .found(let product, let cached):
            if cached, library.isStale(product) { Task { await library.refresh(product.gtin, fetch: BarcodeLibrary.fetch(api)) } }
            return product.food
        case .missing: show(.missing(gtin), warning: true)
        case .queued: show(.queued(gtin), warning: true)
        case .notProduct(let kind): show(.notProduct(gtin, kind), warning: true)
        }
        return nil
    }

    /// A code the camera accepted: a found food joins the plate.
    func scanned(_ code: ScannedCode) async {
        if let food = await food(for: code.gtin) { add(food) }
    }

    enum TypedLookup {
        case food(ExerlyCore.Food)
        /// A valid code with no food; the notice says why.
        case noFood
        /// Digits that can't be a barcode.
        case invalid
    }

    /// Digits typed under a barcode. A form already resolved wins; else each
    /// format they could be is tried, and the first the database knows wins.
    func lookUp(typed text: String) async -> TypedLookup {
        let candidates = GTIN.candidates(typed: text)
        guard let last = candidates.last else { return .invalid }
        if let cached = candidates.first(where: { library.usable($0) != nil }) {
            return await food(for: cached).map(TypedLookup.food) ?? .noFood
        }
        for gtin in candidates.dropLast() where gtin.isProduct {
            notice = .looking(gtin)
            lookingUp += 1
            let outcome = await library.resolve(gtin, meal: plate.meal, date: plate.date, fetch: BarcodeLibrary.fetch(api))
            lookingUp -= 1
            switch outcome {
            case .found(let product, _): return .food(product.food)
            case .missing: library.remove(gtin)
            case .queued: show(.queued(gtin), warning: true); return .noFood
            case .notProduct: break
            }
        }
        return await food(for: last).map(TypedLookup.food) ?? .noFood
    }

    /// Adds a food at the amount the person logs it at, or its default; the
    /// same food again adds one more of it. `pending` is the offline scan it
    /// came from, carried by the row it joins. False when it couldn't join.
    @discardableResult
    func add(_ food: ExerlyCore.Food, pending: UUID? = nil) -> Bool {
        if let row = plate.rows.first(where: { $0.food.id == food.id }), let more = usualAmount(of: food),
           let total = try? ScanTrayAmount.adding(more, to: row.amount, of: food),
           plate.stage(food, amount: total, replacing: row, pending: pending) {
            show(.again(name: food.name))
            return true
        } else if plate.add(food, pending: pending) {
            show(.added(name: food.name))
            return true
        }
        show(nil, warning: true)
        return false
    }

    /// The row with one usual portion more or fewer: one bar, one 100 ml.
    func stepped(_ row: NutritionPlateDraft.Row, more: Bool) -> LoggedAmount? {
        guard let portion = usualAmount(of: row.food) else { return nil }
        return ScanTrayAmount.stepping(row.amount, by: portion, of: row.food, more: more)
    }

    func step(_ row: NutritionPlateDraft.Row, more: Bool) {
        guard let amount = stepped(row, more: more) else { return }
        plate.stage(row.food, amount: amount, replacing: row)
        UIAccessibility.post(notification: .announcement, argument: "\(row.food.name), \(portion(of: plate.rows.first { $0.id == row.id } ?? row))")
    }

    func portion(of row: NutritionPlateDraft.Row) -> String {
        NutritionFormat.portion(row.entry(on: plate.date, meal: plate.meal, at: plate.loggedAt), unit: unit)
    }

    /// The licence line for a food from a database, such as Open Food Facts's.
    func attribution(for food: ExerlyCore.Food) -> String? {
        library.products.values.first { $0.food.id == food.id && !$0.own }?.attribution
    }

    /// The licence lines for the foods on the plate.
    var plateAttributions: [String] {
        var lines: [String] = []
        for row in plate.rows { if let line = attribution(for: row.food), !lines.contains(line) { lines.append(line) } }
        return lines
    }

    /// The licence lines for the past scans shown.
    func attributions(for scans: [PastScan]) -> [String] {
        var lines: [String] = []
        for scan in scans {
            if let product = library.usable(scan.gtin), !product.own, !lines.contains(product.attribution) { lines.append(product.attribution) }
        }
        return lines
    }

    /// What one tap logs for a food from Recent scans.
    func usualPortion(of food: ExerlyCore.Food) -> QuickPortion? { store.quickPortion(for: food, unit: unit) }

    private func usualAmount(of food: ExerlyCore.Food) -> LoggedAmount? {
        guard let portion = store.quickPortion(for: food, unit: unit) else { return nil }
        return try? NutritionStore.preview(food, grams: portion.grams, serving: portion.serving, quantity: portion.quantity)
    }

    private func show(_ notice: Notice?, warning: Bool = false) {
        self.notice = notice
        if warning { warnings += 1 } else { successes += 1 }
        guard let notice else { return }
        UIAccessibility.post(notification: .announcement, argument: Self.announcement(notice, foods: plate.rows.count))
    }

    static func announcement(_ notice: Notice, foods: Int) -> String {
        let plate = "\(foods) \(foods == 1 ? "food" : "foods") to log."
        switch notice {
        case .added(let name): return "Found \(name). \(plate)"
        case .again(let name): return "Another \(name). \(plate)"
        case .looking: return "Looking it up."
        case .queued(let gtin): return "You're offline. Barcode \(gtin.display) is saved and will be looked up when you're back online."
        case .missing(let gtin): return "Barcode \(gtin.display) isn't in the food database. Search for it or enter it yourself."
        case .notProduct(_, let kind): return BarcodeNoticeCopy.title(kind)
        case .ready(let count): return "\(count) \(count == 1 ? "scan" : "scans") saved offline \(count == 1 ? "is" : "are") ready to log."
        }
    }

    func dismissNotice() { notice = nil }

    // MARK: Logging

    /// The plate logs once every accepted scan has been looked up.
    var canLog: Bool { lookingUp == 0 && !plate.rows.isEmpty }

    /// Logs the plate, consuming the offline scans its rows came from.
    func logAll() -> [FoodEntry]? {
        guard lookingUp == 0 else { return nil }
        return plate.save(consuming: library)
    }

    /// The person discarded the plate: its offline scans are free at once,
    /// whatever lookup is still running.
    func discard() {
        plate.discard()
        notice = nil
    }

    /// A past scan, as Recent scans and the history list it.
    enum PastScan: Identifiable, Equatable {
        /// Made offline, with where it was meant to be logged.
        case pending(BarcodeLibrary.Pending)
        case scan(BarcodeLibrary.Scan)

        var id: String {
            switch self {
            case .pending(let scan): "pending-\(scan.id.uuidString)"
            case .scan(let scan): "scan-\(scan.gtin.key)"
            }
        }

        var gtin: GTIN {
            switch self {
            case .pending(let scan): scan.gtin
            case .scan(let scan): scan.gtin
            }
        }
    }

    /// Offline scans ready to log first, then those waiting or not found,
    /// then every other code scanned, latest first.
    var pastScans: [PastScan] {
        // A scan already on this plate, or on the meal it adds to, isn't
        // offered again while it's there.
        let held = held
        let offline = (library.ready + library.waiting + library.pending.filter { $0.state == .missing })
            .filter { !held.contains($0.id) }
        let codes = Set(library.pending.map(\.gtin))
        return offline.map(PastScan.pending) + library.history.filter { !codes.contains($0.gtin) }.map(PastScan.scan)
    }

    /// Offline scans on this plate or on the meal it adds to.
    private var held: Set<UUID> { plate.pending.union(excluded()) }

    enum PastScanResult {
        case logged(FoodEntry)
        case addedToPlate
        case failed
    }

    /// Whether a past scan joins the plate rather than logging alone: with
    /// foods on it, or a scan still being looked up that will join it.
    var pastScansJoinThePlate: Bool { !plate.rows.isEmpty || lookingUp > 0 }

    /// One tap on a past scan. With foods on the plate, or one on its way, it
    /// joins them, so nothing is left behind; an offline scan joining is kept
    /// until the plate logs. Otherwise it logs at once, an offline scan to the
    /// meal, day and time it was scanned for, and is consumed with that entry.
    func use(_ past: PastScan) -> PastScanResult {
        guard let product = library.usable(past.gtin) else { return .failed }
        if pastScansJoinThePlate {
            var pending: UUID?
            if case .pending(let scan) = past { pending = scan.id }
            return add(product.food, pending: pending) ? .addedToPlate : .failed
        }
        guard let portion = store.quickPortion(for: product.food, unit: unit) else { return .failed }
        do {
            let entry: FoodEntry
            if case .pending(let scan) = past {
                let item = NutritionStore.PlateItem(product.food, grams: portion.grams, serving: portion.serving, quantity: portion.quantity)
                guard let logged = try library.log([item], consuming: [scan.id], to: store, on: scan.date, meal: scan.meal,
                                                   at: scan.scannedAt).entries.first else { return .failed }
                entry = logged
            } else {
                entry = try store.log(portion, on: plate.date, meal: plate.meal)
            }
            return .logged(entry)
        } catch {
            show(nil, warning: true)
            return .failed
        }
    }

    /// Looks up scans saved offline, and says when some are ready, whether
    /// they resolved now or in a sync before the scanner opened.
    func resolveWaiting() async {
        if !library.waiting.isEmpty { await library.resolveWaiting(fetch: BarcodeLibrary.fetch(api)) }
        let ready = library.ready.filter { !held.contains($0.id) }.count
        if ready > 0, notice == nil { show(.ready(ready)) }
    }

    /// The person doesn't need the offline scans that resolved, except those
    /// already on a plate.
    func dismissReady() {
        library.dismissResolved(keeping: held)
        notice = nil
    }
}

/// Words for codes that aren't products.
enum BarcodeNoticeCopy {
    static func title(_ kind: GTIN.Kind) -> String {
        switch kind {
        case .variableMeasure: "This is a store's own label"
        case .storeInternal: "This code only works in its store"
        case .coupon: "This is a coupon"
        case .publication: "This is a book or magazine"
        case .product: "Not in the food database yet"
        }
    }

    static func detail(_ kind: GTIN.Kind) -> String {
        switch kind {
        case .variableMeasure:
            "Weighed and priced items carry the store's price or weight, not the product, so no database knows them. Search for the food instead."
        case .storeInternal:
            "The store numbered this itself, and another store may use the same number for something else, so it isn't looked up. Enter the food once and this code finds it on your phone."
        case .coupon: "Scan the barcode on the food's own package instead."
        case .publication: "Scan the barcode on a food package instead."
        case .product: "Search for it with the code below, or enter it from the label."
        }
    }
}
