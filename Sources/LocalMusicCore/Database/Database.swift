import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite(\(code)): \(message)" }
}

public protocol SQLBindable {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32
}

private var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

extension Int64: SQLBindable {
    public func bind(to s: OpaquePointer, at i: Int32) -> Int32 { sqlite3_bind_int64(s, i, self) }
}
extension Int: SQLBindable {
    public func bind(to s: OpaquePointer, at i: Int32) -> Int32 { sqlite3_bind_int64(s, i, Int64(self)) }
}
extension Double: SQLBindable {
    public func bind(to s: OpaquePointer, at i: Int32) -> Int32 { sqlite3_bind_double(s, i, self) }
}
extension Bool: SQLBindable {
    public func bind(to s: OpaquePointer, at i: Int32) -> Int32 { sqlite3_bind_int(s, i, self ? 1 : 0) }
}
extension String: SQLBindable {
    public func bind(to s: OpaquePointer, at i: Int32) -> Int32 { sqlite3_bind_text(s, i, self, Int32(utf8.count), transient) }
}
extension Data: SQLBindable {
    public func bind(to s: OpaquePointer, at i: Int32) -> Int32 {
        isEmpty ? sqlite3_bind_zeroblob(s, i, 0)
            : withUnsafeBytes { sqlite3_bind_blob(s, i, $0.baseAddress, Int32($0.count), transient) }
    }
}
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public func bind(to s: OpaquePointer, at i: Int32) -> Int32 {
        switch self {
        case .some(let value): value.bind(to: s, at: i)
        case .none: sqlite3_bind_null(s, i)
        }
    }
}

public struct Row {
    fileprivate let handle: OpaquePointer

    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(handle, i) == SQLITE_NULL }
    public func int64(_ i: Int32) -> Int64? { isNull(i) ? nil : sqlite3_column_int64(handle, i) }
    public func int(_ i: Int32) -> Int? { int64(i).map(Int.init) }
    public func double(_ i: Int32) -> Double? { isNull(i) ? nil : sqlite3_column_double(handle, i) }

    public func string(_ i: Int32) -> String? {
        guard let p = sqlite3_column_text(handle, i) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: p, count: Int(sqlite3_column_bytes(handle, i))), as: UTF8.self)
    }

    public func data(_ i: Int32) -> Data? {
        guard !isNull(i) else { return nil }
        guard let p = sqlite3_column_blob(handle, i) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(handle, i)))
    }
}

public final class Statement {
    private let handle: OpaquePointer

    fileprivate init(handle: OpaquePointer) { self.handle = handle }
    deinit { sqlite3_finalize(handle) }

    public func run(_ params: [any SQLBindable] = []) throws {
        try bind(params)
        defer { sqlite3_reset(handle) }
        let rc = sqlite3_step(handle)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(rc) }
    }

    public func query<T>(_ params: [any SQLBindable] = [], _ map: (Row) throws -> T) throws -> [T] {
        try bind(params)
        defer { sqlite3_reset(handle) }
        var rows: [T] = []
        while true {
            switch sqlite3_step(handle) {
            case SQLITE_ROW: rows.append(try map(Row(handle: handle)))
            case SQLITE_DONE: return rows
            case let rc: throw error(rc)
            }
        }
    }

    private func bind(_ params: [any SQLBindable]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        for (i, param) in params.enumerated() {
            let rc = param.bind(to: handle, at: Int32(i + 1))
            guard rc == SQLITE_OK else { throw error(rc) }
        }
    }

    private func error(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(sqlite3_db_handle(handle))))
    }
}

/// Single-owner SQLite connection; confine each instance to one actor.
public final class Database {
    private let handle: OpaquePointer

    public init(path: String) throws {
        var h: OpaquePointer?
        let rc = sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let h else {
            let message = h.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close_v2(h)
            throw SQLiteError(code: rc, message: message)
        }
        handle = h
        sqlite3_busy_timeout(h, 5000)
        try execute("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL;")
    }

    public convenience init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.init(path: url.path)
    }

    deinit { sqlite3_close_v2(handle) }

    public func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &message)
        guard rc == SQLITE_OK else {
            defer { sqlite3_free(message) }
            throw SQLiteError(code: rc, message: message.map { String(cString: $0) } ?? "exec failed")
        }
    }

    public func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)))
        }
        return Statement(handle: stmt)
    }

    public func run(_ sql: String, _ params: [any SQLBindable] = []) throws {
        try prepare(sql).run(params)
    }

    public func query<T>(_ sql: String, _ params: [any SQLBindable] = [], _ map: (Row) throws -> T) throws -> [T] {
        try prepare(sql).query(params, map)
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func userVersion() throws -> Int {
        try query("PRAGMA user_version") { $0.int(0) ?? 0 }.first ?? 0
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
}
