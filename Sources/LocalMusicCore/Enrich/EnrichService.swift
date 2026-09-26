import Foundation

/// One library song to look up.
public struct EnrichJob: Sendable {
    public let fingerprint: String
    public let query: MatchQuery
    /// From the file's "163 key": an exact match, no search needed.
    public let songID: Int64?
    /// Lyrics and covers are only fetched for songs without their own.
    public let needsLyrics: Bool
    public let needsCover: Bool

    public init(fingerprint: String, query: MatchQuery, songID: Int64?, needsLyrics: Bool, needsCover: Bool) {
        (self.fingerprint, self.query, self.songID, self.needsLyrics, self.needsCover) = (fingerprint, query, songID, needsLyrics, needsCover)
    }
}

public enum EnrichOutcome: Sendable, Equatable {
    case applied(OnlineSong)
    case pending([OnlineSong])
    case notFound
    case failed(String)
}

/// Looks songs up online, pacing requests to each service, and stores what it finds as that source's layer (shown only
/// where the file has no value of its own) together with the match state.
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

    /// A song already applied keeps its data when a new lookup is inconclusive (the candidates are kept for choosing).
    public func enrich(_ job: EnrichJob) async -> EnrichOutcome {
        do { return try await serial { await self.lookUp(job) } } catch { return .failed(String(describing: error)) }
    }

    public func apply(_ song: OnlineSong, to job: EnrichJob, status: MatchStatus) async throws {
        try await serial { try await self.store(song, for: job, status: status) }
    }

    /// None of the candidates (or the applied songs) is right: remove what the online sources supplied and don't look
    /// the song up again.
    public func reject(_ fingerprint: String) async throws {
        try await serial {
            let covers = self.store.coversDirectory
            for cover in try await self.store.rejectMatch(fingerprint) { try? FileManager.default.removeItem(at: covers.appending(path: cover)) }
        }
    }

    /// A candidate's cover for the picker (not paced: image CDNs, not the APIs).
    public func thumbnail(_ song: OnlineSong) async throws -> Data? { try await client.cover(song, pixels: 100) }

    private func serial<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { await previous?.value; return try await body() }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    private func lookUp(_ job: EnrichJob) async -> EnrichOutcome {
        do {
            if let id = job.songID, let song = try await paced(.netease, { try await self.client.neteaseSong(id) }) {
                try await store(song, for: job, status: .auto)
                return .applied(song)
            }
            let candidates = try await paced(.netease) { try await self.client.search(.netease, job.query.keywords) }
            let result = Matcher.match(job.query, candidates: candidates)
            if case .confident(let song, _) = result {
                try await store(song, for: job, status: .auto)
                return .applied(song)
            }
            let current = try await store.matches(job.fingerprint)[job.fingerprint]?.status
            let applied = current == .auto || current == .confirmed
            switch result {
            case .uncertain(let songs):
                try await store.setMatch(job.fingerprint, applied ? current! : .pending, candidates: songs)
                return .pending(songs)
            default:
                if !applied { try await store.setMatch(job.fingerprint, .none) }
                return .notFound
            }
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Replaces the song's source's layer with `song`: basic fields always (a NetEase year missing from search results
    /// from the song's detail), lyrics (with their credits as composers) and the cover only if the file lacks them.
    private func store(_ song: OnlineSong, for job: EnrichJob, status: MatchStatus) async throws {
        var values: [EnrichField: String] = [.title: song.title]
        if !song.artists.isEmpty { values[.artists] = EnrichField.encode(song.artists) }
        if !song.album.isEmpty { values[.album] = song.album }
        values[.trackNo] = song.trackNo.map(String.init)
        values[.discNo] = song.discNo.map(String.init)
        values[.genre] = song.genre
        var year = song.year
        if year == nil, song.source == .netease, job.songID == nil, let id = Int64(song.id) {
            year = (try? await paced(.netease) { try await self.client.neteaseSong(id) })??.year
        }
        values[.year] = year.map(String.init)
        // LRCLIB's lyrics come with the song and iTunes has none: no request to pace.
        let fetchesLyrics = song.source == .netease || song.source == .qq
        if job.needsLyrics, let lyrics = fetchesLyrics ? try await paced(song.source, { try await self.client.lyrics(song) }) : try await client.lyrics(song) {
            values[.lyrics] = lyrics
            if let composers = LRCParser.parse(lyrics)?.credits.composers, !composers.isEmpty { values[.composers] = EnrichField.encode(composers) }
        }
        let covers = store.coversDirectory
        if job.needsCover, song.coverURL != nil, let data = try await paced(song.source, { try await self.client.cover(song) }) {
            // A new name per download, so caches keyed by it show the new image.
            let name = "\(job.fingerprint.replacing(":", with: "-"))-\(song.source.rawValue)-\(song.id)-\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
            try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
            try data.write(to: covers.appending(path: name))
            values[.cover] = name
        }
        let replaced: [String]
        do {
            replaced = try await store.applyMatch(job.fingerprint, [song.source: values], status)
        } catch {
            if let name = values[.cover] { try? FileManager.default.removeItem(at: covers.appending(path: name)) }
            throw error
        }
        for name in replaced { try? FileManager.default.removeItem(at: covers.appending(path: name)) }
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
