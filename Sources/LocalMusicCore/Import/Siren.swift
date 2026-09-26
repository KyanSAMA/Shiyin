import Foundation

/// 塞壬唱片 (Monster Siren Records, `monster-siren.hypergryph.com`): Arknights' label, whose site streams its whole
/// catalogue — mostly WAV, some MP3.
public enum Siren {
    public static let albumArtist = "塞壬唱片-MSR"

    public struct Album: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let coverURL: URL?
        public let artists: [String]
    }

    public struct Song: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let albumID: String
        public let artists: [String]
    }

    /// An album's page: its songs in order.
    public struct AlbumDetail: Sendable, Equatable {
        public let album: Album
        public let intro: String
        public let songs: [Song]
    }

    /// Where a song's audio and lyrics are; the audio URL is signed and expires, so it's asked for right before a download.
    public struct Source: Sendable, Equatable {
        public let audio: URL
        public let lyrics: URL?
        public let artists: [String]

        /// "wav" or "mp3", from the URL.
        public var format: String { audio.pathExtension.lowercased() }
    }

    static let base = "https://monster-siren.hypergryph.com"
}

extension OnlineClient {
    public func sirenAlbums() async throws -> [Siren.Album] {
        guard let list = try await siren("/api/albums") as? [Any] else { throw OnlineError.malformed }
        return list.compactMap { Self.sirenAlbum($0 as? [String: Any]) }
    }

    public func sirenSongs() async throws -> [Siren.Song] {
        let data = try await siren("/api/songs")
        guard let list = (data as? [String: Any])?["list"] as? [[String: Any]] else {
            throw OnlineError.malformed
        }
        return list.compactMap { Self.sirenSong($0, album: nil) }
    }

    public func sirenAlbum(_ id: String) async throws -> Siren.AlbumDetail {
        let json = try await siren("/api/album/\(id)/detail")
        guard let data = json as? [String: Any], let album = Self.sirenAlbum(data) else { throw OnlineError.malformed }
        let songs = (data["songs"] as? [[String: Any]] ?? []).compactMap { Self.sirenSong($0, album: album.id) }
        return Siren.AlbumDetail(album: album, intro: (data["intro"] as? String ?? "").trimmed, songs: songs)
    }

    public func sirenSource(_ id: String) async throws -> Siren.Source {
        let json = try await siren("/api/song/\(id)")
        guard let data = json as? [String: Any], let audio = (data["sourceUrl"] as? String).flatMap(URL.init(string:)) else { throw OnlineError.malformed }
        return Siren.Source(audio: audio, lyrics: (data["lyricUrl"] as? String).flatMap(URL.init(string:)),
                            artists: (data["artists"] as? [String] ?? []).map(\.trimmed).filter { !$0.isEmpty })
    }

    public func sirenCover(_ album: Siren.Album) async throws -> Data? {
        guard let url = album.coverURL else { return nil }
        return try await fetch(url)
    }

    /// A song's lyrics file (LRC), nil when it has none.
    public func sirenLyrics(_ source: Siren.Source) async throws -> String? {
        guard let url = source.lyrics else { return nil }
        let text = String(decoding: try await fetch(url), as: UTF8.self)
        // Blank lines between the lines.
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The `data` of `{code: 0, data: …}`.
    private func siren(_ path: String) async throws -> Any {
        let json = try await json(Self.url(Siren.base, path, [:]))
        guard let json = json as? [String: Any], (json["code"] as? NSNumber)?.intValue == 0, let data = json["data"] else {
            throw OnlineError.malformed
        }
        return data
    }

    static func sirenAlbum(_ a: [String: Any]?) -> Siren.Album? {
        guard let a, let id = a["cid"] as? String, let name = (a["name"] as? String)?.trimmed else { return nil }
        return Siren.Album(id: id, name: name, coverURL: (a["coverUrl"] as? String).flatMap(URL.init(string:)),
                           artists: (a["artistes"] as? [String] ?? []).map(\.trimmed).filter { !$0.isEmpty })
    }

    static func sirenSong(_ s: [String: Any], album: String?) -> Siren.Song? {
        guard let id = s["cid"] as? String, let name = (s["name"] as? String)?.trimmed,
              let album = album ?? s["albumCid"] as? String else { return nil }
        return Siren.Song(id: id, name: name, albumID: album, artists: (s["artists"] as? [String] ?? s["artistes"] as? [String] ?? []).map(\.trimmed).filter { !$0.isEmpty })
    }
}

extension Siren {
    /// Tags for a downloaded song: its name, artists, the album (by 塞壬唱片-MSR) and its place in it, the album cover,
    /// the site's lyrics.
    public static func edit(_ song: Song, in detail: AlbumDetail, artists: [String], lyrics: String?, cover: Data?) -> TagEdit {
        var edit = TagEdit()
        edit.replaceAll = true   // everything comes from the site
        edit.title = song.name
        edit.artists = artists.isEmpty ? song.artists : artists
        edit.album = detail.album.name
        edit.albumArtist = albumArtist
        edit.trackNo = detail.songs.firstIndex { $0.id == song.id }.map { $0 + 1 }
        edit.lyrics = lyrics
        edit.cover = cover.flatMap { try? TagEdit.Cover($0) }
        return edit
    }

    /// The library songs a Siren song already is, by title: ignoring case, width, traditional / simplified script,
    /// spaces and punctuation, but not bracketed notes (「… (Instrumental)」 is another recording).
    public struct Owned: Sendable {
        private let byTitle: [String: [TrackRow]]

        public init(_ rows: [TrackRow]) {
            byTitle = Dictionary(grouping: rows) { Self.key($0.title) }
        }

        public func rows(_ song: Song) -> [TrackRow] { byTitle[Self.key(song.name)] ?? [] }

        static func key(_ title: String) -> String {
            let folded = (title.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? title)
                .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
            let kept = String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
            // A title of symbols only ("……", "♪") keeps them.
            return kept.isEmpty ? String(folded.filter { !$0.isWhitespace }) : kept
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension Siren {
    /// Downloads a song as a new file in `folder` (see `Importer`): its source asked for afresh (the audio URL expires),
    /// the audio streamed to a staging file, a WAV converted to FLAC, then tagged (`edit`) and placed under the first
    /// free name.
    @concurrent public static func download(_ song: Song, in detail: AlbumDetail, cover: Data?, client: OnlineClient, to folder: URL,
                                            naming: ImportNaming, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        let source = try await client.sirenSource(song.id)
        guard ["wav", "mp3"].contains(source.format) else { throw TagWriteError.unsupported("不支持的音频格式：\(source.format)") }
        let raw = Importer.staging(in: folder, ext: source.format)
        defer { try? FileManager.default.removeItem(at: raw) }
        try await client.download(source.audio, to: raw, progress: progress)
        let lyrics = (try? await client.sirenLyrics(source)) ?? nil
        try Task.checkCancellation()
        var staged = raw
        if source.format == "wav" {
            staged = Importer.staging(in: folder, ext: "flac")
            try FLACConvert.convert(raw, to: staged)
        }
        defer { try? FileManager.default.removeItem(at: staged) }
        try Task.checkCancellation()
        let edit = edit(song, in: detail, artists: source.artists, lyrics: lyrics, cover: cover)
        let names = naming.candidates(title: song.name, artists: edit.artists ?? [], album: detail.album.name, trackNo: edit.trackNo,
                                      ext: staged.pathExtension)
        return try await Importer.place(staged, edit: edit, in: folder, candidates: names)
    }
}
