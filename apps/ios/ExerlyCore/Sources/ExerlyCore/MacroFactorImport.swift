import Foundation

/// What a MacroFactor import adds: before saving, as a preview, and after.
public struct MacroFactorImportSummary: Sendable, Hashable {
    /// The kinds of document, in the order they're saved.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case foods, entries, dayTotals, days, weights, plans, workouts
    }

    public struct Count: Sendable, Hashable {
        /// Documents the import adds, or days whose status or notes it sets.
        public var new = 0
        /// Already in Exerly, from an earlier import or as the same reading,
        /// and left as they are.
        public var existing = 0
    }

    public var counts: [Kind: Count] = [:]
    public var dateRange: ClosedRange<LocalDate>?
    /// Day totals from an earlier import that this file's food log replaces.
    public var replacedDayTotals = 0
    public var report: MacroFactorReport
    /// Kinds that failed to save, with why. Nothing of a failed kind was saved.
    public var failures: [Kind: String] = [:]

    public subscript(_ kind: Kind) -> Count { counts[kind] ?? Count() }
    /// Everything the import adds or sets.
    public var additions: Int { counts.values.reduce(0) { $0 + $1.new } + replacedDayTotals }
}

/// A `MacroFactorExport` checked against what Exerly already has, ready to
/// save through the stores so it syncs like anything logged in Exerly.
///
/// Documents already in Exerly are left as they are, so importing a file
/// twice changes nothing, and an imported entry edited or deleted since stays
/// that way until the file is imported again. Also kept: a day's status or
/// notes once set, a weigh-in within 0.1 kg of one on the same day (from
/// Apple Health, say), food on days Exerly already has food for, and Exerly's
/// own targets: plan versions start only before Exerly's first one.
@MainActor
public struct MacroFactorImport {
    public typealias Kind = MacroFactorImportSummary.Kind

    public let export: MacroFactorExport
    public private(set) var summary: MacroFactorImportSummary
    private var foods: [Food] = []
    private var entries: [FoodEntry] = []
    private var removedTotals: [UUID] = []
    private var totals: [FoodEntry] = []
    private var days: [NutritionDay] = []
    private var weights: [WeightEntry] = []
    private var plans: [NutritionPlan] = []
    private var sessions: [WorkoutSession] = []

    public init(_ export: MacroFactorExport, nutrition: NutritionStore, training: TrainingStore) {
        self.export = export
        summary = MacroFactorImportSummary(dateRange: export.dateRange, report: export.report)
        func count(_ kind: Kind, new: Bool) {
            if new { summary.counts[kind, default: .init()].new += 1 } else { summary.counts[kind, default: .init()].existing += 1 }
        }

        let foodIDs = Set(nutrition.foods.map(\.id))
        for food in export.foods {
            let new = !foodIDs.contains(food.id)
            if new { foods.append(food) }
            count(.foods, new: new)
        }

        let entryIDs = Set(nutrition.entries.map(\.id))
        for entry in export.entries {
            let new = !entryIDs.contains(entry.id)
            if new { entries.append(entry) }
            count(.entries, new: new)
        }
        removedTotals = Set(export.entries.map(\.date)).sorted().map(MacroFactorExport.dayTotalID).filter(entryIDs.contains)
        summary.replacedDayTotals = removedTotals.count

        var covered = 0
        let logged = Dictionary(grouping: nutrition.entries, by: \.date)
        for total in export.dayTotals {
            let others = (logged[total.date] ?? []).contains { $0.id != total.id }
            let new = !entryIDs.contains(total.id) && !others
            if new { totals.append(total) }
            if others && !entryIDs.contains(total.id) { covered += 1 }
            count(.dayTotals, new: new)
        }
        if covered > 0 {
            summary.report.assumptions.append("\(covered) \(covered == 1 ? "day" : "days") already had food in Exerly, so MacroFactor's totals for them were left out.")
        }

        for record in export.days {
            let current = nutrition.day(record.date)
            var day = current
            if let status = record.status, current.status == .unlogged { day.status = status }
            if let notes = record.notes, current.notes.isEmpty { day.notes = notes }
            let new = day != current
            if new { days.append(day) }
            count(.days, new: new)
        }

        let weightIDs = Set(nutrition.weights.map(\.id))
        let weighed = Dictionary(grouping: nutrition.weights, by: \.date)
        for weight in export.weights {
            let new = !weightIDs.contains(weight.id)
                && !(weighed[weight.date] ?? []).contains { abs($0.weight.kilograms - weight.weight.kilograms) < 0.1 }
            if new { weights.append(weight) }
            count(.weights, new: new)
        }

        let planIDs = Set(export.plans.map(\.id))
        let ownStart = nutrition.plans.filter { !planIDs.contains($0.id) }.map(\.startDate).min()
        for plan in export.plans {
            if nutrition.plans.contains(where: { $0.id == plan.id }) {
                count(.plans, new: false)
            } else if let ownStart, plan.startDate >= ownStart {
                summary.report.skipped.append(.init(sheet: "Nutrition program", row: nil,
                    reason: "The program from \(plan.startDate) starts after your Exerly targets do (\(ownStart)), so Exerly's are kept"))
            } else {
                plans.append(plan)
                count(.plans, new: true)
            }
        }

        for session in export.sessions {
            let new = training.history.session(session.id) == nil && training.activeSession?.id != session.id
            if new { sessions.append(session) }
            count(.workouts, new: new)
        }
    }

    /// The kinds with something to save, in saving order.
    public var steps: [Kind] {
        Kind.allCases.filter { kind in
            switch kind {
            case .foods: !foods.isEmpty
            case .entries: !entries.isEmpty || !removedTotals.isEmpty
            case .dayTotals: !totals.isEmpty
            case .days: !days.isEmpty
            case .weights: !weights.isEmpty
            case .plans: !plans.isEmpty
            case .workouts: !sessions.isEmpty
            }
        }
    }

    /// Every document the import writes, with what it expects to replace.
    public func writes(nutrition: NutritionStore) throws -> [PlannedWrite] {
        func add<T: Encodable>(_ kind: String, _ id: String, _ value: T) throws -> PlannedWrite {
            PlannedWrite(kind: kind, id: id, before: nil, after: try ExerlyJSON.canonical(value))
        }
        // A day's foods and the daily total they replace are saved, and undone, together.
        func day(_ date: LocalDate) -> String { "food/\(date)" }
        var writes: [PlannedWrite] = []
        writes += try foods.map { try add(NutritionStore.foodKind, $0.id, $0) }
        writes += try entries.map { entry in
            var write = try add(NutritionStore.entryKind, entry.id.uuidString, entry)
            write.group = day(entry.date)
            return write
        }
        writes += try removedTotals.map { id in
            let before = try nutrition.payload(kind: NutritionStore.entryKind, id: id.uuidString)
            let date = before.flatMap { try? ExerlyJSON.decoder.decode(FoodEntry.self, from: $0) }?.date
            return PlannedWrite(kind: NutritionStore.entryKind, id: id.uuidString, before: before, after: nil, group: date.map(day))
        }
        writes += try totals.map { try add(NutritionStore.entryKind, $0.id.uuidString, $0) }
        writes += try days.map { day in
            PlannedWrite(kind: NutritionStore.dayKind, id: day.id, before: try nutrition.payload(kind: NutritionStore.dayKind, id: day.id),
                         after: try ExerlyJSON.canonical(day))
        }
        writes += try weights.map { try add(NutritionStore.weightKind, $0.id.uuidString, $0) }
        writes += try plans.map { try add(NutritionStore.planKind, $0.id.uuidString, $0) }
        writes += try sessions.map { try add(TrainingStore.sessionKind, $0.id.uuidString, $0) }
        return writes
    }

    /// Saves everything as one unit through `HistoryImporter`: all of it, or
    /// nothing, with every kind reported as failed.
    @discardableResult
    public func save(nutrition: NutritionStore, training: TrainingStore) -> MacroFactorImportSummary {
        var result = summary
        do {
            var plan = HistoryImportPlan(source: .macroFactor, files: [], timeZone: .gmt)
            plan.writes = try writes(nutrition: nutrition)
            try HistoryImporter(hosts: [nutrition, training], persistence: nutrition.persistence).commit(plan)
        } catch {
            for kind in steps { result.failures[kind] = HistoryImporter.describe(error) }
        }
        return result
    }
}
