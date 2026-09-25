import AppKit
import Observation
import LocalMusicCore

/// The 信息补全 queue: looks songs up one at a time (only when asked), refreshing the library every couple of seconds so
/// results show as they land. Requests made while it runs join the queue.
@Observable final class EnrichModel {
    private(set) var matches: [String: MatchState] = [:]
    private(set) var progress: (done: Int, total: Int)?
    /// The last run's problem, or a note such as nothing being left to do.
    private(set) var notice: String?
    /// Candidate covers for the 选择匹配 sheet, fetched while it's open.
    private(set) var thumbnails: [URL: NSImage] = [:]
    @ObservationIgnored private var requestedThumbnails = Set<URL>()

    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let service: EnrichService
    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private var queue: [TrackRow] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<Void, Never>?
    private static let maxFailures = 3

    init(store: LibraryStore, library: LibraryModel, client: NeteaseClient, interval: Duration) {
        self.store = store
        self.library = library
        service = EnrichService(store: store, client: client, interval: interval)
        loading = Task { [weak self] in
            guard let self else { return }
            do { matches = try await store.matches() } catch { notice = String(describing: error) }
        }
    }

    func match(_ row: TrackRow) -> MatchState? { row.fingerprint.flatMap { matches[$0] } }

    /// Queues every song still missing something that was never looked up (once the stored matches are known).
    func enrichAll(_ rows: [TrackRow]) async {
        await loading?.value
        let todo = rows.filter { match($0) == nil && EnrichFilter.missing($0, checkingFolderArt: true) }
        if todo.isEmpty { notice = "没有需要补全的歌曲" } else { enrich(todo) }
    }

    func enrich(_ rows: [TrackRow]) {
        // One lookup per recording.
        var seen = Set(queue.compactMap(\.fingerprint))
        let added = rows.filter { $0.fingerprint.map { seen.insert($0).inserted } ?? false }
        guard !added.isEmpty else { return }
        queue += added
        progress = (progress?.done ?? 0, (progress?.total ?? 0) + added.count)
        if task == nil { task = Task { await run() } }
    }

    /// The user's pick among the candidates. A queued lookup of the song is dropped; one in flight finishes first.
    func choose(_ song: NeteaseSong, for row: TrackRow) async {
        guard let job = job(row, songID: nil) else { return }
        dequeue(job.fingerprint)
        do { try await service.apply(song, to: job, status: .confirmed, confidence: nil) } catch { notice = "补全失败：\(error)" }
        await reloadMatch(job.fingerprint)
        await library.refresh()
    }

    func reject(_ row: TrackRow) async {
        guard let fingerprint = row.fingerprint else { return }
        dequeue(fingerprint)
        do { try await service.reject(fingerprint) } catch { notice = String(describing: error) }
        await reloadMatch(fingerprint)
        await library.refresh()
    }

    private func dequeue(_ fingerprint: String) {
        let before = queue.count
        queue.removeAll { $0.fingerprint == fingerprint }
        if before != queue.count { progress?.total -= before - queue.count }
    }

    private func reloadMatch(_ fingerprint: String) async {
        matches[fingerprint] = try? await store.matches(fingerprint)[fingerprint]
    }

    /// Once per URL until the sheet closes, also when it fails.
    func loadThumbnail(_ url: URL) async {
        guard requestedThumbnails.insert(url).inserted, let data = try? await service.thumbnail(url), let image = NSImage(data: data) else { return }
        thumbnails[url] = image
    }

    func clearThumbnails() {
        thumbnails = [:]
        requestedThumbnails = []
    }

    func stop() {
        queue.removeAll()
        task?.cancel()
    }

    /// Waits for the queue to drain (self-tests).
    func finish() async { await task?.value }

    private func run() async {
        notice = nil
        let keys = (try? await store.neteaseKeys()) ?? [:]
        var refreshed = ContinuousClock.now, failures = 0
        while !queue.isEmpty, !Task.isCancelled {
            let row = queue.removeFirst()
            if let job = job(row, songID: keys[row.id]) {
                switch await service.enrich(job) {
                case .failed(let message) where !Task.isCancelled:
                    failures += 1
                    notice = "网易云请求失败：\(message)"
                    if failures >= Self.maxFailures {
                        notice = "网易云连续 \(failures) 次请求失败，已停止：\(message)"
                        queue.removeAll()
                    }
                default:
                    failures = 0
                }
                await reloadMatch(job.fingerprint)
            }
            progress?.done += 1
            if refreshed.duration(to: .now) > .seconds(2) {
                refreshed = .now
                await library.refresh()
            }
        }
        await library.refresh()
        progress = nil
        task = nil
    }

    /// Lyrics and a cover are fetched only when the file itself has none (enrichment's own don't count, so looking a
    /// song up again keeps them).
    private func job(_ row: TrackRow, songID: Int64?) -> EnrichJob? {
        row.fingerprint.map {
            EnrichJob(fingerprint: $0, query: MatchQuery(title: row.title, artists: row.artists, album: row.album, duration: row.duration),
                      songID: songID, needsLyrics: !row.hasFileLyrics, needsCover: !row.hasCover && !ArtworkCache.hasFolderImage(near: row))
        }
    }
}

/// The 信息补全 page's views of the library.
enum EnrichFilter: String, CaseIterable, Identifiable {
    case missingCover, missingLyrics, missingInfo, pending, done

    var id: Self { self }

    var title: String {
        switch self {
        case .missingCover: "缺封面"
        case .missingLyrics: "缺歌词"
        case .missingInfo: "缺信息"
        case .pending: "待确认"
        case .done: "已补全"
        }
    }

    /// Folder art isn't checked here (a file lookup per song); enrichment still skips covers a folder image provides.
    func includes(_ row: TrackRow, _ match: MatchState?) -> Bool {
        switch self {
        case .missingCover: !row.hasArtwork
        case .missingLyrics: !row.hasLyrics
        case .missingInfo: Self.missingInfo(row)
        case .pending: match?.status == .pending
        case .done: match?.status == .auto || match?.status == .confirmed
        }
    }

    /// Album artist isn't counted: NetEase can't supply it.
    static func missingInfo(_ row: TrackRow) -> Bool { row.album == nil || row.trackNo == nil || row.year == nil }

    /// `checkingFolderArt`: a file lookup, so only on demand (a folder image counts as a cover).
    static func missing(_ row: TrackRow, checkingFolderArt: Bool = false) -> Bool {
        (!row.hasArtwork && !(checkingFolderArt && ArtworkCache.hasFolderImage(near: row))) || !row.hasLyrics || missingInfo(row)
    }

    /// All five counts in one pass.
    static func counts(_ rows: [TrackRow], _ match: (TrackRow) -> MatchState?) -> [EnrichFilter: Int] {
        var counts: [EnrichFilter: Int] = [:]
        for row in rows {
            let state = match(row)
            for filter in allCases where filter.includes(row, state) { counts[filter, default: 0] += 1 }
        }
        return counts
    }
}
