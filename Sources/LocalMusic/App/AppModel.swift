import Foundation
import Observation
import LocalMusicCore

struct LaunchOptions {
    let selfTestScript: URL?
    let outDir: URL?
    let dataDir: URL?

    static let current = LaunchOptions(arguments: CommandLine.arguments)

    init(arguments: [String]) {
        func url(after flag: String) -> URL? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return URL(filePath: arguments[i + 1], relativeTo: .currentDirectory()).standardizedFileURL
        }
        selfTestScript = url(after: "--selftest")
        outDir = url(after: "--out")
        dataDir = url(after: "--data-dir")
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

@Observable final class UIState {
    var sidebar: SidebarItem = .songs
}

@Observable final class AppModel {
    static let shared = AppModel(options: .current)

    let options: LaunchOptions
    let paths: AppPaths
    let ui = UIState()
    private(set) var store: LibraryStore?
    private(set) var startupError: String?

    init(options: LaunchOptions) {
        precondition(!options.isSelfTest || (options.dataDir != nil && options.outDir != nil), "--selftest requires --out and --data-dir")
        self.options = options
        paths = options.dataDir.map { AppPaths(isolatedRoot: $0) } ?? .standard()
        do {
            store = try LibraryStore(url: paths.database)
        } catch {
            startupError = String(describing: error)
        }
    }
}
