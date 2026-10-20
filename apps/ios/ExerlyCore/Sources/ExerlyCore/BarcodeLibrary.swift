import Foundation
import Observation

/// Every barcode this account has resolved, the scans behind them, and scans
/// made offline that still wait for the database. Kept on this device only,
/// in the account's own store, so a re-scan works offline and instantly and
/// nothing scanned offline is lost. See docs/BARCODE.md.
@MainActor
@Observable
public final class BarcodeLibrary {
    /// A product the database returned for a code, or a food the person
    /// entered for it.
    public struct Product: Codable, Hashable, Sendable {
        public var gtin: GTIN
        public var food: Food
        public var attribution: String
        public var resolvedAt: Date
        /// The person entered it on this account, so it's theirs alone: it
        /// answers even a store's own code, which no database may.
        public var own: Bool

        public init(gtin: GTIN, food: Food, attribution: String, resolvedAt: Date, own: Bool = false) {
            self.gtin = gtin
            self.food = food
            self.attribution = attribution
            self.resolvedAt = resolvedAt
            self.own = own
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            gtin = try container.decode(GTIN.self, forKey: .gtin)
            food = try container.decode(Food.self, forKey: .food)
            attribution = try container.decode(String.self, forKey: .attribution)
            resolvedAt = try container.decode(Date.self, forKey: .resolvedAt)
            own = try container.decodeIfPresent(Bool.self, forKey: .own) ?? false
        }
    }

    /// The latest scan of one code, for the history.
    public struct Scan: Codable, Hashable, Sendable, Identifiable {
        public enum State: String, Codable, Sendable {
            case found
            case missing
            /// Scanned offline before the code was cached.
            case waiting
        }

        public var id: GTIN { gtin }
        public var gtin: GTIN
        public var scannedAt: Date
        public var state: State

        public init(gtin: GTIN, scannedAt: Date, state: State) {
            self.gtin = gtin
            self.scannedAt = scannedAt
            self.state = state
        }
    }

    /// One scan made offline, before its code was cached, with where it was
    /// meant to be logged. Each is kept, apart from the history, until it's
    /// logged or dismissed: scanning the same code again never replaces it.
    public struct Pending: Codable, Hashable, Sendable, Identifiable {
        public enum State: String, Codable, Sendable {
            /// Waiting for the database.
            case waiting
            /// Found since: ready to log.
            case ready
            /// The database doesn't know it.
            case missing
        }

        public var id: UUID
        public var gtin: GTIN
        public var scannedAt: Date
        public var meal: String
        public var date: LocalDate
        public var state: State

        public init(id: UUID = UUID(), gtin: GTIN, scannedAt: Date, meal: String, date: LocalDate, state: State = .waiting) {
            self.id = id
            self.gtin = gtin
            self.scannedAt = scannedAt
            self.meal = meal
            self.date = date
            self.state = state
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
    /// Scans made offline, oldest first.
    public private(set) var pending: [Pending] = []
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
            pending = saved.pending ?? []
            products = Dictionary(saved.products.map { ($0.gtin, $0) }, uniquingKeysWith: { a, b in a.resolvedAt > b.resolvedAt ? a : b })
        }
    }

    /// Offline scans still waiting for the database, oldest first.
    public var waiting: [Pending] { pending.filter { $0.state == .waiting } }
    /// Offline scans found since, to log.
    public var ready: [Pending] { pending.filter { $0.state == .ready } }
    /// Offline scans that resolved, found or not, which the person hasn't acted on.
    public var resolved: [Pending] { pending.filter { $0.state != .waiting } }

    public func product(_ gtin: GTIN) -> Product? { products[gtin] }

    /// The cached product a scan may use: any for a product code, and only
    /// the person's own food for a code a store issued for itself.
    public func usable(_ gtin: GTIN) -> Product? {
        guard let product = products[gtin], gtin.isProduct || product.own else { return nil }
        return product
    }

    public func isStale(_ product: Product) -> Bool { !product.own && now().timeIntervalSince(product.resolvedAt) > Self.refreshAge }

    /// The food for a scanned code: from this device when it's been resolved
    /// before, else from the database. Unreachable, it's kept to look up
    /// later with where it was meant to be logged.
    public func resolve(_ gtin: GTIN, meal: String, date: LocalDate, fetch: Fetch) async -> Outcome {
        let time = now()
        if let product = usable(gtin) {
            record(Scan(gtin: gtin, scannedAt: time, state: .found))
            return .found(product, cached: true)
        }
        guard gtin.isProduct else { return .notProduct(gtin.kind) }
        switch await fetch(gtin) {
        case .found(let food, let attribution):
            let product = Product(gtin: gtin, food: food, attribution: attribution, resolvedAt: now())
            products[gtin] = product
            markReady(gtin)
            record(Scan(gtin: gtin, scannedAt: time, state: .found))
            return .found(product, cached: false)
        case .missing:
            record(Scan(gtin: gtin, scannedAt: time, state: .missing))
            return .missing
        case .unavailable:
            pending.append(Pending(gtin: gtin, scannedAt: time, meal: meal, date: date))
            record(Scan(gtin: gtin, scannedAt: time, state: .waiting))
            return .queued
        }
    }

    /// Looks up every code with a waiting scan, oldest first and each code
    /// once, stopping at the first the database can't answer. Returns the
    /// scans that resolved.
    @discardableResult
    public func resolveWaiting(fetch: Fetch) async -> [Pending] {
        var codes: [GTIN] = []
        for scan in waiting where !codes.contains(scan.gtin) { codes.append(scan.gtin) }
        var resolved: [Pending] = []
        for gtin in codes {
            let fetched = await fetch(gtin)
            let state: Pending.State
            switch fetched {
            case .found(let food, let attribution):
                products[gtin] = Product(gtin: gtin, food: food, attribution: attribution, resolvedAt: now())
                state = .ready
            case .missing: state = .missing
            case .unavailable:
                save()
                return resolved
            }
            // The person may have logged or dismissed some meanwhile.
            for index in pending.indices where pending[index].gtin == gtin && pending[index].state == .waiting {
                pending[index].state = state
                resolved.append(pending[index])
            }
            if let index = history.firstIndex(where: { $0.gtin == gtin && $0.state == .waiting }) {
                history[index].state = state == .ready ? .found : .missing
            }
        }
        if !resolved.isEmpty { save() }
        return resolved
    }

    /// Fetches a cached product again, keeping the cached one when the
    /// database is unreachable or has dropped it. The person's own food stays.
    public func refresh(_ gtin: GTIN, fetch: Fetch) async {
        guard let cached = products[gtin], !cached.own, case .found(let food, let attribution) = await fetch(gtin) else { return }
        products[gtin] = Product(gtin: gtin, food: food, attribution: attribution, resolvedAt: now())
        save()
    }

    /// A food the person entered for a code the database didn't know, or a
    /// store's own code: the code finds it from now on, on this device.
    public func remember(_ food: Food, for gtin: GTIN, attribution: String) {
        products[gtin] = Product(gtin: gtin, food: food, attribution: attribution, resolvedAt: now(), own: true)
        markReady(gtin)
        let scannedAt = history.first { $0.gtin == gtin }?.scannedAt ?? now()
        record(Scan(gtin: gtin, scannedAt: scannedAt, state: .found))
    }

    /// The person logged or dismissed an offline scan.
    public func acknowledge(_ id: Pending.ID) {
        pending.removeAll { $0.id == id }
        save()
    }

    /// Dismisses every offline scan that has resolved; waiting ones stay.
    public func dismissResolved() {
        pending.removeAll { $0.state != .waiting }
        save()
    }

    /// Removes a code from the history; its cached product and any offline
    /// scans of it stay.
    public func remove(_ gtin: GTIN) {
        history.removeAll { $0.gtin == gtin }
        save()
    }

    // MARK: Storage

    private struct Saved: Codable {
        var history: [Scan]
        var products: [Product]
        var pending: [Pending]?
    }

    /// A code now has a food: its waiting scans are ready.
    private func markReady(_ gtin: GTIN) {
        for index in pending.indices where pending[index].gtin == gtin && pending[index].state == .waiting {
            pending[index].state = .ready
        }
    }

    private func record(_ scan: Scan) {
        history = Array(([scan] + history.filter { $0.gtin != scan.gtin }).prefix(Self.historyLimit))
        save()
    }

    private func save() {
        if products.count > Self.productLimit {
            let kept = Set(history.map(\.gtin) + pending.map(\.gtin))
            let dropped = products.values.filter { !kept.contains($0.gtin) && !$0.own }.sorted { $0.resolvedAt < $1.resolvedAt }
                .prefix(products.count - Self.productLimit)
            for product in dropped { products[product.gtin] = nil }
        }
        let saved = Saved(history: history, products: products.values.sorted { $0.gtin < $1.gtin }, pending: pending)
        do {
            try persistence.saveValue(try ExerlyJSON.canonical(saved), forKey: Self.key)
            error = nil
        } catch {
            self.error = "Couldn't save your scan history on this device."
        }
    }
}
