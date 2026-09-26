import Foundation

/// A file's tags as they were before the app first wrote to it, and the manual edits a write moved into the file.
public struct TagBackup: Sendable {
    public let id: Int64
    public let path: String
    public let original: TagWriter.Original
    public let moved: [EnrichField: String]
}

/// Tag backups: one per file, keeping the true original across later writes (a row plus `<id>.bin` holding the tag
/// region). A row is `pending` while a write is under way, so a crash can be sorted out on the next launch.
extension LibraryStore {
    public nonisolated var tagBackupsDirectory: URL {
        coversDirectory.deletingLastPathComponent().deletingLastPathComponent().appending(path: "TagBackups")
    }

    private nonisolated func blob(_ id: Int64) -> URL { tagBackupsDirectory.appending(path: "\(id).bin") }

    public func tagBackup(path: String) throws -> TagBackup? {
        try db.query("""
            SELECT id, format, audio_sha256, original_size, original_mtime, moved_edits FROM tag_backup WHERE path = ?
            """, [path]) { r in (r.int64(0)!, r.string(1)!, r.string(2)!, r.int64(3)!, r.double(4)!, r.string(5)) }
            .first.map { id, format, sha, size, mtime, moved in
                TagBackup(id: id, path: path,
                          original: TagWriter.Original(format: format, region: try Data(contentsOf: blob(id)), audioSHA256: sha,
                                                       version: FileVersion(size: size, mtime: mtime)),
                          moved: Self.decode(moved))
            }
    }

    public func tagBackupPaths() throws -> Set<String> {
        Set(try db.query("SELECT path FROM tag_backup WHERE state = 'written'") { $0.string(0)! })
    }

    /// Before a write (or restore): keeps an existing backup of this recording (the true original) or stores this one —
    /// replacing one of a different recording now at the path — durably, and marks the write as under way. Returns the
    /// backup's id and whether it existed.
    public func beginTagWrite(path: String, original: TagWriter.Original) throws -> (id: Int64, existed: Bool) {
        let now = Date().timeIntervalSince1970
        try db.execute("PRAGMA synchronous = FULL")   // the row must survive whatever happens to the file next
        defer { try? db.execute("PRAGMA synchronous = NORMAL") }
        if let (id, sha) = try db.query("SELECT id, audio_sha256 FROM tag_backup WHERE path = ?", [path], { ($0.int64(0)!, $0.string(1)!) }).first {
            if sha == original.audioSHA256 {
                try db.run("UPDATE tag_backup SET state = 'pending', updated_at = ? WHERE id = ?", [now, id])
                return (id, true)
            }
            try removeTagBackup(id: id)
        }
        try db.run("""
            INSERT INTO tag_backup(path, format, audio_sha256, original_size, original_mtime, state, updated_at)
            VALUES (?, ?, ?, ?, ?, 'pending', ?)
            """, [path, original.format, original.audioSHA256, original.version.size, original.version.mtime, now])
        let id = db.lastInsertRowID
        do {
            try FileManager.default.createDirectory(at: tagBackupsDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: blob(id).path, contents: nil)
            let handle = try FileHandle(forWritingTo: blob(id))
            defer { try? handle.close() }
            try handle.write(contentsOf: original.region)
            if fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 { try handle.synchronize() }
        } catch {
            try? db.run("DELETE FROM tag_backup WHERE id = ?", [id])
            try? FileManager.default.removeItem(at: blob(id))
            throw error
        }
        return (id, false)
    }

    /// After a write: what it wrote, and the manual edits it moved into the file (added to earlier ones; a cover moved
    /// before and now superseded loses its file).
    public func finishTagWrite(id: Int64, written: FileVersion, moved: [EnrichField: String]) throws {
        let earlier = Self.decode(try db.query("SELECT moved_edits FROM tag_backup WHERE id = ?", [id]) { $0.string(0) }.first ?? nil)
        if let old = earlier[.cover], let new = moved[.cover], old != new { try? FileManager.default.removeItem(at: coversDirectory.appending(path: old)) }
        try db.run("""
            UPDATE tag_backup SET state = 'written', written_size = ?, written_mtime = ?, moved_edits = ?, updated_at = ? WHERE id = ?
            """, [written.size, written.mtime, Self.encode(earlier.merging(moved) { $1 }), Date().timeIntervalSince1970, id])
    }

    /// Marks a restore as under way, so a crash in it gets its temp file cleaned up.
    public func beginTagRestore(id: Int64) throws {
        try db.run("UPDATE tag_backup SET state = 'pending', updated_at = ? WHERE id = ?", [Date().timeIntervalSince1970, id])
    }

    /// A write (or restore) that failed before touching the file: a new backup goes, an existing one is as before.
    public func abandonTagWrite(id: Int64, existed: Bool) throws {
        if existed {
            try db.run("UPDATE tag_backup SET state = 'written' WHERE id = ?", [id])
        } else {
            try removeTagBackup(id: id)
        }
    }

    /// After a restore.
    public func removeTagBackup(id: Int64) throws {
        try db.run("DELETE FROM tag_backup WHERE id = ?", [id])
        try? FileManager.default.removeItem(at: blob(id))
    }

    /// On launch, for writes a crash interrupted: leftover temp files go; a file still as backed up needs no backup unless
    /// an earlier write succeeded; one that was replaced counts as written. A file that can't be reached (a drive not
    /// mounted) is left for a later launch unless nothing was ever written to it.
    public func recoverTagWrites() throws {
        let pending = try db.query("""
            SELECT id, path, original_size, original_mtime, written_size FROM tag_backup WHERE state = 'pending'
            """) { r in (r.int64(0)!, r.string(1)!, FileVersion(size: r.int64(2)!, mtime: r.double(3)!), r.int64(4)) }
        for (id, path, original, written) in pending {
            let url = URL(filePath: path), folder = url.deletingLastPathComponent()
            let prefix = "." + url.deletingPathExtension().lastPathComponent + TagRegion.temporaryMarker
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: folder.appending(path: name))
            }
            guard let now = try? FileVersion(url) else {
                if written == nil { try removeTagBackup(id: id) }
                continue
            }
            guard now != original || written != nil else {
                try removeTagBackup(id: id)
                continue
            }
            try db.run("UPDATE tag_backup SET state = 'written', written_size = ?, written_mtime = ? WHERE id = ?", [now.size, now.mtime, id])
        }
    }

    /// A tag write leaves the audio as it was: its loudness analysis follows the file's new size and time.
    public func restampLoudness(trackID: Int64, from old: FileVersion, to new: FileVersion) throws {
        try db.run("UPDATE loudness SET file_size = ?, file_mtime = ? WHERE track_id = ? AND file_size = ? AND file_mtime = ?",
                   [new.size, new.mtime, trackID, old.size, old.mtime])
    }

    /// The file's own embedded lyrics text (a sidecar's aren't in the file).
    public func embeddedLyrics(trackID: Int64) throws -> String? {
        try db.query("SELECT lrc FROM lyrics WHERE track_id = ? AND source = 'embedded'", [trackID]) { $0.string(0) }.first ?? nil
    }

    /// The lyrics text the app shows from enrichment: a manual edit, else the online sources' in the user's order.
    public func enrichedLyrics(_ fingerprint: String) throws -> (text: String, manual: Bool)? {
        let sources = [EnrichSource.user] + onlineOrder().map(EnrichSource.online)
        let values = Dictionary(try db.query("SELECT source, value FROM enrichment WHERE fingerprint = ? AND field = 'lyrics'", [fingerprint]) {
            ($0.string(0)!, $0.string(1)!)
        }, uniquingKeysWith: { first, _ in first })
        return sources.lazy.compactMap { source in values[source.rawValue].map { ($0, source == .user) } }.first
    }

    private static func decode(_ json: String?) -> [EnrichField: String] {
        let raw = json.flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in EnrichField(rawValue: key).map { ($0, value) } })
    }

    private static func encode(_ edits: [EnrichField: String]) -> String? {
        edits.isEmpty ? nil : String(decoding: try! JSONEncoder().encode(Dictionary(uniqueKeysWithValues: edits.map { ($0.key.rawValue, $0.value) })), as: UTF8.self)
    }
}
