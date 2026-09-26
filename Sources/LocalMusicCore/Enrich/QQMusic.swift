import Foundation

/// QQ Music (`y.qq.com`): the desktop client's search and the web lyric endpoint.
extension OnlineClient {
    private static let qqReferer = "https://y.qq.com/"

    func qqSearch(_ keywords: String, limit: Int) async throws -> [OnlineSong] {
        let request: [String: Any] = ["req": ["module": "music.search.SearchCgiService", "method": "DoSearchForQQMusicDesktop",
                                              "param": ["query": keywords, "num_per_page": limit, "page_num": 1, "search_type": 0]]]
        let data = String(decoding: try JSONSerialization.data(withJSONObject: request, options: .sortedKeys), as: UTF8.self)
        guard let json = try await json(Self.url("https://u.y.qq.com", "/cgi-bin/musicu.fcg", ["data": data]), referer: Self.qqReferer)
                as? [String: Any], let req = json["req"] as? [String: Any] else { throw OnlineError.malformed }
        if let code = req["code"] as? Int, code != 0 { throw OnlineError.api(code) }
        let body = (req["data"] as? [String: Any])?["body"] as? [String: Any]
        return ((body?["song"] as? [String: Any])?["list"] as? [[String: Any]] ?? []).compactMap(Self.qqSong)
    }

    func qqLyrics(_ song: OnlineSong) async throws -> String? {
        let url = Self.url("https://c.y.qq.com", "/lyric/fcgi-bin/fcg_query_lyric_new.fcg", ["songmid": song.id, "format": "json", "nobase64": "1"])
        guard let json = try await json(url, referer: Self.qqReferer) as? [String: Any] else { throw OnlineError.malformed }
        func text(_ key: String) -> String? { (json[key] as? String).map(Self.unescaped).flatMap { $0.isEmpty ? nil : $0 } }
        guard let lyrics = text("lyric") else { return nil }   // songs without lyrics answer an error code
        // The first line repeats "title - artists"; untranslated lines read "//".
        let original = lyrics.split(whereSeparator: \.isNewline).filter { !($0.hasPrefix("[00:00.00]") && $0.dropFirst(10).hasPrefix("\(song.title) - ")) }
        let translation = text("trans")?.split(whereSeparator: \.isNewline).filter { !$0.hasSuffix("]//") }
        return LyricsMerge.merge(original.joined(separator: "\n"), translation: translation.map { $0.joined(separator: "\n") })
    }

    static func qqSong(_ s: [String: Any]) -> OnlineSong? {
        guard let mid = s["mid"] as? String, let title = s["name"] as? String else { return nil }
        let album = s["album"] as? [String: Any]
        let albumMid = album?["mid"] as? String ?? ""
        return OnlineSong(source: .qq, id: mid, title: title,
                          artists: (s["singer"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String },
                          album: album?["name"] as? String ?? "",
                          coverURL: albumMid.isEmpty ? nil : URL(string: "https://y.gtimg.cn/music/photo_new/T002R1200x1200M000\(albumMid).jpg"),
                          duration: (s["interval"] as? NSNumber)?.doubleValue ?? 0,
                          trackNo: (s["index_album"] as? NSNumber)?.intValue.nonZero,
                          discNo: (s["index_cd"] as? NSNumber).map { $0.intValue + 1 },
                          year: (s["time_public"] as? String).flatMap { Int($0.prefix(4)) }.flatMap(\.nonZero))
    }

    /// Lyrics come HTML-escaped.
    private static func unescaped(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, character) in [("&apos;", "'"), ("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            result = result.replacing(entity, with: character)
        }
        result = result.replacing(/&#(\d+);/) { match in Int(match.1).flatMap(UnicodeScalar.init).map { String($0) } ?? String(match.0) }
        return result.replacing("&amp;", with: "&")
    }
}
