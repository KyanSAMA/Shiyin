import Foundation

public enum PersonRole: String, Sendable {
    case artist, composer, lyricist, arranger
}

public enum ValueSource: String, Sendable {
    case tag
    case filename
    case lyricsCredit = "lyrics-credit"
}

public struct Person: Sendable, Hashable {
    public let role: PersonRole
    public let name: String
    public let source: ValueSource
}

public struct ReplayGain: Sendable, Equatable {
    public var trackGain: Double?
    public var trackPeak: Double?
    public var albumGain: Double?
    public var albumPeak: Double?
}

/// Normalized, display-ready view of one file's raw tags.
public struct TrackMetadata: Sendable, Equatable {
    public var title: String
    public var titleSource: ValueSource
    public var album: String?
    public var albumArtist: String?
    public var people: [Person]
    public var trackNo: Int?
    /// `.filename` for a number taken from "53.Title", which online enrichment may replace.
    public var trackNoSource: ValueSource?
    public var trackTotal: Int?
    public var discNo: Int?
    public var discTotal: Int?
    public var year: Int?
    public var date: String?
    public var genre: String?
    public var lyrics: String?
    public var replayGain: ReplayGain
    public var ncmKey: String?

    public func names(_ role: PersonRole) -> [String] {
        people.filter { $0.role == role }.map(\.name)
    }

    public init(tags: RawTags, fileURL: URL) {
        let fromName = FilenameParser.parse(fileURL.deletingPathExtension().lastPathComponent)
        if let title = tags.first("TITLE") {
            self.title = title
            titleSource = .tag
        } else {
            title = fromName.title
            titleSource = .filename
        }
        album = tags.first("ALBUM")
        albumArtist = tags.first("ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST")

        let track = Self.numberPair(tags.first("TRACKNUMBER"))
        trackNo = track.number ?? fromName.track
        trackNoSource = track.number != nil ? .tag : fromName.track != nil ? .filename : nil
        trackTotal = track.total ?? tags.first("TRACKTOTAL", "TOTALTRACKS").flatMap { Int($0) }
        let disc = Self.numberPair(tags.first("DISCNUMBER"))
        discNo = disc.number
        discTotal = disc.total ?? tags.first("DISCTOTAL", "TOTALDISCS").flatMap { Int($0) }

        date = tags.first("DATE", "YEAR")
        year = date.flatMap { $0.firstMatch(of: Self.yearPattern) }.flatMap { Int($0.output) }
        genre = tags.first("GENRE")
        lyrics = tags.first("LYRICS", "UNSYNCEDLYRICS", "UNSYNCED LYRICS")
        replayGain = ReplayGain(trackGain: Self.decibels(tags.first("REPLAYGAIN_TRACK_GAIN")),
                                trackPeak: tags.first("REPLAYGAIN_TRACK_PEAK").flatMap { Double($0) },
                                albumGain: Self.decibels(tags.first("REPLAYGAIN_ALBUM_GAIN")),
                                albumPeak: tags.first("REPLAYGAIN_ALBUM_PEAK").flatMap { Double($0) })
        // MP3s carry it as a comment (the ID3 reader files it as NCM_KEY); FLACs as DESCRIPTION or COMMENT.
        ncmKey = tags.first("NCM_KEY") ?? (tags["DESCRIPTION"] + tags["COMMENT"]).first { $0.hasPrefix(ID3Reader.ncmKeyPrefix) }

        let credits = lyrics.flatMap(LRCParser.parse)?.credits ?? LyricCredits()
        func people(_ role: PersonRole, tag key: String, credited: [String]) -> [Person] {
            let tagged = PersonSplitter.split(tags[key])
            return tagged.isEmpty
                ? credited.map { Person(role: role, name: $0, source: .lyricsCredit) }
                : tagged.map { Person(role: role, name: $0, source: .tag) }
        }
        self.people = people(.artist, tag: "ARTIST", credited: [])
            + people(.composer, tag: "COMPOSER", credited: credits.composers)
            + people(.lyricist, tag: "LYRICIST", credited: credits.lyricists)
            + people(.arranger, tag: "ARRANGER", credited: credits.arrangers)
    }

    /// "3/12" → (3, 12)
    private static func numberPair(_ value: String?) -> (number: Int?, total: Int?) {
        guard let parts = value?.split(separator: "/", maxSplits: 1) else { return (nil, nil) }
        return (Int(parts[0].trimmingCharacters(in: .whitespaces)),
                parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil)
    }

    private nonisolated(unsafe) static let yearPattern = /[0-9]{4}/
    private nonisolated(unsafe) static let decibelPattern = /[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)/

    /// "-6.54 dB" → -6.54
    private static func decibels(_ value: String?) -> Double? {
        value?.firstMatch(of: decibelPattern).flatMap { Double($0.output) }
    }
}

public enum PersonSplitter {
    /// Multi-value tags are taken as-is; a single string splits on "/" and ", " only (never "、", which appears inside
    /// unit names such as `…<アリス(CV:田中美海)、アル(CV:近藤玲奈)>`).
    public static func split(_ values: [String]) -> [String] {
        let parts = values.count > 1
            ? values
            : values.flatMap { $0.components(separatedBy: "/").flatMap { $0.components(separatedBy: ", ") } }
        var seen = Set<String>()
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

enum FilenameParser {
    /// "53.Knife to the Throat" / "1. Intro" / "01 Title"; a lone digit needs a spaced separator ("2.5次元の誘惑") and a
    /// space-only separator needs a leading zero ("99 Luftballons").
    private nonisolated(unsafe) static let patterns = [
        /([0-9]{2,3})\s*[.\-_]\s*(.+)/, /([0-9])\s*[.\-_]\s+(.+)/, /(0[0-9]{1,2})\s+(.+)/,
    ]

    static func parse(_ stem: String) -> (track: Int?, title: String) {
        for pattern in patterns {
            if let match = stem.wholeMatch(of: pattern) { return (Int(match.1), String(match.2)) }
        }
        return (nil, stem)
    }
}
