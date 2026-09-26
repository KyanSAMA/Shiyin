import Foundation

/// A FLAC file's metadata blocks (after "fLaC", past any leading ID3 tag), edited and serialized back. Blocks other than
/// the comments and the replaced pictures stay byte for byte; padding is rebuilt.
struct FLACTagFile {
    struct Block {
        var type: UInt8
        var body: Data
    }

    /// The block region: from after "fLaC" to the first audio frame.
    let start: Int64
    let length: Int64
    private(set) var blocks: [Block]
    private static let maxBlocks = 128
    private static let maxBlock = 1 << 24
    static let growPadding = 8 << 10

    init(_ source: ByteSource) throws {
        let marker = try ID3Reader.leadingTagLength(source)
        guard try source.read(at: marker, count: 4) == Data("fLaC".utf8) else { throw TagWriteError.unsupported("不是有效的 FLAC 文件") }
        start = marker + 4
        var position = start, blocks: [Block] = [], last = false
        for _ in 0..<Self.maxBlocks where !last {
            let header = [UInt8](try source.read(at: position, count: 4))
            let size = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            guard position + 4 + Int64(size) <= source.size else { throw TagError.truncated }
            if header[0] & 0x7F != 1 { blocks.append(Block(type: header[0] & 0x7F, body: try source.read(at: position + 4, count: size))) }
            position += 4 + Int64(size)
            last = header[0] & 0x80 != 0
        }
        guard last, blocks.first?.type == 0 else { throw TagWriteError.unsupported("FLAC 元数据块不完整") }
        (length, self.blocks) = (position - start, blocks)
    }

    mutating func apply(_ edit: TagEdit) throws {
        if edit.replaceAll { blocks.removeAll { $0.type == 6 } }
        // Comments about to be replaced aren't parsed (a damaged block mustn't stop the write).
        var comments = edit.replaceAll ? Comments() : try blocks.firstIndex { $0.type == 4 }.map { try Comments(blocks[$0].body) } ?? Comments()
        if let title = edit.title { comments.set(["TITLE"], [title]) }
        if let artists = edit.artists { comments.set(["ARTIST"], artists) }
        if let album = edit.album { comments.set(["ALBUM"], [album]) }
        if let artist = edit.albumArtist { comments.set(["ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST"], [artist]) }
        if let number = edit.trackNo { comments.set(["TRACKNUMBER"], [comments.keepingTotal("TRACKNUMBER", number)]) }
        if let number = edit.discNo { comments.set(["DISCNUMBER"], [comments.keepingTotal("DISCNUMBER", number)]) }
        if let year = edit.year { comments.set(["DATE", "YEAR"], [String(year)]) }
        if let genre = edit.genre { comments.set(["GENRE"], [genre]) }
        if let composers = edit.composers { comments.set(["COMPOSER"], composers) }
        if let lyrics = edit.lyrics { comments.set(["LYRICS", "UNSYNCEDLYRICS", "UNSYNCED LYRICS"], [lyrics]) }
        if let key = edit.ncmKey { comments.set(["DESCRIPTION"], [key]) }
        let body = comments.serialized()
        guard body.count < Self.maxBlock else { throw TagWriteError.unsupported("标签超过 FLAC 元数据块的上限") }
        if let index = blocks.firstIndex(where: { $0.type == 4 }) {
            blocks[index].body = body
        } else {
            blocks.insert(Block(type: 4, body: body), at: 1)
        }
        if let cover = edit.cover {
            // Front covers (and "other", which some taggers use for them) are replaced where the first one was.
            let fronts = blocks.indices.filter { blocks[$0].type == 6 && [0, 3].contains(blocks[$0].body.prefix(4).reduce(0) { $0 << 8 | Int($1) }) }
            let at = fronts.first ?? (blocks.firstIndex(where: { $0.type == 4 }) ?? 0) + 1
            for index in fronts.reversed() { blocks.remove(at: index) }
            let picture = Self.picture(cover)
            guard picture.count < Self.maxBlock else { throw TagWriteError.unsupported("封面超过 FLAC 元数据块的上限") }
            blocks.insert(Block(type: 6, body: picture), at: min(at, blocks.count))
        }
    }

    /// The new block region; it keeps the old length when it fits with padding (or exactly), else leaves `growPadding`.
    func serialized() -> Data {
        let used = blocks.reduce(0) { $0 + 4 + $1.body.count }
        var left = used == length ? 0 : Int64(used + 4) <= length ? Int(length) - used : 4 + Self.growPadding
        // Padding past one block's limit (big covers replaced by small ones) is split, never leaving 1–3 bytes over.
        var paddings: [Block] = []
        while left > 0 {
            var body = min(left - 4, Self.maxBlock - 1)
            if (1..<4).contains(left - 4 - body) { body -= 4 }
            paddings.append(Block(type: 1, body: Data(count: body)))
            left -= 4 + body
        }
        var out = Data()
        let all = blocks + paddings
        for (index, block) in all.enumerated() {
            out.append(block.type | (index == all.count - 1 ? 0x80 : 0))
            out.append(contentsOf: [UInt8(block.body.count >> 16 & 0xFF), UInt8(block.body.count >> 8 & 0xFF), UInt8(block.body.count & 0xFF)])
            out.append(block.body)
        }
        return out
    }

    private static func picture(_ cover: TagEdit.Cover) -> Data {
        func be32(_ value: Int) -> [UInt8] { [24, 16, 8, 0].map { UInt8(value >> $0 & 0xFF) } }
        var out = Data(be32(3) + be32(cover.mime.utf8.count))
        out.append(contentsOf: Array(cover.mime.utf8))
        out.append(contentsOf: be32(0) + be32(cover.width) + be32(cover.height) + be32(24) + be32(0) + be32(cover.data.count))
        out.append(cover.data)
        return out
    }

    /// Vorbis comments as raw "KEY=value" entries in their order, kept byte for byte (a value in another encoding stays
    /// as it was); keys match case-insensitively.
    struct Comments {
        var vendor = Data("LocalMusic".utf8)
        var entries: [Data] = []

        init() {}

        init(_ body: Data) throws {
            var r = ByteReader(body)
            vendor = Data(try r.take(try r.uintLE(4)))
            let count = try r.uintLE(4)
            guard count <= r.remaining / 4 else { throw TagWriteError.unsupported("FLAC 注释块已损坏") }
            entries = try (0..<count).map { _ in Data(try r.take(try r.uintLE(4))) }
        }

        private static func key(_ entry: Data) -> String { String(decoding: entry.prefix { $0 != UInt8(ascii: "=") }, as: UTF8.self).uppercased() }

        /// Removes every entry under `keys` and puts the values under the first key where the first removed one was.
        mutating func set(_ keys: [String], _ values: [String]) {
            let at = entries.firstIndex { keys.contains(Self.key($0)) } ?? entries.count
            entries.removeAll { keys.contains(Self.key($0)) }
            entries.insert(contentsOf: values.map { Data("\(keys[0])=\($0)".utf8) }, at: min(at, entries.count))
        }

        /// "n", or "n/total" when the old value carried a total.
        func keepingTotal(_ key: String, _ number: Int) -> String {
            guard let old = entries.first(where: { Self.key($0) == key }).map({ String(decoding: $0, as: UTF8.self) }),
                  let slash = old.firstIndex(of: "/") else { return String(number) }
            return "\(number)" + old[slash...]
        }

        func serialized() -> Data {
            func le32(_ value: Int) -> [UInt8] { [0, 8, 16, 24].map { UInt8(value >> $0 & 0xFF) } }
            var out = Data(le32(vendor.count))
            out.append(vendor)
            out.append(contentsOf: le32(entries.count))
            for entry in entries {
                out.append(contentsOf: le32(entry.count))
                out.append(entry)
            }
            return out
        }
    }
}
