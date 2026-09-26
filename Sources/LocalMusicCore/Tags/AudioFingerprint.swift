import Foundation

/// Audio-content identity that survives retagging, moves and renames, so enrichment and edits keyed by it stay with the
/// recording: FLAC's STREAMINFO MD5 when the encoder wrote one, else a hash of the audio payload's length and two
/// samples of it (the start, and the middle: silent intros encode to the same bytes across tracks). The payload skips
/// tags: FLAC metadata blocks, ID3v2 and trailing ID3v1 / APEv2 / Lyrics3v2, RIFF chunks other than `data`, MP4 atoms
/// other than `mdat`. A malformed container falls back to the whole file rather than failing.
enum AudioFingerprint {
    private static let sample = 16 << 10
    private static let maxBlocks = 128

    static func compute(_ source: ByteSource, format: String) throws -> String {
        if format == "flac", let md5 = try? streamInfoMD5(source) { return "flac:" + md5 }
        var payload = ((try? self.payload(source, format: format)) ?? nil) ?? 0..<source.size
        if payload.isEmpty { payload = 0..<source.size }
        let count = Int(min(Int64(sample), Int64(payload.count)))
        var data = Data("\(payload.count):".utf8)
        data.append(try source.read(at: payload.lowerBound, count: count))
        data.append(try source.read(at: payload.lowerBound + (Int64(payload.count) - Int64(count)) / 2, count: count))
        return "sha:" + TagReader.sha256(data).prefix(40)
    }

    /// nil when the encoder left it zero.
    private static func streamInfoMD5(_ source: ByteSource) throws -> String? {
        let md5 = try source.read(at: ID3Reader.leadingTagLength(source) + 8 + 18, count: 16)   // STREAMINFO is the first block
        return md5.contains { $0 != 0 } ? md5.map { String(format: "%02x", $0) }.joined() : nil
    }

    private static func payload(_ source: ByteSource, format: String) throws -> Range<Int64>? {
        switch format {
        case "flac":
            var position = try ID3Reader.leadingTagLength(source) + 4
            for _ in 0..<maxBlocks {
                let header = [UInt8](try source.read(at: position, count: 4))
                position += 4 + (Int64(header[1]) << 16 | Int64(header[2]) << 8 | Int64(header[3]))
                if header[0] & 0x80 != 0 { break }
            }
            return position <= source.size ? position..<source.size : nil
        case "mp3":
            let start = try ID3Reader.leadingTagLength(source), end = try trailingTagsStart(source)
            return start <= end ? start..<end : nil
        case "wav": return try chunk("data", in: source, riff: true)
        case "m4a": return try chunk("mdat", in: source, riff: false)
        default: return nil
        }
    }

    /// Where ID3v1, APEv2 and Lyrics3v2 tags at the end of an MP3 begin, in whatever order they were appended.
    static func trailingTagsStart(_ source: ByteSource) throws -> Int64 {
        var end = source.size
        while true {
            if end >= 128, try source.read(at: end - 128, count: 3) == Data("TAG".utf8) {
                end -= 128
            } else if end >= 32, case let footer = [UInt8](try source.read(at: end - 32, count: 32)), footer.starts(with: Array("APETAGEX".utf8)) {
                func le32(_ at: Int) -> Int64 { (0..<4).reduce(0) { $0 | Int64(footer[at + $1]) << (8 * $1) } }
                let size = le32(12) + (le32(20) & 0x8000_0000 != 0 ? 32 : 0)   // footer included; header if flagged
                guard size <= end else { return end }
                end -= size
            } else if end >= 15, case let tail = try source.read(at: end - 15, count: 15), tail.suffix(9) == Data("LYRICS200".utf8),
                      let size = Int64(String(decoding: tail.prefix(6), as: UTF8.self)), size + 15 <= end {
                end -= size + 15
            } else {
                return end
            }
        }
    }

    /// The body of the first top-level RIFF chunk (after the 12-byte header; type, then little-endian size, padded to
    /// even) or MP4 atom (big-endian size including the header, then type; 1 means a 64-bit size follows, 0 "to the end").
    private static func chunk(_ type: String, in source: ByteSource, riff: Bool) throws -> Range<Int64>? {
        var position: Int64 = riff ? 12 : 0
        while position + 8 <= source.size {
            let header = [UInt8](try source.read(at: position, count: 8))
            let name = String(decoding: riff ? header[0..<4] : header[4..<8], as: UTF8.self)
            let raw = (riff ? header[4..<8].reversed() : Array(header[0..<4])).reduce(Int64(0)) { $0 << 8 | Int64($1) }
            var body = position + 8
            var length = riff ? raw : raw - 8
            if !riff, raw == 1 {
                length = [UInt8](try source.read(at: body, count: 8)).reduce(Int64(0)) { $0 &<< 8 | Int64($1) } &- 16
                body += 8
            } else if !riff, raw == 0 {
                length = source.size - body
            }
            guard length >= 0, length <= source.size - body else { return name == type ? body..<source.size : nil }
            if name == type { return body..<body + length }
            position = body + length + (riff ? length & 1 : 0)
        }
        return nil
    }
}
