import Foundation

/// Append-only: never edit a migration once committed.
enum Schema {
    static let migrations: [String] = [
        """
        CREATE TABLE library_root(
          id INTEGER PRIMARY KEY,
          path TEXT NOT NULL UNIQUE,
          kind TEXT NOT NULL CHECK(kind IN ('include','exclude')),
          added_at REAL NOT NULL);
        CREATE TABLE track(
          id INTEGER PRIMARY KEY,
          path TEXT NOT NULL UNIQUE,
          file_size INTEGER NOT NULL, file_mtime REAL NOT NULL, sidecar_mtime REAL,
          added_at REAL NOT NULL, scanned_at REAL NOT NULL, scan_error TEXT,
          fingerprint TEXT,
          format TEXT NOT NULL, codec TEXT, sample_rate INTEGER, bit_depth INTEGER, channels INTEGER,
          frame_count INTEGER, duration REAL NOT NULL,
          title TEXT, title_source TEXT NOT NULL, album TEXT, album_artist TEXT,
          track_no INTEGER, track_total INTEGER, disc_no INTEGER, disc_total INTEGER,
          year INTEGER, date TEXT, genre TEXT,
          cover_offset INTEGER, cover_length INTEGER, cover_mime TEXT,
          has_cover INTEGER NOT NULL DEFAULT 0, has_lyrics INTEGER NOT NULL DEFAULT 0,
          rg_track_gain REAL, rg_track_peak REAL, rg_album_gain REAL, rg_album_peak REAL,
          ncm_key TEXT, extra_json TEXT);
        CREATE TABLE track_person(
          track_id INTEGER NOT NULL REFERENCES track(id) ON DELETE CASCADE,
          role TEXT NOT NULL, ord INTEGER NOT NULL, name TEXT NOT NULL, source TEXT NOT NULL,
          PRIMARY KEY(track_id, role, ord)) WITHOUT ROWID;
        CREATE INDEX idx_person ON track_person(role, name);
        CREATE TABLE lyrics(
          track_id INTEGER NOT NULL REFERENCES track(id) ON DELETE CASCADE,
          source TEXT NOT NULL, lrc TEXT NOT NULL, translation TEXT,
          PRIMARY KEY(track_id, source)) WITHOUT ROWID;
        CREATE TABLE setting(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
        """,
        """
        CREATE TABLE loudness(
          track_id INTEGER PRIMARY KEY REFERENCES track(id) ON DELETE CASCADE,
          file_size INTEGER NOT NULL, file_mtime REAL NOT NULL, analyzer_version INTEGER NOT NULL,
          integrated_lufs REAL, sample_peak REAL, block_energies BLOB, analyzed_at REAL NOT NULL, error TEXT);
        """,
        """
        CREATE TABLE liked(
          track_id INTEGER PRIMARY KEY REFERENCES track(id) ON DELETE CASCADE,
          liked_at REAL NOT NULL);
        CREATE TABLE playlist(
          id INTEGER PRIMARY KEY,
          name TEXT NOT NULL, created_at REAL NOT NULL, ord INTEGER NOT NULL);
        CREATE TABLE playlist_item(
          playlist_id INTEGER NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
          pos INTEGER NOT NULL,
          track_id INTEGER NOT NULL REFERENCES track(id) ON DELETE CASCADE,
          PRIMARY KEY(playlist_id, pos)) WITHOUT ROWID;
        CREATE INDEX idx_playlist_item_track ON playlist_item(track_id);
        """,
        """
        CREATE TABLE enrichment(
          fingerprint TEXT NOT NULL, field TEXT NOT NULL,
          source TEXT NOT NULL CHECK(source IN ('user','netease')),
          value TEXT NOT NULL, updated_at REAL NOT NULL,
          PRIMARY KEY(fingerprint, field, source)) WITHOUT ROWID;
        CREATE TABLE netease_match(
          fingerprint TEXT PRIMARY KEY, song_id INTEGER, confidence REAL,
          status TEXT NOT NULL CHECK(status IN ('auto','confirmed','pending','none','rejected')),
          candidates TEXT, updated_at REAL NOT NULL);
        CREATE INDEX idx_track_fingerprint ON track(fingerprint);
        ALTER TABLE track ADD COLUMN track_no_source TEXT;
        """,
    ]

    static func migrate(_ db: Database) throws {
        let current = try db.userVersion()
        guard (0...migrations.count).contains(current) else {
            throw SQLiteError(code: -1, message: "unsupported database schema v\(current) (supported ≤ v\(migrations.count))")
        }
        for version in current..<migrations.count {
            try db.transaction {
                try db.execute(migrations[version])
                try db.execute("PRAGMA user_version = \(version + 1)")
            }
        }
    }
}
