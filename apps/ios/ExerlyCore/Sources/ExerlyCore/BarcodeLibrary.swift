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
    /// The offline scans each logged entry consumed, by entry ID. Undo reads
    /// only this, so it needs nothing kept in memory.
    static let provenanceKey = "barcode_library.consumed.v1"
    /// The scans Undo put back, by the entry it removed, so a conflict that
    /// brings that entry back keeps each scan logged once.
    static let undoneKey = "barcode_library.undone.v1"

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
            // Kept to the millisecond, as stored, so memory always matches the disk.
            pending.append(Pending(gtin: gtin, scannedAt: time.roundedToMilliseconds, meal: meal, date: date))
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

    // MARK: Logging

    public enum LogError: Error, Equatable {
        /// The store keeps its records somewhere else, so one transaction can't hold both.
        case separateStores
        /// These scans aren't pending any more: logged or dismissed elsewhere.
        case alreadyLogged(Set<Pending.ID>)
    }

    /// Logs a plate's foods and consumes exactly the offline scans each item
    /// came from (`consuming[i]` for `plate[i]`), in one transaction, keeping
    /// each scan beside the entry it became so Undo can put it back. An entry
    /// logging a scan Undo put back names the entries it replaces. A scan
    /// no longer pending throws `alreadyLogged`, so nothing logs it twice.
    /// Pending scans are read from the transaction itself, so two logs in one
    /// caller's transaction see each other; memory changes only after the
    /// outermost commit, and a failed one leaves scans and entries as they were.
    @discardableResult
    public func log(_ plate: [NutritionStore.PlateItem], consuming scans: [Set<Pending.ID>], to store: NutritionStore,
                    on date: LocalDate, meal: String, at time: Date? = nil) throws -> [FoodEntry] {
        guard (store.persistence as AnyObject) === (persistence as AnyObject) else { throw LogError.separateStores }
        let ids = scans.reduce(into: Set<Pending.ID>()) { $0.formUnion($1) }
        precondition(scans.count == plate.count && scans.map(\.count).reduce(0, +) == ids.count,
                     "Each plate item names its own scans")
        var entries: [FoodEntry] = []
        try persistence.performAtomically {
            let stored = try storedPending()
            let consumed = stored.filter { ids.contains($0.id) }
            guard consumed.count == ids.count else { throw LogError.alreadyLogged(ids.subtracting(consumed.map(\.id))) }
            try persistence.saveValue(try ExerlyJSON.canonical(saved(pending: stored.filter { !ids.contains($0.id) })), forKey: Self.key)
            let undone = try storedValue([String: [Pending]].self, Self.undoneKey) ?? [:]
            // Each undone entry with what it already stood in for first, so a
            // chain of Undo and logging again keeps the first entry first.
            let replacing = scans.map { own in
                undone.filter { $0.value.contains { own.contains($0.id) } }.keys.compactMap(UUID.init).sorted { $0.uuidString < $1.uuidString }
                    .flatMap { (store.links[$0]?.replaces ?? []) + [$0] }
            }
            let written = try store.writeLog(plate, on: date, meal: meal, at: time, replacing: replacing)
            var provenance = try storedProvenance()
            for (entry, own) in zip(written.entries, scans) where !own.isEmpty {
                provenance[entry.id.uuidString] = consumed.filter { own.contains($0.id) }
            }
            try persistence.saveValue(try ExerlyJSON.canonical(provenance), forKey: Self.provenanceKey)
            entries = written.entries
            persistence.afterCommit { [self] in
                written.publish()
                pending.removeAll { ids.contains($0.id) }
            }
        }
        return entries
    }

    /// Undoes logging these entries, from any log of any age: deletes those
    /// still logged and puts back exactly the offline scans kept with them,
    /// with their meal, day and time, in one transaction. A plain delete
    /// leaves the scans consumed: "I didn't eat it" dismisses them too, and
    /// restoring the entry later makes it the scan's one log again.
    public func undo(_ entryIDs: Set<UUID>, from store: NutritionStore) throws {
        guard (store.persistence as AnyObject) === (persistence as AnyObject) else { throw LogError.separateStores }
        let order = { (a: Pending, b: Pending) in (a.scannedAt, a.id.uuidString) < (b.scannedAt, b.id.uuidString) }
        try persistence.performAtomically {
            let deleted = try store.writeDeletes(Array(entryIDs))
            var provenance = try storedProvenance()
            let stored = try storedPending()
            var restored: [Pending] = []
            var undone = try storedValue([String: [Pending]].self, Self.undoneKey) ?? [:]
            for id in deleted.ids {
                let kept = provenance.removeValue(forKey: id.uuidString) ?? []
                restored += kept.filter { scan in !(stored + restored).contains { $0.id == scan.id } }
                if !kept.isEmpty { undone[id.uuidString] = kept }
            }
            try persistence.saveValue(try ExerlyJSON.canonical(saved(pending: (stored + restored).sorted(by: order))), forKey: Self.key)
            try persistence.saveValue(try ExerlyJSON.canonical(provenance), forKey: Self.provenanceKey)
            try persistence.saveValue(try ExerlyJSON.canonical(undone), forKey: Self.undoneKey)
            persistence.afterCommit { [self] in
                deleted.publish()
                pending = (pending + restored.filter { scan in !pending.contains { $0.id == scan.id } }).sorted(by: order)
            }
        }
    }

    /// Brings back an entry Undo removed, as another device changed it,
    /// while its scans are still pending: bringing it back logs them, once.
    /// An entry logged again from them stands in for it instead; see
    /// `NutritionStore.reconcile`. Returns how to undo it, or nil when no
    /// pending scan is involved. Call inside a transaction.
    func bringBack(_ id: UUID, as entry: FoodEntry, to store: NutritionStore) throws -> (() throws -> Void)? {
        guard try claim(id, store: store, write: { try store.commit(NutritionStore.entryKind, id.uuidString, entry) }) else { return nil }
        return { [self] in try undo([id], from: store) }
    }

    /// Another device brought back an entry Undo removed here: its scans
    /// still pending are its log again. Call inside a transaction.
    func broughtBack(_ id: UUID, to store: NutritionStore) throws {
        _ = try claim(id, store: store, write: {})
    }

    /// Consumes the pending scans Undo put back with `id` and keeps them
    /// with it again, writing it with `write`. False when none is pending.
    private func claim(_ id: UUID, store: NutritionStore, write: () throws -> Void) throws -> Bool {
        guard (store.persistence as AnyObject) === (persistence as AnyObject) else { throw LogError.separateStores }
        var undone = try storedValue([String: [Pending]].self, Self.undoneKey) ?? [:]
        guard let scans = undone[id.uuidString], !scans.isEmpty else { return false }
        let pendingNow = try storedPending()
        let back = scans.filter { scan in pendingNow.contains { $0.id == scan.id } }
        guard !back.isEmpty else { return false }
        let ids = Set(back.map(\.id))
        try persistence.performAtomically {
            try persistence.saveValue(try ExerlyJSON.canonical(saved(pending: pendingNow.filter { !ids.contains($0.id) })), forKey: Self.key)
            try write()
            var provenance = try storedProvenance()
            provenance[id.uuidString] = back
            undone[id.uuidString] = nil
            try persistence.saveValue(try ExerlyJSON.canonical(provenance), forKey: Self.provenanceKey)
            try persistence.saveValue(try ExerlyJSON.canonical(undone), forKey: Self.undoneKey)
            persistence.afterCommit { [self] in pending.removeAll { ids.contains($0.id) } }
        }
        return true
    }

    /// The person logged or dismissed an offline scan.
    public func acknowledge(_ id: Pending.ID) {
        pending.removeAll { $0.id == id }
        save()
    }

    /// Dismisses every offline scan that has resolved; waiting ones stay,
    /// and so do those in `keeping`, such as scans on a plate.
    public func dismissResolved(keeping: Set<Pending.ID> = []) {
        pending.removeAll { $0.state != .waiting && !keeping.contains($0.id) }
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

    /// The pending scans as stored, as an open transaction sees them.
    private func storedPending() throws -> [Pending] {
        guard let data = try persistence.loadValue(forKey: Self.key) else { return [] }
        return try ExerlyJSON.decoder.decode(Saved.self, from: data).pending ?? []
    }

    private func storedValue<T: Decodable>(_ type: T.Type, _ key: String) throws -> T? {
        try persistence.loadValue(forKey: key).map { try ExerlyJSON.decoder.decode(type, from: $0) }
    }

    private func storedProvenance() throws -> [String: [Pending]] {
        guard let data = try persistence.loadValue(forKey: Self.provenanceKey) else { return [:] }
        return try ExerlyJSON.decoder.decode([String: [Pending]].self, from: data)
    }

    private func saved(pending: [Pending]) -> Saved {
        Saved(history: history, products: products.values.sorted { $0.gtin < $1.gtin }, pending: pending)
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
        do {
            try persistence.saveValue(try ExerlyJSON.canonical(saved(pending: pending)), forKey: Self.key)
            error = nil
        } catch {
            self.error = "Couldn't save your scan history on this device."
        }
    }
}
