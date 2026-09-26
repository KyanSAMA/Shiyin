import Foundation

/// NetEase Cloud Music (`music.163.com`).
extension OnlineClient {
    private static let neteaseBase = "https://music.163.com", neteaseReferer = "https://music.163.com/"

    func neteaseSearch(_ keywords: String, limit: Int) async throws -> [OnlineSong] {
        let json = try await netease("/api/cloudsearch/pc", ["s": keywords, "type": "1", "limit": String(limit)])
        return ((json["result"] as? [String: Any])?["songs"] as? [[String: Any]] ?? []).compactMap(Self.neteaseSearchSong)
    }

    /// Song detail: also the album's release date, which search results often lack.
    public func neteaseSong(_ id: Int64) async throws -> OnlineSong? {
        let json = try await netease("/api/song/detail/", ["ids": "[\(id)]"])
        return (json["songs"] as? [[String: Any]])?.first.flatMap(Self.neteaseDetailSong)
    }

    func neteaseLyrics(_ id: String) async throws -> String? {
        let json = try await netease("/api/song/lyric", ["id": id, "lv": "1", "tv": "-1"])
        func text(_ key: String) -> String? { ((json[key] as? [String: Any])?["lyric"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return text("lrc").map { LyricsMerge.merge($0, translation: text("tlyric")) }
    }

    private func netease(_ path: String, _ query: [String: String]) async throws -> [String: Any] {
        guard let json = try await json(Self.url(Self.neteaseBase, path, query), referer: Self.neteaseReferer) as? [String: Any] else {
            throw OnlineError.malformed
        }
        if let code = json["code"] as? Int, code != 200 { throw OnlineError.api(code) }
        return json
    }

    // Search results use short keys (ar, al, dt, cd); song detail spells them out.
    static func neteaseSearchSong(_ s: [String: Any]) -> OnlineSong? {
        neteaseSong(s, artists: s["ar"], album: s["al"], duration: s["dt"], disc: s["cd"], published: s["publishTime"])
    }

    static func neteaseDetailSong(_ s: [String: Any]) -> OnlineSong? {
        neteaseSong(s, artists: s["artists"], album: s["album"], duration: s["duration"], disc: s["disc"],
                    published: (s["album"] as? [String: Any])?["publishTime"])
    }

    private static func neteaseSong(_ s: [String: Any], artists: Any?, album: Any?, duration: Any?, disc: Any?, published: Any?) -> OnlineSong? {
        guard let id = (s["id"] as? NSNumber)?.int64Value, let title = s["name"] as? String else { return nil }
        let album = album as? [String: Any]
        let milliseconds = (published as? NSNumber)?.doubleValue ?? 0
        return OnlineSong(source: .netease, id: String(id), title: title,
                          artists: (artists as? [[String: Any]] ?? []).compactMap { $0["name"] as? String },
                          album: album?["name"] as? String ?? "", coverURL: (album?["picUrl"] as? String).flatMap(URL.init(string:)),
                          duration: ((duration as? NSNumber)?.doubleValue ?? 0) / 1000,
                          trackNo: (s["no"] as? NSNumber)?.intValue.nonZero,
                          discNo: ((disc as? NSNumber)?.intValue ?? (disc as? String).flatMap { Int($0) })?.nonZero,
                          year: milliseconds > 0 ? Calendar.china.component(.year, from: Date(timeIntervalSince1970: milliseconds / 1000)) : nil)
    }
}
