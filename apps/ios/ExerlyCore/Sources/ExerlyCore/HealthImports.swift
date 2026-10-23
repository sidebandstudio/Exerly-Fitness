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

    public init(id: UUID, kind: Kind, target: String, owner: String, source: String, sourceName: String, start: Date, end: Date,
                day: LocalDate, fingerprint: String, state: State = .imported, updatedAt: Date) {
        self.id = id
        self.kind = kind
        self.target = target
        self.owner = owner
        self.source = source
        self.sourceName = sourceName
        self.start = start
        self.end = end
        self.day = day
        self.fingerprint = fingerprint
        self.state = state
        self.updatedAt = updatedAt
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
    static let kind = "health_import"

    public private(set) var records: [UUID: HealthImport] = [:]

    @ObservationIgnored let persistence: TrainingPersistence & DocumentPersistence

    public init(persistence: TrainingPersistence & DocumentPersistence) throws {
        self.persistence = persistence
        for data in try persistence.loadDocuments(kind: Self.kind) {
            let record = try ExerlyJSON.decoder.decode(HealthImport.self, from: data)
            records[record.id] = record
        }
    }

    public func records(_ kind: HealthImport.Kind) -> [HealthImport] { records.values.filter { $0.kind == kind } }

    /// Saves records on their own, as after an activity's change.
    public func save(_ changed: [HealthImport]) throws {
        guard !changed.isEmpty else { return }
        try persistence.performAtomically {
            persistence.afterCommit(try prepare(changed))
        }
    }

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

    /// The later change stands: an adoption, or a record taken out or put back.
    public func merge(kind: String, base: Data?, local: Data, remote: Data) throws -> Data {
        let decoder = ExerlyJSON.decoder
        return try decoder.decode(HealthImport.self, from: remote).updatedAt > decoder.decode(HealthImport.self, from: local).updatedAt
            ? remote : local
    }

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
            for (ids, state) in [(changes.removing, HealthImport.State.removed), (changes.displacing, .displaced)] {
                for id in ids {
                    guard var record = records[id], record.kind == .food, record.owner == install, record.state == .imported else { continue }
                    if let entry = current[id] {
                        guard HealthImport.fingerprint(entry) == record.fingerprint else { continue }
                        entries.append(DocumentWrite(kind: NutritionStore.entryKind, id: id.uuidString, payload: nil))
                        removed += 1
                    }
                    record.state = state
                    record.updatedAt = now
                    changed.append(record)
                }
            }
            for reading in changes.adding where current[reading.id] == nil && records[reading.id] == nil {
                let entry = NutritionStore.entry(for: reading, timeZone: timeZone)
                entries.append(DocumentWrite(kind: NutritionStore.entryKind, id: entry.id.uuidString, payload: try ExerlyJSON.canonical(entry)))
                changed.append(HealthImport(food: reading, entry: entry, owner: install, now: now))
                added += 1
            }
            for reading in changes.restoring where current[reading.id] == nil {
                guard let record = records[reading.id], record.owner == install, record.state == .displaced else { continue }
                let entry = NutritionStore.entry(for: reading, timeZone: timeZone)
                entries.append(DocumentWrite(kind: NutritionStore.entryKind, id: entry.id.uuidString, payload: try ExerlyJSON.canonical(entry)))
                changed.append(HealthImport(food: reading, entry: entry, owner: install, now: now))
                added += 1
            }
            for id in changes.adopting {
                if var record = records[id], record.state == .imported {
                    record.owner = install
                    record.updatedAt = now
                    changed.append(record)
                }
            }
            for reading in changes.claiming where records[reading.id] == nil {
                guard let entry = current[reading.id] else { continue }
                changed.append(HealthImport(food: reading, entry: entry, owner: install, now: now))
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
    /// The record of a food just imported.
    init(food reading: HealthFoodReading, entry: FoodEntry, owner: String, now: Date) {
        self.init(id: reading.id, kind: .food, target: entry.id.uuidString, owner: owner, source: reading.source,
                  sourceName: reading.sourceName, start: reading.at, end: reading.at, day: entry.date,
                  fingerprint: HealthImport.fingerprint(entry), updatedAt: now)
    }

    /// The record of a workout just imported as the activity `clientID`.
    public init(workout reading: HealthWorkoutReading, clientID: String, fingerprint: String, owner: String, timeZone: TimeZone,
                now: Date = Date()) {
        self.init(id: reading.id, kind: .workout, target: clientID, owner: owner, source: reading.source, sourceName: reading.sourceName,
                  start: reading.start, end: reading.end, day: LocalDate(reading.start, in: reading.timeZone ?? timeZone),
                  fingerprint: fingerprint, updatedAt: now)
    }
}
