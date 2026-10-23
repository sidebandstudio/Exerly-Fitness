import CryptoKit
import Foundation

/// A food another app saved to Apple Health: one food correlation and the
/// nutrients in it. Exerly's own are left out before this.
public struct HealthFoodReading: Sendable, Hashable {
    /// The correlation's UUID, which becomes the entry's ID.
    public var id: UUID
    public var at: Date
    public var name: String?
    public var nutrients: NutrientAmounts
    public var source: String
    /// The app's name as Health shows it.
    public var sourceName: String
    public var timeZone: TimeZone?

    public init(id: UUID, at: Date, name: String?, nutrients: NutrientAmounts, source: String, sourceName: String,
                timeZone: TimeZone? = nil) {
        self.id = id
        self.at = at
        self.name = name
        self.nutrients = nutrients
        self.source = source
        self.sourceName = sourceName
        self.timeZone = timeZone
    }
}

/// A workout another app or device saved to Apple Health.
public struct HealthWorkoutReading: Sendable, Hashable {
    public var id: UUID
    public var start: Date
    public var end: Date
    /// What kind it was, in words: "Running".
    public var activity: String
    public var kilocalories: Double?
    public var source: String
    public var sourceName: String
    public var timeZone: TimeZone?

    public init(id: UUID, start: Date, end: Date, activity: String, kilocalories: Double?, source: String, sourceName: String,
                timeZone: TimeZone? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.activity = activity
        self.kilocalories = kilocalories
        self.source = source
        self.sourceName = sourceName
        self.timeZone = timeZone
    }

    public var minutes: Double { end.timeIntervalSince(start) / 60 }
}

/// What importing history from Health would do, shown before anything is
/// saved.
public struct HealthHistoryPreview: Sendable, Hashable {
    public struct Source: Sendable, Hashable {
        public var name: String
        /// Records it would add.
        public var adding: Int
        /// Records set aside because a better source covered the same day or time.
        public var leftOut: Int
    }

    /// Records that would be added.
    public var adding = 0
    /// Records already in Exerly from an earlier import.
    public var alreadyIn = 0
    /// Records set aside by source priority.
    public var leftOut = 0
    /// Records imported earlier to take out: deleted in Health, or now set
    /// aside for a better source's.
    public var removing = 0
    /// Records dated outside the days Exerly keeps, never imported.
    public var outside = 0
    /// The first and last day of what would be added.
    public var first: LocalDate?
    public var last: LocalDate?
    /// Best first.
    public var sources: [Source] = []

    public init() {}

    public var isEmpty: Bool { adding == 0 && removing == 0 }
}

/// What reading Health would change, and what this install has imported
/// once it's done.
public struct HealthHistoryPlan<Reading> {
    public var preview: HealthHistoryPreview
    public var adding: [Reading]
    /// Imported records to take out, by Health ID.
    public var removing: [UUID]
    /// The Health IDs imported here and still in Health or Exerly, to save
    /// once the changes are made. An entry deleted in Exerly stays in it, so
    /// it isn't added back.
    public var imported: Set<UUID>
}

public enum HealthHistory {
    /// Foods from Health to import, from everything Health has now: each
    /// day's from its best source only, so two apps that both saved the same
    /// meals don't count them twice. `existing` is every Health ID with an
    /// entry in Exerly, from any device; `imported`, those this install
    /// imported. An imported entry whose food is gone from Health, or whose
    /// day a better source now covers, is taken out, unless it's `locked`
    /// because the person changed it.
    public static func foods(_ readings: [HealthFoodReading], existing: Set<UUID>, imported: Set<UUID> = [], locked: Set<UUID> = [],
                             timeZone: TimeZone, preferred: [String] = []) -> HealthHistoryPlan<HealthFoodReading> {
        let day = { (food: HealthFoodReading) in LocalDate(food.at, in: food.timeZone ?? timeZone) }
        return plan(readings, existing: existing, imported: imported, locked: locked, preferred: preferred, id: \.id, source: \.source,
                    sourceName: \.sourceName, day: day, group: day)
    }

    /// Workouts from Health to import, in the same way: of workouts that
    /// overlap in time, only those from the best source, so a watch and a
    /// running app recording one run add it once. Those dated outside
    /// `within` are set aside.
    public static func workouts(_ readings: [HealthWorkoutReading], existing: Set<UUID>, imported: Set<UUID> = [], timeZone: TimeZone,
                                within: ClosedRange<LocalDate>? = nil,
                                preferred: [String] = []) -> HealthHistoryPlan<HealthWorkoutReading> {
        let day = { (workout: HealthWorkoutReading) in LocalDate(workout.start, in: workout.timeZone ?? timeZone) }
        // Overlapping workouts share the group of the first one in their run of overlaps.
        let sorted = readings.sorted { $0.start < $1.start }
        var group: [UUID: Int] = [:]
        var current = -1, reach = Date.distantPast
        for workout in sorted {
            if workout.start >= reach { current += 1 }
            reach = max(reach, workout.end)
            group[workout.id] = current
        }
        return plan(sorted, existing: existing, imported: imported, locked: [], preferred: preferred, id: \.id, source: \.source,
                    sourceName: \.sourceName, day: day, group: { group[$0.id] ?? 0 }, eligible: { within?.contains(day($0)) ?? true })
    }

    /// Weigh-ins from Health: every reading, as the weigh-in switch imports
    /// them, counted by source.
    public static func weights(_ readings: [(weight: HealthWeight, source: String)], existing: Set<UUID>,
                               timeZone: TimeZone) -> HealthHistoryPreview {
        plan(readings, existing: existing, imported: [], locked: [], preferred: [], id: \.weight.id, source: \.source,
             sourceName: \.source, day: { LocalDate($0.weight.at, in: $0.weight.timeZone ?? timeZone) }, group: { $0.weight.id }).preview
    }

    private static func plan<T, Group: Hashable>(_ readings: [T], existing: Set<UUID>, imported: Set<UUID>, locked: Set<UUID>,
                                                 preferred: [String], id: (T) -> UUID, source: (T) -> String,
                                                 sourceName: (T) -> String, day: (T) -> LocalDate, group: (T) -> Group,
                                                 eligible: (T) -> Bool = { _ in true }) -> HealthHistoryPlan<T> {
        let allowed = readings.filter(eligible)
        let order = HealthSourcePriority.order(Dictionary(allowed.map { (source($0), 1) }, uniquingKeysWith: +), preferred: preferred)
        let kept = HealthSourcePriority.resolve(allowed, order: order, source: source, group: group).kept
        let keptIDs = Set(kept.map(id)), present = Set(readings.map(id)), allowedIDs = Set(allowed.map(id))
        // What's in Exerly and still in this phone's Health was imported here,
        // even by an earlier install.
        let mine = imported.union(existing.intersection(present))
        let adding = kept.filter { !existing.contains(id($0)) && !mine.contains(id($0)) }
        // One set aside by its date stays as it was imported.
        let removing = mine.intersection(existing).subtracting(keptIDs).subtracting(locked)
            .filter { allowedIDs.contains($0) || !present.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        var preview = HealthHistoryPreview()
        preview.adding = adding.count
        preview.alreadyIn = kept.filter { existing.contains(id($0)) }.count
        preview.leftOut = allowed.count - kept.count
        preview.removing = removing.count
        preview.outside = readings.count - allowed.count
        let days = adding.map(day)
        preview.first = days.min()
        preview.last = days.max()
        let names = Dictionary(allowed.map { (source($0), sourceName($0)) }, uniquingKeysWith: { first, _ in first })
        let addingIDs = Set(adding.map(id))
        preview.sources = order.map { key in
            let theirs = allowed.filter { source($0) == key }
            return .init(name: names[key] ?? key, adding: theirs.filter { addingIDs.contains(id($0)) }.count,
                         leftOut: theirs.filter { !keptIDs.contains(id($0)) }.count)
        }
        let tracked = mine.union(addingIDs).subtracting(removing).intersection(present.union(existing))
        return HealthHistoryPlan(preview: preview, adding: adding, removing: removing, imported: tracked)
    }

    /// The activity a Health workout becomes for an account: the same on
    /// every install, so importing again after a reinstall, or on another
    /// phone sharing the Health data, finds it instead of adding it twice.
    public static func activityID(for workout: UUID, accountID: String) -> String {
        var bytes = Array(SHA256.hash(data: Data("health.workout\n\(accountID)\n\(workout.uuidString)".utf8)).prefix(16))
        bytes[6] = bytes[6] & 0x0F | 0x50 // a name-based UUID
        bytes[8] = bytes[8] & 0x3F | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10],
                           bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString.lowercased()
    }

    /// The food ID an imported food logs under: one per source and name, so
    /// the same food from the same app is one recent food.
    public static func foodID(source: String, name: String) -> String {
        let key = source + "\n" + name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return foodIDPrefix + SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    public static let foodIDPrefix = "health:"
}

extension NutritionStore {
    /// Adds foods read from Health as entries, all or none. Each keeps its
    /// Health ID, so importing again adds nothing; a food deleted in Health
    /// removes its entry. Its meal is the one the clock gives at its time,
    /// and it's never written back to Health (see `HealthFoodRecord`).
    @discardableResult
    public func importHealthFoods(_ readings: [HealthFoodReading], deleted: [UUID] = [], timeZone: TimeZone) throws -> Int {
        let known = Set(entries.map(\.id))
        var writes: [(UUID, FoodEntry?)] = deleted.filter { id in
            entries.contains { $0.id == id && $0.food.foodID.hasPrefix(HealthHistory.foodIDPrefix) }
        }.map { ($0, nil) }
        for reading in readings where !known.contains(reading.id) && !deleted.contains(reading.id) {
            let zone = reading.timeZone ?? timeZone
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let parts = calendar.dateComponents([.hour, .minute], from: reading.at)
            let name = reading.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Food from \(reading.sourceName)"
            var food = FoodSnapshot(foodID: HealthHistory.foodID(source: reading.source, name: name), name: name,
                                    brand: reading.sourceName, source: .imported, per100g: reading.nutrients)
            food.unweighed = true
            let at = reading.at.roundedToMilliseconds
            writes.append((reading.id, FoodEntry(id: reading.id, date: LocalDate(at, in: zone),
                                                 meal: Self.meal(atMinute: (parts.hour ?? 12) * 60 + (parts.minute ?? 0)),
                                                 loggedAt: at, food: food, grams: 100)))
        }
        guard !writes.isEmpty else { return 0 }
        var publish: [() -> Void] = []
        try persistence.performAtomically {
            publish = try writes.map { try prepareWrite(kind: Self.entryKind, id: $0.0.uuidString, payload: $0.1.map(ExerlyJSON.canonical)) }
        }
        publish.forEach { $0() }
        return writes.filter { $0.1 != nil }.count
    }
}
