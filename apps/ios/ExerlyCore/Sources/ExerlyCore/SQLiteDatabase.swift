import Foundation
import SQLite3

/// A small wrapper over the system SQLite library. One connection, used from
/// one actor; not thread-safe by itself.
final class SQLiteDatabase {
    struct Error: Swift.Error, CustomStringConvertible {
        let code: Int32
        let message: String
        var description: String { "SQLite error \(code): \(message)" }
    }

    /// A value bound to or read from a statement.
    enum Value: Equatable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
    }

    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard status == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            handle = nil
            throw Error(code: status, message: message)
        }
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit { sqlite3_close(handle) }

    /// Closes the connection. Everything after that throws.
    func close() {
        sqlite3_close(handle)
        handle = nil
    }

    private func open() throws -> OpaquePointer {
        guard let handle else { throw Error(code: SQLITE_MISUSE, message: "The database is closed") }
        return handle
    }

    private func check(_ status: Int32) throws {
        guard status == SQLITE_OK || status == SQLITE_DONE || status == SQLITE_ROW else {
            throw Error(code: status, message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    /// Runs one statement with bound parameters.
    func execute(_ sql: String, _ parameters: Any?...) throws {
        _ = try query(sql, values: parameters.map(Self.value))
    }

    /// Runs several statements with no parameters.
    func executeScript(_ sql: String) throws {
        try check(sqlite3_exec(try open(), sql, nil, nil, nil))
    }

    func query(_ sql: String, _ parameters: Any?...) throws -> [[Value]] {
        try query(sql, values: parameters.map(Self.value))
    }

    func query(_ sql: String, values parameters: [Value]) throws -> [[Value]] {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(try open(), sql, -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            switch parameter {
            case .null: try check(sqlite3_bind_null(statement, index))
            case .integer(let value): try check(sqlite3_bind_int64(statement, index, value))
            case .real(let value): try check(sqlite3_bind_double(statement, index, value))
            case .text(let value): try check(sqlite3_bind_text(statement, index, value, -1, Self.transient))
            case .blob(let value):
                try value.withUnsafeBytes { bytes in
                    try check(sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.transient))
                }
            }
        }
        var rows: [[Value]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { try check(status); break }
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(statement, column)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return .blob(Data()) }
                    return .blob(Data(bytes: bytes, count: count))
                default: return .null
                }
            })
        }
        return rows
    }

    private var depth = 0
    private var committed: [(depth: Int, action: () -> Void)] = []

    /// Runs `body` in a transaction, committing on success and rolling back on
    /// error. A nested call uses a savepoint, so it can fail on its own.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        let savepoint = "level\(depth)"
        try executeScript(depth == 0 ? "BEGIN IMMEDIATE" : "SAVEPOINT \(savepoint)")
        depth += 1
        let level = depth
        let result: T
        do {
            result = try body()
            try executeScript(depth == 1 ? "COMMIT" : "RELEASE \(savepoint)")
        } catch {
            try? executeScript(depth == 1 ? "ROLLBACK" : "ROLLBACK TO \(savepoint); RELEASE \(savepoint)")
            committed.removeAll { $0.depth >= level }
            depth -= 1
            throw error
        }
        depth -= 1
        if depth == 0 {
            let actions = committed
            committed = []
            actions.forEach { $0.action() }
        }
        return result
    }

    /// Runs `action` after the outermost transaction commits; at once outside one.
    func afterCommit(_ action: @escaping () -> Void) {
        if depth == 0 { action() } else { committed.append((depth, action)) }
    }

    private static func value(_ parameter: Any?) -> Value {
        switch parameter {
        case nil: .null
        case let value as Value: value
        case let value as Int: .integer(Int64(value))
        case let value as Int64: .integer(value)
        case let value as Double: .real(value)
        case let value as String: .text(value)
        case let value as Data: .blob(value)
        case let value as Date: .real(value.timeIntervalSince1970)
        case let value as UUID: .text(value.uuidString)
        default: preconditionFailure("Unsupported SQLite parameter \(String(describing: parameter))")
        }
    }
}
