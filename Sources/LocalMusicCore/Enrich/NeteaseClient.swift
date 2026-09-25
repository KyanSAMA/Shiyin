import Foundation

/// A NetEase Cloud Music song, from search or song detail.
public struct NeteaseSong: Sendable, Equatable, Codable {
    public let id: Int64
    public let title: String
    public let artists: [String]
    public let album: String
    public let coverURL: URL?
    /// Seconds.
    public let duration: Double
    public let trackNo: Int?
    public let discNo: Int?
    public let year: Int?

    public init(id: Int64, title: String, artists: [String], album: String, coverURL: URL?, duration: Double, trackNo: Int?,
                discNo: Int?, year: Int?) {
        (self.id, self.title, self.artists, self.album, self.coverURL) = (id, title, artists, album, coverURL)
        (self.duration, self.trackNo, self.discNo, self.year) = (duration, trackNo, discNo, year)
    }
}

public enum NeteaseError: Error, Equatable {
    case http(Int)
    case api(Int)
    case malformed
}

/// NetEase's unofficial web API (`music.163.com`, needs a browser User-Agent and Referer; it may change without notice).
/// Only search terms and song ids are sent.
public struct NeteaseClient: Sendable {
    public static let base = URL(string: "https://music.163.com")!
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    private let session: URLSession

    /// Tests and self-tests pass a configuration whose `protocolClasses` serve recorded responses.
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
    }

    public func search(_ keywords: String, limit: Int = 10) async throws -> [NeteaseSong] {
        let json = try await get("/api/cloudsearch/pc", ["s": keywords, "type": "1", "limit": String(limit)])
        return ((json["result"] as? [String: Any])?["songs"] as? [[String: Any]] ?? []).compactMap(Self.searchSong)
    }

    public func song(_ id: Int64) async throws -> NeteaseSong? {
        let json = try await get("/api/song/detail/", ["ids": "[\(id)]"])
        return (json["songs"] as? [[String: Any]])?.first.flatMap(Self.detailSong)
    }

    /// The original lyrics with the translation merged in (see `LyricsMerge`); nil when the song has none.
    public func lyrics(_ id: Int64) async throws -> String? {
        let json = try await get("/api/song/lyric", ["id": String(id), "lv": "1", "tv": "-1"])
        func text(_ key: String) -> String? { ((json[key] as? [String: Any])?["lyric"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return text("lrc").map { LyricsMerge.merge($0, translation: text("tlyric")) }
    }

    public func cover(_ url: URL, pixels: Int = 1200) async throws -> Data {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        components?.queryItems = [URLQueryItem(name: "param", value: "\(pixels)y\(pixels)")]
        return try await fetch(components?.url ?? url)
    }

    private func get(_ path: String, _ query: [String: String]) async throws -> [String: Any] {
        var components = URLComponents(url: Self.base, resolvingAgainstBaseURL: false)!
        components.path = path   // verbatim: `song/detail/` needs its trailing slash
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // A captcha or error page can come back as HTML with status 200.
        guard let json = (try? JSONSerialization.jsonObject(with: try await fetch(components.url!))) as? [String: Any] else {
            throw NeteaseError.malformed
        }
        if let code = json["code"] as? Int, code != 200 { throw NeteaseError.api(code) }
        return json
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw NeteaseError.http(status) }
        return data
    }

    // Search results use short keys (ar, al, dt, cd); song detail spells them out.
    static func searchSong(_ s: [String: Any]) -> NeteaseSong? {
        song(s, artists: s["ar"], album: s["al"], duration: s["dt"], disc: s["cd"], published: s["publishTime"])
    }

    static func detailSong(_ s: [String: Any]) -> NeteaseSong? {
        song(s, artists: s["artists"], album: s["album"], duration: s["duration"], disc: s["disc"],
             published: (s["album"] as? [String: Any])?["publishTime"])
    }

    private static func song(_ s: [String: Any], artists: Any?, album: Any?, duration: Any?, disc: Any?, published: Any?) -> NeteaseSong? {
        guard let id = (s["id"] as? NSNumber)?.int64Value, let title = s["name"] as? String else { return nil }
        let album = album as? [String: Any]
        let milliseconds = (published as? NSNumber)?.doubleValue ?? 0
        return NeteaseSong(id: id, title: title, artists: (artists as? [[String: Any]] ?? []).compactMap { $0["name"] as? String },
                           album: album?["name"] as? String ?? "", coverURL: (album?["picUrl"] as? String).flatMap(URL.init(string:)),
                           duration: ((duration as? NSNumber)?.doubleValue ?? 0) / 1000,
                           trackNo: (s["no"] as? NSNumber)?.intValue.nonZero,
                           discNo: ((disc as? NSNumber)?.intValue ?? (disc as? String).flatMap { Int($0) })?.nonZero,
                           year: milliseconds > 0 ? chinaCalendar.component(.year, from: Date(timeIntervalSince1970: milliseconds / 1000)) : nil)
    }

    /// Release dates are midnight China time.
    private static let chinaCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
