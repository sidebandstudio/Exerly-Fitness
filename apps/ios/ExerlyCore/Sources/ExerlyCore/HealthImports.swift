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
        /// Taken out for a better source's record of the same day or time; it
        /// comes back if that one goes.
        case displaced
        /// Taken out because Health deleted it, or because they chose to.
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
        case id, kind, target, owner, generation, source, sourceName, start, end, day, fingerprint, state, updatedAt
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

    @ObservationIgnored let persistence: TrainingPersistence & DocumentPersistence

    public init(persistence: TrainingPersistence & DocumentPersistence) throws {
        self.persistence = persistence
        for data in try persistence.loadDocuments(kind: Self.kind) {
            let record = try ExerlyJSON.decoder.decode(HealthImport.self, from: data)
            records[record.id] = record
        }
    }

    /// Starts from records, and any unfinished work, read off the main actor (`StoredAccount`).
    public init(persistence: TrainingPersistence & DocumentPersistence, loaded: [HealthImport], work: Data? = nil) {
        self.persistence = persistence
        records = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        openingWork = .some(work)
    }

    public func records(_ kind: HealthImport.Kind) -> [HealthImport] { records.values.filter { $0.kind == kind } }

    /// Saves records on their own, as after an activity's change. With
    /// `finishingWork`, the work written down for them (`recordWork`) is
    /// cleared in the same transaction.
    public func save(_ changed: [HealthImport], finishingWork: Bool = false) throws {
        guard !changed.isEmpty || finishingWork else { return }
        try persistence.performAtomically {
            if finishingWork {
                try persistence.saveValue(nil, forKey: Self.workKey)
                openingWork = nil
            }
            persistence.afterCommit(try prepare(changed))
        }
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
    /// Displaced records to put back, read from Health again.
    public var restoring: [HealthFoodReading] = []
    /// Records Health deleted, or they chose to remove.
    public var removing: [UUID] = []
    /// Records a better source now covers.
    public var displacing: [UUID] = []
    /// Another install's records to keep as this one's.
    public var adopting: [UUID] = []
    /// Entries already in Exerly with no record, as after a reinstall before
    /// sync, to keep as this install's, as they are now.
    public var claiming: [HealthFoodReading] = []

    public init() {}
}

extension HealthImportStore {
    /// Makes food changes in one transaction with their records. Each
    /// removal is checked again inside it: only this install's, and only an
    /// entry still as it was imported. Returns how many entries were added
    /// and taken out.
    @discardableResult
    public func apply(_ changes: HealthFoodChanges, to nutrition: NutritionStore, install: String, timeZone: TimeZone,
                      now: Date = Date()) throws -> (added: Int, removed: Int) {
        var entries: [DocumentWrite] = [], changed: [HealthImport] = [], added = 0, removed = 0
        let current = Dictionary(nutrition.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        try persistence.performAtomically {
            for (id, state) in HealthImport.outcomes(removing: changes.removing, displacing: changes.displacing) {
                guard var record = records[id], record.kind == .food, record.owner == install, record.allows(state) else { continue }
                if let entry = current[id] {
                    guard record.state == .imported, HealthImport.fingerprint(entry) == record.fingerprint else { continue }
                    entries.append(DocumentWrite(kind: NutritionStore.entryKind, id: id.uuidString, payload: nil))
                    removed += 1
                }
                record.state = state
                record.updatedAt = now
                changed.append(record)
            }
            for reading in changes.adding where current[reading.id] == nil && records[reading.id] == nil {
                let entry = NutritionStore.entry(for: reading, timeZone: timeZone)
                entries.append(DocumentWrite(kind: NutritionStore.entryKind, id: entry.id.uuidString, payload: try ExerlyJSON.canonical(entry)))
                changed.append(HealthImport(food: reading, entry: entry, owner: install, now: now))
                added += 1
            }
            for reading in changes.restoring where current[reading.id] == nil {
                guard var record = records[reading.id], record.owner == install, record.state == .displaced else { continue }
                let entry = NutritionStore.entry(for: reading, timeZone: timeZone)
                entries.append(DocumentWrite(kind: NutritionStore.entryKind, id: entry.id.uuidString, payload: try ExerlyJSON.canonical(entry)))
                // The same record, at its generation, so an older version arriving later doesn't undo this.
                (record.state, record.target, record.fingerprint, record.updatedAt) = (.imported, entry.id.uuidString, HealthImport.fingerprint(entry), now)
                changed.append(record)
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
            guard !entries.isEmpty || !changed.isEmpty else { return }
            let publishEntries = try nutrition.prepareWrites(kind: NutritionStore.entryKind, entries)
            let publishRecords = try prepare(changed)
            persistence.afterCommit { publishEntries(); publishRecords() }
        }
        return (added, removed)
    }
}

extension HealthImport {
    /// One outcome per record, in a stable order: a removal, Health's or
    /// theirs, wins over setting the same record aside, so a removed record
    /// never comes back when the better source goes.
    public static func outcomes(removing: [UUID], displacing: [UUID]) -> [(UUID, State)] {
        var outcome: [UUID: State] = [:]
        for id in displacing { outcome[id] = .displaced }
        for id in removing { outcome[id] = .removed }
        return outcome.sorted { $0.key.uuidString < $1.key.uuidString }.map { ($0.key, $0.value) }
    }

    /// Whether the record can become `state` on its own: one in Exerly can be
    /// taken out or set aside, and one set aside can still be taken out, as
    /// when Health deletes it, so it's never a better source again.
    public func allows(_ state: State) -> Bool {
        self.state == .imported || (self.state == .displaced && state == .removed)
    }

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
