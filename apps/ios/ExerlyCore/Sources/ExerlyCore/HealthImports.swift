import CryptoKit
import Foundation
import Observation

/// One record Exerly imported from Apple Health, kept as a synced
/// `health_import` document so every device knows it: the install that
/// imported it, the entry or activity it became, what that looked like
/// then, and what's become of it. Only the install that imported a record
/// takes it out on its own, and only when Health says it was deleted.
public struct HealthImport: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable { case food, workout }

    public enum State: String, Sendable, Codable {
        /// In Exerly, as imported or as they've changed it since.
        case imported
        /// Taken out, as they chose, because Health deleted it or no longer has it.
        case removed
    }

    /// The Health sample's UUID, which is also the document's ID.
    public var id: UUID
    public var kind: Kind
    /// The entry's ID, or the activity's client ID.
    public var target: String
    /// The install that imported it, or adopted it.
    public var owner: String
    /// How many times it changed hands: each adoption counts one more, and a
    /// version from an earlier one never overwrites a later (`merge`).
    public var generation: Int
    /// The app that saved it to Health, by bundle identifier.
    public var source: String
    public var sourceName: String
    public var start: Date
    public var end: Date
    /// The day it counts toward, in the zone it was recorded in.
    public var day: LocalDate
    /// What the entry or activity was like when it was imported. Once it
    /// differs, they've changed it, and nothing automatic touches it again.
    public var fingerprint: String
    public var state: State
    public var updatedAt: Date
    /// Other sources Health also has for its day or time, by name, set aside
    /// because this was imported first: "Also in Health from Tracker, not imported".
    public var alsoIn: [String] = []

    public init(id: UUID, kind: Kind, target: String, owner: String, generation: Int = 0, source: String, sourceName: String,
                start: Date, end: Date, day: LocalDate, fingerprint: String, state: State = .imported, updatedAt: Date) {
        self.id = id
        self.kind = kind
        self.target = target
        self.owner = owner
        self.generation = generation
        self.source = source
        self.sourceName = sourceName
        self.start = start
        self.end = end
        self.day = day
        self.fingerprint = fingerprint
        self.state = state
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, target, owner, generation, source, sourceName, start, end, day, fingerprint, state, updatedAt, alsoIn
    }

    /// Records written before generations count as the first. A removed
    /// record is kept as a tombstone (`encode(to:)`), and reads back with
    /// empty details, which nothing uses once it's out.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        owner = try container.decode(String.self, forKey: .owner)
        generation = try container.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        state = try container.decode(State.self, forKey: .state)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        let tombstone = state == .removed && !container.contains(.target)
        target = tombstone ? "" : try container.decode(String.self, forKey: .target)
        source = tombstone ? "" : try container.decode(String.self, forKey: .source)
        sourceName = tombstone ? "" : try container.decode(String.self, forKey: .sourceName)
        start = tombstone ? Self.none : try container.decode(Date.self, forKey: .start)
        end = tombstone ? Self.none : try container.decode(Date.self, forKey: .end)
        day = tombstone ? LocalDate(Self.none, in: Self.utc) : try container.decode(LocalDate.self, forKey: .day)
        fingerprint = tombstone ? "" : try container.decode(String.self, forKey: .fingerprint)
        alsoIn = tombstone ? [] : try container.decodeIfPresent([String].self, forKey: .alsoIn) ?? []
    }

    /// Retention: a removed record keeps only what stops its sample being
    /// imported again and who may change it, its ID, kind, owner, generation
    /// and state, and drops the rest, so years of removals stay small.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(owner, forKey: .owner)
        try container.encode(generation, forKey: .generation)
        try container.encode(state, forKey: .state)
        try container.encode(updatedAt, forKey: .updatedAt)
        guard state != .removed else { return }
        try container.encode(target, forKey: .target)
        try container.encode(source, forKey: .source)
        try container.encode(sourceName, forKey: .sourceName)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(day, forKey: .day)
        try container.encode(fingerprint, forKey: .fingerprint)
        if !alsoIn.isEmpty { try container.encode(alsoIn, forKey: .alsoIn) }
    }

    /// What `alsoIn` says, nil when there's no other source.
    public var alsoInNote: String? {
        alsoIn.isEmpty ? nil : "Also in Health from \(ListFormatter.localizedString(byJoining: alsoIn)), not imported"
    }

    private static let none = Date(timeIntervalSince1970: 0)
    private static let utc = TimeZone(identifier: "UTC")!

    /// Makes this install the owner, one generation on.
    public mutating func adopt(by install: String, at now: Date) {
        owner = install
        generation += 1
        updatedAt = now
    }

    /// A food entry's fingerprint: any change to it, its amount, portion,
    /// day, meal, nutrients, name or note, changes this.
    public static func fingerprint(_ entry: FoodEntry) -> String {
        digest((try? ExerlyJSON.canonical(entry)) ?? Data())
    }

    /// An activity's fingerprint, from the fields it's saved and synced with
    /// (`ActivityRequest`, the API's routes/activities.js): any edit to its
    /// name, minutes, calories, intensity, day or type changes this. Numbers
    /// compare by value, as the server may send 30.0 back as 30.
    public static func fingerprint(activity fields: [String: Any]) -> String {
        let keys = ["activity", "duration_min", "calories", "intensity", "entry_date", "type"]
        let text = keys.map { key -> String in
            switch fields[key] {
            case let number as NSNumber: String(format: "%.3f", number.doubleValue)
            case let string as String: Double(string).map { String(format: "%.3f", $0) } ?? string
            default: ""
            }
        }.joined(separator: "\n")
        return digest(Data(text.utf8))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// The account's Health imports, as `health_import` documents.
@MainActor
@Observable
public final class HealthImportStore {
    nonisolated static let kind = "health_import"

    public private(set) var records: [UUID: HealthImport] = [:]
    /// Changes from Health waiting for the person (`HealthChangeQueue`).
    public private(set) var queue = HealthChangeQueue()

    @ObservationIgnored let persistence: TrainingPersistence & DocumentPersistence

    public init(persistence: TrainingPersistence & DocumentPersistence) throws {
        self.persistence = persistence
        for data in try persistence.loadDocuments(kind: Self.kind) {
            let record = try ExerlyJSON.decoder.decode(HealthImport.self, from: data)
            records[record.id] = record
        }
        queue = try Self.queue(persistence.loadValue(forKey: Self.queueKey))
    }

    /// Starts from records, and any unfinished work and waiting changes, read off the main actor (`StoredAccount`).
    public init(persistence: TrainingPersistence & DocumentPersistence, loaded: [HealthImport], work: Data? = nil,
                queue: Data? = nil) throws {
        self.persistence = persistence
        records = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        openingWork = .some(work)
        self.queue = try Self.queue(queue)
    }

    private static func queue(_ data: Data?) throws -> HealthChangeQueue {
        try data.map { try ExerlyJSON.decoder.decode(HealthChangeQueue.self, from: $0) } ?? HealthChangeQueue()
    }

    @ObservationIgnored private var tail: Task<Void, Never>?

    /// Runs Health reads and applies for this account one at a time, in the
    /// order they're asked for, so an apply and a read never interleave.
    public func serially(_ work: @escaping @MainActor () async throws -> Void) async throws {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            try await work()
        }
        tail = Task { _ = try? await task.value }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Keeps everything as it is: exactly these waiting changes are dismissed.
    public func keep(_ ids: Set<UUID>) throws { try save([], queue: queue.removing(ids)) }

    /// Leaves only these waiting changes, as once the rest are satisfied
    /// elsewhere; saves nothing when nothing goes.
    public func prune(keeping actionable: [HealthChangeQueue.Entry]) throws {
        let keep = Set(actionable.map(\.id))
        guard queue.entries.contains(where: { !keep.contains($0.id) }) else { return }
        try save([], queue: HealthChangeQueue(entries: queue.entries.filter { keep.contains($0.id) }))
    }

    public func records(_ kind: HealthImport.Kind) -> [HealthImport] { records.values.filter { $0.kind == kind } }

    /// Saves records on their own, as after an activity's change. With
    /// `finishingWork`, the work written down for them (`recordWork`) is
    /// cleared in the same transaction.
    public func save(_ changed: [HealthImport], finishingWork: Bool = false, queue: HealthChangeQueue? = nil) throws {
        guard !changed.isEmpty || finishingWork || queue != nil else { return }
        try persistence.performAtomically {
            if finishingWork {
                try persistence.saveValue(nil, forKey: Self.workKey)
                openingWork = nil
            }
            let publishQueue = try queue.map(prepareQueue)
            let publishRecords = try prepare(changed)
            persistence.afterCommit { publishRecords(); publishQueue?() }
        }
    }

    nonisolated static let queueKey = "health_import.queue"

    /// Saves the account's changes from Health inside the caller's transaction.
    func prepareQueue(_ queue: HealthChangeQueue) throws -> () -> Void {
        try persistence.saveValue(queue.isEmpty ? nil : ExerlyJSON.canonical(queue), forKey: Self.queueKey)
        return { [self] in self.queue = queue }
    }

    nonisolated static let workKey = "health_import.work"

    /// Changes that span this store and another, as an imported workout's
    /// activity and its record, written down before either is made so a
    /// crash between them can be finished. Kept on this device only.
    public func recordWork(_ work: Data) throws {
        try persistence.saveValue(work, forKey: Self.workKey)
        openingWork = nil
    }

    /// Work written down and not yet finished, if any: as the account was
    /// read off the main actor while it opened, until anything here changes it.
    public func pendingWork() throws -> Data? {
        if let openingWork { return openingWork }
        return try persistence.loadValue(forKey: Self.workKey)
    }

    /// The work `StoredAccount` read with the records, `.some(nil)` when there
    /// was none, so finishing it as the account opens reads nothing here.
    @ObservationIgnored private var openingWork: Data??

    /// Persists records inside the caller's transaction; publish after it commits.
    func prepare(_ changed: [HealthImport]) throws -> () -> Void {
        try prepareWrites(kind: Self.kind, changed.map { DocumentWrite(kind: Self.kind, id: $0.id.uuidString, payload: try ExerlyJSON.canonical($0)) })
    }
}

extension HealthImportStore: DocumentHost {
    public var documentKinds: [String] { [Self.kind] }

    public func documentIDs(kind: String) -> [String] { records.keys.map(\.uuidString) }

    public func payload(kind: String, id: String) throws -> Data? {
        try UUID(uuidString: id).flatMap { records[$0] }.map(ExerlyJSON.canonical)
    }

    public func canonicalize(kind: String, payload: Data) throws -> Data {
        guard kind == Self.kind else { throw DocumentError(message: "Unknown kind \(kind)") }
        return try ExerlyJSON.canonical(ExerlyJSON.decoder.decode(HealthImport.self, from: payload))
    }

    public func validate(kind: String, id: String, payload: Data) throws {
        let record = try ExerlyJSON.decoder.decode(HealthImport.self, from: canonicalize(kind: kind, payload: payload))
        guard record.id.uuidString == id.uppercased() else { throw DocumentError(message: "The Health import's ID doesn't match") }
    }

    /// The later generation stands whatever its time, so a phone that was
    /// offline while another adopted a record can't take it back, or out,
    /// with what it knew before. Within a generation only its owner changes
    /// the record, and the later change stands.
    public func merge(kind: String, base: Data?, local: Data, remote: Data) throws -> Data {
        let decoder = ExerlyJSON.decoder
        let mine = try decoder.decode(HealthImport.self, from: local), theirs = try decoder.decode(HealthImport.self, from: remote)
        if mine.generation != theirs.generation { return theirs.generation > mine.generation ? remote : local }
        return theirs.updatedAt > mine.updatedAt ? remote : local
    }

    /// The same whole-record rule, field by field never: a record mixing an
    /// adoption's owner with a stale owner's state would be neither.
    public func merge(kind: String, base: Data?, local: Data, remote: Data, preferring prefer: Merge.Preference) throws -> MergeOutcome {
        MergeOutcome(merged: try merge(kind: kind, base: base, local: local, remote: remote), conflicts: [])
    }

    /// Generation and time settle every clash, with nothing for a person to choose.
    public func reviewsConflicts(kind: String) -> Bool { false }

    public func prepareWrite(kind: String, id: String, payload: Data?) throws -> () -> Void {
        try prepareWrites(kind: kind, [DocumentWrite(kind: kind, id: id, payload: payload)])
    }

    /// One publish step for any number, as an import writes thousands.
    public func prepareWrites(kind: String, _ writes: [DocumentWrite]) throws -> () -> Void {
        guard kind == Self.kind else { throw DocumentError(message: "Unknown kind \(kind)") }
        var changed: [UUID: HealthImport?] = [:]
        for write in writes {
            guard let id = UUID(uuidString: write.id) else { throw DocumentError(message: "A Health import's ID is a UUID") }
            if let payload = write.payload {
                let data = try canonicalize(kind: kind, payload: payload)
                try persistence.saveDocument(kind: kind, id: id.uuidString, payload: data)
                changed[id] = .some(try ExerlyJSON.decoder.decode(HealthImport.self, from: data))
            } else {
                try persistence.deleteDocument(kind: kind, id: id.uuidString)
                changed[id] = .some(nil)
            }
        }
        return { [self] in for (id, record) in changed { records[id] = record } }
    }
}

/// What to do with food from Health, decided by `HealthHistory.plan` and
/// checked again as it's saved.
public struct HealthFoodChanges: Sendable {
    public var adding: [HealthFoodReading] = []
    /// Another install's records to keep as this one's.
    public var adopting: [UUID] = []
    /// Entries already in Exerly with no record, as after a reinstall before
    /// sync, to keep as this install's, as they are now.
    public var claiming: [HealthFoodReading] = []
    /// Sources set aside for what's imported, to note on its record.
    public var alsoIn: [UUID: Set<String>] = [:]
    /// The account's changes from Health as they stand once these are made,
    /// saved in the same transaction; nil leaves them as they are.
    public var queue: HealthChangeQueue?

    public init() {}
}

/// Changes from Health waiting for the person, per account: only removals,
/// of this install's imports Health deleted or no longer has. Nothing is
/// taken out until they apply them on this device. Each is a small
/// reference, kept on the device with the account's data, and there are
/// at most `cap`: a read that would go past it keeps its anchor, and reads
/// the rest again once there's room.
public struct HealthChangeQueue: Codable, Sendable, Hashable {
    public struct Entry: Codable, Sendable, Hashable, Identifiable {
        public enum Reason: String, Codable, Sendable { case deleted, missing }
        public var kind: HealthImport.Kind
        /// The Health sample's UUID, which is also its record's ID.
        public var id: UUID
        /// The entry's ID, or the activity's client ID.
        public var target: String
        /// The entry or activity as it was when listed: once it differs, it's theirs, and the change is dropped.
        public var fingerprint: String
        public var reason: Reason

        public init(kind: HealthImport.Kind, id: UUID, target: String, fingerprint: String, reason: Reason) {
            (self.kind, self.id, self.target, self.fingerprint, self.reason) = (kind, id, target, fingerprint, reason)
        }

        /// The change for an imported record, as it is now.
        public init(_ record: HealthImport, reason: Reason) {
            self.init(kind: record.kind, id: record.id, target: record.target, fingerprint: record.fingerprint, reason: reason)
        }
    }

    public static let cap = 2000

    public var entries: [Entry] = []

    public init(entries: [Entry] = []) { self.entries = entries }

    public var isEmpty: Bool { entries.isEmpty }

    /// Adds entries not already listed, as many as `cap` allows. `full` when
    /// some didn't fit: the read that found them keeps its anchor.
    public func adding(_ new: [Entry], cap: Int = HealthChangeQueue.cap) -> (queue: HealthChangeQueue, full: Bool) {
        var queue = self
        var listed = Set(entries.map(\.id))
        var full = false
        for entry in new where !listed.contains(entry.id) {
            guard queue.entries.count < cap else {
                full = true
                break
            }
            queue.entries.append(entry)
            listed.insert(entry.id)
        }
        return (queue, full)
    }

    /// Without exactly these, as once they're applied or kept.
    public func removing(_ ids: Set<UUID>) -> HealthChangeQueue {
        HealthChangeQueue(entries: entries.filter { !ids.contains($0.id) })
    }
}

extension HealthImportStore {
    /// Adds food read from Health, with its records, in one transaction: new
    /// entries, adoptions, claims, notes of sources set aside, and the
    /// account's changes from Health. Nothing is taken out here. Returns how
    /// many entries were added.
    @discardableResult
    public func apply(_ changes: HealthFoodChanges, to nutrition: NutritionStore, install: String, timeZone: TimeZone,
                      now: Date = Date()) throws -> Int {
        var entries: [DocumentWrite] = [], changed: [HealthImport] = [], added = 0
        let current = Dictionary(nutrition.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        try persistence.performAtomically {
            for reading in changes.adding where current[reading.id] == nil && records[reading.id] == nil {
                let entry = NutritionStore.entry(for: reading, timeZone: timeZone)
                entries.append(DocumentWrite(kind: NutritionStore.entryKind, id: entry.id.uuidString, payload: try ExerlyJSON.canonical(entry)))
                changed.append(HealthImport(food: reading, entry: entry, owner: install, now: now))
                added += 1
            }
            for id in changes.adopting {
                if var record = records[id], record.state == .imported {
                    record.adopt(by: install, at: now)
                    changed.append(record)
                }
            }
            // Kept as this install's, one generation on, as an adoption is:
            // the entry was already in Exerly, imported somewhere.
            for reading in changes.claiming where records[reading.id] == nil {
                guard let entry = current[reading.id] else { continue }
                changed.append(HealthImport(food: reading, entry: entry, owner: install, generation: 1, now: now))
            }
            changed += noting(changes.alsoIn, except: Set(changed.map(\.id)), now: now)
            let publishQueue = try changes.queue.map(prepareQueue)
            guard !entries.isEmpty || !changed.isEmpty else {
                if let publishQueue { persistence.afterCommit(publishQueue) }
                return
            }
            let publishEntries = try nutrition.prepareWrites(kind: NutritionStore.entryKind, entries)
            let publishRecords = try prepare(changed)
            persistence.afterCommit { publishEntries(); publishRecords(); publishQueue?() }
        }
        return added
    }

    /// Imported records with the sources set aside for them added to their
    /// note, those whose note already has them left out.
    public func noting(_ alsoIn: [UUID: Set<String>], except: Set<UUID> = [], now: Date) -> [HealthImport] {
        alsoIn.sorted { $0.key.uuidString < $1.key.uuidString }.compactMap { id, names in
            guard !except.contains(id), var record = records[id], record.state == .imported else { return nil }
            let noted = Set(record.alsoIn).union(names)
            guard noted.count > record.alsoIn.count else { return nil }
            record.alsoIn = noted.sorted()
            record.updatedAt = now
            return record
        }
    }

    /// Takes out the foods of `entries` they chose to apply, in one
    /// transaction with their records and the queue. Each is checked again
    /// inside it: still imported, its entry still as it was listed and as
    /// imported. Those that pass are taken out and become this install's, a
    /// generation on; the rest are dropped. Exactly these entries leave the
    /// queue. Returns how many entries were taken out.
    @discardableResult
    public func applyRemovals(_ entries: [HealthChangeQueue.Entry], to nutrition: NutritionStore, install: String,
                              now: Date = Date()) throws -> Int {
        let foods = entries.filter { $0.kind == .food }
        guard !foods.isEmpty else { return 0 }
        let current = Dictionary(nutrition.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var deletes: [DocumentWrite] = [], changed: [HealthImport] = []
        try persistence.performAtomically {
            for listed in foods {
                guard var record = records[listed.id], record.kind == .food, record.state == .imported,
                      let entry = UUID(uuidString: record.target).flatMap({ current[$0] }),
                      HealthImport.fingerprint(entry) == listed.fingerprint, listed.fingerprint == record.fingerprint else { continue }
                deletes.append(DocumentWrite(kind: NutritionStore.entryKind, id: entry.id.uuidString, payload: nil))
                record.adopt(by: install, at: now)
                record.state = .removed
                changed.append(record)
            }
            let publishQueue = try prepareQueue(queue.removing(Set(foods.map(\.id))))
            let publishEntries = try nutrition.prepareWrites(kind: NutritionStore.entryKind, deletes)
            let publishRecords = try prepare(changed)
            persistence.afterCommit { publishEntries(); publishRecords(); publishQueue() }
        }
        return deletes.count
    }
}

extension HealthImport {
    /// The record of a food just imported.
    init(food reading: HealthFoodReading, entry: FoodEntry, owner: String, generation: Int = 0, now: Date) {
        self.init(id: reading.id, kind: .food, target: entry.id.uuidString, owner: owner, generation: generation, source: reading.source,
                  sourceName: reading.sourceName, start: reading.at, end: reading.at, day: entry.date,
                  fingerprint: HealthImport.fingerprint(entry), updatedAt: now)
    }

    /// The record of a workout just imported as the activity `clientID`.
    public init(workout reading: HealthWorkoutReading, clientID: String, fingerprint: String, owner: String, generation: Int = 0,
                timeZone: TimeZone, now: Date = Date()) {
        self.init(id: reading.id, kind: .workout, target: clientID, owner: owner, generation: generation, source: reading.source,
                  sourceName: reading.sourceName,
                  start: reading.start, end: reading.end, day: LocalDate(reading.start, in: reading.timeZone ?? timeZone),
                  fingerprint: fingerprint, updatedAt: now)
    }
}
