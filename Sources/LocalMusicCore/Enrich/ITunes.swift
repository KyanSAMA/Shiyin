import Foundation

/// The iTunes Search API: release dates, track and disc numbers, genres and large covers; no lyrics. Names come as the
/// store's catalog spells them (a Japanese store writes Chinese titles in traditional characters).
extension OnlineClient {
    func itunesSearch(_ keywords: String, limit: Int) async throws -> [OnlineSong] {
        // English genre names; titles and artists stay as the catalog has them.
        let url = Self.url("https://itunes.apple.com", "/search",
                           ["term": keywords, "entity": "song", "country": storefront, "lang": "en_us", "limit": String(limit)])
        guard let json = try await json(url) as? [String: Any] else { throw OnlineError.malformed }
        return (json["results"] as? [[String: Any]] ?? []).compactMap(Self.itunesSong)
    }

    static func itunesSong(_ s: [String: Any]) -> OnlineSong? {
        guard let id = (s["trackId"] as? NSNumber)?.int64Value, let title = s["trackName"] as? String else { return nil }
        // Releases are dated midnight local time in UTC (the day before, east of Greenwich); half a day later is the
        // local date's year almost everywhere.
        let released = (s["releaseDate"] as? String).flatMap { try? Date($0, strategy: .iso8601) }?.addingTimeInterval(12 * 3600)
        // Several artists come as one "A, B & C".
        let artists = (s["artistName"] as? String)?.split(separator: /,\s|\s&\s/).map(String.init) ?? []
        return OnlineSong(source: .itunes, id: String(id), title: title, artists: artists,
                          album: (s["collectionName"] as? String ?? "").replacing(/\s-\s(?:Single|EP)$/, with: ""),
                          coverURL: (s["artworkUrl100"] as? String).flatMap(URL.init(string:)),
                          duration: ((s["trackTimeMillis"] as? NSNumber)?.doubleValue ?? 0) / 1000,
                          trackNo: (s["trackNumber"] as? NSNumber)?.intValue.nonZero, discNo: (s["discNumber"] as? NSNumber)?.intValue.nonZero,
                          year: released.map { Calendar.utc.component(.year, from: $0) }, genre: s["primaryGenreName"] as? String)
    }
}

extension Calendar {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()
}
