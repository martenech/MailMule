import Foundation
import SQLite3

public enum SQLiteError: Error, LocalizedError {
    case open(String)
    case statement(String, sql: String)

    public var errorDescription: String? {
        switch self {
        case .open(let message): "Nepodarilo sa otvoriť index: \(message)"
        case .statement(let message, let sql): "Chyba indexu: \(message) (\(sql.prefix(80)))"
        }
    }
}

enum SQLValue {
    case text(String)
    case int(Int64)
    case real(Double)
    case null
}

protocol SQLBindable {
    var sqlValue: SQLValue { get }
}

extension String: SQLBindable { var sqlValue: SQLValue { .text(self) } }
extension Int: SQLBindable { var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { var sqlValue: SQLValue { .int(self) } }
extension UInt32: SQLBindable { var sqlValue: SQLValue { .int(Int64(self)) } }
extension Double: SQLBindable { var sqlValue: SQLValue { .real(self) } }
extension Bool: SQLBindable { var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

struct SQLRow {
    let values: [String: SQLValue]

    func string(_ key: String) -> String? {
        if case .text(let s) = values[key] { return s }
        if case .int(let i) = values[key] { return String(i) }
        return nil
    }

    func int(_ key: String) -> Int {
        switch values[key] {
        case .int(let i): Int(i)
        case .real(let d): Int(d)
        case .text(let s): Int(s) ?? 0
        default: 0
        }
    }

    func double(_ key: String) -> Double {
        switch values[key] {
        case .real(let d): d
        case .int(let i): Double(i)
        default: 0
        }
    }
}

/// Thin wrapper over the SQLite C API. Not thread-safe; owned by the `MailIndex` actor.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if sqlite3_open(url.path, &handle) != SQLITE_OK {
            throw SQLiteError.open(String(cString: sqlite3_errmsg(handle)))
        }
        // Wait for a concurrent writer instead of failing with "database is locked".
        sqlite3_busy_timeout(handle, 10_000)
        // mm_fold(x): Unicode lower-casing (SQLite's LOWER only handles ASCII), for case-insensitive tags.
        sqlite3_create_function_v2(handle, "mm_fold", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, _, values in
            guard let values, let text = sqlite3_value_text(values[0]) else {
                sqlite3_result_null(context)
                return
            }
            let folded = Tags.fold(String(cString: text))
            sqlite3_result_text(context, folded, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }, nil, nil, nil)
        // mm_search(x): case- and diacritic-insensitive, for search operators ("faktura" finds "Faktúra").
        sqlite3_create_function_v2(handle, "mm_search", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, _, values in
            guard let values, let text = sqlite3_value_text(values[0]) else {
                sqlite3_result_null(context)
                return
            }
            let folded = String(cString: text).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            sqlite3_result_text(context, folded, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }, nil, nil, nil)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        // The list queries read every message row; keep the database in memory instead of re-reading pages.
        try execute("PRAGMA cache_size=-65536")
        try execute("PRAGMA mmap_size=536870912")
        try execute("PRAGMA temp_store=MEMORY")
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String, _ params: [SQLBindable] = []) throws {
        _ = try query(sql, params)
    }

    @discardableResult
    func query(_ sql: String, _ params: [SQLBindable] = []) throws -> [SQLRow] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.statement(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        defer { sqlite3_finalize(statement) }

        for (index, param) in params.enumerated() {
            let i = Int32(index + 1)
            switch param.sqlValue {
            case .text(let s): sqlite3_bind_text(statement, i, s, -1, Self.transient)
            case .int(let v): sqlite3_bind_int64(statement, i, v)
            case .real(let d): sqlite3_bind_double(statement, i, d)
            case .null: sqlite3_bind_null(statement, i)
            }
        }

        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw SQLiteError.statement(String(cString: sqlite3_errmsg(handle)), sql: sql)
            }
            var values: [String: SQLValue] = [:]
            for col in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, col))
                switch sqlite3_column_type(statement, col) {
                case SQLITE_INTEGER: values[name] = .int(sqlite3_column_int64(statement, col))
                case SQLITE_FLOAT: values[name] = .real(sqlite3_column_double(statement, col))
                case SQLITE_NULL: values[name] = .null
                default: values[name] = .text(String(cString: sqlite3_column_text(statement, col)))
                }
            }
            rows.append(SQLRow(values: values))
        }
        return rows
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
