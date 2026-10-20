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
    /// Counts that drive haptics.
    @Published private(set) var successes = 0
    @Published private(set) var warnings = 0
    let plate: NutritionPlateDraft
    let library: BarcodeLibrary
    private let api: AccountAPI
    private let store: NutritionStore
    private var plateChanges: AnyCancellable?

    init(workspace: TrainingWorkspace, api: AccountAPI, date: LocalDate, meal: String, unit: MassUnit, timeZone: TimeZone) {
        self.api = api
        store = workspace.nutrition
        library = workspace.barcodes
        plate = NutritionPlateDraft(store: workspace.nutrition, date: date, meal: meal, unit: unit, timeZone: timeZone)
        // The tray redraws as the plate changes.
        plateChanges = plate.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var unit: MassUnit { plate.unit }

    // MARK: Scanning

    /// The food for a code, or nil after saying why there isn't one.
    func food(for gtin: GTIN) async -> ExerlyCore.Food? {
        guard gtin.isProduct else {
            show(.notProduct(gtin, gtin.kind), warning: true)
            return nil
        }
        notice = .looking(gtin)
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
        if let cached = candidates.first(where: { library.product($0) != nil }) {
            return await food(for: cached).map(TypedLookup.food) ?? .noFood
        }
        for gtin in candidates.dropLast() where gtin.isProduct {
            notice = .looking(gtin)
            switch await library.resolve(gtin, meal: plate.meal, date: plate.date, fetch: BarcodeLibrary.fetch(api)) {
            case .found(let product, _): return .food(product.food)
            case .missing: library.remove(gtin)
            case .queued: show(.queued(gtin), warning: true); return .noFood
            case .notProduct: break
            }
        }
        return await food(for: last).map(TypedLookup.food) ?? .noFood
    }

    /// Adds a food at the amount the person logs it at, or its default; the
    /// same food again adds one more of it.
    func add(_ food: ExerlyCore.Food) {
        if let row = plate.rows.first(where: { $0.food.id == food.id }), let more = usualAmount(of: food),
           let total = try? ScanTrayAmount.adding(more, to: row.amount, of: food), plate.stage(food, amount: total, replacing: row) {
            show(.again(name: food.name))
        } else if plate.add(food) {
            show(.added(name: food.name))
        } else {
            show(nil, warning: true)
        }
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

    func logAll() -> [FoodEntry]? {
        plate.save()
    }

    /// Logs a past scan again in one tap, at the amount usually logged. A
    /// scan made offline logs to the meal and time it was scanned for.
    func relog(_ scan: BarcodeLibrary.Scan) -> FoodEntry? {
        guard let product = library.product(scan.gtin), let portion = store.quickPortion(for: product.food, unit: unit) else { return nil }
        do {
            let entry = scan.ready
                ? try store.log(portion, on: scan.date, meal: scan.meal, at: scan.scannedAt)
                : try store.log(portion, on: plate.date, meal: plate.meal)
            library.acknowledge(scan.gtin)
            return entry
        } catch {
            show(nil, warning: true)
            return nil
        }
    }

    /// Looks up scans saved offline, and says when some are ready, whether
    /// they resolved now or in a sync before the scanner opened.
    func resolveWaiting() async {
        if !library.waiting.isEmpty { await library.resolveWaiting(fetch: BarcodeLibrary.fetch(api)) }
        if !library.ready.isEmpty, notice == nil { show(.ready(library.ready.count)) }
    }

    /// The person doesn't need the scans that resolved: they stay in the history.
    func dismissReady() {
        for scan in library.ready { library.acknowledge(scan.gtin) }
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
        case .storeInternal: "The store made this number up for itself, so no food database knows it. Search for the food instead."
        case .coupon: "Scan the barcode on the food's own package instead."
        case .publication: "Scan the barcode on a food package instead."
        case .product: "Search for it with the code below, or enter it from the label."
        }
    }
}
