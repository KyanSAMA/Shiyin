import Foundation

/// An MP3's leading ID3v2.3 / v2.4 tag, edited and serialized back in the same version (a file without one gets v2.3).
/// Frames other than the replaced ones are copied verbatim with their flags; the output has no extended header, no
/// tag-level unsynchronisation, syncsafe v2.4 frame sizes, and rebuilt padding.
struct ID3TagFile {
    struct Frame {
        var id: String
        var flags: [UInt8]
        var body: Data
    }

    let major: UInt8
    /// The whole old tag (header, frames, padding, footer); 0 when there was none.
    let length: Int64
    private(set) var frames: [Frame]
    static let growPadding = 4 << 10

    init(_ source: ByteSource) throws {
        guard source.size >= 10, case let header = [UInt8](try source.read(at: 0, count: 10)), header.starts(with: Array("ID3".utf8)) else {
            (major, length, frames) = (3, 0, [])
            return
        }
        guard (3...4).contains(header[3]) else { throw TagWriteError.unsupported("不支持 ID3v2.\(header[3]) 标签") }
        major = header[3]
        let flags = header[5], size = syncsafe(header[6..<10])
        guard 10 + Int64(size) <= source.size else { throw TagError.truncated }
        length = try ID3Reader.leadingTagLength(source)
        var body = [UInt8](try source.read(at: 10, count: size))
        if major == 3, flags & 0x80 != 0 { body = ID3Reader.removeUnsync(body) }
        var position = 0
        if flags & 0x40 != 0, body.count >= 4 {
            position = major == 4 ? syncsafe(body[0..<4]) : 4 + body[0..<4].reduce(0) { $0 << 8 | Int($1) }
        }
        let plain = major == 3 || !Self.intact(body, from: position, plain: false) && Self.intact(body, from: position, plain: true)
        var frames: [Frame] = []
        while position + 10 <= body.count, ID3Reader.isFrameID(body[position..<position + 4]) {
            let raw = body[position + 4..<position + 8]
            let frameSize = plain ? raw.reduce(0) { $0 << 8 | Int($1) } : syncsafe(raw)
            guard position + 10 + frameSize <= body.count else { break }
            var frameFlags = Array(body[position + 8..<position + 10])
            // A v2.4 tag-level unsync flag means every frame is unsynchronised; say so per frame, as the header won't.
            if major == 4, flags & 0x80 != 0 { frameFlags[1] |= 0x02 }
            frames.append(Frame(id: String(decoding: body[position..<position + 4], as: UTF8.self), flags: frameFlags,
                                body: Data(body[position + 10..<position + 10 + frameSize])))
            position += 10 + frameSize
        }
        // What isn't a frame must be padding; anything else would be lost in the rewrite.
        guard body[min(position, body.count)...].allSatisfy({ $0 == 0 }) else { throw TagWriteError.unsupported("ID3 标签里有无法解析的内容") }
        self.frames = frames
    }

    private static func intact(_ body: [UInt8], from start: Int, plain: Bool) -> Bool {
        var position = start
        while position + 10 <= body.count {
            if body[position..<position + 4].allSatisfy({ $0 == 0 }) { return true }
            guard ID3Reader.isFrameID(body[position..<position + 4]) else { return false }
            let raw = body[position + 4..<position + 8]
            position += 10 + (plain ? raw.reduce(0) { $0 << 8 | Int($1) } : syncsafe(raw))
        }
        return position <= body.count
    }

    mutating func apply(_ edit: TagEdit) {
        if let title = edit.title { set(["TIT2"], text("TIT2", title)) }
        if let artists = edit.artists { set(["TPE1"], text("TPE1", artists.joined(separator: "/"))) }
        if let album = edit.album { set(["TALB"], text("TALB", album)) }
        if let artist = edit.albumArtist { set(["TPE2"], text("TPE2", artist)) }
        if let number = edit.trackNo { set(["TRCK"], text("TRCK", keepingTotal("TRCK", number))) }
        if let number = edit.discNo { set(["TPOS"], text("TPOS", keepingTotal("TPOS", number))) }
        if let year = edit.year { set(["TYER", "TDRC"], text(major == 4 ? "TDRC" : "TYER", String(year))) }
        if let genre = edit.genre { set(["TCON"], text("TCON", genre)) }
        if let composers = edit.composers { set(["TCOM"], text("TCOM", composers.joined(separator: "/"))) }
        if let lyrics = edit.lyrics {
            let language = frames.lazy.filter { $0.id == "USLT" }.compactMap(content).first { $0.count >= 4 }.map { Data($0[1..<4]) }
            var body = Data([encoding(lyrics)])
            body.append(language ?? Data("und".utf8))
            body.append(encoded("", terminated: true, encoding: encoding(lyrics)))
            body.append(encoded(lyrics, terminated: false, encoding: encoding(lyrics)))
            set(["USLT"], Frame(id: "USLT", flags: [0, 0], body: body))
        }
        if let cover = edit.cover {
            var body = Data([0])
            body.append(contentsOf: Array(cover.mime.utf8) + [0, 3, 0])
            body.append(cover.data)
            let fronts = frames.indices.filter { frames[$0].id == "APIC" && [0, 3].contains(pictureType(frames[$0])) }
            let at = fronts.first ?? frames.count
            for index in fronts.reversed() { frames.remove(at: index) }
            frames.insert(Frame(id: "APIC", flags: [0, 0], body: body), at: min(at, frames.count))
        }
    }

    /// The new tag; it keeps the old length when it fits (padding filled with zeros), else leaves `growPadding`.
    func serialized() -> Data {
        var body = Data()
        for frame in frames {
            body.append(contentsOf: Array(frame.id.utf8))
            body.append(contentsOf: major == 4 ? Self.encodeSyncsafe(frame.body.count) : [24, 16, 8, 0].map { UInt8(frame.body.count >> $0 & 0xFF) })
            body.append(contentsOf: frame.flags)
            body.append(frame.body)
        }
        let size = Int64(10 + body.count) <= length ? Int(length) - 10 : body.count + Self.growPadding
        body.append(Data(count: size - body.count))
        var out = Data(Array("ID3".utf8) + [major, 0, 0])
        out.append(contentsOf: Self.encodeSyncsafe(size))
        out.append(body)
        return out
    }

    /// Replaces every frame with these ids by `frame`, where the first of them was.
    private mutating func set(_ ids: [String], _ frame: Frame) {
        let at = frames.firstIndex { ids.contains($0.id) } ?? frames.count
        frames.removeAll { ids.contains($0.id) }
        frames.insert(frame, at: min(at, frames.count))
    }

    private func text(_ id: String, _ value: String) -> Frame {
        var body = Data([encoding(value)])
        body.append(encoded(value, terminated: false, encoding: encoding(value)))
        return Frame(id: id, flags: [0, 0], body: body)
    }

    /// v2.4: UTF-8. v2.3: Latin-1 for ASCII, else UTF-16 with a BOM.
    private func encoding(_ text: String) -> UInt8 { major == 4 ? 3 : text.allSatisfy(\.isASCII) ? 0 : 1 }

    private func encoded(_ text: String, terminated: Bool, encoding: UInt8) -> Data {
        switch encoding {
        case 1:
            var out = Data([0xFF, 0xFE])
            for unit in text.utf16 { out.append(contentsOf: [UInt8(unit & 0xFF), UInt8(unit >> 8)]) }
            if terminated { out.append(contentsOf: [0, 0]) }
            return out
        default:
            return Data(text.utf8) + (terminated ? [0] : [])
        }
    }

    private func keepingTotal(_ id: String, _ number: Int) -> String {
        guard let bytes = frames.first(where: { $0.id == id }).flatMap(content), let encoding = bytes.first,
              case let old = ID3Reader.decode(Array(bytes.dropFirst()), encoding: encoding).trimmingCharacters(in: .controlCharacters),
              let slash = old.firstIndex(of: "/") else { return String(number) }
        return "\(number)" + old[slash...]
    }

    /// A frame's content past its format flags' extra bytes, unsynchronisation undone; nil when compressed or encrypted.
    private func content(_ frame: Frame) -> [UInt8]? {
        let format = frame.flags[1]
        if major == 4 ? format & 0x0C != 0 : format & 0xC0 != 0 { return nil }
        let prefix = major == 4 ? (format & 0x40 != 0 ? 1 : 0) + (format & 0x01 != 0 ? 4 : 0) : format & 0x20 != 0 ? 1 : 0
        let bytes = [UInt8](frame.body.dropFirst(prefix))
        return major == 4 && format & 0x02 != 0 ? ID3Reader.removeUnsync(bytes) : bytes
    }

    /// nil for a frame it can't read, which is kept.
    private func pictureType(_ frame: Frame) -> Int? {
        guard let bytes = content(frame) else { return nil }
        var r = ByteReader(bytes)
        guard (try? r.u8()) != nil, (try? r.terminated(width: 1)) != nil, let type = try? r.u8() else { return nil }
        return Int(type)
    }

    private static func encodeSyncsafe(_ value: Int) -> [UInt8] { [21, 14, 7, 0].map { UInt8(value >> $0 & 0x7F) } }
}
