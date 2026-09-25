import Foundation

/// Serves recorded NetEase responses from a directory instead of the network, for tests and self-tests:
/// `search/<keywords>.json`, `song/<id>.json`, `lyric/<id>.json`, and `cover.jpg` for any image URL. A missing search or
/// lyric file answers "nothing found"; every request is logged. One directory per process: the latest
/// `configuration(directory:)` serves every session.
public final class NeteaseFixtures: URLProtocol {
    private nonisolated(unsafe) static var directory: URL?
    private nonisolated(unsafe) static var logged: [String] = []
    private static let lock = NSLock()

    public static func configuration(directory: URL) -> URLSessionConfiguration {
        lock.withLock { self.directory = directory }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NeteaseFixtures.self]
        return configuration
    }

    /// Paths and queries requested so far.
    public static var requests: [String] { lock.withLock { logged } }

    override public class func canInit(with request: URLRequest) -> Bool { true }
    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override public func stopLoading() {}

    override public func startLoading() {
        guard let url = request.url, let client else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let directory = Self.lock.withLock {
            Self.logged.append((components?.path ?? "") + (components?.query.map { "?" + $0 } ?? ""))
            return Self.directory
        }
        let (file, fallback): (String, String?) = switch components?.path {   // URL.path would drop the trailing slash
        case "/api/cloudsearch/pc": ("search/\(query["s"] ?? "").json", #"{"code":200,"result":{"songs":[]}}"#)
        case "/api/song/detail/": ("song/\(query["ids"]?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) ?? "").json", nil)
        case "/api/song/lyric": ("lyric/\(query["id"] ?? "").json", #"{"code":200}"#)
        default: ("cover.jpg", nil)
        }
        let body = directory.flatMap { try? Data(contentsOf: $0.appending(path: file)) } ?? fallback.map { Data($0.utf8) }
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: body ?? Data())
        client.urlProtocolDidFinishLoading(self)
    }
}
