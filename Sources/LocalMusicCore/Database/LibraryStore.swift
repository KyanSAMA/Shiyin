import Foundation

public actor LibraryStore {
    let db: Database

    public init(url: URL) throws {
        db = try Database(url: url)
        try Schema.migrate(db)
    }

    public func setting<T: Decodable & Sendable>(_ key: String, as type: T.Type) throws -> T? {
        guard let json = try db.query("SELECT value FROM setting WHERE key = ?", [key], { $0.string(0) }).first ?? nil
        else { return nil }
        return try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    public func setSetting<T: Encodable & Sendable>(_ key: String, _ value: T) throws {
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try db.run("INSERT INTO setting(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, json])
    }
}
