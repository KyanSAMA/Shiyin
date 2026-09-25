import Foundation

public struct AlbumGroup: Sendable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let artist: String
    public let year: Int?
    public let trackIDs: [Int64]
    public let coverTrackID: Int64?

    /// Tracks without an album title, grouped per artist (see `albumKeys`).
    public var isUntitled: Bool { id.hasPrefix("\u{1}") }
}

public struct PersonGroup: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let trackIDs: [Int64]
    public let isUnknown: Bool
}

/// Derived browse structures over one library snapshot. Pure; build it off the main thread.
public struct LibraryIndex: Sendable {
    public static let unknown = "未知"
    public static let unknownAlbum = "未知专辑"
    public static let variousArtists = "多位艺人"

    /// Changes with every rebuild; lets views memoize derived lists.
    public let id = UUID()
    public let songs: [TrackRow]
    public let albums: [AlbumGroup]
    public let artists: [PersonGroup]
    public let composers: [PersonGroup]
    public let tracks: [Int64: TrackRow]
    public let facets: Facets
    private let searchKeys: [Int64: String]
    private let albumOfTrack: [Int64: Int]

    public init(rows: [TrackRow]) {
        songs = rows.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        tracks = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        albums = Self.albums(songs)
        albumOfTrack = Dictionary(uniqueKeysWithValues: albums.enumerated().flatMap { i, album in album.trackIDs.map { ($0, i) } })
        artists = Self.people(songs, \.artists)
        composers = Self.people(songs, \.composers)
        facets = Facets(songs: songs, albums: albums)
        searchKeys = Dictionary(uniqueKeysWithValues: rows.map {
            ($0.id, Self.searchFold(([$0.title, $0.albumTitle] + $0.artists + $0.composers).joined(separator: "\u{1}")))
        })
    }

    // MARK: Search

    /// Case-, width- and diacritic-insensitive, with hiragana folded to katakana (よるしか matches ヨルシカ).
    public static func searchFold(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
        return folded.applyingTransform(.hiraganaToKatakana, reverse: false) ?? folded
    }

    private static func needle(_ query: String) -> String {
        searchFold(query.trimmingCharacters(in: .whitespaces))
    }

    /// Keeps the given order (e.g. a sorted table's).
    public func filter(_ rows: [TrackRow], matching query: String) -> [TrackRow] {
        let needle = Self.needle(query)
        return needle.isEmpty ? rows : rows.filter { searchKeys[$0.id]?.contains(needle) == true }
    }

    public func albums(matching query: String) -> [AlbumGroup] {
        let needle = Self.needle(query)
        return needle.isEmpty ? albums : albums.filter { Self.searchFold($0.title + "\u{1}" + $0.artist).contains(needle) }
    }

    public func people(_ role: PersonRole, matching query: String = "") -> [PersonGroup] {
        let groups = role == .composer ? composers : artists
        let needle = Self.needle(query)
        return needle.isEmpty ? groups : groups.filter { Self.searchFold($0.name).contains(needle) }
    }

    public func album(_ id: String) -> AlbumGroup? { albums.first { $0.id == id } }
    public func album(containing trackID: Int64) -> AlbumGroup? { albumOfTrack[trackID].map { albums[$0] } }

    /// DISCNUMBER, else a disc folder's number (CD1, Disc 2), else 1.
    public static func disc(of row: TrackRow) -> Int {
        if let disc = row.discNo { return disc }
        let folder = URL(filePath: row.path).deletingLastPathComponent().lastPathComponent
        return folder.wholeMatch(of: discFolder).flatMap { Int($0.1) } ?? 1
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    private nonisolated(unsafe) static let discFolder = /(?i)(?:cd|dis[ck])\s*([0-9]+)/

    /// The folder that owns an album: disc subfolders (CD1, Disc 2) belong to their parent.
    static func albumFolder(_ path: String) -> String {
        let folder = URL(filePath: path).deletingLastPathComponent()
        return (folder.lastPathComponent.wholeMatch(of: discFolder) != nil ? folder.deletingLastPathComponent() : folder).path
    }

    /// Album identity: (album, ALBUMARTIST) when tagged — untagged tracks inherit the album artist tagged elsewhere
    /// in the same folder — else (album, folder), so an album whose tracks credit different artists stays whole.
    /// Untitled tracks group per primary artist.
    static func albumKeys(_ songs: [TrackRow]) -> [Int64: String] {
        var folderArtist: [String: String] = [:]
        for row in songs {
            guard let album = row.album, !album.isEmpty, let artist = row.albumArtist else { continue }
            let key = fold(album) + "\u{0}" + albumFolder(row.path)
            if folderArtist[key] == nil { folderArtist[key] = fold(artist) }
        }
        return Dictionary(uniqueKeysWithValues: songs.map { row in
            guard let album = row.album, !album.isEmpty else { return (row.id, "\u{1}" + fold(row.artists.first ?? unknown)) }
            let folderKey = fold(album) + "\u{0}" + albumFolder(row.path)
            return (row.id, fold(album) + "\u{0}" + (row.albumArtist.map(fold) ?? folderArtist[folderKey] ?? albumFolder(row.path)))
        })
    }

    private static func albums(_ songs: [TrackRow]) -> [AlbumGroup] {
        let keys = albumKeys(songs)
        return Dictionary(grouping: songs, by: { keys[$0.id]! }).map { key, rows in
            let ordered = rows.sorted {
                let a = (disc(of: $0), $0.trackNo ?? .max), b = (disc(of: $1), $1.trackNo ?? .max)
                return a != b ? a < b : $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return AlbumGroup(id: key, title: rows[0].album.flatMap { $0.isEmpty ? nil : $0 } ?? unknownAlbum,
                              artist: rows.lazy.compactMap(\.albumArtist).first ?? majorityArtist(rows),
                              year: rows.lazy.compactMap(\.year).max(), trackIDs: ordered.map(\.id),
                              coverTrackID: (ordered.first(where: \.hasCover) ?? ordered.first)?.id)
        }
        .sorted {
            let title = $0.title.localizedStandardCompare($1.title)
            if title != .orderedSame { return title == .orderedAscending }
            let artist = $0.artist.localizedStandardCompare($1.artist)
            return artist != .orderedSame ? artist == .orderedAscending : $0.id < $1.id
        }
    }

    private static func majorityArtist(_ rows: [TrackRow]) -> String {
        let counts = Dictionary(grouping: rows.compactMap(\.artists.first), by: { $0 }).mapValues(\.count)
        guard let (name, count) = counts.max(by: { $0.value < $1.value }) else { return unknown }
        return count * 2 > rows.count ? name : variousArtists
    }

    private static func people(_ songs: [TrackRow], _ names: KeyPath<TrackRow, [String]>) -> [PersonGroup] {
        var groups: [String: (name: String, ids: [Int64])] = [:]
        var unknownIDs: [Int64] = []
        for row in songs {
            let list = row[keyPath: names]
            if list.isEmpty { unknownIDs.append(row.id) }
            var seen = Set<String>()
            for name in list where seen.insert(fold(name)).inserted { groups[fold(name), default: (name, [])].ids.append(row.id) }
        }
        let known = groups.map { PersonGroup(id: $0.key, name: $0.value.name, trackIDs: $0.value.ids, isUnknown: false) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return unknownIDs.isEmpty ? known : known + [PersonGroup(id: "\u{1}", name: unknown, trackIDs: unknownIDs, isUnknown: true)]
    }
}
