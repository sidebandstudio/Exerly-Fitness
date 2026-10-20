import Foundation
import Observation

/// Every barcode this account has resolved, the scans behind them, and scans
/// made offline that still wait for the database. Kept on this device only,
/// in the account's own store, so a re-scan works offline and instantly and
/// nothing scanned offline is lost. See docs/BARCODE.md.
@MainActor
@Observable
public final class BarcodeLibrary {
    /// A product the database returned for a code.
    public struct Product: Codable, Hashable, Sendable {
        public var gtin: GTIN
        public var food: Food
        public var attribution: String
        public var resolvedAt: Date

        public init(gtin: GTIN, food: Food, attribution: String, resolvedAt: Date) {
            self.gtin = gtin
            self.food = food
            self.attribution = attribution
            self.resolvedAt = resolvedAt
        }
    }

    /// The latest scan of one code.
    public struct Scan: Codable, Hashable, Sendable, Identifiable {
        public enum State: String, Codable, Sendable {
            case found
            case missing
            /// Scanned offline before the code was cached: it resolves once the
            /// database is reachable.
            case waiting
        }

        public var id: GTIN { gtin }
        public var gtin: GTIN
        public var scannedAt: Date
        public var state: State
        /// Where a scan made offline is meant to be logged.
        public var meal: String
        public var date: LocalDate
        /// Resolved from the offline queue and not yet logged or dismissed.
        public var ready: Bool

        public init(gtin: GTIN, scannedAt: Date, state: State, meal: String, date: LocalDate, ready: Bool = false) {
            self.gtin = gtin
            self.scannedAt = scannedAt
            self.state = state
            self.meal = meal
            self.date = date
            self.ready = ready
        }
    }

    /// What the food database said about a code.
    public enum Fetched: Sendable {
        case found(Food, attribution: String)
        case missing
        /// Offline, the server down or busy: try again later.
        case unavailable
    }

    public typealias Fetch = @MainActor (GTIN) async -> Fetched

    public enum Outcome: Hashable, Sendable {
        case found(Product, cached: Bool)
        case missing
        /// Saved to look up once the database is reachable.
        case queued
        /// A code no database can know, such as an in-store weighed label.
        case notProduct(GTIN.Kind)
    }

    public static let historyLimit = 60
    public static let productLimit = 500
    /// A cached product older than this is fetched again in the background.
    public static let refreshAge: TimeInterval = 30 * 24 * 3600
    static let key = "barcode_library.v1"

    /// Latest first, one per code.
    public private(set) var history: [Scan] = []
    public private(set) var products: [GTIN: Product] = [:]
    public private(set) var error: String?

    @ObservationIgnored private let persistence: TrainingPersistence
    @ObservationIgnored private let now: () -> Date

    public init(persistence: TrainingPersistence, now: @escaping () -> Date = Date.init) {
        self.persistence = persistence
        self.now = now
        if let data = try? persistence.loadValue(forKey: Self.key),
           let saved = try? ExerlyJSON.decoder.decode(Saved.self, from: data) {
            history = saved.history
            products = Dictionary(saved.products.map { ($0.gtin, $0) }, uniquingKeysWith: { a, b in a.resolvedAt > b.resolvedAt ? a : b })
        }
    }

    /// Scans still waiting for the database, oldest first.
    public var waiting: [Scan] { history.filter { $0.state == .waiting }.reversed() }
    /// Scans resolved from the queue that the person hasn't acted on.
    public var ready: [Scan] { history.filter(\.ready) }

    public func product(_ gtin: GTIN) -> Product? { products[gtin] }

    public func isStale(_ product: Product) -> Bool { now().timeIntervalSince(product.resolvedAt) > Self.refreshAge }

    /// The food for a scanned code: from this device when it's been resolved
    /// before, else from the database. Unreachable, it's queued.
    public func resolve(_ gtin: GTIN, meal: String, date: LocalDate, fetch: Fetch) async -> Outcome {
        guard gtin.isProduct else { return .notProduct(gtin.kind) }
        let time = now()
        if let product = products[gtin] {
            record(Scan(gtin: gtin, scannedAt: time, state: .found, meal: meal, date: date))
            return .found(product, cached: true)
        }
        switch await fetch(gtin) {
        case .found(let food, let attribution):
            let product = Product(gtin: gtin, food: food, attribution: attribution, resolvedAt: now())
            products[gtin] = product
            record(Scan(gtin: gtin, scannedAt: time, state: .found, meal: meal, date: date))
            return .found(product, cached: false)
        case .missing:
            record(Scan(gtin: gtin, scannedAt: time, state: .missing, meal: meal, date: date))
            return .missing
        case .unavailable:
            record(Scan(gtin: gtin, scannedAt: time, state: .waiting, meal: meal, date: date))
            return .queued
        }
    }

    /// Looks up every waiting scan, oldest first, stopping at the first the
    /// database can't answer. Returns the scans that resolved.
    @discardableResult
    public func resolveWaiting(fetch: Fetch) async -> [Scan] {
        var resolved: [Scan] = []
        for scan in waiting {
            let fetched = await fetch(scan.gtin)
            // The person may have scanned or dismissed it meanwhile.
            guard let index = history.firstIndex(where: { $0.gtin == scan.gtin && $0.state == .waiting }) else { continue }
            switch fetched {
            case .found(let food, let attribution):
                products[scan.gtin] = Product(gtin: scan.gtin, food: food, attribution: attribution, resolvedAt: now())
                history[index].state = .found
            case .missing:
                history[index].state = .missing
            case .unavailable:
                save()
                return resolved
            }
            history[index].ready = true
            resolved.append(history[index])
        }
        if !resolved.isEmpty { save() }
        return resolved
    }

    /// Fetches a cached product again, keeping the cached one when the
    /// database is unreachable or has dropped it.
    public func refresh(_ gtin: GTIN, fetch: Fetch) async {
        guard products[gtin] != nil, case .found(let food, let attribution) = await fetch(gtin) else { return }
        products[gtin] = Product(gtin: gtin, food: food, attribution: attribution, resolvedAt: now())
        save()
    }

    /// A food the person entered for a code the database didn't know: the
    /// code finds it from now on, on this device.
    public func remember(_ food: Food, for gtin: GTIN, attribution: String, meal: String, date: LocalDate) {
        products[gtin] = Product(gtin: gtin, food: food, attribution: attribution, resolvedAt: now())
        let scannedAt = history.first { $0.gtin == gtin }?.scannedAt ?? now()
        record(Scan(gtin: gtin, scannedAt: scannedAt, state: .found, meal: meal, date: date))
    }

    /// The person logged or dismissed a scan resolved from the queue.
    public func acknowledge(_ gtin: GTIN) {
        guard let index = history.firstIndex(where: { $0.gtin == gtin }), history[index].ready else { return }
        history[index].ready = false
        save()
    }

    /// Removes a scan from the history; its cached product stays.
    public func remove(_ gtin: GTIN) {
        history.removeAll { $0.gtin == gtin }
        save()
    }

    // MARK: Storage

    private struct Saved: Codable {
        var history: [Scan]
        var products: [Product]
    }

    private func record(_ scan: Scan) {
        history = [scan] + history.filter { $0.gtin != scan.gtin }
        if history.count > Self.historyLimit {
            // Never drop a scan still waiting for the database.
            let keep = history.prefix(Self.historyLimit)
            history = Array(keep) + history.dropFirst(Self.historyLimit).filter { $0.state == .waiting }
        }
        save()
    }

    private func save() {
        if products.count > Self.productLimit {
            let inHistory = Set(history.map(\.gtin))
            let dropped = products.values.filter { !inHistory.contains($0.gtin) }.sorted { $0.resolvedAt < $1.resolvedAt }
                .prefix(products.count - Self.productLimit)
            for product in dropped { products[product.gtin] = nil }
        }
        let saved = Saved(history: history, products: products.values.sorted { $0.gtin < $1.gtin })
        do {
            try persistence.saveValue(try ExerlyJSON.canonical(saved), forKey: Self.key)
            error = nil
        } catch {
            self.error = "Couldn't save your scan history on this device."
        }
    }
}
