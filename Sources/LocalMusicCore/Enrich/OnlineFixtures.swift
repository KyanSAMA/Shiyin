import Foundation

/// Serves recorded responses from a directory instead of the network, for tests and self-tests:
/// `netease/search/<keywords>.json`, `netease/song/<id>.json`, `netease/lyric/<id>.json`, `qq/search/<keywords>.json`,
/// `qq/lyric/<mid>.json`, `itunes/<keywords>.json`, `lrclib/<keywords>.json`, `siren/albums.json`, `siren/songs.json`,
/// `siren/album/<cid>.json`, `siren/song/<cid>.json`, `siren/audio/<file>`, `siren/lyric/<file>`, and `cover.jpg` for any image. A missing
/// search or lyric file answers "nothing found"; every request is logged. One directory per process: the latest
/// `configuration(directory:)` serves every session.
public final class OnlineFixtures: URLProtocol {
    private nonisolated(unsafe) static var directory: URL?
    private nonisolated(unsafe) static var logged: [String] = []
    private static let lock = NSLock()

    public static func configuration(directory: URL) -> URLSessionConfiguration {
        lock.withLock { self.directory = directory }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OnlineFixtures.self]
        return configuration
    }

    /// Hosts, paths and queries requested so far.
    public static var requests: [String] { lock.withLock { logged } }

    override public class func canInit(with request: URLRequest) -> Bool { true }
    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override public func stopLoading() {}

    override public func startLoading() {
        guard let url = request.url, let client else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let directory = Self.lock.withLock {
            Self.logged.append((components?.host ?? "") + (components?.path ?? "") + (components?.query.map { "?" + $0 } ?? ""))
            return Self.directory
        }
        let qqQuery = query["data"].flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .flatMap { (($0["req"] as? [String: Any])?["param"] as? [String: Any])?["query"] as? String }
        let (file, fallback): (String, String?) = switch (components?.host, components?.path) {   // URL.path would drop a trailing slash
        case ("music.163.com", "/api/cloudsearch/pc"): ("netease/search/\(query["s"] ?? "").json", #"{"code":200,"result":{"songs":[]}}"#)
        case ("music.163.com", "/api/song/detail/"):
            ("netease/song/\(query["ids"]?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) ?? "").json", nil)
        case ("music.163.com", "/api/song/lyric"): ("netease/lyric/\(query["id"] ?? "").json", #"{"code":200}"#)
        case ("u.y.qq.com", _): ("qq/search/\(qqQuery ?? "").json", #"{"code":0,"req":{"code":0,"data":{"body":{"song":{"list":[]}}}}}"#)
        case ("c.y.qq.com", _): ("qq/lyric/\(query["songmid"] ?? "").json", #"{"retcode":-1901,"code":-1901}"#)
        case ("itunes.apple.com", _): ("itunes/\(query["term"] ?? "").json", #"{"resultCount":0,"results":[]}"#)
        case ("lrclib.net", _): ("lrclib/\(query["q"] ?? "").json", "[]")
        case ("monster-siren.hypergryph.com", let path?):
            ("siren/" + path.dropFirst("/api/".count).replacing("/detail", with: "") + ".json", nil)
        case (_, let path?) where path.contains("/siren/audio/") || path.contains("/siren/lyric/"):
            ("siren/" + (path.contains("/siren/audio/") ? "audio/" : "lyric/") + (path.split(separator: "/").last ?? ""), nil)
        default: ("cover.jpg", nil)
        }
        let body = directory.flatMap { try? Data(contentsOf: $0.appending(path: file)) } ?? fallback.map { Data($0.utf8) }
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: nil,
                                       headerFields: ["Content-Length": String(body?.count ?? 0)])!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: body ?? Data())
        client.urlProtocolDidFinishLoading(self)
    }
}
