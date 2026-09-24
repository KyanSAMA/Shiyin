import Foundation

enum FLACReader {
    private static let maxBlocks = 128
    private static let pictureHeaderProbe = 4096

    static func read(_ source: ByteSource) throws -> RawTrack {
        let start = try ID3Reader.leadingTagLength(source)
        guard try source.read(at: start, count: 4) == Data("fLaC".utf8) else { throw TagError.invalid("missing fLaC marker") }

        var properties: AudioProperties?
        var tags = RawTags()
        var covers: [CoverRef] = []
        var position = start + 4
        for _ in 0..<maxBlocks {
            var header = ByteReader(try source.read(at: position, count: 4))
            let flags = try header.u8()
            let length = try header.uintBE(3)
            let body = position + 4
            guard body + Int64(length) <= source.size else { throw TagError.truncated }
            switch flags & 0x7F {
            case 0: properties = try streamInfo(try source.read(at: body, count: length))
            // A malformed comment or picture block must not cost the file its other metadata.
            case 4: try? readComments(try source.read(at: body, count: length), into: &tags)
            case 6: if let cover = try? picture(source, at: body, length: length) { covers.append(cover) }
            default: break
            }
            position = body + Int64(length)
            if flags & 0x80 != 0 { break }
        }
        guard let properties else { throw TagError.invalid("missing STREAMINFO") }
        return RawTrack(properties: properties, tags: tags, cover: covers.first { $0.pictureType == 3 } ?? covers.first)
    }

    private static func streamInfo(_ data: Data) throws -> AudioProperties {
        guard data.count >= 18 else { throw TagError.truncated }
        let b = [UInt8](data)
        let rate = Int(b[10]) << 12 | Int(b[11]) << 4 | Int(b[12]) >> 4
        let channels = Int(b[12] >> 1 & 0x07) + 1
        let bitDepth = Int((b[12] & 0x01) << 4 | b[13] >> 4) + 1
        let total = Int64(b[13] & 0x0F) << 32 | Int64(b[14]) << 24 | Int64(b[15]) << 16 | Int64(b[16]) << 8 | Int64(b[17])
        guard rate > 0 else { throw TagError.invalid("zero sample rate") }
        return AudioProperties(format: "flac", codec: "flac", sampleRate: rate, bitDepth: bitDepth, channels: channels,
                               frameCount: total, duration: Double(total) / Double(rate))
    }

    private static func readComments(_ data: Data, into tags: inout RawTags) throws {
        var r = ByteReader(data)
        try r.skip(try r.uintLE(4))
        let count = try r.uintLE(4)
        for _ in 0..<count {
            let entry = String(decoding: try r.take(try r.uintLE(4)), as: UTF8.self)
            guard let eq = entry.firstIndex(of: "=") else { continue }
            tags.add(String(entry[..<eq]), String(entry[entry.index(after: eq)...]))
        }
    }

    /// Parses the PICTURE header only; the image bytes stay on disk.
    private static func picture(_ source: ByteSource, at body: Int64, length: Int) throws -> CoverRef {
        func parse(_ data: Data) throws -> CoverRef {
            var r = ByteReader(data)
            let type = try r.uintBE(4)
            let mime = String(decoding: try r.take(try r.uintBE(4)), as: UTF8.self)
            try r.skip(try r.uintBE(4))
            try r.skip(16)
            let dataLength = try r.uintBE(4)
            guard r.position + dataLength == length else { throw TagError.invalid("PICTURE length mismatch") }
            return CoverRef(offset: body + Int64(r.position), length: dataLength, mime: mime, pictureType: type)
        }
        // The header nearly always fits the probe; only an unusually long description needs the whole block.
        if let cover = try? parse(try source.read(at: body, count: min(length, pictureHeaderProbe))) { return cover }
        return try parse(try source.read(at: body, count: length))
    }
}
