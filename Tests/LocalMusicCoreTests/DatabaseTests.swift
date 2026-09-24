import Foundation
import Testing
@testable import LocalMusicCore

struct DatabaseTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "lm-\(UUID().uuidString)/library.sqlite")
    }

    @Test func migratesFreshDatabaseAndReopensIdempotently() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let db = try Database(url: url)
            try Schema.migrate(db)
            #expect(try db.userVersion() == Schema.migrations.count)
            let tables = try db.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name") { $0.string(0)! }
            #expect(tables == ["library_root", "loudness", "lyrics", "setting", "track", "track_person"])
        }
        let db = try Database(url: url)
        try Schema.migrate(db)
        #expect(try db.userVersion() == Schema.migrations.count)
    }

    @Test func refusesNewerSchema() throws {
        let db = try Database(path: ":memory:")
        try db.execute("PRAGMA user_version = \(Schema.migrations.count + 1)")
        #expect(throws: SQLiteError.self) { try Schema.migrate(db) }
    }

    @Test func roundTripsValuesIncludingCJK() throws {
        let db = try Database(path: ":memory:")
        try db.execute("CREATE TABLE t(s TEXT, i INTEGER, d REAL, b BLOB, n TEXT)")
        let text = "春日影 (MyGO!!!!! ver.) — ヨルシカ"
        try db.run("INSERT INTO t VALUES (?, ?, ?, ?, ?)", [text, Int64(1) << 40, 0.25, Data([0, 1, 255]), String?.none])
        let row = try db.query("SELECT s, i, d, b, n FROM t") {
            ($0.string(0), $0.int64(1), $0.double(2), $0.data(3), $0.string(4))
        }.first
        #expect(row?.0 == text)
        #expect(row?.1 == 1 << 40)
        #expect(row?.2 == 0.25)
        #expect(row?.3 == Data([0, 1, 255]))
        #expect(row?.4 == nil)
    }

    @Test func rollsBackFailedTransaction() throws {
        let db = try Database(path: ":memory:")
        try db.execute("CREATE TABLE t(x INTEGER NOT NULL)")
        #expect(throws: SQLiteError.self) {
            try db.transaction {
                try db.run("INSERT INTO t VALUES (1)")
                try db.run("INSERT INTO t VALUES (NULL)")
            }
        }
        #expect(try db.query("SELECT COUNT(*) FROM t") { $0.int(0) } == [0])
    }

    @Test func deletingTrackCascadesToChildren() throws {
        let db = try Database(path: ":memory:")
        try Schema.migrate(db)
        try db.run("""
            INSERT INTO track(path, file_size, file_mtime, added_at, scanned_at, format, duration, title_source)
            VALUES ('/a.flac', 1, 0, 0, 0, 'flac', 1, 'tag')
            """)
        let id = db.lastInsertRowID
        try db.run("INSERT INTO track_person VALUES (?, 'artist', 0, 'YOASOBI', 'tag')", [id])
        try db.run("INSERT INTO lyrics VALUES (?, 'embedded', '[00:01.00]x', NULL)", [id])
        try db.run("DELETE FROM track WHERE id = ?", [id])
        #expect(try db.query("SELECT (SELECT COUNT(*) FROM track_person) + (SELECT COUNT(*) FROM lyrics)") { $0.int(0) } == [0])
    }

    @Test func storesCodableSettings() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LibraryStore(url: url)
        #expect(try await store.setting("volume", as: Double.self) == nil)
        try await store.setSetting("volume", 0.8)
        try await store.setSetting("volume", 0.6)
        try await store.setSetting("roots", ["/Users/x/Music"])
        #expect(try await store.setting("volume", as: Double.self) == 0.6)
        #expect(try await store.setting("roots", as: [String].self) == ["/Users/x/Music"])
    }
}
