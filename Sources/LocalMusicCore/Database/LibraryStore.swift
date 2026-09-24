import Foundation

public actor LibraryStore {
    let db: Database

    public init(url: URL) throws {
        db = try Database(url: url)
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
        let rows = try db.query("SELECT path, id, file_size, file_mtime, sidecar_mtime FROM track") {
            ($0.string(0)!.pathKey, StoredStamp(id: $0.int64(1)!, size: $0.int64(2)!, mtime: $0.double(3)!, sidecarMtime: $0.double(4)))
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
                ("album_artist", meta.albumArtist), ("track_no", meta.trackNo), ("track_total", meta.trackTotal),
                ("disc_no", meta.discNo), ("disc_total", meta.discTotal), ("year", meta.year), ("date", meta.date),
                ("genre", meta.genre), ("cover_offset", raw.cover?.offset), ("cover_length", raw.cover?.length),
                ("cover_mime", raw.cover?.mime), ("has_cover", raw.cover != nil),
                ("has_lyrics", meta.lyrics != nil || track.sidecarLyrics != nil),
                ("rg_track_gain", meta.replayGain.trackGain), ("rg_track_peak", meta.replayGain.trackPeak),
                ("rg_album_gain", meta.replayGain.albumGain), ("rg_album_peak", meta.replayGain.albumPeak),
                ("ncm_key", meta.ncmKey),
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
    /// track was deleted meanwhile.
    func saveLoudness(_ job: LoudnessJob, _ result: Result<LoudnessResult, Error>) throws {
        let (integrated, peak, blocks, error): (Double?, Double?, Data?, String?) = switch result {
        case .success(let r): (r.integrated, r.samplePeak, r.blockEnergies.withUnsafeBytes { Data($0) }, nil)
        case .failure(let e): (nil, nil, nil, String(describing: e))
        }
        try db.run("""
            INSERT OR REPLACE INTO loudness(track_id, file_size, file_mtime, analyzer_version, integrated_lufs, sample_peak,
                                            block_energies, analyzed_at, error)
            SELECT ?, ?, ?, ?, ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM track WHERE id = ?)
            """, [job.trackID, job.size, job.mtime, LoudnessAnalyzer.version, integrated, peak, blocks,
                  Date().timeIntervalSince1970, error, job.trackID])
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
    public func lyrics(for trackID: Int64) throws -> Lyrics? {
        // An empty or header-only sidecar parses to nil and must not hide embedded lyrics.
        try db.query("SELECT lrc FROM lyrics WHERE track_id = ? ORDER BY source = 'sidecar' DESC", [trackID]) {
            $0.string(0)
        }.lazy.compactMap { $0.flatMap(LRCParser.parse) }.first
    }

    /// Playable tracks (files that failed to parse are kept only to avoid re-parsing them).
    public func rows() throws -> [TrackRow] {
        var people: [Int64: (artists: [String], composers: [String])] = [:]
        let credits = try db.query("SELECT track_id, role, name FROM track_person WHERE role IN ('artist', 'composer') ORDER BY track_id, role, ord") {
            ($0.int64(0)!, $0.string(1)!, $0.string(2)!)
        }
        for (id, role, name) in credits {
            if role == "artist" { people[id, default: ([], [])].artists.append(name) } else { people[id, default: ([], [])].composers.append(name) }
        }
        return try db.query("""
            SELECT id, path, title, album, album_artist, track_no, disc_no, year, genre, duration, format, sample_rate,
                   bit_depth, has_cover, has_lyrics, added_at, file_mtime, cover_offset, cover_length, codec
            FROM track WHERE scan_error IS NULL
            """) { r in
            let id = r.int64(0)!
            return TrackRow(id: id, path: r.string(1)!, title: r.string(2) ?? "", album: r.string(3), albumArtist: r.string(4),
                            artists: people[id]?.artists ?? [], composers: people[id]?.composers ?? [],
                            trackNo: r.int(5), discNo: r.int(6), year: r.int(7), genre: r.string(8), duration: r.double(9) ?? 0,
                            format: r.string(10) ?? "", codec: r.string(19), sampleRate: r.int(11), bitDepth: r.int(12),
                            hasCover: r.int(13) == 1, coverOffset: r.int64(17), coverLength: r.int(18), hasLyrics: r.int(14) == 1,
                            addedAt: Date(timeIntervalSince1970: r.double(15) ?? 0), fileMtime: r.double(16) ?? 0)
        }
    }
}
