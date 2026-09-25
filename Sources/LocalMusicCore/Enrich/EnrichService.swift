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
    case applied(NeteaseSong)
    case pending([NeteaseSong])
    case notFound
    case failed(String)
}

/// Looks songs up on NetEase, pacing requests, and stores what it finds as the `netease` layer (shown only where the file
/// has no value of its own) together with the match state.
public actor EnrichService {
    private let store: LibraryStore
    private let client: NeteaseClient
    private let interval: Duration
    private var nextSlot = ContinuousClock.now

    public init(store: LibraryStore, client: NeteaseClient, interval: Duration = .milliseconds(600)) {
        (self.store, self.client, self.interval) = (store, client, interval)
    }

    /// A song already applied keeps its data when a new lookup is inconclusive.
    public func enrich(_ job: EnrichJob) async -> EnrichOutcome {
        do {
            if let id = job.songID, let song = try await paced({ try await self.client.song(id) }) {
                try await apply(song, to: job, status: .auto, confidence: 1)
                return .applied(song)
            }
            let candidates = try await paced { try await self.client.search(job.query.keywords) }
            let result = Matcher.match(job.query, candidates: candidates)
            if case .confident(let song, let score) = result {
                try await apply(song, to: job, status: .auto, confidence: score)
                return .applied(song)
            }
            let applied = try await store.matches(job.fingerprint)[job.fingerprint].map { $0.status == .auto || $0.status == .confirmed } ?? false
            switch result {
            case .uncertain(let songs):
                if !applied { try await store.setMatch(job.fingerprint, .pending, candidates: songs) }
                return .pending(songs)
            default:
                if !applied { try await store.setMatch(job.fingerprint, .none) }
                return .notFound
            }
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Replaces the song's NetEase layer with `song` (also when the user picks a candidate): basic fields always, lyrics
    /// (with their credits as composers) and the cover only if the file lacks them.
    public func apply(_ song: NeteaseSong, to job: EnrichJob, status: MatchStatus, confidence: Double?) async throws {
        var values: [EnrichField: String] = [.title: song.title]
        if !song.artists.isEmpty { values[.artists] = EnrichField.encode(song.artists) }
        if !song.album.isEmpty { values[.album] = song.album }
        values[.trackNo] = song.trackNo.map(String.init)
        values[.discNo] = song.discNo.map(String.init)
        values[.year] = song.year.map(String.init)
        if job.needsLyrics, let lyrics = try await paced({ try await self.client.lyrics(song.id) }) {
            values[.lyrics] = lyrics
            if let composers = LRCParser.parse(lyrics)?.credits.composers, !composers.isEmpty { values[.composers] = EnrichField.encode(composers) }
        }
        let covers = store.coversDirectory
        if job.needsCover, let url = song.coverURL {
            let data = try await paced { try await self.client.cover(url) }
            // A new name per download, so caches keyed by it show the new image.
            let name = "\(job.fingerprint.replacing(":", with: "-"))-\(song.id)-\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
            try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
            try data.write(to: covers.appending(path: name))
            values[.cover] = name
        }
        let previous = try await store.enrichment(job.fingerprint, source: .netease)[.cover]
        do {
            try await store.applyMatch(job.fingerprint, values, status, songID: song.id, confidence: confidence)
        } catch {
            if let name = values[.cover] { try? FileManager.default.removeItem(at: covers.appending(path: name)) }
            throw error
        }
        if let previous, previous != values[.cover] { try? FileManager.default.removeItem(at: covers.appending(path: previous)) }
    }

    /// Requests start at least `interval` apart, also for overlapping callers: each takes the next slot before waiting.
    private func paced<T: Sendable>(_ request: @Sendable () async throws -> T) async throws -> T {
        let slot = max(nextSlot, .now)
        nextSlot = slot + interval
        try await Task.sleep(until: slot)
        return try await request()
    }
}
