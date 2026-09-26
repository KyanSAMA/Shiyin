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

/// Where an online layer comes from. Shown after the file's own tags, in the user's order.
public enum OnlineSource: String, CaseIterable, Sendable, Codable {
    case netease, qq, itunes, lrclib
}

/// A layer of values: manual edits, or one online source's. Shown values: a manual edit, else the file's own tag, else
/// the online layers in the user's order, else what the scan inferred.
public enum EnrichSource: Hashable, Sendable {
    case user
    case online(OnlineSource)

    public static let allOnline = OnlineSource.allCases.map(EnrichSource.online)

    public init?(rawValue: String) {
        if rawValue == "user" { self = .user } else if let source = OnlineSource(rawValue: rawValue) { self = .online(source) } else { return nil }
    }

    public var rawValue: String {
        switch self {
        case .user: "user"
        case .online(let source): source.rawValue
        }
    }
}

/// Which online sources batch enrichment uses, and the order their layers show in.
public struct OnlineSettings: Sendable, Codable, Equatable {
    public var order: [OnlineSource]
    public var disabled: Set<OnlineSource>
    /// iTunes Store country (the catalog searched).
    public var storefront: String

    public static let key = "onlineSources"
    public static let `default` = OnlineSettings(order: OnlineSource.allCases, disabled: [], storefront: "jp")

    public init(order: [OnlineSource], disabled: Set<OnlineSource>, storefront: String) {
        (self.order, self.disabled, self.storefront) = (order, disabled, storefront)
    }

    /// Every source once, in the saved order (sources added later go last).
    public var ordered: [OnlineSource] {
        var seen = Set<OnlineSource>()
        return (order + OnlineSource.allCases).filter { seen.insert($0).inserted }
    }

    public var enabled: [OnlineSource] { ordered.filter { !disabled.contains($0) } }
}

public enum MatchStatus: String, Sendable, Codable {
    /// Applied without asking (a "163 key" or a confident match).
    case auto
    /// Chosen by the user from the candidates.
    case confirmed
    case pending
    /// No source had anything that fits.
    case none
    /// The user dismissed every candidate; batch enrichment leaves it alone.
    case rejected
}

public struct MatchState: Sendable, Equatable {
    public let status: MatchStatus
    /// For `pending`: best first.
    public let candidates: [OnlineSong]
}
