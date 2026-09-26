import Foundation

/// ID3v2.3 / v2.4 reader. Frames are read one by one so APIC image bytes are skipped unless requested.
enum ID3Reader {
    struct Tag {
        var tags = RawTags()
        var cover: CoverRef?
        var coverData: Data?
    }

    private static let textFrames = [
        "TIT2": "TITLE", "TPE1": "ARTIST", "TPE2": "ALBUMARTIST", "TALB": "ALBUM", "TCOM": "COMPOSER",
        "TEXT": "LYRICIST", "TRCK": "TRACKNUMBER", "TPOS": "DISCNUMBER", "TYER": "DATE", "TDRC": "DATE", "TCON": "GENRE",
    ]
    private static let apicProbe = 4096
    private static let maxTextFrame = 1 << 20
    static let ncmKeyPrefix = "163 key(Don't modify):"

    /// Byte length of a leading ID3v2 tag including header and footer; 0 when absent.
    static func leadingTagLength(_ source: ByteSource) throws -> Int64 {
        guard source.size >= 10 else { return 0 }
        let header = [UInt8](try source.read(at: 0, count: 10))
        guard header.starts(with: Array("ID3".utf8)) else { return 0 }
        return 10 + Int64(syncsafe(header[6..<10])) + (header[5] & 0x10 != 0 ? 10 : 0)
    }

    /// nil when there is no ID3v2 tag or it is a version other than 2.3/2.4.
    static func read(_ source: ByteSource, includeCoverData: Bool = false) throws -> Tag? {
        guard source.size >= 10 else { return nil }
        let header = [UInt8](try source.read(at: 0, count: 10))
        guard header.starts(with: Array("ID3".utf8)), (3...4).contains(header[3]) else { return nil }
        let major = header[3], flags = header[5]
        let size = syncsafe(header[6..<10])
        guard 10 + Int64(size) <= source.size else { throw TagError.truncated }

        // v2.3 tag-level unsynchronisation shifts every offset: decode the whole tag in memory.
        if major == 3, flags & 0x80 != 0 {
            let body = removeUnsync([UInt8](try source.read(at: 10, count: size)))
            return try Parser(source: DataSource(Data(body)), major: major, start: 0, end: Int64(body.count),
                              extendedHeader: flags & 0x40 != 0, tagUnsync: false, offsetsValid: false,
                              includeCoverData: includeCoverData).parse()
        }
        // In v2.4 the tag-level flag means every frame is unsynchronised individually.
        return try Parser(source: source, major: major, start: 10, end: 10 + Int64(size),
                          extendedHeader: flags & 0x40 != 0, tagUnsync: major == 4 && flags & 0x80 != 0, offsetsValid: true,
                          includeCoverData: includeCoverData).parse()
    }

    private struct Parser {
        let source: ByteSource
        let major: UInt8
        let start: Int64
        let end: Int64
        let extendedHeader: Bool
        let tagUnsync: Bool
        let offsetsValid: Bool
        let includeCoverData: Bool

        func parse() throws -> Tag {
            var position = start
            if extendedHeader {
                let raw = [UInt8](try source.read(at: position, count: 4))
                position += major == 4 ? Int64(syncsafe(raw)) : 4 + Int64(raw.reduce(0) { $0 << 8 | Int($1) })
            }
            // iTunes writes v2.4 frame sizes as plain integers: pick the reading under which the frame chain is intact.
            let plainSizes = try major == 3
                || !chainIsIntact(from: position, plain: false) && chainIsIntact(from: position, plain: true)
            var tag = Tag()
            var covers: [(CoverRef, Data?)] = []
            while position + 10 <= end {
                let header = [UInt8](try source.read(at: position, count: 10))
                guard isFrameID(header[0..<4]) else { break }
                let size = frameSize(header, plain: plainSizes)
                let dataStart = position + 10
                guard dataStart + Int64(size) <= end else { break }
                // A malformed frame must not cost the file its other tags.
                try? handle(String(decoding: header[0..<4], as: UTF8.self), flags: header[9], at: dataStart, size: size,
                            into: &tag, covers: &covers)
                position = dataStart + Int64(size)
            }
            if let (cover, data) = covers.first(where: { $0.0.pictureType == 3 }) ?? covers.first {
                tag.cover = cover
                tag.coverData = data
            }
            return tag
        }

        private func frameSize(_ header: [UInt8], plain: Bool) -> Int {
            plain ? header[4..<8].reduce(0) { $0 << 8 | Int($1) } : syncsafe(header[4..<8])
        }

        private func chainIsIntact(from start: Int64, plain: Bool) throws -> Bool {
            var position = start
            while position + 10 <= end {
                let header = [UInt8](try source.read(at: position, count: 10))
                if header[0..<4].allSatisfy({ $0 == 0 }) { return true }
                guard isFrameID(header[0..<4]) else { return false }
                position += 10 + Int64(frameSize(header, plain: plain))
            }
            return position <= end
        }

        private func handle(_ id: String, flags: UInt8, at dataStart: Int64, size: Int,
                            into tag: inout Tag, covers: inout [(CoverRef, Data?)]) throws {
            let isText = id.hasPrefix("T") || id == "USLT" || id == "COMM"
            guard isText || id == "APIC", size > 0 else { return }
            var skip = 0
            var unsynced = false
            if major == 4 {
                if flags & 0x0C != 0 { return }             // compressed or encrypted
                if flags & 0x40 != 0 { skip += 1 }          // grouping identity
                if flags & 0x01 != 0 { skip += 4 }          // data length indicator
                unsynced = flags & 0x02 != 0 || tagUnsync
            } else {
                if flags & 0xC0 != 0 { return }             // compressed or encrypted
                if flags & 0x20 != 0 { skip += 1 }          // grouping identity
            }
            let available = size - skip
            guard available > 0 else { return }

            if id == "APIC" {
                let wantAll = includeCoverData || unsynced
                // The probe covers the header unless the description is unusually long; then read the whole frame.
                for count in wantAll ? [available] : [min(available, apicProbe), available] {
                    var bytes = [UInt8](try source.read(at: dataStart + Int64(skip), count: count))
                    if unsynced { bytes = removeUnsync(bytes) }
                    var r = ByteReader(bytes)
                    let encoding = try r.u8()
                    let mime = String(decoding: try r.terminated(width: 1), as: UTF8.self)
                    let type = Int(try r.u8())
                    _ = try r.terminated(width: encoding == 1 || encoding == 2 ? 2 : 1)
                    if r.remaining == 0, count < available { continue }
                    let exact = offsetsValid && !unsynced
                    covers.append((CoverRef(offset: exact ? dataStart + Int64(skip + r.position) : nil,
                                            length: wantAll ? r.remaining : available - r.position, mime: mime, pictureType: type),
                                   includeCoverData ? Data(r.rest()) : nil))
                    return
                }
                return
            }

            guard available <= maxTextFrame else { return }
            var bytes = [UInt8](try source.read(at: dataStart + Int64(skip), count: available))
            if unsynced { bytes = removeUnsync(bytes) }
            var r = ByteReader(bytes)
            let encoding = try r.u8()
            let width = encoding == 1 || encoding == 2 ? 2 : 1
            switch id {
            case "USLT":
                try r.skip(3)
                _ = try r.terminated(width: width)
                tag.tags.add("LYRICS", decode(r.rest(), encoding: encoding))
            case "COMM":
                try r.skip(3)
                _ = try r.terminated(width: width)
                let text = decode(r.rest(), encoding: encoding)
                if text.hasPrefix(ncmKeyPrefix) { tag.tags.add("NCM_KEY", text) }
            case "TXXX":
                let name = decode(try r.terminated(width: width), encoding: encoding).uppercased()
                if name.hasPrefix("REPLAYGAIN_") { tag.tags.add(name, decode(r.rest(), encoding: encoding)) }
            default:
                guard let key = textFrames[id] else { return }
                for value in values(r.rest(), encoding: encoding) {
                    tag.tags.add(key, key == "GENRE" ? ID3Genres.resolve(value) : value)
                }
            }
        }
    }

    static func isFrameID(_ id: ArraySlice<UInt8>) -> Bool {
        id.count == 4 && id.allSatisfy { (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) }
    }

    static func removeUnsync(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var previous: UInt8 = 0
        for byte in bytes {
            if !(previous == 0xFF && byte == 0x00) { out.append(byte) }
            previous = byte
        }
        return out
    }

    /// NUL-separated values (v2.4 multi-value text frames).
    static func values(_ bytes: [UInt8], encoding: UInt8) -> [String] {
        var r = ByteReader(bytes)
        var result: [String] = []
        while r.remaining > 0 {
            result.append(decode((try? r.terminated(width: encoding == 1 || encoding == 2 ? 2 : 1)) ?? [], encoding: encoding))
        }
        return result
    }

    static func decode(_ bytes: [UInt8], encoding: UInt8) -> String {
        switch encoding {
        case 0:
            return String(bytes.map { Character(Unicode.Scalar($0)) })
        case 1, 2:
            var body = bytes[...]
            var bigEndian = encoding == 2
            if body.starts(with: [0xFF, 0xFE]) { bigEndian = false; body = body.dropFirst(2) }
            else if body.starts(with: [0xFE, 0xFF]) { bigEndian = true; body = body.dropFirst(2) }
            let units = stride(from: body.startIndex, to: body.endIndex - 1, by: 2).map { i in
                bigEndian ? UInt16(body[i]) << 8 | UInt16(body[i + 1]) : UInt16(body[i + 1]) << 8 | UInt16(body[i])
            }
            return String(decoding: units, as: UTF16.self)
        default:
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
