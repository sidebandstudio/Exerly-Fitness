import Foundation

// What Exerly writes to Apple Health, as plain values. The app turns these
// records into HealthKit objects; this file decides what each one holds, and
// `HealthWriteLedger` decides when one is written, replaced or removed.

public enum HealthRecordKind: String, Sendable, Codable, Hashable, CaseIterable, CodingKeyRepresentable {
    case food, weight, workout
}

/// A unit HealthKit understands, by its `HKUnit` unit string.
public enum HealthUnit: String, Sendable, Codable, Hashable {
    case kilocalories = "kcal", grams = "g", milligrams = "mg", micrograms = "mcg"
    case kilograms = "kg", pounds = "lb", percent = "%"
}

/// An amount of one HealthKit quantity type.
public struct HealthQuantity: Sendable, Codable, Hashable {
    /// A HealthKit quantity type identifier, such as "HKQuantityTypeIdentifierDietaryProtein".
    public var type: String
    public var value: Double
    public var unit: HealthUnit

    public init(type: String, value: Double, unit: HealthUnit) {
        self.type = type
        self.value = value
        self.unit = unit
    }
}

public enum HealthMetadata {
    /// Every sample Exerly writes carries its record's ID under this key, so it
    /// can be found to replace or remove, and is never read back as a reading
    /// from another app.
    public static let recordID = "ExerlyRecordID"
    /// HealthKit's `HKMetadataKeySyncIdentifier`.
    public static let syncIdentifierKey = "HKMetadataKeySyncIdentifier"
    static let syncPrefix = "exerly."

    /// The sync identifier of a record, or of one part of it ("protein").
    /// HealthKit keeps one sample per identifier and a save with a higher sync
    /// version replaces it, so a retried write never adds a second sample.
    public static func syncIdentifier(_ kind: HealthRecordKind, _ id: UUID, part: String? = nil) -> String {
        syncPrefix + kind.rawValue + "." + id.uuidString.lowercased() + (part.map { "." + $0 } ?? "")
    }

    /// True for a sample Exerly wrote, on this device or another one.
    public static func isFromExerly(_ metadata: [String: Any]?) -> Bool {
        guard let metadata else { return false }
        if metadata[recordID] != nil { return true }
        return (metadata[syncIdentifierKey] as? String)?.hasPrefix(syncPrefix) == true
    }
}

extension Nutrient {
    /// The HealthKit dietary type this nutrient is written as, or nil when
    /// Health has none. Water is left out on purpose: Health's water is what
    /// someone drinks, and a food's moisture would inflate it. Health counts
    /// alcohol in drinks, not grams, and has no added sugar, starch, trans fat,
    /// omega fatty acid, choline or amino acid types.
    public var healthType: String? {
        let name: String? = switch self {
        case .energy: "DietaryEnergyConsumed"
        case .protein: "DietaryProtein"
        case .carbohydrate: "DietaryCarbohydrates"
        case .fat: "DietaryFatTotal"
        case .fiber: "DietaryFiber"
        case .sugars: "DietarySugar"
        case .saturatedFat: "DietaryFatSaturated"
        case .monounsaturatedFat: "DietaryFatMonounsaturated"
        case .polyunsaturatedFat: "DietaryFatPolyunsaturated"
        case .cholesterol: "DietaryCholesterol"
        case .sodium: "DietarySodium"
        case .potassium: "DietaryPotassium"
        case .calcium: "DietaryCalcium"
        case .iron: "DietaryIron"
        case .magnesium: "DietaryMagnesium"
        case .phosphorus: "DietaryPhosphorus"
        case .zinc: "DietaryZinc"
        case .copper: "DietaryCopper"
        case .manganese: "DietaryManganese"
        case .selenium: "DietarySelenium"
        case .vitaminA: "DietaryVitaminA"
        case .vitaminC: "DietaryVitaminC"
        case .vitaminD: "DietaryVitaminD"
        case .vitaminE: "DietaryVitaminE"
        case .vitaminK: "DietaryVitaminK"
        case .thiamin: "DietaryThiamin"
        case .riboflavin: "DietaryRiboflavin"
        case .niacin: "DietaryNiacin"
        case .pantothenicAcid: "DietaryPantothenicAcid"
        case .vitaminB6: "DietaryVitaminB6"
        case .vitaminB12: "DietaryVitaminB12"
        case .folate: "DietaryFolate"
        case .caffeine: "DietaryCaffeine"
        default: nil
        }
        return name.map { "HKQuantityTypeIdentifier" + $0 }
    }

    /// Nutrients Exerly writes to Health, in declaration order.
    public static let healthWritable = allCases.filter { $0.healthType != nil }

    public var healthUnit: HealthUnit {
        switch unit {
        case .kilocalories: .kilocalories
        case .grams: .grams
        case .milligrams: .milligrams
        case .micrograms: .micrograms
        }
    }
}

/// A record Exerly writes to Health: one food entry, weigh-in or workout.
public protocol HealthRecord: Sendable, Codable, Hashable, Identifiable where ID == UUID {
    static var kind: HealthRecordKind { get }
    /// When it happened, to tell whether it falls after writing was turned on.
    var at: Date { get }
}

extension HealthRecord {
    /// A digest of everything written, the same on every launch and device,
    /// so a changed record is told apart from one already written.
    public var fingerprint: String {
        // Encoding plain values can't fail; an empty digest would only force a rewrite.
        let bytes = (try? ExerlyJSON.canonical(self)) ?? Data()
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}

/// A food entry as Health holds it: one food correlation of dietary samples.
public struct HealthFoodRecord: HealthRecord {
    public static let kind = HealthRecordKind.food
    /// The entry's ID.
    public var id: UUID
    public var name: String
    public var meal: String
    /// When it was eaten; see `eatenAt`.
    public var at: Date
    /// The IANA zone the day is counted in.
    public var timeZone: String
    /// Amounts above zero of the nutrients Health has a type for, sorted by type.
    public var quantities: [HealthQuantity]

    /// The entry as Health holds it, or nil when it reports nothing Health
    /// can hold or came from Health.
    public init?(entry: FoodEntry, timeZone: TimeZone) {
        // Read from Health: Health stays its source.
        guard !entry.food.foodID.hasPrefix(HealthHistory.foodIDPrefix) else { return nil }
        let nutrients = entry.nutrients
        let quantities = Nutrient.healthWritable.compactMap { nutrient -> HealthQuantity? in
            guard let type = nutrient.healthType, let value = nutrients[nutrient], value.isFinite, value > 0 else { return nil }
            return HealthQuantity(type: type, value: value, unit: nutrient.healthUnit)
        }.sorted { $0.type < $1.type }
        guard !quantities.isEmpty else { return nil }
        id = entry.id
        name = entry.food.name
        meal = entry.meal
        at = Self.eatenAt(entry, timeZone: timeZone)
        self.timeZone = timeZone.identifier
        self.quantities = quantities
    }

    /// When an entry was eaten: when it was logged, if that was on the day it
    /// counts for; otherwise a usual time for its meal on that day, so an entry
    /// logged late, or moved to another day, lands on its own day in Health.
    public static func eatenAt(_ entry: FoodEntry, timeZone: TimeZone) -> Date {
        if LocalDate(entry.loggedAt, in: timeZone) == entry.date { return entry.loggedAt }
        let (hour, minute) = NutritionStore.typicalTime(of: entry.meal)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = entry.date
        return calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day, hour: hour, minute: minute))!
            .roundedToMilliseconds
    }
}

/// A weigh-in entered in Exerly, as Health holds it: a body mass sample, and a
/// body fat percentage sample when the weigh-in has one.
public struct HealthWeightRecord: HealthRecord {
    public static let kind = HealthRecordKind.weight
    public var id: UUID
    public var at: Date
    /// The weight in the unit it was entered in, so Health shows it unchanged.
    public var weight: HealthQuantity
    /// Body fat as Health stores it, a fraction: 0.185 for 18.5 %.
    public var bodyFatFraction: Double?
    public var timeZone: String

    /// Nil for a weigh-in read from Health: Health stays its source, and
    /// writing it back would add a copy.
    public init?(entry: WeightEntry, timeZone: TimeZone) {
        guard entry.source == nil else { return nil }
        id = entry.id
        at = entry.at
        weight = HealthQuantity(type: "HKQuantityTypeIdentifierBodyMass", value: entry.weight.value,
                                unit: entry.weight.unit == .pounds ? .pounds : .kilograms)
        bodyFatFraction = entry.bodyFat.map { $0 / 100 }
        self.timeZone = timeZone.identifier
    }
}

/// A finished workout, as Health holds it: a traditional strength training
/// workout with its start, end and duration.
public struct HealthWorkoutRecord: HealthRecord {
    public static let kind = HealthRecordKind.workout
    public var id: UUID
    public var start: Date
    public var end: Date
    public var timeZone: String
    public var at: Date { start }

    /// Nil for a workout still in progress, or one with no duration.
    public init?(session: WorkoutSession) {
        guard let end = session.endedAt, end > session.startedAt else { return nil }
        id = session.id
        start = session.startedAt
        self.end = end
        timeZone = session.timeZoneID
    }
}

/// What Exerly has written to Health for one account: each record's
/// fingerprint when it was written. It turns the records Exerly holds now
/// into the smallest set of changes, so writing is idempotent: one sample set
/// per record, replaced when the record changes, removed when it's deleted,
/// and nothing written twice when a sync is retried.
public struct HealthWriteLedger: Sendable, Codable, Hashable {
    /// Fingerprints by kind, then by record ID.
    public private(set) var written: [HealthRecordKind: [String: String]] = [:]

    public init() {}

    public func contains(_ kind: HealthRecordKind, _ id: UUID) -> Bool { written[kind]?[id.uuidString] != nil }

    public func count(_ kind: HealthRecordKind) -> Int { written[kind]?.count ?? 0 }

    /// The changes that bring Health in line with `records`, every record of
    /// the kind Exerly holds now. Records from `start` on are written; earlier
    /// ones only when they were written before (and changed since). A record
    /// that changed is removed, then written again; one that's gone is removed.
    /// `fingerprint` lets a caller reuse digests it already has.
    public func changes<R: HealthRecord>(for records: [R], since start: Date,
                                         fingerprint: (R) -> String = { $0.fingerprint }) -> HealthWriteChanges<R> {
        let ledger = written[R.kind] ?? [:]
        var changes = HealthWriteChanges<R>()
        var held = Set<String>()
        for record in records.sorted(by: { ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) }) {
            let key = record.id.uuidString
            guard held.insert(key).inserted else { continue }
            if let written = ledger[key] {
                guard written != fingerprint(record) else { continue }
                changes.remove.append(record.id)
                changes.write.append(record)
            } else if record.at >= start {
                changes.write.append(record)
            }
        }
        changes.remove += ledger.keys.filter { !held.contains($0) }.sorted().compactMap(UUID.init(uuidString:))
        return changes
    }

    /// Records that samples were removed from Health.
    public mutating func removed(_ kind: HealthRecordKind, _ ids: [UUID]) {
        for id in ids { written[kind]?[id.uuidString] = nil }
    }

    /// Records that these records were written to Health as they are now.
    public mutating func wrote<R: HealthRecord>(_ records: [R]) {
        for record in records { written[R.kind, default: [:]][record.id.uuidString] = record.fingerprint }
    }
}

public struct HealthWriteChanges<R: HealthRecord>: Sendable {
    /// Records whose samples come out of Health first: deleted, or changed.
    public var remove: [UUID] = []
    /// Records to write: new, or changed.
    public var write: [R] = []

    public var isEmpty: Bool { remove.isEmpty && write.isEmpty }
}
