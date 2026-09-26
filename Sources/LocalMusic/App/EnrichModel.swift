import AppKit
import Observation
import LocalMusicCore

/// The 信息补全 queue: looks songs up one at a time (only when asked), refreshing the library every couple of seconds so
/// results show as they land. Requests made while it runs join the queue.
@Observable final class EnrichModel {
    private(set) var matches: [String: MatchState] = [:]
    private(set) var settings = OnlineSettings.default
    @ObservationIgnored private var settingsChanged = false
    private(set) var progress: (done: Int, total: Int)?
    /// The last run's problem, or a note such as nothing being left to do.
    var notice: String?
    /// Result covers for the 选择匹配 sheet, fetched while it's open.
    private(set) var thumbnails: [URL: NSImage] = [:]
    /// Songs whose pick is being applied.
    var applying = Set<String>()
    @ObservationIgnored private var requestedThumbnails = Set<URL>()

    @ObservationIgnored let store: LibraryStore
    @ObservationIgnored let service: EnrichService
    @ObservationIgnored let library: LibraryModel
    @ObservationIgnored private var queue: [TrackRow] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<Void, Never>?
    private static let maxFailures = 3

    init(store: LibraryStore, library: LibraryModel, client: OnlineClient, interval: Duration) {
        self.store = store
        self.library = library
        service = EnrichService(store: store, client: client, interval: interval)
        loading = Task { [weak self] in
            guard let self else { return }
            do {
                matches = try await store.matches()
                let saved = try await store.setting(OnlineSettings.key, as: OnlineSettings.self)
                if !settingsChanged, let saved { settings = saved }
            } catch {
                notice = String(describing: error)
            }
        }
    }

    func match(_ row: TrackRow) -> MatchState? { row.fingerprint.flatMap { matches[$0] } }

    /// Takes effect at once, so the next change builds on it; then it's saved and, since the order decides which
    /// source's value shows, the library refreshed.
    @discardableResult func setSettings(_ settings: OnlineSettings) -> Task<Void, Never> {
        self.settings = settings
        settingsChanged = true
        return Task {
            do { try await store.setSetting(OnlineSettings.key, settings) } catch { notice = String(describing: error) }
            await library.refresh()
        }
    }

    /// Queues every song still missing something that was never looked up (once the stored matches are known).
    func enrichAll(_ rows: [TrackRow]) async {
        await loading?.value
        guard !settings.enabled.isEmpty else { notice = "没有启用的在线资料来源，请在设置里开启"; return }
        let todo = rows.filter { match($0) == nil && EnrichFilter.missing($0, checkingFolderArt: true) }
        if todo.isEmpty { notice = "没有需要补全的歌曲" } else { enrich(todo) }
    }

    func enrich(_ rows: [TrackRow]) {
        guard !settings.enabled.isEmpty else { notice = "没有启用的在线资料来源，请在设置里开启"; return }
        // One lookup per recording.
        var seen = Set(queue.compactMap(\.fingerprint))
        let added = rows.filter { $0.fingerprint.map { seen.insert($0).inserted } ?? false }
        guard !added.isEmpty else { return }
        queue += added
        progress = (progress?.done ?? 0, (progress?.total ?? 0) + added.count)
        if task == nil { task = Task { await run() } }
    }

    func reject(_ row: TrackRow) async {
        guard let fingerprint = row.fingerprint else { return }
        dequeue(fingerprint)
        do { try await service.reject(fingerprint) } catch { notice = String(describing: error) }
        await reloadMatch(fingerprint)
        await library.refresh()
    }

    func dequeue(_ fingerprint: String) {
        let before = queue.count
        queue.removeAll { $0.fingerprint == fingerprint }
        if before != queue.count { progress?.total -= before - queue.count }
    }

    func reloadMatch(_ fingerprint: String) async {
        matches[fingerprint] = try? await store.matches(fingerprint)[fingerprint]
    }

    /// Once per cover and size until the sheet closes, also when it fails.
    func loadThumbnail(_ song: OnlineSong, pixels: Int) async {
        guard let url = OnlineClient.coverURL(song, pixels: pixels), requestedThumbnails.insert(url).inserted else { return }
        // A load cancelled by scrolling away is retried next time.
        guard let data = try? await service.thumbnail(song, pixels: pixels), let image = NSImage(data: data) else {
            if Task.isCancelled { requestedThumbnails.remove(url) }
            return
        }
        thumbnails[url] = image
    }

    func thumbnail(_ song: OnlineSong, pixels: Int) -> NSImage? { OnlineClient.coverURL(song, pixels: pixels).flatMap { thumbnails[$0] } }

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
        await loading?.value   // jobs take the saved sources
        notice = nil
        let keys = (try? await store.neteaseKeys()) ?? [:]
        var refreshed = ContinuousClock.now, failures = 0
        while !queue.isEmpty, !Task.isCancelled {
            let row = queue.removeFirst()
            if let job = job(row, songID: keys[row.id]) {
                switch await service.enrich(job) {
                case .failed(let message) where !Task.isCancelled:
                    failures += 1
                    notice = "在线资料来源请求失败：\(message)"
                    if failures >= Self.maxFailures {
                        notice = "连续 \(failures) 首歌请求失败，已停止：\(message)"
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
    func job(_ row: TrackRow, songID: Int64?) -> EnrichJob? {
        row.fingerprint.map {
            EnrichJob(fingerprint: $0, trackID: row.id,
                      query: MatchQuery(title: row.title, artists: row.artists, album: row.album, duration: row.duration),
                      songID: songID, needsLyrics: !row.hasFileLyrics, needsCover: !row.hasCover && !ArtworkCache.hasFolderImage(near: row),
                      sources: settings.enabled, storefront: settings.storefront)
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

    /// The missing-* views list what's left to do: a matched song's remaining gaps are ones no source filled (shown in
    /// 已补全). Folder art isn't checked here (a file lookup per song); enrichment still skips covers a folder image provides.
    func includes(_ row: TrackRow, _ match: MatchState?) -> Bool {
        let applied = match?.status == .auto || match?.status == .confirmed
        return switch self {
        case .missingCover: !applied && !row.hasArtwork
        case .missingLyrics: !applied && !row.hasLyrics
        case .missingInfo: !applied && Self.missingInfo(row)
        case .pending: match?.status == .pending
        case .done: applied
        }
    }

    /// Album artist isn't counted: no source supplies it.
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
