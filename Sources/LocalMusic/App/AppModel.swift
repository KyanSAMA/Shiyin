import Foundation
import Observation
import SwiftUI
import LocalMusicCore

struct LaunchOptions {
    let selfTestScript: URL?
    let outDir: URL?
    let dataDir: URL?
    let fixturesDir: URL?

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
    }

    var isSelfTest: Bool { selfTestScript != nil }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case songs, albums, artists, composers

    var id: Self { self }

    var title: String {
        switch self {
        case .songs: "歌曲"
        case .albums: "专辑"
        case .artists: "艺人"
        case .composers: "作曲"
        }
    }

    var symbol: String {
        switch self {
        case .songs: "music.note"
        case .albums: "square.stack"
        case .artists: "music.mic"
        case .composers: "pianokeys"
        }
    }
}

enum Route: Hashable {
    case album(String)
    case person(PersonRole, String)
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
    @ObservationIgnored private var sortedMemo: (index: UUID, sort: [KeyPathComparator<TrackRow>], rows: [TrackRow])?
    @ObservationIgnored private var filteredMemo: (index: UUID, search: String, sort: [KeyPathComparator<TrackRow>], rows: [TrackRow])?

    /// Library songs sorted like the table (memoized per sort) then filtered by the search field (memoized per query),
    /// so typing never re-sorts.
    func songs(in index: LibraryIndex) -> [TrackRow] {
        let search = search, sort = songSort
        if let memo = filteredMemo, memo.index == index.id, memo.search == search, memo.sort == sort { return memo.rows }
        if sortedMemo?.index != index.id || sortedMemo?.sort != sort {
            sortedMemo = (index.id, sort, index.songs.sorted(using: sort))
        }
        let rows = index.filter(sortedMemo!.rows, matching: search)
        filteredMemo = (index.id, search, sort, rows)
        return rows
    }
    /// Captured from the view environment so non-view code (menus, self-tests) can open Settings.
    @ObservationIgnored var openSettings: OpenSettingsAction?
}

@Observable final class AppModel {
    static let shared = AppModel(options: .current)

    let options: LaunchOptions
    let paths: AppPaths
    let ui = UIState()
    let library: LibraryModel?
    let player: PlayerModel?
    let loudness: LoudnessModel?
    let artwork: ArtworkStore
    @ObservationIgnored private var nowPlaying: NowPlayingBridge?
    private(set) var startupError: String?

    init(options: LaunchOptions) {
        precondition(!options.isSelfTest || (options.dataDir != nil && options.outDir != nil), "--selftest requires --out and --data-dir")
        self.options = options
        paths = options.dataDir.map { AppPaths(isolatedRoot: $0) } ?? .standard()
        artwork = ArtworkStore(cache: ArtworkCache(directory: paths.cache.appending(path: "artwork")))
        var library: LibraryModel?, player: PlayerModel?, loudness: LoudnessModel?
        do {
            let store = try LibraryStore(url: paths.database)
            library = LibraryModel(store: store)
            loudness = LoudnessModel(store: store)
            player = try PlayerModel(library: library!, loudness: loudness, muted: options.isSelfTest)
            library?.onReload = { [weak library, weak player, weak loudness] in
                player?.libraryReloaded()
                if let library { loudness?.refresh(library.index) }
            }
            loudness?.onGainsChange = { [weak player] in player?.gainsChanged(modeChanged: $0) }
        } catch {
            startupError = String(describing: error)
        }
        self.library = library
        self.player = player
        self.loudness = loudness
        if !options.isSelfTest { enableNowPlaying() }
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
