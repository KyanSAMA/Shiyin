import Foundation

/// Fields enrichment can set, keyed by the recording's `AudioFingerprint`. People lists are stored as JSON arrays;
/// `cover` is a file name in `LibraryStore.coversDirectory`.
public enum EnrichField: String, CaseIterable, Sendable {
    case title, artists, album, albumArtist = "album_artist", trackNo = "track_no", discNo = "disc_no", year, genre,
         composers, lyrics, cover

    public var isList: Bool { self == .artists || self == .composers }

    public static func encode(_ names: [String]) -> String {
        String(decoding: (try? JSONEncoder().encode(names)) ?? Data("[]".utf8), as: UTF8.self)
    }

    public static func decode(_ value: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(value.utf8))) ?? []
    }
}

/// Shown values: a manual edit, else the file's own tag, else online enrichment, else what the scan inferred.
public enum EnrichSource: String, Sendable {
    case user, netease
}

public enum MatchStatus: String, Sendable, Codable {
    /// Applied without asking (a "163 key" or a confident match).
    case auto
    /// Chosen by the user from the candidates.
    case confirmed
    case pending
    /// NetEase had nothing that fits.
    case none
    /// The user dismissed every candidate; batch enrichment leaves it alone.
    case rejected
}

public struct MatchState: Sendable, Equatable {
    public let status: MatchStatus
    public let songID: Int64?
    /// For `pending`: best first.
    public let candidates: [NeteaseSong]
}
