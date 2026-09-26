import Foundation

public actor LibraryStore {
    let db: Database
    /// Enrichment covers, next to the database.
    public nonisolated let coversDirectory: URL

    public init(url: URL) throws {
        db = try Database(url: url)
        coversDirectory = url.deletingLastPathComponent().appending(path: "Enriched/covers")
        try Schema.migrate(db)
    }

    // MARK: Settings

    public func setting<T: Decodable & Sendable>(_ key: String, as type: T.Type) throws -> T? {
        guard let json = try db.query("SELECT value FROM setting WHERE key = ?", [key], { $0.string(0) }).first ?? nil
        else { return nil }
        return try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    public func setSetting<T: Encodable & Sendable>(_ key: String, _ value: T) throws {
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try db.run("INSERT INTO setting(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, json])
    }

    // MARK: Roots

    /// Stored roots; the defaults are seeded exactly once, so a user who removes every folder keeps an empty list.
    public func roots() throws -> LibraryRoots {
        if try setting("rootsSeeded", as: Bool.self) != true { try setRoots(.defaults) }
        let rows = try db.query("SELECT path, kind FROM library_root ORDER BY id") { ($0.string(0)!, $0.string(1)!) }
        return LibraryRoots(include: rows.filter { $0.1 == "include" }.map(\.0), exclude: rows.filter { $0.1 == "exclude" }.map(\.0))
    }

    public func setRoots(_ roots: LibraryRoots) throws {
        try db.transaction {
            try db.run("DELETE FROM library_root")
            let insert = try db.prepare("INSERT OR IGNORE INTO library_root(path, kind, added_at) VALUES (?, ?, ?)")
            let now = Date().timeIntervalSince1970
            for path in roots.include { try insert.run([path, "include", now]) }
            for path in roots.exclude { try insert.run([path, "exclude", now]) }
            try setSetting("rootsSeeded", true)
        }
    }

    // MARK: Tracks

    func stamps() throws -> [String: StoredStamp] {
        let rows = try db.query("""
            SELECT path, id, file_size, file_mtime, sidecar_mtime, fingerprint IS NULL AND scan_error IS NULL FROM track
            """) {
            ($0.string(0)!.pathKey, StoredStamp(id: $0.int64(1)!, size: $0.int64(2)!, mtime: $0.double(3)!, sidecarMtime: $0.double(4),
                                                needsFingerprint: $0.int(5) == 1))
        }
        return Dictionary(rows, uniquingKeysWith: { first, _ in first })
    }

    /// One transaction per call; the scanner calls this per batch.
    func apply(_ scanned: [ScannedTrack], removing ids: [Int64]) throws {
        let now = Date().timeIntervalSince1970
        try db.transaction {
            for track in scanned { try upsert(track, now: now) }
            let delete = try db.prepare("DELETE FROM track WHERE id = ?")
            for id in ids { try delete.run([id]) }
        }
    }

    private func upsert(_ track: ScannedTrack, now: Double) throws {
        let stamp = track.stamp
        var values: [(String, any SQLBindable)] = [
            ("path", stamp.path), ("file_size", stamp.size), ("file_mtime", stamp.mtime), ("sidecar_mtime", track.sidecarMtime),
            ("added_at", stamp.created), ("scanned_at", now), ("format", URL(filePath: stamp.path).pathExtension.lowercased()),
        ]
        var people: [Person] = []
        var embeddedLyrics: String?
        switch track.result {
        case .success(let (raw, meta)):
            let p = raw.properties
            values += [
                ("scan_error", String?.none), ("codec", p.codec), ("sample_rate", p.sampleRate), ("bit_depth", p.bitDepth),
                ("channels", p.channels), ("frame_count", p.frameCount), ("duration", p.duration),
                ("title", meta.title), ("title_source", meta.titleSource.rawValue), ("album", meta.album),
                ("album_artist", meta.albumArtist), ("track_no", meta.trackNo), ("track_no_source", meta.trackNoSource?.rawValue),
                ("track_total", meta.trackTotal),
                ("disc_no", meta.discNo), ("disc_total", meta.discTotal), ("year", meta.year), ("date", meta.date),
                ("genre", meta.genre), ("cover_offset", raw.cover?.offset), ("cover_length", raw.cover?.length),
                ("cover_mime", raw.cover?.mime), ("has_cover", raw.cover != nil),
                ("has_lyrics", meta.lyrics != nil || track.sidecarLyrics != nil),
                ("rg_track_gain", meta.replayGain.trackGain), ("rg_track_peak", meta.replayGain.trackPeak),
                ("rg_album_gain", meta.replayGain.albumGain), ("rg_album_peak", meta.replayGain.albumPeak),
                ("ncm_key", meta.ncmKey), ("fingerprint", raw.fingerprint),
            ]
            people = meta.people
            embeddedLyrics = meta.lyrics
        case .failure(let failure):
            let stem = URL(filePath: stamp.path).deletingPathExtension().lastPathComponent
            values += [("scan_error", failure.message), ("duration", 0.0), ("title", stem), ("title_source", "filename")]
        }

        // Known rows update by id (also rewriting `path`, so an NFD→NFC rename never duplicates); `added_at` is kept.
        let id: Int64
        if let storedID = track.storedID {
            let updates = values.filter { $0.0 != "added_at" }
            try db.run("UPDATE track SET \(updates.map { "\($0.0) = ?" }.joined(separator: ", ")) WHERE id = ?",
                       updates.map(\.1) + [storedID])
            id = storedID
        } else {
            let columns = values.map(\.0)
            let updates = columns.filter { $0 != "path" && $0 != "added_at" }.map { "\($0) = excluded.\($0)" }
            guard let inserted = try db.query("""
                INSERT INTO track(\(columns.joined(separator: ", "))) VALUES (\(Array(repeating: "?", count: columns.count).joined(separator: ", ")))
                ON CONFLICT(path) DO UPDATE SET \(updates.joined(separator: ", ")) RETURNING id
                """, values.map(\.1), { $0.int64(0) }).first ?? nil else { return }
            id = inserted
        }

        try db.run("DELETE FROM track_person WHERE track_id = ?", [id])
        try db.run("DELETE FROM lyrics WHERE track_id = ?", [id])
        let person = try db.prepare("INSERT INTO track_person(track_id, role, ord, name, source) VALUES (?, ?, ?, ?, ?)")
        var order: [PersonRole: Int] = [:]
        for p in people {
            try person.run([id, p.role.rawValue, order[p.role, default: 0], p.name, p.source.rawValue])
            order[p.role, default: 0] += 1
        }
        let lyrics = try db.prepare("INSERT INTO lyrics(track_id, source, lrc) VALUES (?, ?, ?)")
        if let embeddedLyrics { try lyrics.run([id, "embedded", embeddedLyrics]) }
        if let sidecar = track.sidecarLyrics { try lyrics.run([id, "sidecar", sidecar]) }
    }

    // MARK: Liked

    /// Liked track ids with when they were liked.
    public func liked() throws -> [Int64: Date] {
        Dictionary(uniqueKeysWithValues: try db.query("SELECT track_id, liked_at FROM liked") {
            ($0.int64(0)!, Date(timeIntervalSince1970: $0.double(1)!))
        })
    }

    /// Tracks a scan removed meanwhile are skipped.
    public func setLiked(_ ids: [Int64], _ liked: Bool) throws {
        let now = Date().timeIntervalSince1970
        try db.transaction {
            let statement = try db.prepare(liked
                ? "INSERT OR IGNORE INTO liked(track_id, liked_at) SELECT ?, ? WHERE EXISTS (SELECT 1 FROM track WHERE id = ?)"
                : "DELETE FROM liked WHERE track_id = ?")
            for id in ids { try statement.run(liked ? [id, now, id] : [id]) }
        }
    }

    // MARK: Playlists

    public func playlists() throws -> [Playlist] {
        let items = Dictionary(grouping: try db.query("SELECT playlist_id, track_id FROM playlist_item ORDER BY playlist_id, pos") {
            ($0.int64(0)!, $0.int64(1)!)
        }, by: \.0)
        return try db.query("SELECT id, name FROM playlist ORDER BY ord, id") {
            let id = $0.int64(0)!
            return Playlist(id: id, name: $0.string(1)!, trackIDs: items[id]?.map(\.1) ?? [])
        }
    }

    /// Appended after the existing playlists.
    public func createPlaylist(_ name: String, tracks: [Int64]) throws -> Playlist {
        try db.transaction {
            try db.run("INSERT INTO playlist(name, created_at, ord) SELECT ?, ?, COALESCE(MAX(ord), 0) + 1 FROM playlist",
                       [name, Date().timeIntervalSince1970])
            let id = db.lastInsertRowID
            return Playlist(id: id, name: name, trackIDs: try replaceItems(id, tracks))
        }
    }

    public func renamePlaylist(_ id: Int64, _ name: String) throws {
        try db.run("UPDATE playlist SET name = ? WHERE id = ?", [name, id])
    }

    public func deletePlaylist(_ id: Int64) throws {
        try db.run("DELETE FROM playlist WHERE id = ?", [id])
    }

    /// Replaces the playlist's contents, skipping repeats and tracks a scan removed meanwhile; returns what was stored.
    @discardableResult
    public func setPlaylistTracks(_ id: Int64, _ tracks: [Int64]) throws -> [Int64] {
        try db.transaction { try replaceItems(id, tracks) }
    }

    private func replaceItems(_ id: Int64, _ tracks: [Int64]) throws -> [Int64] {
        try db.run("DELETE FROM playlist_item WHERE playlist_id = ?", [id])
        let insert = try db.prepare("""
            INSERT OR IGNORE INTO playlist_item(playlist_id, pos, track_id)
            SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM track WHERE id = ?)
            """)
        var seen = Set<Int64>()
        for track in tracks where seen.insert(track).inserted { try insert.run([id, seen.count, track, track]) }
        return try db.query("SELECT track_id FROM playlist_item WHERE playlist_id = ? ORDER BY pos", [id]) { $0.int64(0)! }
    }

    // MARK: Loudness

    /// Tracks without a loudness row for their current file stamp and analyzer version.
    func loudnessPending() throws -> [LoudnessJob] {
        try db.query("""
            SELECT t.id, t.path, t.file_size, t.file_mtime FROM track t LEFT JOIN loudness l ON l.track_id = t.id
            WHERE t.scan_error IS NULL AND (l.track_id IS NULL OR l.file_size != t.file_size OR l.file_mtime != t.file_mtime
                  OR l.analyzer_version != ?)
            """, [LoudnessAnalyzer.version]) {
            LoudnessJob(trackID: $0.int64(0)!, url: URL(filePath: $0.string(1)!), size: $0.int64(2)!, mtime: $0.double(3)!)
        }
    }

    /// A failure is recorded too, so an undecodable file isn't retried until it changes. Silently skipped when the
    /// track was deleted or moved meanwhile.
    func saveLoudness(_ job: LoudnessJob, _ result: Result<LoudnessResult, Error>) throws {
        let (integrated, peak, blocks, error): (Double?, Double?, Data?, String?) = switch result {
        case .success(let r): (r.integrated, r.samplePeak, r.blockEnergies.withUnsafeBytes { Data($0) }, nil)
        case .failure(let e): (nil, nil, nil, String(describing: e))
        }
        try db.run("""
            INSERT OR REPLACE INTO loudness(track_id, file_size, file_mtime, analyzer_version, integrated_lufs, sample_peak,
                                            block_energies, analyzed_at, error)
            SELECT ?, ?, ?, ?, ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM track WHERE id = ? AND path = ?)
            """, [job.trackID, job.size, job.mtime, LoudnessAnalyzer.version, integrated, peak, blocks,
                  Date().timeIntervalSince1970, error, job.trackID, job.url.path])
    }

    /// Analyses of the tracks' current files.
    private static let currentLoudness = """
        FROM loudness l JOIN track t ON t.id = l.track_id AND t.file_size = l.file_size AND t.file_mtime = l.file_mtime
        WHERE l.analyzer_version = ?
        """

    func loudness(for ids: [Int64]) throws -> [Int64: LoudnessRecord] {
        guard !ids.isEmpty else { return [:] }
        let rows = try db.query("""
            SELECT l.track_id, l.integrated_lufs, l.sample_peak, l.block_energies \(Self.currentLoudness)
              AND l.error IS NULL AND l.track_id IN (\(ids.map(String.init).joined(separator: ",")))
            """, [LoudnessAnalyzer.version]) { r in
            (r.int64(0)!, LoudnessRecord(integrated: r.double(1), samplePeak: r.double(2)!,
                                         blockEnergies: r.data(3).map { data in data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } } ?? []))
        }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    /// Every current analysis without the block energies; a failed one has no peak.
    func loudnessSummaries() throws -> [Int64: LoudnessSummary] {
        Dictionary(uniqueKeysWithValues: try db.query("SELECT l.track_id, l.integrated_lufs, l.sample_peak \(Self.currentLoudness)",
                                                      [LoudnessAnalyzer.version]) {
            ($0.int64(0)!, LoudnessSummary(integrated: $0.double(1), samplePeak: $0.double(2)))
        })
    }

    func loudnessProgress() throws -> LoudnessService.Progress {
        try db.query("""
            SELECT COUNT(l.track_id) - COUNT(l.error), COUNT(l.error), COUNT(*) FROM track t LEFT JOIN loudness l
            ON l.track_id = t.id AND l.file_size = t.file_size AND l.file_mtime = t.file_mtime AND l.analyzer_version = ?
            WHERE t.scan_error IS NULL
            """, [LoudnessAnalyzer.version]) { LoudnessService.Progress(analyzed: $0.int(0)!, failed: $0.int(1)!, total: $0.int(2)!) }[0]
    }

    /// A sidecar `.lrc` wins over embedded lyrics, so lyrics can be fixed without touching the audio file.
    /// Manual lyrics, else the sidecar, else embedded, else the online sources' in the user's order.
    public func lyrics(for trackID: Int64) throws -> Lyrics? {
        // An empty or header-only sidecar parses to nil and must not hide embedded lyrics.
        let file = try db.query("SELECT lrc FROM lyrics WHERE track_id = ? ORDER BY source = 'sidecar' DESC", [trackID]) { $0.string(0) }
        let sources = [EnrichSource.user] + onlineOrder().map(EnrichSource.online)
        let rank = sources.enumerated().map { "WHEN '\($0.element.rawValue)' THEN \($0.offset)" }.joined(separator: " ") + " ELSE \(sources.count)"
        let enriched = try db.query("""
            SELECT e.source = 'user', e.value FROM enrichment e JOIN track t ON t.fingerprint = e.fingerprint
            WHERE t.id = ? AND e.field = 'lyrics' ORDER BY CASE e.source \(rank) END
            """, [trackID]) { ($0.int(0) == 1, $0.string(1)) }
        // Manual lyrics, the file's, then the online sources'.
        let ordered = enriched.filter(\.0).map(\.1) + file + enriched.filter { !$0.0 }.map(\.1)
        return ordered.lazy.compactMap { $0.flatMap(LRCParser.parse) }.first
    }

    // MARK: Enrichment

    /// Sets (non-nil) or removes (nil) one source's values for these recordings; fields not given are left alone.
    public func setEnrichment(_ fingerprints: [String], _ values: [EnrichField: String?], source: EnrichSource) throws {
        try db.transaction { try setEnrichmentRows(fingerprints, values, source: source) }
    }

    private func setEnrichmentRows(_ fingerprints: [String], _ values: [EnrichField: String?], source: EnrichSource) throws {
        let now = Date().timeIntervalSince1970
        let set = try db.prepare("""
            INSERT INTO enrichment(fingerprint, field, source, value, updated_at) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(fingerprint, field, source) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
            """)
        let remove = try db.prepare("DELETE FROM enrichment WHERE fingerprint = ? AND field = ? AND source = ?")
        for fingerprint in fingerprints {
            for (field, value) in values {
                if let value { try set.run([fingerprint, field.rawValue, source.rawValue, value, now]) }
                else { try remove.run([fingerprint, field.rawValue, source.rawValue]) }
            }
        }
    }

    public func clearEnrichment(_ fingerprints: [String], source: EnrichSource) throws {
        try db.transaction {
            let remove = try db.prepare("DELETE FROM enrichment WHERE fingerprint = ? AND source = ?")
            for fingerprint in fingerprints { try remove.run([fingerprint, source.rawValue]) }
        }
    }

    public func setMatch(_ fingerprint: String, _ status: MatchStatus, candidates: [OnlineSong] = []) throws {
        let json = candidates.isEmpty ? nil : String(decoding: try JSONEncoder().encode(candidates), as: UTF8.self)
        try db.run("INSERT OR REPLACE INTO online_match(fingerprint, status, candidates, updated_at) VALUES (?, ?, ?, ?)",
                   [fingerprint, status.rawValue, json, Date().timeIntervalSince1970])
    }

    /// Replaces these sources' layers (others stay), sets the `user` edits and records the match, in one transaction;
    /// returns the cover files the replaced layers and edits referenced and the new ones don't.
    public func applyMatch(_ fingerprint: String, _ layers: [OnlineSource: [EnrichField: String]], _ status: MatchStatus,
                           candidates: [OnlineSong] = [], user: [EnrichField: String] = [:]) throws -> [String] {
        try db.transaction {
            var covers: [String] = []
            for (source, values) in layers {
                if let cover = try enrichment(fingerprint, source: .online(source))[.cover], cover != values[.cover] { covers.append(cover) }
                try db.run("DELETE FROM enrichment WHERE fingerprint = ? AND source = ?", [fingerprint, source.rawValue])
                try setEnrichmentRows([fingerprint], values, source: .online(source))
            }
            if let new = user[.cover], let old = try enrichment(fingerprint, source: .user)[.cover], old != new { covers.append(old) }
            try setEnrichmentRows([fingerprint], user, source: .user)
            try setMatch(fingerprint, status, candidates: candidates)
            return covers
        }
    }

    /// Drops every online layer and marks the recording so batch enrichment leaves it alone; returns the cover files
    /// they referenced.
    public func rejectMatch(_ fingerprint: String) throws -> [String] {
        try db.transaction {
            let covers = try db.query("SELECT value FROM enrichment WHERE fingerprint = ? AND field = 'cover' AND source != 'user'",
                                      [fingerprint]) { $0.string(0)! }
            try db.run("DELETE FROM enrichment WHERE fingerprint = ? AND source != 'user'", [fingerprint])
            try setMatch(fingerprint, .rejected)
            return covers
        }
    }

    /// All matches, or one recording's.
    public func matches(_ fingerprint: String? = nil) throws -> [String: MatchState] {
        let sql = "SELECT fingerprint, status, candidates FROM online_match" + (fingerprint == nil ? "" : " WHERE fingerprint = ?")
        return Dictionary(try db.query(sql, fingerprint.map { [$0] } ?? []) { r in
            (r.string(0)!, MatchState(status: MatchStatus(rawValue: r.string(1)!) ?? .none,
                                      candidates: r.string(2).flatMap { try? JSONDecoder().decode([OnlineSong].self, from: Data($0.utf8)) } ?? []))
        }, uniquingKeysWith: { first, _ in first })
    }

    /// The order online layers show in.
    private func onlineOrder() -> [OnlineSource] {
        ((try? setting(OnlineSettings.key, as: OnlineSettings.self)) ?? .default).ordered
    }

    /// NetEase ids from the files' "163 key" comments.
    public func neteaseKeys() throws -> [Int64: Int64] {
        Dictionary(try db.query("SELECT id, ncm_key FROM track WHERE ncm_key IS NOT NULL") { r in
            r.string(1).flatMap(NCMKey.songID).map { (r.int64(0)!, $0) }
        }.compactMap { $0 }, uniquingKeysWith: { first, _ in first })
    }

    public func enrichment(_ fingerprint: String, source: EnrichSource) throws -> [EnrichField: String] {
        Dictionary(try db.query("SELECT field, value FROM enrichment WHERE fingerprint = ? AND source = ?", [fingerprint, source.rawValue]) {
            (EnrichField(rawValue: $0.string(0)!), $0.string(1)!)
        }.compactMap { field, value in field.map { ($0, value) } }, uniquingKeysWith: { first, _ in first })
    }

    /// Playable tracks (files that failed to parse are kept only to avoid re-parsing them).
    /// Tracks as shown: each field is a manual edit, else the file's tag, else the online layers in the user's order,
    /// else what the scan inferred (title and track number from the file name, composers from lyrics credits). `ids`
    /// limits the result; `without` leaves layers out (the edit sheet shows what clearing a manual edit would reveal).
    public func rows(_ ids: [Int64]? = nil, without skipped: [EnrichSource] = []) throws -> [TrackRow] {
        func only(_ column: String) -> String { ids.map { " AND \(column) IN (\($0.map(String.init).joined(separator: ",")))" } ?? "" }
        var people: [Int64: (artists: [String], composers: [String], credited: [String])] = [:]
        let credits = try db.query("""
            SELECT track_id, role, name, source FROM track_person WHERE role IN ('artist', 'composer')\(only("track_id")) ORDER BY track_id, role, ord
            """) { ($0.int64(0)!, $0.string(1)!, $0.string(2)!, $0.string(3)!) }
        for (id, role, name, source) in credits {
            switch (role, source) {
            case ("artist", _): people[id, default: ([], [], [])].artists.append(name)
            case (_, ValueSource.lyricsCredit.rawValue): people[id, default: ([], [], [])].credited.append(name)
            default: people[id, default: ([], [], [])].composers.append(name)
            }
        }
        var layers: [String: [EnrichField: [EnrichSource: String]]] = [:]
        let enrichment = try db.query("SELECT fingerprint, field, source, CASE field WHEN 'lyrics' THEN '' ELSE value END FROM enrichment") {
            ($0.string(0)!, EnrichField(rawValue: $0.string(1)!), EnrichSource(rawValue: $0.string(2)!), $0.string(3)!)
        }
        for case let (fingerprint, field?, source?, value) in enrichment where !skipped.contains(source) {
            layers[fingerprint, default: [:]][field, default: [:]][source] = value
        }
        let covers = coversDirectory, order = onlineOrder().map(EnrichSource.online)
        return try db.query("""
            SELECT id, path, title, album, album_artist, track_no, disc_no, year, genre, duration, format, sample_rate,
                   bit_depth, has_cover, has_lyrics, added_at, file_mtime, cover_offset, cover_length, codec, fingerprint, title_source,
                   track_no_source
            FROM track WHERE scan_error IS NULL\(only("id"))
            """) { r in
            let id = r.int64(0)!, fingerprint = r.string(20)
            let layer = fingerprint.flatMap { layers[$0] } ?? [:]
            func online(_ field: EnrichField) -> String? { layer[field].flatMap { values in order.lazy.compactMap { values[$0] }.first } }
            func pick(_ field: EnrichField, _ file: String?, inferred: String? = nil) -> String? {
                layer[field]?[.user] ?? file ?? online(field) ?? inferred
            }
            func names(_ field: EnrichField, _ file: [String], inferred: [String] = []) -> [String] {
                if let user = layer[field]?[.user] { return EnrichField.decode(user) }
                if !file.isEmpty { return file }
                return online(field).map(EnrichField.decode) ?? inferred
            }
            let title = r.string(2) ?? "", tagged = r.string(21) == ValueSource.tag.rawValue, trackTagged = r.string(22) == ValueSource.tag.rawValue
            let credited = people[id]
            return TrackRow(id: id, path: r.string(1)!, title: pick(.title, tagged ? title : nil, inferred: title) ?? "",
                            album: pick(.album, r.string(3)), albumArtist: pick(.albumArtist, r.string(4)),
                            artists: names(.artists, credited?.artists ?? []),
                            composers: names(.composers, credited?.composers ?? [], inferred: credited?.credited ?? []),
                            trackNo: pick(.trackNo, trackTagged ? r.int(5).map(String.init) : nil, inferred: r.int(5).map(String.init)).flatMap { Int($0) },
                            discNo: pick(.discNo, r.int(6).map(String.init)).flatMap { Int($0) },
                            year: pick(.year, r.int(7).map(String.init)).flatMap { Int($0) }, genre: pick(.genre, r.string(8)),
                            duration: r.double(9) ?? 0, format: r.string(10) ?? "", codec: r.string(19), sampleRate: r.int(11),
                            bitDepth: r.int(12), hasCover: r.int(13) == 1, coverOffset: r.int64(17), coverLength: r.int(18),
                            hasLyrics: r.int(14) == 1 || layer[.lyrics] != nil, addedAt: Date(timeIntervalSince1970: r.double(15) ?? 0),
                            fileMtime: r.double(16) ?? 0, fingerprint: fingerprint, hasFileLyrics: r.int(14) == 1,
                            coverFile: (layer[.cover]?[.user] ?? online(.cover)).map { covers.appending(path: $0).path },
                            userCover: layer[.cover]?[.user] != nil,
                            inferred: Set([(EnrichField.title, tagged || r.string(2) == nil), (.trackNo, trackTagged || r.int(5) == nil)]
                                .filter { field, known in !known && layer[field]?[.user] == nil && online(field) == nil }.map(\.0)))
        }
    }
}
