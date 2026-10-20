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

    public var id: String { key }

    public init(key: String, title: String, new: Int, existing: Int = 0) {
        self.key = key
        self.title = title
        self.new = new
        self.existing = existing
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

    /// Nothing to save: the file is empty or already in Exerly.
    public var isEmpty: Bool { writes.isEmpty }
    public var additions: Int { lines.reduce(0) { $0 + $1.new } }

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
    }

    public var id: UUID
    public var source: ImportSource
    public var files: [String]
    public var importedAt: Date
    public var timeZoneID: String
    public var lines: [ImportLine]
    public var dateRange: ClosedRange<LocalDate>?
    public var changes: [Change]
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
    }

    public enum ImportError: Error, Equatable {
        case noStore(String)
        case invalid(String)
        case alreadyUndone
    }

    static let recordKind = "import_record"

    let hosts: [DocumentHost]
    let persistence: TrainingPersistence & DocumentPersistence
    let now: () -> Date

    /// `hosts` must all keep their documents in `persistence`, so a plan
    /// saves in one transaction.
    public init(hosts: [DocumentHost], persistence: TrainingPersistence & DocumentPersistence, now: @escaping () -> Date = Date.init) {
        self.hosts = hosts
        self.persistence = persistence
        self.now = { now().roundedToMilliseconds }
    }

    /// Every import saved in this account, the latest first.
    public func records() throws -> [ImportRecord] {
        try persistence.loadDocuments(kind: Self.recordKind)
            .map { try ExerlyJSON.decoder.decode(ImportRecord.self, from: $0) }
            .sorted { $0.importedAt > $1.importedAt }
    }

    /// Saves everything in the plan, or nothing. A document that changed since
    /// the plan was made, from a sync say, is left as it is now, so a stale
    /// preview never overwrites newer data. Importing the same file again adds
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
                    guard current == write.before else { continue }
                    let after = try write.after.map { try host.canonicalize(kind: kind, payload: $0) }
                    guard after != current else { continue }
                    writes.append(DocumentWrite(kind: kind, id: write.id, payload: after))
                    changes.append(.init(kind: kind, id: write.id, before: current, after: after.map(Self.fingerprint)))
                }
                if !writes.isEmpty { batches.append((host, kind, writes)) }
            }
        }
        if let stray = plan.writes.first(where: { write in !hosts.contains { $0.documentKinds.contains(write.kind) } }) {
            throw ImportError.noStore(stray.kind)
        }
        try validate(batches)
        let record = ImportRecord(id: UUID(), source: plan.source, files: plan.files, importedAt: now(), timeZoneID: plan.timeZone.identifier,
                                  lines: plan.lines, dateRange: plan.dateRange, changes: changes)
        // Nothing new, as when a file is imported again: nothing to save or undo.
        guard !changes.isEmpty else { return record }
        try apply(batches, saving: record)
        return record
    }

    /// Removes what an import added and puts back what it replaced. A document
    /// edited since the import is kept as it is now.
    @discardableResult
    public func undo(_ id: UUID) throws -> UndoResult {
        guard var record = try records().first(where: { $0.id == id }) else { throw ImportError.invalid("That import isn't in this account") }
        guard record.undoneAt == nil else { throw ImportError.alreadyUndone }
        var result = UndoResult(undone: 0, kept: 0)
        var batches: [(host: DocumentHost, kind: String, writes: [DocumentWrite])] = []
        for host in hosts {
            for kind in host.documentKinds {
                var writes: [DocumentWrite] = []
                for change in record.changes where change.kind == kind {
                    let current = try host.payload(kind: kind, id: change.id)
                    guard current.map(Self.fingerprint) == change.after else {
                        if current != change.before { result.kept += 1 }
                        continue
                    }
                    writes.append(DocumentWrite(kind: kind, id: change.id, payload: change.before))
                    result.undone += 1
                }
                if !writes.isEmpty { batches.append((host, kind, writes)) }
            }
        }
        try validate(batches)
        record.undoneAt = now()
        try apply(batches, saving: record)
        return result
    }

    private func validate(_ batches: [(host: DocumentHost, kind: String, writes: [DocumentWrite])]) throws {
        for host in hosts {
            let writes = batches.filter { $0.host === host }.flatMap(\.writes)
            guard !writes.isEmpty else { continue }
            do {
                try host.validate(batch: writes)
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
