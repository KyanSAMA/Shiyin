import Foundation

/// A NetEase Cloud Music download (.ncm): the original FLAC or MP3, byte-XORed with a keystream derived from an
/// AES-wrapped RC4 key, after the song's metadata (JSON) and cover. Layout, integers little-endian:
/// "CTENFDAM" · 2 bytes · key length + key (^0x64, AES core key, "neteasecloudmusic"…) · metadata length + metadata
/// (^0x63, "163 key(Don't modify):" + base64 of the AES meta-key'd "music:{json}") · CRC32 · 1 byte · cover frame
/// length · image length + image · the rest of the cover frame · audio.
public struct NCMFile: Sendable {
    public struct Meta: Sendable, Equatable {
        public let musicId: Int64?
        public let title: String
        public let artists: [String]
        public let album: String
        public let albumPic: URL?
        public let format: String?
        /// The metadata as the "163 key(Don't modify):…" comment NetEase writes into its MP3s (kept in the new file).
        public let key163: String
    }

    public let url: URL
    public let meta: Meta?
    public let cover: Data?
    let audioOffset: Int64
    private let keystream: [UInt8]

    static let magic = Data("CTENFDAM".utf8)
    private static let chunk = 1 << 20

    public init(_ url: URL) throws {
        let source = try FileSource(url: url)
        guard source.size >= 10, try source.read(at: 0, count: 8) == Self.magic else { throw TagWriteError.unsupported("不是 NCM 文件") }
        var position: Int64 = 10
        // Real keys are ~128 bytes and metadata a few KB: a damaged length mustn't allocate the file.
        func block(max: Int64) throws -> Data {
            let length = Int64(try source.read(at: position, count: 4).reversed().reduce(0) { $0 << 8 | Int($1) })
            guard length <= max, position + 4 + length <= source.size else { throw TagError.truncated }
            defer { position += 4 + length }
            return try source.read(at: position + 4, count: Int(length))
        }
        let prefix = Data("neteasecloudmusic".utf8)
        guard let key = NCMKey.crypt(Data(try block(max: 4096).map { $0 ^ 0x64 }), key: NCMKey.coreKey, encrypt: false), key.starts(with: prefix),
              key.count > prefix.count else { throw TagWriteError.unsupported("NCM 密钥无法解开") }
        keystream = Self.keystream(Array(key.dropFirst(prefix.count)))
        let metadata = Data(try block(max: 1 << 20).map { $0 ^ 0x63 })
        meta = Self.meta(metadata)
        position += 5   // CRC32, then a byte
        let frame = Int64(try source.read(at: position, count: 4).reversed().reduce(0) { $0 << 8 | Int($1) })
        let image = Int64(try source.read(at: position + 4, count: 4).reversed().reduce(0) { $0 << 8 | Int($1) })
        guard image <= frame, position + 8 + frame <= source.size else { throw TagError.truncated }
        cover = image > 0 ? try source.read(at: position + 8, count: Int(image)) : nil
        (self.url, audioOffset) = (url, position + 8 + frame)
    }

    /// RC4's key schedule; the stream byte for position i is taken without RC4's swaps: S[(S[i] + S[(i + S[i]) & 0xff]) & 0xff].
    private static func keystream(_ key: [UInt8]) -> [UInt8] {
        var box = [UInt8](0...255), j = 0
        for i in 0..<256 {
            j = (j + Int(box[i]) + Int(key[i % key.count])) & 0xff
            box.swapAt(i, j)
        }
        return (0..<256).map { i in box[(Int(box[i]) + Int(box[(i + Int(box[i])) & 0xff])) & 0xff] }
    }

    /// Lenient: "music:" or "dj:" (a radio programme, its song under `mainMusic`), ids as strings or numbers, artists as
    /// [[name, id]] or names.
    private static func meta(_ data: Data) -> Meta? {
        let prefix = "163 key(Don't modify):"
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix(prefix),
              let encrypted = Data(base64Encoded: String(text.dropFirst(prefix.count))),
              let plain = NCMKey.crypt(encrypted, key: NCMKey.metaKey, encrypt: false),
              let colon = plain.firstIndex(of: UInt8(ascii: ":")),
              var json = try? JSONSerialization.jsonObject(with: plain[(colon + 1)...]) as? [String: Any] else { return nil }
        if plain.starts(with: Data("dj:".utf8)), let song = json["mainMusic"] as? [String: Any] {
            json = song.merging(json.filter { $0.key == "programName" }) { $1 }
        }
        func number(_ key: String) -> Int64? { (json[key] as? NSNumber)?.int64Value ?? (json[key] as? String).flatMap { Int64($0) } }
        let artists = (json["artist"] as? [Any] ?? []).compactMap { ($0 as? [Any])?.first as? String ?? $0 as? String }
        return Meta(musicId: number("musicId"), title: json["programName"] as? String ?? json["musicName"] as? String ?? "",
                    artists: artists, album: json["album"] as? String ?? "",
                    albumPic: (json["albumPic"] as? String).flatMap(URL.init(string:)), format: json["format"] as? String, key163: text)
    }

    /// "flac" or "mp3": a FLAC marker at the start; else the metadata's word; else an MP3 start (an ID3 tag, which a FLAC
    /// may carry too, or a frame sync).
    public func audioFormat() throws -> String {
        let head = xor(try FileSource(url: url).read(at: audioOffset, count: 4), from: 0)
        if head.starts(with: Data("fLaC".utf8)) { return "flac" }
        if let format = meta?.format, ["flac", "mp3"].contains(format) { return format }
        if head.starts(with: Data("ID3".utf8)) || head.count > 1 && head[head.startIndex] == 0xFF && head[head.startIndex + 1] & 0xE0 == 0xE0 {
            return "mp3"
        }
        throw TagWriteError.unsupported("无法判断 NCM 里的音频格式")
    }

    /// Writes the original audio to `out`, streamed.
    public func decrypt(to out: URL) throws {
        guard FileManager.default.createFile(atPath: out.path, contents: nil) else { throw TagWriteError.unsupported("无法创建文件") }
        let input = try FileHandle(forReadingFrom: url), output = try FileHandle(forWritingTo: out)
        defer {
            try? input.close()
            try? output.close()
        }
        try input.seek(toOffset: UInt64(audioOffset))
        var offset = 0
        while let data = try input.read(upToCount: Self.chunk), !data.isEmpty {
            try output.write(contentsOf: xor(data, from: offset))
            offset += data.count
        }
    }

    /// Audio byte k (counted from the start of the audio) is XORed with keystream[(k + 1) & 0xff].
    private func xor(_ data: Data, from offset: Int) -> Data {
        var bytes = [UInt8](data)
        for i in bytes.indices { bytes[i] ^= keystream[(offset + i + 1) & 0xff] }
        return Data(bytes)
    }

    /// NetEase's sidecar .lrc as plain LRC: its JSON lines ({"t": ms, "c": [{"tx": text}…]}, the credits) become
    /// timestamped lines; LRC lines stay.
    public static func lyrics(fromSidecar text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { line in
            guard line.hasPrefix("{"), let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let ms = (json["t"] as? NSNumber)?.intValue else { return String(line) }
            let words = (json["c"] as? [[String: Any]] ?? []).compactMap { $0["tx"] as? String }.joined()
            return String(format: "[%02d:%02d.%02d]", ms / 60000, ms / 1000 % 60, ms % 1000 / 10) + words
        }.joined(separator: "\n")
    }

    /// An .ncm around `audio` with this metadata (e.g. `music:{json}`; nil for none) and cover — for tests and self-tests.
    public static func encode(audio: Data, meta metadata: String?, cover: Data?, key: Data = Data("123456789012345678901234567890".utf8)) -> Data {
        func le32(_ value: Int) -> Data { Data([0, 8, 16, 24].map { UInt8(value >> $0 & 0xFF) }) }
        let wrappedKey = NCMKey.crypt(Data("neteasecloudmusic".utf8) + key, key: NCMKey.coreKey, encrypt: true)!.map { $0 ^ 0x64 }
        let meta = metadata.map { Data(("163 key(Don't modify):" + NCMKey.crypt(Data($0.utf8), key: NCMKey.metaKey, encrypt: true)!
            .base64EncodedString()).utf8).map { $0 ^ 0x63 } } ?? []
        let stream = keystream([UInt8](key))
        let image = cover ?? Data()
        var out = magic + Data([1, 0x6D]) + le32(wrappedKey.count) + Data(wrappedKey) + le32(meta.count) + Data(meta)
        out += Data(count: 4) + Data([1]) + le32(image.count) + le32(image.count) + image
        out += Data(audio.enumerated().map { $0.element ^ stream[($0.offset + 1) & 0xff] })
        return out
    }
}
