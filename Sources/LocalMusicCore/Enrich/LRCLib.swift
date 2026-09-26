import Foundation

/// LRCLIB (`lrclib.net`), an open lyrics database: synced lyrics when it has them, else plain text.
extension OnlineClient {
    func lrclibSearch(_ keywords: String, limit: Int) async throws -> [OnlineSong] {
        guard let json = try await json(Self.url("https://lrclib.net", "/api/search", ["q": keywords])) as? [[String: Any]] else {
            throw OnlineError.malformed
        }
        return json.prefix(limit).compactMap(Self.lrclibSong)
    }

    static func lrclibSong(_ s: [String: Any]) -> OnlineSong? {
        guard let id = (s["id"] as? NSNumber)?.int64Value, let title = s["trackName"] as? String else { return nil }
        let lyrics = [s["syncedLyrics"], s["plainLyrics"]].lazy.compactMap { $0 as? String }.first { !$0.isEmpty }
        return OnlineSong(source: .lrclib, id: String(id), title: title, artists: [s["artistName"] as? String].compactMap { $0 },
                          album: s["albumName"] as? String ?? "", coverURL: nil, duration: (s["duration"] as? NSNumber)?.doubleValue ?? 0,
                          trackNo: nil, discNo: nil, year: nil, lyrics: lyrics)
    }
}
