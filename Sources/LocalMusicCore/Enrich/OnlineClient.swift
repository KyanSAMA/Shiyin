import Foundation

/// A song found online, from search or song detail.
public struct OnlineSong: Sendable, Equatable, Codable {
    public let source: OnlineSource
    /// NetEase and LRCLIB number their songs, QQ Music uses a "mid" string, iTunes a track id.
    public let id: String
    public let title: String
    public let artists: [String]
    public let album: String
    /// `OnlineClient.coverURL(_:pixels:)` sizes it.
    public let coverURL: URL?
    /// Seconds.
    public let duration: Double
    public let trackNo: Int?
    public let discNo: Int?
    public let year: Int?
    public let genre: String?
    /// LRCLIB returns lyrics with the search result.
    public let lyrics: String?

    public init(source: OnlineSource, id: String, title: String, artists: [String], album: String, coverURL: URL?, duration: Double,
                trackNo: Int?, discNo: Int?, year: Int?, genre: String? = nil, lyrics: String? = nil) {
        (self.source, self.id, self.title, self.artists, self.album, self.coverURL) = (source, id, title, artists, album, coverURL)
        (self.duration, self.trackNo, self.discNo, self.year, self.genre, self.lyrics) = (duration, trackNo, discNo, year, genre, lyrics)
    }

    /// Candidates stored before there were other sources are NetEase songs with numeric ids.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(OnlineSource.self, forKey: .source) ?? .netease
        id = try (try? c.decode(String.self, forKey: .id)) ?? String(c.decode(Int64.self, forKey: .id))
        title = try c.decode(String.self, forKey: .title)
        artists = try c.decode([String].self, forKey: .artists)
        album = try c.decode(String.self, forKey: .album)
        coverURL = try c.decodeIfPresent(URL.self, forKey: .coverURL)
        duration = try c.decode(Double.self, forKey: .duration)
        trackNo = try c.decodeIfPresent(Int.self, forKey: .trackNo)
        discNo = try c.decodeIfPresent(Int.self, forKey: .discNo)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        genre = try c.decodeIfPresent(String.self, forKey: .genre)
        lyrics = try c.decodeIfPresent(String.self, forKey: .lyrics)
    }
}

public enum OnlineError: Error, Equatable {
    case http(Int)
    case api(Int)
    case malformed
}

/// Song search, lyrics and covers from NetEase Cloud Music and QQ Music (unofficial web APIs that need a browser
/// User-Agent and Referer and may change without notice), the iTunes Search API and LRCLIB. Only search terms and song
/// ids are sent.
public struct OnlineClient: Sendable {
    static let browserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    private let session: URLSession

    /// Tests and self-tests pass a configuration whose `protocolClasses` serve recorded responses.
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
    }

    /// `storefront`: the iTunes Store country searched.
    public func search(_ source: OnlineSource, _ keywords: String, limit: Int = 10,
                       storefront: String = OnlineSettings.default.storefront) async throws -> [OnlineSong] {
        switch source {
        case .netease: try await neteaseSearch(keywords, limit: limit)
        case .qq: try await qqSearch(keywords, limit: limit)
        case .itunes: try await itunesSearch(keywords, limit: limit, storefront: storefront)
        case .lrclib: try await lrclibSearch(keywords, limit: limit)
        }
    }

    /// The original lyrics with any translation merged in (see `LyricsMerge`); nil when the song has none.
    public func lyrics(_ song: OnlineSong) async throws -> String? {
        switch song.source {
        case .netease: try await neteaseLyrics(song.id)
        case .qq: try await qqLyrics(song)
        case .itunes: nil
        case .lrclib: song.lyrics
        }
    }

    /// nil when the song has no cover.
    public func cover(_ song: OnlineSong, pixels: Int = 1200) async throws -> Data? {
        guard let url = Self.coverURL(song, pixels: pixels) else { return nil }
        do {
            return try await fetch(url)
        } catch OnlineError.http(404) where song.source == .qq && pixels > 800 {
            // Older QQ albums stop at 800 px.
            return try await cover(song, pixels: 800)
        }
    }

    public static func coverURL(_ song: OnlineSong, pixels: Int) -> URL? {
        guard let url = song.coverURL else { return nil }
        switch song.source {
        case .netease:
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            components?.queryItems = [URLQueryItem(name: "param", value: "\(pixels)y\(pixels)")]
            return components?.url
        case .qq:
            // Served in fixed sizes only.
            let size = pixels <= 150 ? 150 : pixels <= 800 ? 800 : 1200
            return URL(string: url.absoluteString.replacing("R1200x1200", with: "R\(size)x\(size)"))
        case .itunes:
            return url.deletingLastPathComponent().appending(path: "\(pixels)x\(pixels)bb.jpg")
        case .lrclib:
            return nil
        }
    }

    /// `path` is kept verbatim: NetEase's `song/detail/` needs its trailing slash.
    static func url(_ base: String, _ path: String, _ query: [String: String]) -> URL {
        var components = URLComponents(string: base)!
        components.path = path
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // A literal "+" would read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacing("+", with: "%2B")
        return components.url!
    }

    /// A captcha or error page can come back as HTML with status 200.
    func json(_ url: URL, referer: String? = nil) async throws -> Any {
        guard let json = try? JSONSerialization.jsonObject(with: try await fetch(url, referer: referer)) else { throw OnlineError.malformed }
        return json
    }

    func fetch(_ url: URL, referer: String? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(url.host() == "lrclib.net" ? "LocalMusic (macOS)" : Self.browserAgent, forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw OnlineError.http(status) }
        return data
    }
}

extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

extension Calendar {
    /// Chinese services date releases at midnight China time.
    static let china: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()
}
