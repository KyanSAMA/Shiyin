import Foundation

/// What a library song is searched by.
public struct MatchQuery: Sendable, Equatable {
    public var title: String
    public var artists: [String]
    public var album: String?
    /// Seconds.
    public var duration: Double

    public init(title: String, artists: [String], album: String?, duration: Double) {
        (self.title, self.artists, self.album, self.duration) = (title, artists, album, duration)
    }

    /// Title and first artist: extra artists and album names mostly narrow a search too far.
    public var keywords: String { ([title] + artists.prefix(1)).joined(separator: " ") }

    /// The song as a known match names it, for asking other sources (the file's duration still decides).
    func pinned(_ song: OnlineSong) -> MatchQuery {
        song.source == .lrclib ? self : MatchQuery(title: song.title, artists: song.artists.isEmpty ? artists : song.artists,
                                                   album: song.album.isEmpty ? album : song.album, duration: duration)
    }
}

public enum MatchResult: Sendable, Equatable {
    /// Safe to apply without asking.
    case confident(OnlineSong, score: Double)
    /// Up to five candidates, best first, for the user to pick from.
    case uncertain([OnlineSong])
    case none
}

/// Picks the online song for a library song: the same title (ignoring case, width, traditional / simplified Chinese,
/// bracketed notes and "feat.") and a duration within 2 s, with a shared artist or the same album (a store may spell
/// the artist in another script; a single named after its song doesn't count), is confident; the album name breaks ties
/// between releases of one recording.
public enum Matcher {
    public static let durationTolerance = 2.0

    public static func match(_ query: MatchQuery, candidates: [OnlineSong]) -> MatchResult {
        let scored = ranking(query, candidates).filter { $0.1.title > 0 }
        guard let best = scored.first else { return .none }
        if best.1.title == 1, best.1.duration == 1,
           best.1.artist == 1 || best.1.album == 1 && normalized(best.0.album) != normalized(best.0.title) {
            return .confident(best.0, score: best.1.total)
        }
        return .uncertain(scored.prefix(5).map(\.0))
    }

    /// Every candidate, best first, including those whose title differs (the user may be searching by other words).
    public static func ranked(_ query: MatchQuery, candidates: [OnlineSong]) -> [OnlineSong] { ranking(query, candidates).map(\.0) }

    /// Ties keep the given order (the sources' relevance).
    private static func ranking(_ query: MatchQuery, _ candidates: [OnlineSong]) -> [(OnlineSong, Score)] {
        candidates.enumerated().map { ($0.element, score($0.element, query), $0.offset) }
            .sorted { ($0.1.total, -$0.2) > ($1.1.total, -$1.2) }.map { ($0.0, $0.1) }
    }

    struct Score {
        var title = 0.0, artist = 0.0, duration = 0.0, album = 0.0
        var total: Double { title * 4 + artist * 3 + duration * 2 + album }
    }

    static func score(_ song: OnlineSong, _ query: MatchQuery) -> Score {
        var score = Score()
        let (a, b) = (normalized(song.title), normalized(query.title))
        score.title = a == b ? 1 : !a.isEmpty && !b.isEmpty && (a.contains(b) || b.contains(a)) ? 0.5 : 0
        let theirs = Set(song.artists.map(normalized))
        score.artist = query.artists.contains { theirs.contains(normalized($0)) } ? 1 : 0
        let delta = abs(song.duration - query.duration)
        score.duration = delta <= durationTolerance ? 1 : delta <= 10 ? 0.3 : 0
        score.album = query.album.map { !song.album.isEmpty && normalized($0) == normalized(song.album) ? 1 : 0 } ?? 0
        return score
    }

    private nonisolated(unsafe) static let noise = /\([^)]*\)|（[^）]*）|\[[^\]]*\]|【[^】]*】|\s(?:feat\.|feat\s|ft\.).*$/

    /// Case, width, diacritics and traditional Chinese folded; bracketed notes ("(TV size)", "【Live】") and "feat." tails dropped (「」 quote
    /// part of a title and stay); only letters and digits kept.
    static func normalized(_ text: String) -> String {
        let folded = (text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text)
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
        let stripped = folded.replacing(noise.ignoresCase(), with: "")
        let kept = String(stripped.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        return kept.isEmpty ? String(folded.filter { !$0.isWhitespace }) : kept
    }
}
