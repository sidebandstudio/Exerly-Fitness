import Foundation

/// Reads exported history from MacroFactor, MacroFactor Workouts, Hevy,
/// Strong or Exerly itself into a `HistoryImportPlan`, in two steps: `read`
/// parses the files and can run off the main thread; `plan` checks the
/// result against the stores. PARITY I12, I13 and I14.
public enum HistoryImportReader {
    public struct Options: Sendable, Hashable {
        /// The account's zone: exported times have none, so they're read in it.
        public var timeZone: TimeZone
        /// The unit for weights the file doesn't give a unit for.
        public var unit: MassUnit
        /// The exercise for a name in the file, ahead of matching by name.
        public var mapping: [String: ExerciseID]
        /// Names whose sets are left out.
        public var leftOut: Set<String>

        public init(timeZone: TimeZone, unit: MassUnit, mapping: [String: ExerciseID] = [:], leftOut: Set<String> = []) {
            self.timeZone = timeZone
            self.unit = unit
            self.mapping = mapping
            self.leftOut = leftOut
        }
    }

    public enum ReadError: Error, Equatable {
        /// None of the formats: what was found instead.
        case unrecognized(String)
        /// Files of more than one app chosen together.
        case mixed([ImportSource])
    }

    /// What `read` found, ready for `plan`.
    public enum Parsed: Sendable {
        case macroFactor(MacroFactorExport, workoutsOnly: Bool)
        case workouts(WorkoutImport.Result)
        case measurements(MeasurementImport.Result)
        case exerly(ExerlyExportFile)

        public var source: ImportSource {
            switch self {
            case .macroFactor(_, let workoutsOnly): workoutsOnly ? .macroFactorWorkouts : .macroFactor
            case .workouts(let result): result.source == .hevy ? .hevy : .strong
            case .measurements(let result): result.source
            case .exerly: .exerly
            }
        }
    }

    /// A Hevy or Strong file of body measurements rather than workouts:
    /// Hevy's has `fat_percent` and `_cm` or `_in` columns, Strong's a
    /// `Measurement Type` (or `Measurement`) and a `Value`.
    static func isMeasurements(_ data: Data) -> Bool {
        let header = headerRow(data).map { $0.lowercased() }
        if header.contains("exercise_title") || header.contains("exercise name") { return false }
        if header.contains("date") && (header.contains("fat_percent") || header.contains { $0.hasSuffix("_cm") || $0.hasSuffix("_in") }) {
            return true
        }
        return header.contains("date") && header.contains("value") && (header.contains("measurement type") || header.contains("measurement"))
    }

    static func headerRow(_ data: Data) -> [String] {
        guard let text = String(data: data.prefix(64 * 1024), encoding: .utf8) ?? String(data: data.prefix(64 * 1024), encoding: .isoLatin1)
        else { return [] }
        let trimmed = text.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
        return WorkoutImport.csv(String(trimmed.prefix { $0 != "\n" && $0 != "\r" })).first?
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
    }

    /// The app a file came from, by its contents rather than its name.
    public static func detect(_ data: Data) -> ImportSource? {
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .macroFactor }
        guard let text = String(data: data.prefix(64 * 1024), encoding: .utf8) ?? String(data: data.prefix(64 * 1024), encoding: .isoLatin1)
        else { return nil }
        let trimmed = text.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
        if trimmed.first == "{" { return ExerlyExportFile.looksLikeExport(data) ? .exerly : nil }
        let header = WorkoutImport.csv(String(trimmed.prefix { $0 != "\n" && $0 != "\r" })).first?
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        if header.contains("exercise_title") && header.contains("start_time") { return .hevy }
        if header.contains("Exercise Name") && header.contains("Set Order") { return .strong }
        if isMeasurements(data) {
            let lower = header.map { $0.lowercased() }
            return lower.contains("value") ? .strong : .hevy
        }
        let keys = Set(header.map(MFColumns.key))
        if keys.contains("exercise") && keys.contains("date") { return .macroFactorWorkouts }
        if keys.contains("date") || keys.contains("food name") { return .macroFactor }
        return nil
    }

    /// Parses the files. MacroFactor's may be several (a workbook, or a CSV per
    /// sheet); the other apps export one file.
    public static func read(_ files: [(name: String, data: Data)], options: Options, library: ExerciseLibrary,
                            now: Date = Date()) throws -> Parsed {
        let sources = files.map { detect($0.data) }
        guard let first = sources.first.flatMap({ $0 }), sources.allSatisfy({ $0 != nil }) else {
            let name = zip(files, sources).first { $0.1 == nil }?.0.name ?? "The file"
            throw ReadError.unrecognized(name)
        }
        let kinds = Set(sources.compactMap { $0 }.map { $0 == .macroFactorWorkouts ? .macroFactor : $0 })
        guard kinds.count == 1 else { throw ReadError.mixed(ImportSource.allCases.filter(kinds.contains)) }
        switch first {
        case .macroFactor, .macroFactorWorkouts:
            let export = try MacroFactorExport.read(files, timeZone: options.timeZone, unit: options.unit, library: library,
                                                    mapping: options.mapping, leftOut: options.leftOut, now: now)
            let workoutsOnly = !export.sessions.isEmpty && export.entries.isEmpty && export.dayTotals.isEmpty && export.weights.isEmpty
                && export.foods.isEmpty && export.plans.isEmpty
            return .macroFactor(export, workoutsOnly: workoutsOnly || (sources.allSatisfy { $0 == .macroFactorWorkouts } && export.isEmpty))
        case .hevy where files.allSatisfy({ isMeasurements($0.data) }), .strong where files.allSatisfy({ isMeasurements($0.data) }):
            let texts = files.map { String(data: $0.data, encoding: .utf8) ?? String(data: $0.data, encoding: .isoLatin1) ?? "" }
            if first == .hevy {
                guard texts.count == 1 else { throw ReadError.unrecognized("Choose one Hevy measurements file at a time") }
                return .measurements(MeasurementImport.hevy(texts[0], timeZone: options.timeZone))
            }
            return .measurements(MeasurementImport.strong(texts, timeZone: options.timeZone, unit: options.unit))
        case .hevy, .strong:
            guard files.count == 1 else {
                throw ReadError.unrecognized("Choose \(first.name)'s workouts file and its measurements files one at a time. These")
            }
            let text = String(data: files[0].data, encoding: .utf8) ?? String(data: files[0].data, encoding: .isoLatin1) ?? ""
            return .workouts(try WorkoutImport.parse(text, timeZone: options.timeZone, unit: options.unit, library: library,
                                                     mapping: options.mapping, leftOut: options.leftOut))
        case .exerly:
            guard files.count == 1 else { throw ReadError.unrecognized("Choose one Exerly export at a time") }
            return .exerly(try ExerlyExportFile(files[0].data))
        }
    }

    /// Checks what was read against the stores: what's new, what's already
    /// there, and what comes across differently or not at all.
    @MainActor
    /// `records` are this account's earlier imports: a workout an earlier
    /// import saved, unchanged in Exerly since, can be updated from the file.
    public static func plan(_ parsed: Parsed, files: [String], options: Options, hosts: [DocumentHost],
                            records: [ImportRecord] = [], measurements: ImportedMeasurementStore? = nil) throws -> HistoryImportPlan {
        let nutrition = hosts.lazy.compactMap { $0 as? NutritionStore }.first
        let training = hosts.lazy.compactMap { $0 as? TrainingStore }.first
        var plan = HistoryImportPlan(source: parsed.source, files: files, timeZone: options.timeZone)
        switch parsed {
        case .macroFactor(let export, _):
            guard let nutrition, let training else { throw HistoryImporter.ImportError.noStore("food or training") }
            try macroFactor(export, into: &plan, nutrition: nutrition, training: training, records: records)
        case .workouts(let result):
            guard let training else { throw HistoryImporter.ImportError.noStore("training") }
            try workouts(result, into: &plan, training: training, options: options, records: records)
        case .measurements(let result):
            guard let nutrition else { throw HistoryImporter.ImportError.noStore("weigh-ins") }
            try bodyMeasurements(result, into: &plan, nutrition: nutrition)
        case .exerly(let file):
            try exerly(file, into: &plan, hosts: hosts)
        }
        try planMeasurements(parsed, into: &plan, store: measurements, records: records)
        return plan
    }

    // MARK: MacroFactor

    @MainActor
    private static func macroFactor(_ export: MacroFactorExport, into plan: inout HistoryImportPlan, nutrition: NutritionStore,
                                    training: TrainingStore, records: [ImportRecord]) throws {
        let check = MacroFactorImport(export, nutrition: nutrition, training: training, records: records)
        let summary = check.summary
        let report = summary.report
        plan.writes = try check.writes(nutrition: nutrition)
        plan.dateRange = summary.dateRange
        let titles: [(MacroFactorImportSummary.Kind, String)] = [
            (.entries, "Foods logged"), (.dayTotals, "Days as daily totals"), (.days, "Day statuses and notes"), (.weights, "Weigh-ins"),
            (.foods, "Custom foods, favorites and recipes"), (.plans, "Past nutrition targets"), (.workouts, "Workouts"),
        ]
        for (kind, title) in titles where summary[kind].new + summary[kind].existing + summary[kind].updated > 0 {
            plan.lines.append(ImportLine(key: kind.rawValue, title: title, new: summary[kind].new, existing: summary[kind].existing,
                                         updated: summary[kind].updated))
        }
        appendKept(check.keptEdited, to: &plan.lost)
        let newSessions = Set(plan.writes.filter { $0.kind == TrainingStore.sessionKind && $0.before == nil }.map(\.id))
        let sessions = export.sessions.filter { newSessions.contains($0.id.uuidString) }
        if !sessions.isEmpty { plan.lines.append(setsLine(sessions)) }

        var exercises = report.mappedExercises.map { name, id in
            ExerciseMatch(name: name, sets: report.exerciseSets[name] ?? 0, exerciseID: id, how: .automatic)
        }
        exercises += report.unmappedExercises.map { ExerciseMatch(name: $0.key, sets: $0.value, exerciseID: nil, how: .unmatched) }
        exercises += report.leftOutExercises.map { ExerciseMatch(name: $0.key, sets: $0.value, exerciseID: nil, how: .leftOut) }
        plan.exercises = exercises

        let weightUnits = Set(export.weights.map(\.weight.unit))
        if !export.weights.isEmpty {
            plan.units.append("Weigh-ins in \(weightUnits.map(\.rawValue).sorted().joined(separator: " and ")), from the column headers")
        }
        if !export.entries.isEmpty { plan.units.append("Food amounts in grams, nutrients in their columns' units") }
        plan.units.append("Dates and times read in \(plan.timeZone.identifier): the file has no time zone")

        for sheet in report.sheets where !sheet.imported { plan.lost.append("\(sheet.name): \(sheet.detail)") }
        for (sheet, columns) in report.unusedColumns.sorted(by: { $0.key < $1.key }) {
            plan.lost.append("\(sheet): \(columns.joined(separator: ", ")). Exerly works these out from your own data.")
        }
        for (sheet, columns) in report.unknownColumns.sorted(by: { $0.key < $1.key }) {
            plan.lost.append("\(sheet): columns Exerly doesn't recognise, \(columns.joined(separator: ", "))")
        }
        appendExerciseLosses(plan.exercises, to: &plan.lost)
        plan.approximated = report.assumptions
        if !sessions.isEmpty {
            plan.approximated.append("The file has no time for each set, so sets are spaced evenly through each workout.")
        }
        plan.skip(report.skipped.map { skipped in "\(skipped.sheet)\(skipped.row.map { ", row \($0)" } ?? ""): \(skipped.reason)" })
    }

    // MARK: Hevy and Strong

    @MainActor
    private static func workouts(_ result: WorkoutImport.Result, into plan: inout HistoryImportPlan, training: TrainingStore,
                                 options: Options, records: [ImportRecord]) throws {
        let reconciled = try reconcile(result.sessions, training: training, records: records)
        plan.writes = reconciled.writes
        let added = Set(reconciled.writes.filter { $0.before == nil }.map(\.id))
        let new = result.sessions.filter { added.contains($0.id.uuidString) }
        plan.lines.append(ImportLine(key: "workouts", title: "Workouts", new: reconciled.new, existing: reconciled.existing,
                                     updated: reconciled.updated))
        appendKept(reconciled.keptEdited, to: &plan.lost)
        if !new.isEmpty {
            plan.lines.append(ImportLine(key: "exercises", title: "Exercises", new: Set(new.flatMap { $0.exercises.map(\.exerciseID) }).count))
            plan.lines.append(setsLine(new))
        }
        let dates = result.sessions.map(\.localDate)
        if let first = dates.min(), let last = dates.max() { plan.dateRange = first...last }
        plan.units = result.units
        plan.assumedWeightUnit = result.weightUnitAssumed ? options.unit : nil

        plan.exercises = result.setCounts.map { name, sets in
            if result.leftOut[name] != nil { return ExerciseMatch(name: name, sets: sets, exerciseID: nil, how: .leftOut) }
            guard let id = result.matched[name] else { return ExerciseMatch(name: name, sets: sets, exerciseID: nil, how: .unmatched) }
            return ExerciseMatch(name: name, sets: sets, exerciseID: id, how: options.mapping[name] == id ? .chosen : .automatic)
        }
        appendExerciseLosses(plan.exercises, to: &plan.lost)
        if result.restTimers > 0 {
            plan.lost.append("\(result.restTimers) rest \(result.restTimers == 1 ? "timer" : "timers"). Exerly times rest itself during a workout.")
        }
        let name = result.source == .hevy ? "Hevy" : "Strong"
        plan.lost.append("\(name)'s routines and settings aren't in this file. Its body measurements are a separate export, "
                         + "which you can import here too.")
        // Unitless weights and distances are said under units, where the weight's can be changed.
        plan.approximated = result.assumptions.filter { !$0.hasPrefix("Weights have no unit") && !$0.hasPrefix("Distances have no unit") }
        if result.sessions.contains(where: { $0.exercises.contains { $0.sets.contains { $0.rir != nil } } }) {
            plan.approximated.append("RPE becomes reps in reserve: RPE 8 is 2 reps in reserve.")
        }
        if !result.sessions.isEmpty {
            plan.approximated.append("The file has no time for each set, so sets are spaced evenly through each workout.")
        }
        if result.source == .hevy {
            plan.approximated.append("Hevy's failure sets become failure sets, drop sets become drop sets, each drop on its own set.")
        }
        plan.skip(result.skipped)
    }

    // MARK: Body measurements

    @MainActor
    private static func bodyMeasurements(_ result: MeasurementImport.Result, into plan: inout HistoryImportPlan,
                                         nutrition: NutritionStore) throws {
        let ids = Set(nutrition.weights.map(\.id))
        let byDay = Dictionary(grouping: nutrition.weights, by: \.date)
        var existing = 0
        for weight in result.weights {
            // The same reading from Apple Health or an earlier import is kept.
            if ids.contains(weight.id) || (byDay[weight.date] ?? []).contains(where: { abs($0.weight.kilograms - weight.weight.kilograms) < 0.1 }) {
                existing += 1
                continue
            }
            plan.writes.append(PlannedWrite(kind: NutritionStore.weightKind, id: weight.id.uuidString, before: nil,
                                            after: try ExerlyJSON.canonical(weight)))
        }
        if !result.weights.isEmpty {
            plan.lines.append(ImportLine(key: "weights", title: "Weigh-ins", new: result.weights.count - existing, existing: existing))
        }
        let dates = result.weights.map(\.date) + result.measurements.map(\.date)
        if let first = dates.min(), let last = dates.max() { plan.dateRange = first...last }
        plan.units = result.units
        plan.approximated = result.assumptions
        for (name, count) in result.unknown.sorted(by: { $0.key < $1.key }) {
            plan.lost.append("\(name): \(count) \(count == 1 ? "value" : "values") of a measurement Exerly doesn't keep")
        }
        plan.skip(result.skipped)
    }

    /// The file's body measurements, less those the account already has.
    @MainActor
    private static func planMeasurements(_ parsed: Parsed, into plan: inout HistoryImportPlan, store: ImportedMeasurementStore?,
                                         records: [ImportRecord]) throws {
        let all: [ImportedMeasurement] = switch parsed {
        case .macroFactor(let export, _): export.measurements
        case .measurements(let result): result.measurements
        default: []
        }
        guard !all.isEmpty else { return }
        guard let store else {
            plan.lost.append("\(all.count) body \(all.count == 1 ? "measurement" : "measurements"): sign in to import them.")
            return
        }
        let have = store.states(all.map(\.clientID))
        // What the latest import that still stands saved for each, and whether
        // the latest import to touch each was undone with its Undo deleting it.
        var saved: [String: ImportedMeasurement] = [:]
        var undoneHere: [String: Bool] = [:]
        for record in records.reversed() {
            let touched = (record.measurements ?? []).map(\.clientID) + (record.measurementChanges ?? []).map(\.measurement.clientID)
            for id in touched { undoneHere[id] = record.undoneAt != nil && record.removedMeasurements?.contains(id) == true }
            guard record.undoneAt == nil else { continue }
            for measurement in record.measurements ?? [] { saved[measurement.clientID] = measurement }
            for change in record.measurementChanges ?? [] { saved[change.measurement.clientID] = change.measurement }
        }
        var existing = 0, kept = 0, deleted = 0
        for measurement in all {
            guard let state = have[measurement.clientID] else {
                plan.measurements.append(measurement)
                continue
            }
            if state.deleted {
                // Brought back only if an import's Undo deleted it; a deletion of the person's own stands.
                if undoneHere[measurement.clientID] == true {
                    plan.measurements.append(measurement)
                    plan.revivedMeasurements.insert(measurement.clientID)
                } else {
                    existing += 1
                    deleted += 1
                }
            } else if state == measurement.state {
                existing += 1
            } else if let imported = saved[measurement.clientID], state == imported.state {
                // Corrected in the file and exactly as the last import left it here.
                plan.measurementChanges.append(ImportedMeasurementChange(measurement: measurement, from: imported.value))
            } else {
                existing += 1
                kept += 1
            }
        }
        plan.lines.append(ImportLine(key: "measurements", title: "Body measurements", new: plan.measurements.count, existing: existing,
                                     updated: plan.measurementChanges.count))
        if kept > 0 {
            plan.lost.append(kept == 1 ? "1 body measurement you changed in Exerly since the last import is kept as it is."
                             : "\(kept) body measurements you changed in Exerly since the last import are kept as they are.")
        }
        if deleted > 0 {
            plan.lost.append(deleted == 1 ? "1 body measurement you deleted in Exerly stays deleted."
                             : "\(deleted) body measurements you deleted in Exerly stay deleted.")
        }
        if plan.dateRange == nil, let first = all.map(\.date).min(), let last = all.map(\.date).max() { plan.dateRange = first...last }
    }

    // MARK: Exerly

    @MainActor
    private static func exerly(_ file: ExerlyExportFile, into plan: inout HistoryImportPlan, hosts: [DocumentHost]) throws {
        var counts: [String: (new: Int, existing: Int)] = [:]
        var unsupported: [String: Int] = [:]
        for document in file.documents {
            guard let host = hosts.first(where: { $0.documentKinds.contains(document.kind) }) else {
                unsupported[document.kind, default: 0] += 1
                continue
            }
            let id = DocumentWrite.canonicalID(document.id)
            if try host.payload(kind: document.kind, id: id) == nil {
                plan.writes.append(PlannedWrite(kind: document.kind, id: id, before: nil, after: document.payload))
                counts[document.kind, default: (0, 0)].new += 1
            } else {
                counts[document.kind, default: (0, 0)].existing += 1
            }
        }
        for host in hosts {
            for kind in host.documentKinds {
                guard let count = counts[kind] else { continue }
                plan.lines.append(ImportLine(key: kind, title: ExerlyExportFile.title(kind), new: count.new, existing: count.existing))
            }
        }
        // The server's older tables, restored through the account.
        for (table, count) in file.serverRows.sorted(by: { $0.key < $1.key }) {
            plan.lines.append(ImportLine(key: "server/\(table)", title: ExerlyExportFile.restorable[table] ?? table, new: count))
        }
        plan.serverTables = file.serverTables
        plan.dateRange = file.dateRange
        plan.units = ["Every document keeps its own units, time zone and IDs"]
        if file.serverTables != nil {
            plan.units.append("Older records are restored through your account, so this import needs a connection")
        }
        if file.offline { plan.lost.append("The export was made offline, so it holds what that device had.") }
        for (kind, count) in unsupported.sorted(by: { $0.key < $1.key }) {
            plan.lost.append("\(count) \(ExerlyExportFile.title(kind).lowercased()) this version of Exerly can't keep on a phone")
        }
        for (table, count) in file.otherTables.sorted(by: { $0.key < $1.key }) where count > 0 && file.serverRows[table] == nil {
            let name = table.replacingOccurrences(of: "_", with: " ").capitalized
            plan.lost.append("\(name): \(ExerlyExportFile.notRestored[table] ?? "Exerly doesn't know this table, so it isn't restored.")")
        }
        if file.hasAccount { plan.lost.append("Account details and settings stay with the account they came from.") }
        plan.approximated.append("Documents keep their IDs. One this account already has is kept as it is, not overwritten.")
    }

    // MARK: Shared

    /// Workouts checked against Exerly's: new ones are added; one an earlier
    /// import saved and Exerly hasn't changed since is updated from the file;
    /// one changed in Exerly is kept as it is.
    @MainActor
    static func reconcile(_ sessions: [WorkoutSession], training: TrainingStore, records: [ImportRecord]) throws
        -> (writes: [PlannedWrite], new: Int, existing: Int, updated: Int, keptEdited: Int) {
        // What the latest import that still stands saved for each workout.
        var saved: [String: String] = [:]
        for record in records.reversed() where record.undoneAt == nil {
            for change in record.changes where change.kind == TrainingStore.sessionKind { saved[change.id] = change.after }
        }
        var result: (writes: [PlannedWrite], new: Int, existing: Int, updated: Int, keptEdited: Int) = ([], 0, 0, 0, 0)
        for session in sessions {
            let id = session.id.uuidString
            guard training.activeSession?.id != session.id else {
                result.existing += 1
                continue
            }
            guard let current = try training.payload(kind: TrainingStore.sessionKind, id: id) else {
                result.writes.append(PlannedWrite(kind: TrainingStore.sessionKind, id: id, before: nil, after: try ExerlyJSON.canonical(session)))
                result.new += 1
                continue
            }
            let after = try ExerlyJSON.canonical(anchored(session, like: current))
            if current == after {
                result.existing += 1
            } else if saved[id] == HistoryImporter.fingerprint(current) {
                result.writes.append(PlannedWrite(kind: TrainingStore.sessionKind, id: id, before: current, after: after))
                result.updated += 1
            } else {
                result.existing += 1
                result.keptEdited += 1
            }
        }
        return result
    }

    /// A workout the account already has, read in the zone it was saved in. The
    /// files' times have no zone, so after a move the same wall-clock times
    /// would otherwise land hours away; only new workouts take the new zone.
    private static func anchored(_ session: WorkoutSession, like current: Data) throws -> WorkoutSession {
        let saved = try ExerlyJSON.decoder.decode(WorkoutSession.self, from: current)
        guard saved.timeZoneID != session.timeZoneID, let zone = TimeZone(identifier: saved.timeZoneID) else { return session }
        let shift = TimeInterval(session.timeZone.secondsFromGMT(for: session.startedAt) - zone.secondsFromGMT(for: session.startedAt))
        var moved = session
        moved.timeZoneID = saved.timeZoneID
        moved.startedAt += shift
        moved.endedAt = moved.endedAt.map { $0 + shift }
        for e in moved.exercises.indices {
            for s in moved.exercises[e].sets.indices {
                moved.exercises[e].sets[s].completedAt = moved.exercises[e].sets[s].completedAt.map { $0 + shift }
            }
        }
        return moved
    }

    private static func appendKept(_ count: Int, to lost: inout [String]) {
        guard count > 0 else { return }
        lost.append(count == 1 ? "1 workout you changed in Exerly since the last import is kept as it is."
                    : "\(count) workouts you changed in Exerly since the last import are kept as they are.")
    }

    private static func setsLine(_ sessions: [WorkoutSession]) -> ImportLine {
        ImportLine(key: "sets", title: "Sets", new: sessions.reduce(0) { $0 + $1.exercises.reduce(0) { $0 + $1.sets.count } })
    }

    private static func appendExerciseLosses(_ exercises: [ExerciseMatch], to lost: inout [String]) {
        let unmatched = exercises.filter { $0.how == .unmatched }
        if !unmatched.isEmpty {
            let sets = unmatched.reduce(0) { $0 + $1.sets }
            lost.append("\(sets) \(sets == 1 ? "set" : "sets") of \(unmatched.count) \(unmatched.count == 1 ? "exercise" : "exercises") "
                        + "Exerly has no match for. Choose an exercise for each to keep them.")
        }
        let leftOut = exercises.filter { $0.how == .leftOut }
        if !leftOut.isEmpty {
            let sets = leftOut.reduce(0) { $0 + $1.sets }
            lost.append("\(sets) \(sets == 1 ? "set" : "sets") of exercises you chose to leave out")
        }
    }
}

extension HistoryImportPlan {
    /// Exercises the person should look at first: unmatched, then the rest by sets.
    public var exercisesInOrder: [ExerciseMatch] {
        exercises.sorted { a, b in
            let rank = { (match: ExerciseMatch) in match.how == .unmatched ? 0 : 1 }
            return (rank(a), -a.sets, a.name) < (rank(b), -b.sets, b.name)
        }
    }
}
