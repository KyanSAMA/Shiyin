import AppKit
import Foundation
import Observation
import SwiftUI
import LocalMusicCore

struct LaunchOptions {
    let selfTestScript: URL?
    let outDir: URL?
    let dataDir: URL?
    let fixturesDir: URL?
    /// Recorded NetEase responses instead of the network (self-tests).
    let neteaseFixturesDir: URL?

    static let current = LaunchOptions(arguments: CommandLine.arguments)

    init(arguments: [String]) {
        func url(after flag: String) -> URL? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return URL(filePath: arguments[i + 1], relativeTo: .currentDirectory()).standardizedFileURL
        }
        selfTestScript = url(after: "--selftest")
        outDir = url(after: "--out")
        dataDir = url(after: "--data-dir")
        fixturesDir = url(after: "--fixtures")
        neteaseFixturesDir = url(after: "--netease-fixtures")
    }

    var isSelfTest: Bool { selfTestScript != nil }
}

enum SidebarItem: Hashable, Identifiable {
    case songs, albums, artists, composers, recent, liked, enrich
    case playlist(Int64)

    static let library: [Self] = [.songs, .albums, .artists, .composers]
    static let presets: [Self] = [.recent, .liked]
    static let tools: [Self] = [.enrich]

    var id: Self { self }

    /// Self-test names of the fixed items.
    init?(name: String) {
        guard let item = (Self.library + Self.presets + Self.tools).first(where: { $0.name == name }) else { return nil }
        self = item
    }

    var name: String {
        switch self {
        case .songs: "songs"
        case .albums: "albums"
        case .artists: "artists"
        case .composers: "composers"
        case .recent: "recent"
        case .liked: "liked"
        case .enrich: "enrich"
        case .playlist: "playlist"
        }
    }

    var title: String {
        switch self {
        case .songs: "歌曲"
        case .albums: "专辑"
        case .artists: "艺人"
        case .composers: "作曲"
        case .recent: "最近添加"
        case .liked: "喜欢的歌曲"
        case .enrich: "信息补全"
        case .playlist: "播放列表"
        }
    }

    var symbol: String {
        switch self {
        case .songs: "music.note"
        case .albums: "square.stack"
        case .artists: "music.mic"
        case .composers: "pianokeys"
        case .recent: "clock"
        case .liked: "heart"
        case .enrich: "wand.and.sparkles"
        case .playlist: "music.note.list"
        }
    }
}

/// The name field of the new / rename playlist dialog.
enum PlaylistPrompt {
    case create([Int64])
    case rename(Int64)

    var title: String { if case .rename = self { "重命名播放列表" } else { "新建播放列表" } }
    var action: String { if case .rename = self { "重命名" } else { "创建" } }
}

enum DropTarget: Equatable {
    case playlist(Int64)
    case newPlaylist
}

enum Route: Hashable {
    case album(String)
}

@Observable final class UIState {
    var sidebar: SidebarItem = .songs
    var path: [Route] = []
    var search = ""
    var songSort = [KeyPathComparator(\TrackRow.title, comparator: .localizedStandard)]
    var songSelection: Set<Int64> = []
    var nowPlayingShown = false
    var lyricsPosition = ScrollPosition(idType: Int.self)
    /// Self-tests turn animations off: with the display asleep they never advance, so an animated scroll or
    /// transition would stay at its first frame.
    var animationsEnabled = true
    var queueShown = false
    var filter = TrackFilter()
    var personSelection: [PersonRole: String] = [:]
    var playlistPrompt: PlaylistPrompt?
    var playlistName = ""
    var deletingPlaylist: Int64?
    var infoEditor: InfoEditor?
    var enrichFilter = EnrichFilter.missingLyrics
    var enrichSelection: Set<Int64> = []
    /// The song whose NetEase candidates are being chosen from, with the candidates as they were when the sheet opened.
    var candidatesFor: (row: TrackRow, candidates: [NeteaseSong])?
    /// What songs are being dragged over in the sidebar.
    var dropTarget: DropTarget?
    @ObservationIgnored private var sortedMemo: (index: UUID, sort: [KeyPathComparator<TrackRow>], rows: [TrackRow])?
    @ObservationIgnored private var filteredMemo: (index: UUID, search: String, filter: TrackFilter, sort: [KeyPathComparator<TrackRow>], rows: [TrackRow])?
    @ObservationIgnored private var matchesMemo: (index: UUID, filter: TrackFilter, ids: Set<Int64>?)?

    /// Library songs sorted like the table (memoized per sort) then narrowed by the search field and filter (memoized
    /// per query), so typing never re-sorts.
    func songs(in index: LibraryIndex) -> [TrackRow] {
        let search = search, filter = filter, sort = songSort
        if let memo = filteredMemo, memo.index == index.id, memo.search == search, memo.filter == filter, memo.sort == sort {
            return memo.rows
        }
        if sortedMemo?.index != index.id || sortedMemo?.sort != sort {
            sortedMemo = (index.id, sort, index.songs.sorted(using: sort))
        }
        var rows = index.filter(sortedMemo!.rows, matching: search)
        if let ids = matches(in: index) { rows.removeAll { !ids.contains($0.id) } }
        filteredMemo = (index.id, search, filter, sort, rows)
        return rows
    }

    /// Albums and people with at least one track the filter keeps.
    func albums(in index: LibraryIndex) -> [AlbumGroup] {
        let albums = index.albums(matching: search)
        guard let ids = matches(in: index) else { return albums }
        return albums.filter { $0.trackIDs.contains(where: ids.contains) }
    }

    func people(_ role: PersonRole, in index: LibraryIndex) -> [PersonGroup] {
        let groups = index.people(role, matching: search)
        guard let ids = matches(in: index) else { return groups }
        return groups.filter { $0.trackIDs.contains(where: ids.contains) }
    }

    /// Albums by their latest-added track, newest first.
    func recentAlbums(in index: LibraryIndex) -> [AlbumGroup] {
        albums(in: index)
            .map { album in (album, album.trackIDs.lazy.compactMap { index.tracks[$0]?.addedAt }.max() ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(100)
            .map(\.0)
    }

    /// `rows` narrowed by the search field and filter, order kept.
    func narrowed(_ rows: [TrackRow], in index: LibraryIndex) -> [TrackRow] {
        var rows = index.filter(rows, matching: search)
        if let ids = matches(in: index) { rows.removeAll { !ids.contains($0.id) } }
        return rows
    }

    func likedSongs(in index: LibraryIndex, liked: [Int64: Date]) -> [TrackRow] {
        songs(in: index).filter { liked[$0.id] != nil }
    }

    /// The chosen person, else the first one the search and filter leave.
    func selectedPerson(_ role: PersonRole, in groups: [PersonGroup]) -> PersonGroup? {
        groups.first { $0.id == personSelection[role] } ?? groups.first
    }

    private func matches(in index: LibraryIndex) -> Set<Int64>? {
        let filter = filter
        if let memo = matchesMemo, memo.index == index.id, memo.filter == filter { return memo.ids }
        let ids = index.matches(filter)
        matchesMemo = (index.id, filter, ids)
        return ids
    }

    /// Lists are rebuilt rather than diffed when this changes: far cheaper than SwiftUI diffing hundreds of reinserted
    /// rows (2.5 s to clear a search over 322 songs).
    var listID: [AnyHashable] { [search, filter] }

    /// Bumped by ⌘F; the root view moves focus into the search field.
    private(set) var searchFocusRequests = 0

    func focusSearch() {
        nowPlayingShown = false
        searchFocusRequests += 1
    }

    /// Captured from the view environment so non-view code (menus, the mini player, self-tests) can open windows.
    @ObservationIgnored var openSettings: OpenSettingsAction?
    @ObservationIgnored var openWindow: OpenWindowAction?
}

@Observable final class AppModel {
    static let shared = AppModel(options: .current)

    let options: LaunchOptions
    let paths: AppPaths
    let ui = UIState()
    let library: LibraryModel?
    let player: PlayerModel?
    let loudness: LoudnessModel?
    let enrich: EnrichModel?
    let artwork: ArtworkStore
    @ObservationIgnored private var nowPlaying: NowPlayingBridge?
    private(set) var startupError: String?
    private(set) var miniPlayerShown = false
    @ObservationIgnored private var miniPanel: NSPanel?

    init(options: LaunchOptions) {
        precondition(!options.isSelfTest || (options.dataDir != nil && options.outDir != nil), "--selftest requires --out and --data-dir")
        self.options = options
        paths = options.dataDir.map { AppPaths(isolatedRoot: $0) } ?? .standard()
        artwork = ArtworkStore(cache: ArtworkCache(directory: paths.cache.appending(path: "artwork")))
        var library: LibraryModel?, player: PlayerModel?, loudness: LoudnessModel?, enrich: EnrichModel?
        do {
            let store = try LibraryStore(url: paths.database)
            library = LibraryModel(store: store)
            loudness = LoudnessModel(store: store)
            player = try PlayerModel(library: library!, store: store, loudness: loudness, muted: options.isSelfTest)
            library?.onReload = { [weak library, weak player, weak loudness] in
                player?.libraryReloaded()
                if let library { loudness?.refresh(library.index) }
            }
            loudness?.onGainsChange = { [weak player] in player?.gainsChanged(modeChanged: $0) }
            let fixtures = options.neteaseFixturesDir
            enrich = library.map { EnrichModel(store: store, library: $0,
                                 client: NeteaseClient(configuration: fixtures.map(NeteaseFixtures.configuration) ?? .ephemeral),
                                 interval: fixtures == nil ? .milliseconds(600) : .zero) }
        } catch {
            startupError = String(describing: error)
        }
        self.library = library
        self.player = player
        self.loudness = loudness
        self.enrich = enrich
        if let player { Task { await player.restore() } }
        if !options.isSelfTest { enableNowPlaying() }
        // AppKit retains the monitor and calls it on the main thread.
        _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] in self?.handleKey($0) ?? $0 }
    }

    /// Bare keys in the library window, run before menu key equivalents (a bare-key menu shortcut would swallow what's
    /// typed into the search field): space plays / pauses, ← / → seek 5 s. Text being edited keeps them. Returns the
    /// event if it should continue.
    func handleKey(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad])
        guard modifiers.isEmpty, let window = event.window, window.isLibraryWindow, !(window.firstResponder is NSText),
              let player, player.queue.current != nil else { return event }
        switch event.keyCode {
        case 49: if !event.isARepeat { player.togglePlayPause() }
        case 123 where player.current != nil: player.seek(to: max(player.position - 5, 0))
        case 124 where player.current != nil: player.seek(to: min(player.position + 5, player.duration))
        default: return event
        }
        return nil
    }

    func setMiniPlayer(_ shown: Bool) {
        if shown {
            guard let player else { return }
            let panel = miniPanel ?? .miniPlayer(self, player: player)
            miniPanel = panel
            panel.orderFrontRegardless()
        } else {
            miniPanel?.orderOut(nil)
        }
        miniPlayerShown = shown
    }

    func showMainWindow() {
        NSApp.activate()
        ui.openWindow?(id: "main")
    }

    /// Asks for a name; an empty playlist is then opened, one made from songs is not.
    func promptNewPlaylist(_ tracks: [Int64] = []) {
        showMainWindow()
        ui.playlistName = ""
        ui.playlistPrompt = .create(tracks)
    }

    func promptRenamePlaylist(_ playlist: Playlist) {
        ui.playlistName = playlist.name
        ui.playlistPrompt = .rename(playlist.id)
    }

    func commitPlaylistPrompt(_ prompt: PlaylistPrompt) {
        guard let library else { return }
        let name = ui.playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch prompt {
        case .create(let tracks):
            Task {
                guard let playlist = await library.createPlaylist(name.isEmpty ? "未命名播放列表" : name, tracks: tracks), tracks.isEmpty
                else { return }
                ui.sidebar = .playlist(playlist.id)
                ui.path = []
            }
        case .rename(let id):
            if !name.isEmpty { library.renamePlaylist(id, name) }
        }
    }

    func deletePlaylist(_ id: Int64) {
        if ui.sidebar == .playlist(id) { ui.sidebar = .songs }
        library?.deletePlaylist(id)
    }

    /// ⌘F: unlike `UIState.focusSearch`, also brings the library window forward (e.g. from Settings).
    func searchFromMenu() {
        ui.openWindow?(id: "main")
        ui.focusSearch()
    }

    /// Registers media keys / Control Center. Self-tests opt in explicitly so they never grab the user's media keys.
    func enableNowPlaying() {
        guard let player, nowPlaying == nil else { return }
        let bridge = NowPlayingBridge(player: player, artwork: artwork)
        nowPlaying = bridge
        player.onChange = { [unowned player] in bridge.update(player) }
    }

    /// Self-tests start the library themselves, with their own roots.
    func startLibrary() async {
        guard !options.isSelfTest else { return }
        await library?.start()
    }
}

extension NSWindow {
    /// The main library window (SwiftUI names it after the scene id "main").
    var isLibraryWindow: Bool { identifier?.rawValue.hasPrefix("main") == true }
}
