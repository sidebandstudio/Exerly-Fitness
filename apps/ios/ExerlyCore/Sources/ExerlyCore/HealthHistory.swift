import CryptoKit
import Foundation

/// A food another app saved to Apple Health: one food correlation and the
/// nutrients in it. Exerly's own are left out before this.
public struct HealthFoodReading: Sendable, Hashable, Codable {
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
public struct HealthWorkoutReading: Sendable, Hashable, Codable {
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
    /// Imports Health deleted, taken out.
    public var removing = 0
    /// Imports a better source now covers, taken out until it goes.
    public var displacing = 0
    /// Imports put back because the better source's record went.
    public var restoring = 0
    /// Imports no longer in Health, with no deletion: kept unless they choose.
    public var missing = 0
    /// Better sources' records held back, as adding them would set aside
    /// what's in Exerly: they wait in Changes from Health.
    public var deferred = 0
    /// Imports another install made, or that have no record, of samples this
    /// phone's Health has: theirs to keep as this iPhone's.
    public var adoptable = 0
    /// Records dated outside the days Exerly keeps, never imported.
    public var outside = 0
    /// The first and last day of what would be added.
    public var first: LocalDate?
    public var last: LocalDate?
    /// Best first.
    public var sources: [Source] = []

    public init() {}

    public var isEmpty: Bool { adding + removing + displacing + restoring == 0 }
}

/// What reading Health would change. Read automatically (`deferring`),
/// only additions: Health's deletions, a better source over what's in
/// Exerly, and what a full read no longer finds wait for the person in
/// Changes from Health, and applying those plans everything again.
public struct HealthImportPlan<Reading> {
    public var preview: HealthHistoryPreview
    public var adding: [Reading]
    /// Unchanged imports Health deleted, and set-aside ones.
    public var removing: [UUID]
    /// Unchanged imports a better source now covers.
    public var displacing: [UUID]
    /// Displaced imports whose better source went.
    public var restoring: [UUID]
    /// This install's imports a full read no longer finds, with no deletion.
    public var missing: [UUID]
    /// Imports this install could adopt: another's, or entries with no record.
    public var adoptable: [UUID]
    /// Better sources' readings held back while `deferring`, as adding them
    /// would set aside what's in Exerly.
    public var deferred: [Reading] = []
    /// The day or time each added, set aside or restored record counts
    /// toward, so their changes are made, or dropped, together.
    public var groups: [UUID: Int] = [:]
}

/// What a reading is, for grouping and priority.
public struct HealthItem: Sendable, Hashable {
    public var id: UUID
    public var source: String
    public var sourceName: String
    public var start: Date
    public var end: Date
    public var day: LocalDate

    public init(id: UUID, source: String, sourceName: String, start: Date, end: Date, day: LocalDate) {
        self.id = id
        self.source = source
        self.sourceName = sourceName
        self.start = start
        self.end = end
        self.day = day
    }

    init(_ record: HealthImport) {
        self.init(id: record.id, source: record.source, sourceName: record.sourceName, start: record.start, end: record.end, day: record.day)
    }
}

public enum HealthHistory {
    /// How records count as the same: food by day, workouts by overlapping time.
    public enum Grouping: Sendable { case day, overlap }

    /// What Health's changes mean for Exerly, against the account's synced
    /// records. `added` and `deleted` come from an anchored read, or `added`
    /// is everything when `full`. `live` holds the records whose entry or
    /// activity is still in Exerly, `changed` those they've changed since
    /// import, and `untracked` the readings already in Exerly with no record.
    /// `deferring`, as Health is read with no one choosing, nothing is taken
    /// out, set aside or put back: Health's deletions are only listed, and a
    /// day or time where a new record would set aside one in Exerly holds
    /// that record back (`deferred`). Applied by choice, everything is, by
    /// whichever install owned it, except what they've changed.
    public static func plan<T>(added: [T], deleted: Set<UUID> = [], full: Bool, records: [HealthImport], install: String,
                               live: Set<UUID>, changed: Set<UUID>, untracked: Set<UUID> = [], grouping: Grouping,
                               within: ClosedRange<LocalDate>? = nil, preferred: [String] = [], deferring: Bool = false,
                               item: (T) -> HealthItem) -> HealthImportPlan<T> {
        let known = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mine = { (record: HealthImport) in record.owner == install }
        // Health's deletions of imports as imported, or set aside.
        var removing: [UUID] = []
        for id in deleted.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let record = known[id] else { continue }
            if record.state == .displaced || (record.state == .imported && (!live.contains(id) || !changed.contains(id))) { removing.append(id) }
        }
        let gone = deferring ? [] : Set(removing)
        let present = Set(added.map { item($0).id })
        var outside = 0
        var fresh: [T] = []
        for reading in added where known[item(reading).id] == nil && !untracked.contains(item(reading).id) {
            if let within, !within.contains(item(reading).day) { outside += 1 } else { fresh.append(reading) }
        }
        // What counts for a day or time: what's in Exerly, what's set aside to come back, and what's new.
        let held = records.filter { record in
            !gone.contains(record.id) && (record.state == .displaced || (record.state == .imported && live.contains(record.id)))
        }
        var members = held.map { (item: HealthItem($0), record: Optional($0), reading: T?.none) }
            + fresh.map { (item: item($0), record: HealthImport?.none, reading: Optional($0)) }
        members.sort { ($0.item.start, $0.item.id.uuidString) < ($1.item.start, $1.item.id.uuidString) }
        var group: [UUID: Int] = [:]
        switch grouping {
        case .day:
            var days: [LocalDate: Int] = [:]
            for member in members {
                if days[member.item.day] == nil { days[member.item.day] = days.count }
                group[member.item.id] = days[member.item.day]
            }
        case .overlap:
            var current = -1, reach = Date.distantPast
            for member in members {
                if member.item.start >= reach { current += 1 }
                reach = max(reach, member.item.end)
                group[member.item.id] = current
            }
        }
        let order = HealthSourcePriority.order(Dictionary(members.map { ($0.item.source, 1) }, uniquingKeysWith: +), preferred: preferred)
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        var adding: [T] = [], displacing: [UUID] = [], restoring: [UUID] = [], leftOut: [T] = [], deferred: [T] = []
        var groups: [UUID: Int] = [:]
        for (index, those) in Dictionary(grouping: members, by: { group[$0.item.id] ?? 0 }) {
            let best = those.map(\.item.source).min { rank[$0, default: .max] < rank[$1, default: .max] }
            let worse = those.filter { $0.item.source != best }
            // A day or time held by one they changed stays as it is.
            let frozen = worse.contains { member in
                guard let record = member.record, record.state == .imported else { return false }
                return changed.contains(record.id)
            }
            var adds: [T] = [], aside: [UUID] = [], back: [UUID] = []
            for member in those {
                switch (member.record, member.reading) {
                case (nil, let reading?):
                    if !frozen, member.item.source == best { adds.append(reading) } else { leftOut.append(reading) }
                case (let record?, _) where !frozen:
                    if record.state == .imported, member.item.source != best { aside.append(record.id) }
                    if record.state == .displaced, member.item.source == best { back.append(record.id) }
                default: break
                }
            }
            if deferring, !aside.isEmpty || !back.isEmpty {
                // Adding these would set aside or bring back what's in Exerly: that waits for them to choose.
                deferred += adds
            } else {
                (adding, displacing, restoring) = (adding + adds, displacing + aside, restoring + back)
                for id in adds.map({ item($0).id }) + aside + back { groups[id] = index }
            }
        }
        adding.sort { (item($0).start, item($0).id.uuidString) < (item($1).start, item($1).id.uuidString) }
        var missing: [UUID] = [], adoptable: [UUID] = []
        if full {
            for record in records where record.state == .imported && live.contains(record.id) && !gone.contains(record.id) {
                if mine(record) { if !present.contains(record.id) { missing.append(record.id) } } else if present.contains(record.id) {
                    adoptable.append(record.id)
                }
            }
            adoptable += untracked.intersection(present)
        }
        let sorted = { (ids: [UUID]) in ids.sorted { $0.uuidString < $1.uuidString } }
        var preview = HealthHistoryPreview()
        preview.adding = adding.count
        preview.alreadyIn = held.filter { $0.state == .imported && (!full || present.contains($0.id)) }.count
            + untracked.intersection(present).count
        preview.leftOut = leftOut.count
        preview.removing = removing.count
        preview.displacing = displacing.count
        preview.restoring = restoring.count
        preview.missing = missing.count
        preview.deferred = deferred.count
        preview.adoptable = adoptable.count
        preview.outside = outside
        let days = adding.map { item($0).day }
        preview.first = days.min()
        preview.last = days.max()
        let addingIDs = Set(adding.map { item($0).id }), leftOutIDs = Set(leftOut.map { item($0).id })
        let names = Dictionary(members.map { ($0.item.source, $0.item.sourceName) }, uniquingKeysWith: { first, _ in first })
        preview.sources = order.compactMap { key in
            let theirs = fresh.map(item).filter { $0.source == key }
            guard !theirs.isEmpty else { return nil }
            return .init(name: names[key] ?? key, adding: theirs.filter { addingIDs.contains($0.id) }.count,
                         leftOut: theirs.filter { leftOutIDs.contains($0.id) }.count)
        }
        deferred.sort { (item($0).start, item($0).id.uuidString) < (item($1).start, item($1).id.uuidString) }
        return HealthImportPlan(preview: preview, adding: adding, removing: removing, displacing: sorted(displacing),
                                restoring: sorted(restoring), missing: sorted(missing), adoptable: sorted(adoptable),
                                deferred: deferred, groups: groups)
    }

    public static func item(_ food: HealthFoodReading, timeZone: TimeZone) -> HealthItem {
        HealthItem(id: food.id, source: food.source, sourceName: food.sourceName, start: food.at, end: food.at,
                   day: LocalDate(food.at, in: food.timeZone ?? timeZone))
    }

    public static func item(_ workout: HealthWorkoutReading, timeZone: TimeZone) -> HealthItem {
        HealthItem(id: workout.id, source: workout.source, sourceName: workout.sourceName, start: workout.start, end: workout.end,
                   day: LocalDate(workout.start, in: workout.timeZone ?? timeZone))
    }

    /// Weigh-ins from Health: every reading, as the weigh-in switch imports
    /// them, counted by source.
    public static func weights(_ readings: [(weight: HealthWeight, source: String)], existing: Set<UUID>,
                               timeZone: TimeZone) -> HealthHistoryPreview {
        var preview = HealthHistoryPreview()
        let adding = readings.filter { !existing.contains($0.weight.id) }
        preview.adding = adding.count
        preview.alreadyIn = readings.count - adding.count
        let days = adding.map { LocalDate($0.weight.at, in: $0.weight.timeZone ?? timeZone) }
        preview.first = days.min()
        preview.last = days.max()
        let order = HealthSourcePriority.order(Dictionary(readings.map { ($0.source, 1) }, uniquingKeysWith: +))
        preview.sources = order.map { name in
            .init(name: name, adding: adding.filter { $0.source == name }.count, leftOut: 0)
        }
        return preview
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
    /// The entry a food from Health becomes: its Health ID, the meal the
    /// clock gives at its time, never written back to Health (see `HealthFoodRecord`).
    static func entry(for reading: HealthFoodReading, timeZone: TimeZone) -> FoodEntry {
        let zone = reading.timeZone ?? timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: reading.at)
        let name = reading.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Food from \(reading.sourceName)"
        var food = FoodSnapshot(foodID: HealthHistory.foodID(source: reading.source, name: name), name: name,
                                brand: reading.sourceName, source: .imported, per100g: reading.nutrients)
        food.unweighed = true
        let at = reading.at.roundedToMilliseconds
        return FoodEntry(id: reading.id, date: LocalDate(at, in: zone), meal: meal(atMinute: (parts.hour ?? 12) * 60 + (parts.minute ?? 0)),
                         loggedAt: at, food: food, grams: 100)
    }

    /// Adds foods read from Health as entries, all or none, published once.
    /// Each keeps its Health ID, so importing again adds nothing; `deleted`
    /// takes out entries imported from Health.
    @discardableResult
    public func importHealthFoods(_ readings: [HealthFoodReading], deleted: [UUID] = [], timeZone: TimeZone) throws -> Int {
        let known = Set(entries.map(\.id))
        var writes = deleted.filter { id in
            entries.contains { $0.id == id && $0.food.foodID.hasPrefix(HealthHistory.foodIDPrefix) }
        }.map { DocumentWrite(kind: Self.entryKind, id: $0.uuidString, payload: nil) }
        for reading in readings where !known.contains(reading.id) && !deleted.contains(reading.id) {
            writes.append(DocumentWrite(kind: Self.entryKind, id: reading.id.uuidString,
                                        payload: try ExerlyJSON.canonical(Self.entry(for: reading, timeZone: timeZone))))
        }
        guard !writes.isEmpty else { return 0 }
        try persistence.performAtomically {
            persistence.afterCommit(try prepareWrites(kind: Self.entryKind, writes))
        }
        return writes.filter { $0.payload != nil }.count
    }
}
