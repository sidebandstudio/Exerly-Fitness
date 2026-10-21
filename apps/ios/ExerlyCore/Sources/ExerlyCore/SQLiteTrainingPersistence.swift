import Foundation

/// Training data in a local SQLite database. Each session and custom exercise
/// is one JSON document keyed by its ID, written in one statement, so a crash
/// leaves either the old or the new version. The file uses write-ahead logging
/// with full sync. On iOS it gets the default data-protection class,
/// complete until first user authentication, so it is encrypted at rest and
/// still writable in the background after the first unlock.
@MainActor
public final class SQLiteTrainingPersistence: TrainingPersistence {
    public enum PersistenceError: Error, Equatable {
        /// The file was written by a newer app version. It is never downgraded.
        case newerSchema(found: Int, supported: Int)
        /// Account IDs become directory names, so only letters, digits and dashes are allowed.
        case invalidAccountID(String)
    }

    public static let currentSchemaVersion = 4

    /// Rows that could not be decoded, as `table/id`. They stay in the file
    /// untouched so a later version can read them.
    public private(set) var unreadableRows: [String] = []

    let database: SQLiteDatabase
    private let path: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    public private(set) var isClosed = false

    /// Every persistence opened in this process, so deleting a file can close
    /// the ones still using it.
    private struct Opened { let path: String; weak var persistence: SQLiteTrainingPersistence? }
    private static var opened: [Opened] = []

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        database = try SQLiteDatabase(url: url)
        path = url.standardizedFileURL.path
        try database.executeScript("PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL; PRAGMA foreign_keys = ON;")
        try migrate()
        Self.opened.removeAll { $0.persistence == nil }
        Self.opened.append(Opened(path: path, persistence: self))
    }

    /// Closes the file. Reads and writes after this throw, so a store that
    /// outlives its account can't write to it.
    public func close() {
        database.close()
        isClosed = true
    }

    /// `Application Support/Exerly/<accountID>/exerly.sqlite`. Each account
    /// gets its own file, so signing in as someone else never shows the
    /// previous person's training.
    public static func defaultURL(accountID: String) throws -> URL {
        guard (1...64).contains(accountID.count),
              accountID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { throw PersistenceError.invalidAccountID(accountID) }
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Exerly", isDirectory: true)
            .appendingPathComponent(accountID, isDirectory: true)
            .appendingPathComponent("exerly.sqlite")
    }

    /// Removes an account's local database, for after the account is deleted.
    /// Any persistence still using the file is closed first, so nothing that
    /// still holds one can write to the deleted file, or to a new one at the
    /// same path.
    public static func deleteDatabase(accountID: String) throws {
        let url = try defaultURL(accountID: accountID)
        for entry in opened where entry.path == url.standardizedFileURL.path { entry.persistence?.close() }
        let directory = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func schemaVersion() throws -> Int {
        guard case .integer(let version) = try database.query("PRAGMA user_version").first?.first else { return 0 }
        return Int(version)
    }

    /// Ordered migrations; migration `n` moves the schema from version n to n + 1.
    private static let migrations = [
        """
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            started_at REAL NOT NULL,
            ended_at REAL,
            payload BLOB NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX sessions_started_at ON sessions (started_at);
        CREATE TABLE custom_exercises (
            id TEXT PRIMARY KEY,
            payload BLOB NOT NULL,
            updated_at REAL NOT NULL
        );
        """,
        """
        CREATE TABLE settings (
            key TEXT PRIMARY KEY,
            value BLOB NOT NULL,
            updated_at REAL NOT NULL
        );
        """,
        """
        CREATE TABLE sync_bases (
            kind TEXT NOT NULL,
            id TEXT NOT NULL,
            revision INTEGER NOT NULL,
            payload BLOB,
            push_key TEXT,
            push_hash TEXT,
            PRIMARY KEY (kind, id)
        );
        """,
        """
        CREATE TABLE documents (
            kind TEXT NOT NULL,
            id TEXT NOT NULL,
            payload BLOB NOT NULL,
            PRIMARY KEY (kind, id)
        );
        """,
    ]

    private func migrate() throws {
        let version = try schemaVersion()
        guard version <= Self.currentSchemaVersion else {
            throw PersistenceError.newerSchema(found: version, supported: Self.currentSchemaVersion)
        }
        for step in version..<Self.currentSchemaVersion {
            try database.transaction {
                try database.executeScript(Self.migrations[step])
                try database.executeScript("PRAGMA user_version = \(step + 1)")
            }
        }
    }

    public func performAtomically(_ body: () throws -> Void) throws {
        try database.transaction(body)
    }

    public func afterCommit(_ action: @escaping () -> Void) {
        database.afterCommit(action)
    }

    // MARK: TrainingPersistence

    public func loadSessions() throws -> [WorkoutSession] {
        try load(WorkoutSession.self, table: "sessions", order: "started_at")
    }

    public func loadCustomExercises() throws -> [Exercise] {
        try load(Exercise.self, table: "custom_exercises", order: "id")
    }

    public func save(_ session: WorkoutSession) throws {
        try database.execute(
            """
            INSERT INTO sessions (id, started_at, ended_at, payload, updated_at) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (id) DO UPDATE SET started_at = excluded.started_at, ended_at = excluded.ended_at,
                payload = excluded.payload, updated_at = excluded.updated_at
            """,
            session.id.uuidString, session.startedAt, session.endedAt, try encoder.encode(session), Date()
        )
    }

    public func deleteSession(_ id: UUID) throws {
        try database.execute("DELETE FROM sessions WHERE id = ?", id.uuidString)
    }

    public func save(_ exercise: Exercise) throws {
        try database.execute(
            """
            INSERT INTO custom_exercises (id, payload, updated_at) VALUES (?, ?, ?)
            ON CONFLICT (id) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at
            """,
            exercise.id.rawValue, try encoder.encode(exercise), Date()
        )
    }

    public func loadValue(forKey key: String) throws -> Data? {
        guard case .blob(let value) = try database.query("SELECT value FROM settings WHERE key = ?", key).first?.first else {
            return nil
        }
        return value
    }

    public func saveValue(_ value: Data?, forKey key: String) throws {
        if let value {
            try database.execute(
                """
                INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?)
                ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                """,
                key, value, Date()
            )
        } else {
            try database.execute("DELETE FROM settings WHERE key = ?", key)
        }
    }

    private func load<T: Decodable>(_ type: T.Type, table: String, order: String) throws -> [T] {
        var values: [T] = []
        for row in try database.query("SELECT id, payload FROM \(table) ORDER BY \(order)") {
            guard case .text(let id) = row[0] else { continue }
            if case .blob(let payload) = row[1], let value = try? decoder.decode(T.self, from: payload) {
                values.append(value)
            } else if !unreadableRows.contains("\(table)/\(id)") {
                unreadableRows.append("\(table)/\(id)")
            }
        }
        return values
    }
}

extension SQLiteTrainingPersistence: DocumentPersistence {
    public func loadDocuments(kind: String) throws -> [Data] {
        try database.query("SELECT payload FROM documents WHERE kind = ? ORDER BY id", kind).compactMap { row in
            if case .blob(let payload) = row[0] { return payload }
            return nil
        }
    }

    public func saveDocument(kind: String, id: String, payload: Data) throws {
        try database.execute(
            "INSERT INTO documents (kind, id, payload) VALUES (?, ?, ?) ON CONFLICT (kind, id) DO UPDATE SET payload = excluded.payload",
            kind, id, payload
        )
    }

    public func deleteDocument(kind: String, id: String) throws {
        try database.execute("DELETE FROM documents WHERE kind = ? AND id = ?", kind, id)
    }
}
