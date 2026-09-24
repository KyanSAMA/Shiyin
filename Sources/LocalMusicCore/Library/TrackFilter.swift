import Foundation

/// Library-wide filter: dimensions combine with AND, values within one with OR; a nil tri-state matches either way.
public struct TrackFilter: Sendable, Hashable {
    public var albumArtists: Set<String> = []
    public var years: Set<Int> = []
    public var genres: Set<String> = []
    public var formats: Set<String> = []
    public var hiRes: Bool?
    public var hasLyrics: Bool?

    public init() {}

    public var isEmpty: Bool { self == TrackFilter() }

    /// Expects `albumArtists` and `genres` folded (see `LibraryIndex.matches`), so spelling variants match alike.
    func matches(_ row: TrackRow, albumArtist: String?) -> Bool {
        (albumArtists.isEmpty || albumArtist.map { albumArtists.contains(LibraryIndex.fold($0)) } == true)
            && (years.isEmpty || row.year.map(years.contains) == true)
            && (genres.isEmpty || row.genres.contains { genres.contains(LibraryIndex.fold($0)) })
            && (formats.isEmpty || formats.contains(row.formatName))
            && hiRes.map { $0 == row.isHiRes } != false
            && hasLyrics.map { $0 == row.hasLyrics } != false
    }
}

extension TrackRow {
    /// FLAC / ALAC / AAC / MP3 / WAV; the file extension when the codec is unknown.
    public var formatName: String { ((codec == "pcm" ? nil : codec) ?? format).uppercased() }
    public var isLossless: Bool { ["flac", "alac", "pcm"].contains(codec) }
    /// Lossless beyond CD quality: above 48 kHz or at least 24 bit.
    public var isHiRes: Bool { isLossless && ((sampleRate ?? 0) > 48000 || (bitDepth ?? 0) >= 24) }
    /// A GENRE such as "New Wave, Synth-pop" splits like artist names.
    public var genres: [String] { PersonSplitter.split(genre.map { [$0] } ?? []) }
}

extension LibraryIndex {
    /// The values each filter dimension offers.
    public struct Facets: Sendable {
        public let albumArtists: [String]
        /// Newest first.
        public let years: [Int]
        public let genres: [String]
        public let formats: [String]

        init(songs: [TrackRow], albums: [AlbumGroup]) {
            albumArtists = Self.distinct(albums.map(\.artist))
            years = Set(songs.compactMap(\.year)).sorted(by: >)
            genres = Self.distinct(songs.flatMap(\.genres))
            formats = Set(songs.map(\.formatName)).sorted()
        }

        /// One entry per folded spelling (the first seen), so "J-Pop" and "J-POP" don't both appear.
        private static func distinct(_ names: [String]) -> [String] {
            var seen = Set<String>()
            return names.filter { seen.insert(LibraryIndex.fold($0)).inserted }.localizedSorted()
        }
    }

    /// Ids of the tracks the filter keeps; nil for an empty filter. The album artist is the one the album grid shows.
    public func matches(_ filter: TrackFilter) -> Set<Int64>? {
        guard !filter.isEmpty else { return nil }
        var folded = filter
        folded.albumArtists = Set(filter.albumArtists.map(Self.fold))
        folded.genres = Set(filter.genres.map(Self.fold))
        return Set(songs.lazy.filter { folded.matches($0, albumArtist: self.album(containing: $0.id)?.artist) }.map(\.id))
    }
}

extension Sequence<String> {
    public func localizedSorted() -> [String] {
        sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
