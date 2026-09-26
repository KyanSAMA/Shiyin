import AppKit
import ImageIO
import Observation
import Synchronization
import LocalMusicCore

enum SirenDownloadState: Equatable {
    case queued
    /// The share received, when the size is known.
    case downloading(Double?)
    case done(URL)
    case failed(String)
}

/// 下载: an album's chosen songs, where they go and how they're named (the import defaults, remembered).
@Observable final class SirenPlan {
    let detail: Siren.AlbumDetail
    let songs: [Siren.Song]
    /// nil: the first music folder.
    var target: URL?
    var naming: ImportNaming
    /// The album cover, fetched once for the plan's songs.
    @ObservationIgnored fileprivate var cover: Task<Data?, Never>?

    init(detail: Siren.AlbumDetail, songs: [Siren.Song], settings: ImportSettings) {
        (self.detail, self.songs) = (detail, songs)
        (target, naming) = (settings.target.map { URL(filePath: $0) }, settings.naming)
    }
}

/// 塞壬唱片: the label's catalogue (asked for when the page opens), which of it the library has by title, and downloads —
/// two at a time, each retried while retrying can help, cancellable; the library is scanned when a run ends.
@Observable final class SirenModel {
    private(set) var albums: [Siren.Album] = []
    /// Every song, for the albums' 已有 counts.
    private(set) var songs: [Siren.Song] = []
    private(set) var failure: String?
    private(set) var albumID: String?
    private(set) var details: [String: Siren.AlbumDetail] = [:]
    private(set) var detailFailure: String?
    var selection: Set<String> = []
    private(set) var states: [String: SirenDownloadState] = [:]
    private(set) var running = false
    private(set) var covers: [String: NSImage] = [:]
    private(set) var loading = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var coverQueue: [Siren.Album] = []
    @ObservationIgnored private var coverLoading: Set<String> = []
    @ObservationIgnored private var queue: [(Siren.Song, SirenPlan)] = []
    @ObservationIgnored private var run: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var ownedMemo: (index: UUID, owned: Siren.Owned, counts: [String: (Int, Int)])?
    @ObservationIgnored private let client: OnlineClient
    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private let importer: ImportModel
    @ObservationIgnored private let options: LaunchOptions

    init(client: OnlineClient, library: LibraryModel, importer: ImportModel, options: LaunchOptions) {
        (self.client, self.library, self.importer, self.options) = (client, library, importer, options)
    }

    /// The catalogue, once it loads (again after a failure); a load under way is awaited.
    func load() async {
        guard albums.isEmpty else { return }
        if loadTask == nil {
            loading = true
            loadTask = Task {
                do {
                    let albums = try await client.sirenAlbums()
                    let songs = try await client.sirenSongs()
                    (self.albums, self.songs, failure) = (albums, songs, nil)
                    if albumID == nil, let first = albums.first { select(first.id) }
                } catch {
                    failure = "无法连接塞壬唱片：\(error.localizedDescription)"
                }
                (loadTask, loading) = (nil, false)
            }
        }
        await loadTask?.value
    }

    /// The downloads run to their end (self-tests).
    func finish() async { await run?.value }

    /// Albums whose name, or a song's, contains the search.
    func albums(matching search: String) -> [Siren.Album] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return albums }
        let names = Set(songs.filter { $0.name.localizedStandardContains(query) }.map(\.albumID))
        return albums.filter { $0.name.localizedStandardContains(query) || names.contains($0.id) }
    }

    var detail: Siren.AlbumDetail? { albumID.flatMap { details[$0] } }

    /// Shows the album at once, its songs when they load.
    func select(_ id: String) {
        albumID = id
        selection = []
        detailFailure = nil
        if details[id] == nil { Task { await loadDetail(id) } }
    }

    /// An album's songs (after a failure, again).
    func loadDetail(_ id: String) async {
        detailFailure = nil
        do {
            let detail = try await client.sirenAlbum(id)
            details[id] = detail
            ownedMemo?.counts[id] = nil
        } catch {
            if albumID == id, !Self.cancelled(error) { detailFailure = "专辑读取失败：\(error.localizedDescription)" }
        }
    }

    /// A cover for the album list, when its row shows: at most four fetched at once; a failed one is tried again the
    /// next time its row shows.
    func showCover(_ album: Siren.Album) {
        guard covers[album.id] == nil, !coverLoading.contains(album.id), !coverQueue.contains(where: { $0.id == album.id }) else { return }
        coverQueue.append(album)
        pumpCovers()
    }

    private func pumpCovers() {
        while coverLoading.count < 4, !coverQueue.isEmpty {
            let album = coverQueue.removeFirst()
            coverLoading.insert(album.id)
            Task {
                let data = (try? await client.sirenCover(album)) ?? nil
                let image = await Task.detached { data.flatMap { Self.thumbnail($0, pixels: 320) } }.value
                if let image { covers[album.id] = image }
                coverLoading.remove(album.id)
                pumpCovers()
            }
        }
    }

    private nonisolated static func thumbnail(_ data: Data, pixels: Int) -> NSImage? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixels,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// Library songs with this title.
    func owned(_ song: Siren.Song) -> [TrackRow] { owner.rows(song) }

    /// Songs of the album the library has, and all of them (memoized per library index).
    func ownedCount(_ album: Siren.Album) -> (owned: Int, total: Int) {
        let owner = owner
        if let count = ownedMemo?.counts[album.id] { return count }
        let songs = details[album.id]?.songs ?? self.songs.filter { $0.albumID == album.id }
        let count = (songs.count { !owner.rows($0).isEmpty }, songs.count)
        ownedMemo?.counts[album.id] = count
        return count
    }

    private var owner: Siren.Owned {
        let index = library.index
        if let memo = ownedMemo, memo.index == index.id { return memo.owned }
        let owned = Siren.Owned(index.songs)
        ownedMemo = (index.id, owned, [:])
        return owned
    }

    func plan(_ songs: [Siren.Song], in detail: Siren.AlbumDetail) -> SirenPlan {
        SirenPlan(detail: detail, songs: songs, settings: importer.settings)
    }

    func isPending(_ song: Siren.Song) -> Bool {
        switch states[song.id] {
        case .queued?, .downloading?: true
        default: false
        }
    }

    var remaining: Int { states.values.count { if case .queued = $0 { true } else if case .downloading = $0 { true } else { false } } }

    /// Queues the plan's songs (remembering its target and naming); runs the queue if idle.
    func start(_ plan: SirenPlan) {
        var settings = importer.settings
        (settings.target, settings.naming) = (plan.target?.path, plan.naming)
        importer.setSettings(settings)
        for song in plan.songs where !isPending(song) {
            states[song.id] = .queued
            queue.append((song, plan))
        }
        guard !running else { return }
        running = true
        generation += 1
        let mine = generation
        run = Task {
            await withTaskGroup { group in
                for _ in 0..<2 {
                    group.addTask { await self.work() }
                }
            }
            // A stopped run winds down while a newer one may already be going.
            guard mine == generation else { return }
            running = false
            if library.started { await library.scan() }
        }
    }

    /// Stops the downloads; ones already in place stay, the others go back to not downloaded.
    func stop() {
        run?.cancel()
        for (song, _) in queue { states[song.id] = nil }
        queue.removeAll()
        running = false
        generation += 1
        if library.started { Task { await library.scan() } }
    }

    private func work() async {
        var swept: Set<URL> = []
        while !Task.isCancelled, !queue.isEmpty {
            let (song, plan) = queue.removeFirst()
            states[song.id] = .downloading(nil)
            let state = await download(song, plan, swept: &swept)
            states[song.id] = state
        }
    }

    /// nil when stopped.
    private func download(_ song: Siren.Song, _ plan: SirenPlan, swept: inout Set<URL>) async -> SirenDownloadState? {
        guard let target = plan.target ?? importer.firstFolder else { return .failed("没有下载目录：请先在设置里添加音乐文件夹") }
        guard options.allowsFiles(at: target.path) else { return .failed("自测只能下载到自测目录") }
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            return .failed(error.localizedDescription)
        }
        // Left behind by a quit mid-download.
        if swept.insert(target).inserted { await Task.detached { Importer.sweepStaging(in: target) }.value }
        let client = client
        if plan.cover == nil { plan.cover = Task { (try? await client.sirenCover(plan.detail.album)) ?? nil } }
        let cover = await plan.cover?.value
        var failure = ""
        for attempt in 1...3 {
            do {
                let placed = try await Siren.download(song, in: plan.detail, cover: cover, client: client, to: target, naming: plan.naming,
                                                      progress: Self.progress(song.id, self))
                return .done(placed)
            } catch {
                if Task.isCancelled || Self.cancelled(error) { return nil }
                failure = error.localizedDescription
                guard attempt < 3, Self.retryable(error) else { break }
                try? await Task.sleep(for: .seconds(2 * attempt))
                if Task.isCancelled { return nil }
            }
        }
        return .failed(failure)
    }

    /// The network, a server error or an expired address (403; asked for afresh next time), a short download.
    private static func retryable(_ error: Error) -> Bool {
        switch error {
        case is URLError: true
        case OnlineError.http(let status): status == 403 || status >= 500
        case OnlineError.file: true
        default: false
        }
    }

    private static func cancelled(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// Called on the download's delegate queue: hops to the main actor when the percentage changes (a download of
    /// unknown size just spins).
    private nonisolated static func progress(_ id: String, _ model: SirenModel) -> @Sendable (Int64, Int64?) -> Void {
        let last = Mutex(-1)
        return { [weak model] received, expected in
            guard let expected, expected > 0 else { return }
            let percent = Int(received * 100 / expected)
            guard last.withLock({ previous in
                defer { previous = percent }
                return previous != percent
            }) else { return }
            Task { @MainActor in
                guard let model, case .downloading? = model.states[id] else { return }
                model.states[id] = .downloading(Double(percent) / 100)
            }
        }
    }
}
