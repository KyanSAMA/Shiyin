import Foundation

/// One library song to look up.
public struct EnrichJob: Sendable {
    public let fingerprint: String
    public let trackID: Int64
    public let query: MatchQuery
    /// From the file's "163 key": an exact NetEase match, no search needed.
    public let songID: Int64?
    /// Lyrics and covers are only fetched for songs without their own.
    public let needsLyrics: Bool
    public let needsCover: Bool
    /// The enabled sources, in the user's order.
    public let sources: [OnlineSource]
    public let storefront: String

    public init(fingerprint: String, trackID: Int64, query: MatchQuery, songID: Int64?, needsLyrics: Bool, needsCover: Bool,
                sources: [OnlineSource], storefront: String) {
        (self.fingerprint, self.trackID, self.query, self.songID) = (fingerprint, trackID, query, songID)
        (self.needsLyrics, self.needsCover, self.sources, self.storefront) = (needsLyrics, needsCover, sources, storefront)
    }
}

public enum EnrichOutcome: Sendable, Equatable {
    /// The confident matches, one per source.
    case applied([OnlineSong])
    case pending([OnlineSong])
    case notFound
    /// Every source asked failed.
    case failed(String)
}

extension OnlineSource {
    /// The gaps its songs can fill.
    var fills: Set<EnrichField> {
        switch self {
        case .netease, .qq: [.artists, .album, .trackNo, .year, .lyrics, .cover]
        case .itunes: [.artists, .album, .trackNo, .year, .genre, .cover]
        case .lrclib: [.lyrics]
        }
    }
}

/// Looks songs up online, pacing requests to each service, and stores each source's confident match as its layer (shown
/// only where the file has no value of its own) together with the match state.
public actor EnrichService {
    private let store: LibraryStore
    private let client: OnlineClient
    private let interval: Duration
    private var nextSlot: [OnlineSource: ContinuousClock.Instant] = [:]
    /// The last operation; each waits for it, so a pick or a reject never interleaves with a lookup of the same song.
    private var tail: Task<Void, Never>?

    public init(store: LibraryStore, client: OnlineClient, interval: Duration = .milliseconds(600)) {
        (self.store, self.client, self.interval) = (store, client, interval)
    }

    /// Asks the sources in order, each only while it can fill a gap the file still has; LRCLIB only supplements a song
    /// another source knows. The matches replace every online layer. A song already applied keeps its data when a new
    /// lookup is inconclusive.
    public func enrich(_ job: EnrichJob) async -> EnrichOutcome {
        do { return try await serial { await self.lookUp(job) } } catch { return .failed(String(describing: error)) }
    }

    /// None of the candidates (or the applied songs) is right: remove what the online sources supplied and don't look
    /// the song up again.
    public func reject(_ fingerprint: String) async throws {
        try await serial {
            let covers = self.store.coversDirectory
            for cover in try await self.store.rejectMatch(fingerprint) { try? FileManager.default.removeItem(at: covers.appending(path: cover)) }
        }
    }

    /// A result's cover for the 选择匹配 sheet (not paced: image CDNs, not the APIs).
    public func thumbnail(_ song: OnlineSong, pixels: Int) async throws -> Data? { try await client.cover(song, pixels: pixels) }

    /// For the 选择匹配 sheet: a search with the user's keywords.
    public func search(_ source: OnlineSource, _ keywords: String, storefront: String) async throws -> [OnlineSong] {
        try await paced(source) { try await self.client.search(source, keywords, storefront: storefront) }
    }

    /// The album's release year from the song's detail, which NetEase search results often lack.
    public func neteaseYear(_ song: OnlineSong) async throws -> Int? {
        guard let id = Int64(song.id) else { return nil }
        return try await paced(.netease) { try await self.client.neteaseSong(id) }?.year
    }

    /// LRCLIB's lyrics come with the song and iTunes has none: no request to pace.
    public func lyrics(_ song: OnlineSong) async throws -> String? {
        song.source == .netease || song.source == .qq ? try await paced(song.source) { try await self.client.lyrics(song) } : try await client.lyrics(song)
    }

    /// An image file chosen as a manual cover, copied into the covers directory; returns its name there.
    public func saveCover(_ url: URL, fingerprint: String) throws -> String {
        let data = try Data(contentsOf: url)
        let covers = store.coversDirectory
        let name = "\(fingerprint.replacing(":", with: "-"))-user-\(Int(Date().timeIntervalSince1970 * 1000)).\(url.pathExtension.lowercased())"
        try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
        try data.write(to: covers.appending(path: name))
        return name
    }

    private func serial<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { await previous?.value; return try await body() }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    private func lookUp(_ job: EnrichJob) async -> EnrichOutcome {
        do {
            var gaps = try await gaps(job), found = Found()
            if let id = job.songID, job.sources.contains(.netease) {
                found.asked += 1
                do {
                    if let song = try await paced(.netease, { try await self.client.neteaseSong(id) }) {
                        try await take(song, job, &found, gaps: &gaps)
                    }
                } catch {
                    found.failures.append(String(describing: error))
                }
            }
            await search(job, found.applied.first.map(job.query.pinned) ?? job.query, &found, gaps: &gaps)
            if !found.applied.isEmpty {
                try await save(job.fingerprint, found.layers, .auto)
                return .applied(found.applied)
            }
            if found.asked > 0, found.failures.count == found.asked { return .failed(found.failures[0]) }
            let current = try await store.matches(job.fingerprint)[job.fingerprint]?.status
            let keeps = current == .auto || current == .confirmed
            // The best five across the sources.
            guard case .uncertain(let best) = Matcher.match(job.query, candidates: found.undecided) else {
                if !keeps { try await store.setMatch(job.fingerprint, .none) }
                return .notFound
            }
            try await store.setMatch(job.fingerprint, keeps ? current! : .pending, candidates: best)
            return .pending(best)
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// The user's pick becomes the song's match, replacing every online layer; the other sources are asked with the
    /// pick's title, artists and album, keeping only confident matches. `candidates` stay for picking again.
    public func apply(_ song: OnlineSong, to job: EnrichJob, candidates: [OnlineSong]) async throws -> [OnlineSong] {
        try await serial {
            var gaps = try await self.gaps(job), found = Found()
            try await self.take(song, job, &found, gaps: &gaps)
            await self.search(job, job.query.pinned(song), &found, gaps: &gaps)
            try await self.save(job.fingerprint, found.layers, .confirmed, candidates: candidates)
            return found.applied
        }
    }

    private struct Found {
        var layers: [OnlineSource: [EnrichField: String]] = [:], applied: [OnlineSong] = [], undecided: [OnlineSong] = []
        var asked = 0, failures: [String] = []
    }

    private func take(_ song: OnlineSong, _ job: EnrichJob, _ found: inout Found, gaps: inout Set<EnrichField>) async throws {
        found.layers[song.source] = try await values(song, job, gaps: &gaps)
        found.applied.append(song)
    }

    /// Asks the sources without a layer yet, in order, each only while it can fill a gap; LRCLIB goes last whatever its
    /// place, as it only supplements a song another source knows.
    private func search(_ job: EnrichJob, _ query: MatchQuery, _ found: inout Found, gaps: inout Set<EnrichField>) async {
        let order = job.sources.filter { $0 != .lrclib } + job.sources.filter { $0 == .lrclib }
        for source in order where found.layers[source] == nil && !gaps.isDisjoint(with: source.fills) && (source != .lrclib || !found.applied.isEmpty) {
            found.asked += 1
            do {
                let songs = try await paced(source) { try await self.client.search(source, query.keywords, storefront: job.storefront) }
                switch Matcher.match(query, candidates: songs) {
                case .confident(let song, _): try await take(song, job, &found, gaps: &gaps)
                case .uncertain(let songs): found.undecided += songs
                case .none: break
                }
            } catch {
                found.failures.append(String(describing: error))
            }
        }
    }

    /// What the song lacks without online layers: manual edits count as filled, except for lyrics and covers, which
    /// follow the file. Disc numbers and composers are filled along the way but aren't worth another source's request.
    private func gaps(_ job: EnrichJob) async throws -> Set<EnrichField> {
        guard let row = try await store.rows([job.trackID], without: EnrichSource.allOnline).first else { return [] }
        let missing: [(EnrichField, Bool)] = [(.artists, row.artists.isEmpty), (.album, row.album == nil), (.trackNo, row.trackNo == nil),
                                              (.year, row.year == nil), (.genre, row.genre == nil),
                                              (.lyrics, job.needsLyrics), (.cover, job.needsCover)]
        return Set(missing.filter(\.1).map(\.0))
    }

    /// The song's values for its source's layer: what it has (LRCLIB: only lyrics), lyrics (with their credits as
    /// composers) and the cover only while still missing, and a NetEase year missing from search results from the
    /// song's detail. Removes what it fills from `gaps`; a downloaded cover is written to the covers directory.
    private func values(_ song: OnlineSong, _ job: EnrichJob, gaps: inout Set<EnrichField>) async throws -> [EnrichField: String] {
        var values: [EnrichField: String] = [:]
        if song.source != .lrclib {
            values[.title] = song.title
            if !song.artists.isEmpty { values[.artists] = EnrichField.encode(song.artists) }
            if !song.album.isEmpty { values[.album] = song.album }
            values[.trackNo] = song.trackNo.map(String.init)
            values[.discNo] = song.discNo.map(String.init)
            values[.genre] = song.genre
            var year = song.year
            if year == nil, gaps.contains(.year), song.source == .netease { year = try? await neteaseYear(song) }
            values[.year] = year.map(String.init)
        }
        if gaps.contains(.lyrics), let lyrics = try await self.lyrics(song) {
            values[.lyrics] = lyrics
            if let composers = LRCParser.parse(lyrics)?.credits.composers, !composers.isEmpty { values[.composers] = EnrichField.encode(composers) }
        }
        if gaps.contains(.cover), song.coverURL != nil, let data = try await paced(song.source, { try await self.client.cover(song) }) {
            let covers = store.coversDirectory
            // A new name per download, so caches keyed by it show the new image.
            let name = "\(job.fingerprint.replacing(":", with: "-"))-\(song.source.rawValue)-\(song.id)-\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
            try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
            try data.write(to: covers.appending(path: name))
            values[.cover] = name
        }
        gaps.subtract(values.keys)
        return values
    }

    /// Replaces every online layer with these, removing the cover files no longer referenced (or the new ones if saving
    /// fails).
    private func save(_ fingerprint: String, _ layers: [OnlineSource: [EnrichField: String]], _ status: MatchStatus,
                      candidates: [OnlineSong] = []) async throws {
        let covers = store.coversDirectory
        let all = Dictionary(uniqueKeysWithValues: OnlineSource.allCases.map { ($0, layers[$0] ?? [:]) })
        do {
            for name in try await store.applyMatch(fingerprint, all, status, candidates: candidates) { try? FileManager.default.removeItem(at: covers.appending(path: name)) }
        } catch {
            for name in layers.values.compactMap({ $0[.cover] }) { try? FileManager.default.removeItem(at: covers.appending(path: name)) }
            throw error
        }
    }

    /// Requests to one service start at least `interval` apart, also for overlapping callers: each takes the next slot
    /// before waiting.
    private func paced<T: Sendable>(_ source: OnlineSource, _ request: @Sendable () async throws -> T) async throws -> T {
        let slot = max(nextSlot[source] ?? .now, .now)
        nextSlot[source] = slot + interval
        try await Task.sleep(until: slot)
        return try await request()
    }
}
