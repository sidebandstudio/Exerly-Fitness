import Foundation

/// Where imported history came from. PARITY I12, I13 and I14.
public enum ImportSource: String, Sendable, Codable, Hashable, CaseIterable {
    case macroFactor, macroFactorWorkouts, hevy, strong, exerly

    public var name: String {
        switch self {
        case .macroFactor: "MacroFactor"
        case .macroFactorWorkouts: "MacroFactor Workouts"
        case .hevy: "Hevy"
        case .strong: "Strong"
        case .exerly: "Exerly export"
        }
    }
}

/// One count in a preview or a past import: "Foods logged, 120 new, 4 already in Exerly".
public struct ImportLine: Sendable, Codable, Hashable, Identifiable {
    public var key: String
    public var title: String
    /// What the import adds or sets.
    public var new: Int
    /// Already in Exerly, and left as it is.
    public var existing: Int
    /// In Exerly from an earlier import, and changed in the file since: the
    /// import updates them.
    public var updated: Int

    public var id: String { key }

    /// Lines that break another down, such as a workout's sets.
    public static let breakdowns: Set<String> = ["exercises", "sets"]

    public init(key: String, title: String, new: Int, existing: Int = 0, updated: Int = 0) {
        self.key = key
        self.title = title
        self.new = new
        self.existing = existing
        self.updated = updated
    }

    enum CodingKeys: String, CodingKey { case key, title, new, existing, updated }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: try c.decode(String.self, forKey: .key), title: try c.decode(String.self, forKey: .title),
                  new: try c.decode(Int.self, forKey: .new), existing: try c.decode(Int.self, forKey: .existing),
                  updated: try c.decodeIfPresent(Int.self, forKey: .updated) ?? 0)
    }
}

/// How one exercise name in a file is brought into Exerly.
public struct ExerciseMatch: Sendable, Hashable, Identifiable {
    public enum How: Sendable, Hashable {
        /// Matched by name.
        case automatic
        /// Chosen by the person.
        case chosen
        /// The person chose to leave its sets out.
        case leftOut
        /// Nothing matched: its sets are left out unless one is chosen.
        case unmatched
    }

    /// The name as the file writes it.
    public var name: String
    public var sets: Int
    public var exerciseID: ExerciseID?
    public var how: How

    public var id: String { name }
}

/// A document an import writes: what it should find there, and what it puts.
public struct PlannedWrite: Sendable, Hashable {
    public var kind: String
    public var id: String
    /// The canonical document the import expects to replace; nil when it adds one.
    public var before: Data?
    /// The document to save; nil to remove `before`.
    public var after: Data?
    /// Writes that only make sense together, such as a day's foods and the
    /// daily total they replace, share a group.
    public var group: String?
}

/// A file read and checked against what Exerly already has, before anything
/// is saved. `HistoryImportReader` makes one; `HistoryImporter` saves it.
public struct HistoryImportPlan: Sendable {
    public var source: ImportSource
    public var files: [String]
    public var lines: [ImportLine]
    public var dateRange: ClosedRange<LocalDate>?
    /// The zone the file's times were read in.
    public var timeZone: TimeZone
    /// How units and times were read, one sentence each.
    public var units: [String]
    /// The unit unitless weights were read in, when the file has them, so it
    /// can be changed before importing. Nil when every weight names its unit.
    public var assumedWeightUnit: MassUnit?
    /// Every exercise name in the file, the most sets first.
    public var exercises: [ExerciseMatch]
    /// What the file holds that Exerly leaves out.
    public var lost: [String]
    /// What comes across differently from how the file has it.
    public var approximated: [String]
    /// Rows left out, with why. The first 50.
    public var skipped: [String]
    public var skippedCount: Int
    public var writes: [PlannedWrite]
    /// The server's older tables an Exerly export restores, through the account.
    public var serverTables: Data?
    /// Body measurements the account doesn't have yet, for its measurement log.
    public var measurements: [ImportedMeasurement] = []
    /// Measurements an earlier import saved whose value the file corrects.
    public var measurementChanges: [ImportedMeasurementChange] = []

    /// Nothing to save: the file is empty or already in Exerly.
    public var isEmpty: Bool { writes.isEmpty && serverTables == nil && measurements.isEmpty && measurementChanges.isEmpty }
    /// What the import adds or updates, counting workouts rather than the
    /// exercises and sets inside them.
    public var additions: Int { lines.filter { !ImportLine.breakdowns.contains($0.key) }.reduce(0) { $0 + $1.new + $1.updated } }

    public init(source: ImportSource, files: [String], timeZone: TimeZone) {
        self.source = source
        self.files = files
        self.timeZone = timeZone
        lines = []
        units = []
        exercises = []
        lost = []
        approximated = []
        skipped = []
        skippedCount = 0
        writes = []
    }

    mutating func skip(_ reasons: [String]) {
        skippedCount += reasons.count
        skipped += reasons.prefix(max(0, 50 - skipped.count))
    }
}

/// An import as saved, kept in the account's own database so it can be
/// undone. It doesn't sync: undoing on another device isn't possible, but
/// what it removes syncs as removals.
public struct ImportRecord: Sendable, Codable, Hashable, Identifiable {
    public struct Change: Sendable, Codable, Hashable {
        public var kind: String
        public var id: String
        /// The document before the import; nil when the import added it.
        public var before: Data?
        /// A fingerprint of what the import saved; nil when it removed the document.
        public var after: String?
        public var group: String?
    }

    public var id: UUID
    public var source: ImportSource
    public var files: [String]
    public var importedAt: Date
    public var timeZoneID: String
    public var lines: [ImportLine]
    public var dateRange: ClosedRange<LocalDate>?
    public var changes: [Change]
    /// Rows of the server's older tables the import restored, undone through the account.
    public var serverRows: [RestoredRow]?
    /// The server's record of that restore, which Undo names.
    public var serverRestoreID: String?
    /// What the server left out, with why (at most 50), and how many in all.
    public var serverSkipped: [String]?
    public var serverSkippedCount: Int?
    /// Body measurements the import added to the measurement log.
    public var measurements: [ImportedMeasurement]?
    /// Measurements whose value it changed, with the value each had.
    public var measurementChanges: [ImportedMeasurementChange]?
    public var undoneAt: Date?

    /// Documents the import added, rather than changed or removed.
    public var added: Int { changes.filter { $0.before == nil }.count }
}

/// Saves import plans as one unit across the stores, and undoes them.
@MainActor
public struct HistoryImporter {
    public struct UndoResult: Sendable, Hashable {
        /// Documents removed, or put back as they were before the import.
        public var undone: Int
        /// Documents changed since the import, kept as they are now.
        public var kept: Int
        /// Custom exercises the import added, kept in the library.
        public var keptExercises: Int
        /// Groups kept whole as imported, because one of their documents changed since.
        public var keptGroups: [String] = []

        public init(undone: Int, kept: Int, keptExercises: Int = 0) {
            self.undone = undone
            self.kept = kept
            self.keptExercises = keptExercises
        }
    }

    public enum ImportError: Error, Equatable {
        /// What the plan expected changed since it was made: read the file again.
        case stale
        /// The import needs the account on the server, which couldn't be reached. Nothing was saved.
        case needsAccount(String)
        case noStore(String)
        case invalid(String)
        case alreadyUndone
    }

    static let recordKind = "import_record"

    let hosts: [DocumentHost]
    let persistence: TrainingPersistence & DocumentPersistence
    let measurementStore: ImportedMeasurementStore?
    let now: () -> Date

    /// `hosts` must all keep their documents in `persistence`, so a plan
    /// saves in one transaction. `measurements` is the account's measurement
    /// log, saved alongside it.
    public init(hosts: [DocumentHost], persistence: TrainingPersistence & DocumentPersistence,
                measurements: ImportedMeasurementStore? = nil, now: @escaping () -> Date = Date.init) {
        self.hosts = hosts
        self.persistence = persistence
        measurementStore = measurements
        self.now = { now().roundedToMilliseconds }
    }

    /// Every import saved in this account, the latest first.
    public func records() throws -> [ImportRecord] {
        try persistence.loadDocuments(kind: Self.recordKind)
            .map { try ExerlyJSON.decoder.decode(ImportRecord.self, from: $0) }
            .sorted { $0.importedAt > $1.importedAt }
    }

    /// Saves everything in the plan, or nothing. If any document changed since
    /// the plan was made, from a sync say, it throws `stale` and saves nothing:
    /// read the file again for a new plan. Importing the same file again adds
    /// nothing, not even a record: its documents are already there.
    @discardableResult
    public func commit(_ plan: HistoryImportPlan) throws -> ImportRecord {
        var changes: [ImportRecord.Change] = []
        var batches: [(host: DocumentHost, kind: String, writes: [DocumentWrite])] = []
        for host in hosts {
            for kind in host.documentKinds {
                var writes: [DocumentWrite] = []
                for write in plan.writes where write.kind == kind {
                    let current = try host.payload(kind: kind, id: write.id)
                    // Something changed since the preview, from a sync say. Saving part
                    // of the plan could count a day twice, so none of it is saved.
                    guard current == write.before else { throw ImportError.stale }
                    let after = try write.after.map { try host.canonicalize(kind: kind, payload: $0) }
                    guard after != current else { continue }
                    writes.append(DocumentWrite(kind: kind, id: write.id, payload: after))
                    changes.append(.init(kind: kind, id: write.id, before: current, after: after.map(Self.fingerprint), group: write.group))
                }
                if !writes.isEmpty { batches.append((host, kind, writes)) }
            }
        }
        if let stray = plan.writes.first(where: { write in !hosts.contains { $0.documentKinds.contains(write.kind) } }) {
            throw ImportError.noStore(stray.kind)
        }
        var record = ImportRecord(id: UUID(), source: plan.source, files: plan.files, importedAt: now(), timeZoneID: plan.timeZone.identifier,
                                  lines: plan.lines, dateRange: plan.dateRange, changes: changes)
        let have = measurementStore?.values(plan.measurements.map(\.clientID)) ?? [:]
        let measurements = plan.measurements.filter { have[$0.clientID] == nil }
        let corrections = plan.measurementChanges
        if !measurements.isEmpty || !corrections.isEmpty, measurementStore == nil { throw ImportError.noStore("measurement") }
        // Nothing new, as when a file is imported again: nothing to save or undo.
        guard !changes.isEmpty || !measurements.isEmpty || !corrections.isEmpty else { return record }
        if !measurements.isEmpty { record.measurements = measurements }
        if !corrections.isEmpty { record.measurementChanges = corrections }
        // Where the documents came from, saved and undone with them. A restored
        // export brings its own provenance, so it adds none.
        if plan.source != .exerly, let store = hosts.lazy.compactMap({ $0 as? ProvenanceStore }).first {
            let saved = changes.filter { $0.after != nil }.map { "\($0.kind)/\($0.id)" } + measurements.map { "measurement/\($0.clientID)" }
            let parts = try ImportProvenance.parts(for: record, documents: saved).map { part in
                DocumentWrite(kind: ProvenanceStore.kind, id: part.id, payload: try ExerlyJSON.canonical(part))
            }
            batches.append((store, ProvenanceStore.kind, parts))
            record.changes += parts.map { .init(kind: $0.kind, id: $0.id, before: nil, after: $0.payload.map(Self.fingerprint)) }
        }
        try validate(batches)
        // The measurement log isn't in this database: saved first, and taken out
        // again if the documents can't be, so it's all or nothing.
        if !measurements.isEmpty { try measurementStore?.add(measurements) }
        do {
            if !corrections.isEmpty { _ = try measurementStore?.update(corrections) }
        } catch {
            if !measurements.isEmpty { _ = try? measurementStore?.remove(measurements) }
            throw error
        }
        do {
            try apply(batches, saving: record)
        } catch {
            if !measurements.isEmpty { _ = try? measurementStore?.remove(measurements) }
            if !corrections.isEmpty { _ = try? measurementStore?.update(corrections.map(\.reversed)) }
            throw error
        }
        return record
    }

    /// Saves a plan that also restores the server's older tables: the documents
    /// here, then the tables through `api`. If the server can't be reached or
    /// refuses, the documents are taken out again and the import is forgotten,
    /// so it's both or neither.
    public func commit(_ plan: HistoryImportPlan, api: AccountAPI?) async throws -> ImportRecord {
        guard let tables = plan.serverTables else { return try commit(plan) }
        guard let api else { throw ImportError.needsAccount("Sign in, then try again.") }
        var record = try commit(plan)
        let saved = !record.changes.isEmpty
        let result: ImportResult
        do {
            result = try await api.importExport(tables)
        } catch {
            if saved {
                _ = try? undo(record.id)
                try? persistence.deleteDocument(kind: Self.recordKind, id: record.id.uuidString)
            }
            throw ImportError.needsAccount(Self.describe(error))
        }
        record.serverRows = result.restored
        record.serverRestoreID = result.restoreID
        if result.skippedCount > 0 {
            record.serverSkipped = result.skipped
            record.serverSkippedCount = result.skippedCount
        }
        if saved || !result.restored.isEmpty {
            try persistence.saveDocument(kind: Self.recordKind, id: record.id.uuidString, payload: ExerlyJSON.canonical(record))
        }
        return record
    }

    /// Undoes an import that restored the server's older tables too: those
    /// first, through `api`, then the documents here. If the server can't be
    /// reached, nothing is undone.
    public func undo(_ id: UUID, api: AccountAPI?) async throws -> UndoResult {
        guard let record = try records().first(where: { $0.id == id }) else { throw ImportError.invalid("That import isn't in this account") }
        guard record.undoneAt == nil else { throw ImportError.alreadyUndone }
        var server = (removed: 0, kept: 0)
        if let restoreID = record.serverRestoreID {
            guard let api else { throw ImportError.needsAccount("Sign in, then try again.") }
            do {
                server = try await api.undoRestore(restoreID)
            } catch {
                throw ImportError.needsAccount(Self.describe(error))
            }
        }
        var result = try undo(id)
        result.undone += server.removed
        result.kept += server.kept
        return result
    }

    /// Removes what an import added and puts back what it replaced. A document
    /// edited since the import is kept as it is now, and so is the rest of its
    /// group: a day whose imported food was corrected keeps its imported foods
    /// rather than getting back the daily total they replaced beside them.
    @discardableResult
    public func undo(_ id: UUID) throws -> UndoResult {
        guard var record = try records().first(where: { $0.id == id }) else { throw ImportError.invalid("That import isn't in this account") }
        guard record.undoneAt == nil else { throw ImportError.alreadyUndone }
        var result = UndoResult(undone: 0, kept: 0, keptExercises: 0)
        // A document changed since the import keeps its whole group as imported.
        var changedGroups = Set<String>()
        for change in record.changes {
            guard let group = change.group, let host = hosts.first(where: { $0.documentKinds.contains(change.kind) }) else { continue }
            let current = try host.payload(kind: change.kind, id: change.id)
            if current.map(Self.fingerprint) != change.after && current != change.before { changedGroups.insert(group) }
        }
        result.keptGroups = changedGroups.sorted()
        var batches: [(host: DocumentHost, kind: String, writes: [DocumentWrite])] = []
        for host in hosts {
            for kind in host.documentKinds {
                var writes: [DocumentWrite] = []
                for change in record.changes where change.kind == kind {
                    // Custom exercises are never deleted: workouts may use them.
                    if kind == TrainingStore.exerciseKind && change.before == nil {
                        result.keptExercises += 1
                        continue
                    }
                    if let group = change.group, changedGroups.contains(group) {
                        result.kept += 1
                        continue
                    }
                    let current = try host.payload(kind: kind, id: change.id)
                    guard current.map(Self.fingerprint) == change.after else {
                        if current != change.before { result.kept += 1 }
                        continue
                    }
                    writes.append(DocumentWrite(kind: kind, id: change.id, payload: change.before))
                    // Provenance goes with what it describes; it isn't counted as one of the person's records.
                    if kind != ProvenanceStore.kind { result.undone += 1 }
                }
                if !writes.isEmpty { batches.append((host, kind, writes)) }
            }
        }
        try validate(batches)
        record.undoneAt = now()
        var removed: [ImportedMeasurement] = []
        if let measurements = record.measurements, !measurements.isEmpty {
            guard let measurementStore else { throw ImportError.noStore("measurement") }
            let outcome = try measurementStore.remove(measurements)
            result.undone += outcome.removed
            result.kept += outcome.kept
            removed = measurements
        }
        // A corrected value goes back to the earlier import's, unless changed since.
        var reverted: [ImportedMeasurementChange] = []
        if let corrections = record.measurementChanges, !corrections.isEmpty {
            guard let measurementStore else { throw ImportError.noStore("measurement") }
            reverted = corrections.map(\.reversed)
            let outcome = try measurementStore.update(reverted)
            result.undone += outcome.updated
            result.kept += outcome.kept
        }
        do {
            try apply(batches, saving: record)
        } catch {
            // Put the measurements back, so nothing is half undone.
            if !removed.isEmpty { try? measurementStore?.add(removed.filter { measurementStore?.values([$0.clientID]).isEmpty == true }) }
            if !reverted.isEmpty { _ = try? measurementStore?.update(reverted.map(\.reversed)) }
            throw error
        }
        return result
    }

    private func validate(_ batches: [(host: DocumentHost, kind: String, writes: [DocumentWrite])]) throws {
        // Programs may use custom exercises saved alongside them.
        var library = hosts.lazy.compactMap { $0 as? TrainingStore }.first?.library
        for write in batches.flatMap(\.writes) where write.kind == TrainingStore.exerciseKind {
            if let payload = write.payload, let exercise = try? ExerlyJSON.decoder.decode(Exercise.self, from: payload) {
                library = try? library?.replacing(exercise)
            }
        }
        for host in hosts {
            let writes = batches.filter { $0.host === host }.flatMap(\.writes)
            guard !writes.isEmpty else { continue }
            do {
                if let programs = host as? ProgramStore, let library {
                    for write in writes {
                        if let payload = write.payload { try programs.validate(kind: write.kind, id: write.id, payload: payload, library: library) }
                    }
                } else {
                    try host.validate(batch: writes)
                }
            } catch {
                throw ImportError.invalid(Self.describe(error))
            }
        }
    }

    private func apply(_ batches: [(host: DocumentHost, kind: String, writes: [DocumentWrite])], saving record: ImportRecord) throws {
        var publish: [() -> Void] = []
        try persistence.performAtomically {
            for batch in batches { publish.append(try batch.host.prepareWrites(kind: batch.kind, batch.writes)) }
            try persistence.saveDocument(kind: Self.recordKind, id: record.id.uuidString, payload: ExerlyJSON.canonical(record))
        }
        publish.forEach { $0() }
    }

    public static func describe(_ error: Error) -> String {
        switch error {
        case ImportError.invalid(let message): message
        case ImportError.noStore(let kind): "Exerly can't keep \(kind) documents on this device"
        case ImportError.alreadyUndone: "This import was already undone"
        case ImportError.stale: "Your data changed since this preview, so it was read again"
        case ImportError.needsAccount(let why): "Your account couldn't be reached, so nothing was restored. \(why)"
        case let error as DocumentError: error.message
        case NutritionStore.StoreError.invalid(let problems): problems.joined(separator: "; ")
        case TrainingStore.StoreError.edit(let problem): "A workout isn't valid: \(problem)"
        case let error as WorkoutSession.EditError: "A workout isn't valid: \(error)"
        default: "\(error)"
        }
    }

    /// FNV-1a, 64 bits, in hex: enough to tell whether a document changed.
    static func fingerprint(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}
