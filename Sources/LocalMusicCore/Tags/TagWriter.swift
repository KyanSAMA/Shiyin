import AVFAudio
import Foundation

/// Writes tags into FLAC and MP3 files (WAV and M4A aren't supported). Only the tag region changes; before the new file
/// replaces the old one it must hash to the same audio bytes and fingerprint, read back as written, and open for
/// playback. The original region is handed to `backup` first, so `restore` can put the file back byte for byte.
public enum TagWriter {
    /// A file's tag region before the first write, and what identifies its audio.
    public struct Original: Sendable, Codable, Equatable {
        public let format: String
        public let region: Data
        public let audioSHA256: String
        public let version: FileVersion
    }

    /// A write worked out but not yet made: its `original` goes to the backup before `commit`.
    public struct Prepared: Sendable {
        public let url: URL
        public let original: Original
        fileprivate let start: Int64, length: Int64, bytes: Data, fingerprint: String, edit: TagEdit
    }

    public static func prepare(_ edit: TagEdit, for url: URL) throws -> Prepared {
        let url = url.resolvingSymlinksInPath()
        try TagRegion.checkWritable(url)
        let version = try FileVersion(url)
        var file = try TagFile(url)
        let source = try FileSource(url: url)
        let original = Original(format: file.format, region: try source.read(at: file.start, count: Int(file.length)),
                                audioSHA256: try TagRegion.sha256(url, try file.audio(source)), version: version)
        let fingerprint = try AudioFingerprint.compute(source, format: file.format)
        try file.apply(edit)
        return Prepared(url: url, original: original, start: file.start, length: file.length, bytes: file.serialized(),
                        fingerprint: fingerprint, edit: edit)
    }

    /// Fails with `TagWriteError.changed` if the file changed since `prepare`.
    public static func commit(_ prepared: Prepared) async throws -> FileVersion {
        try await TagRegion.commit(prepared.url, start: prepared.start, length: prepared.length, bytes: prepared.bytes,
                                   expecting: prepared.original.version) { temp in
            try await verify(temp, like: prepared.original, fingerprint: prepared.fingerprint)
            try await verify(temp, reads: prepared.edit, format: prepared.original.format)
        }
    }

    public static func write(_ edit: TagEdit, to url: URL, backup: (Original) throws -> Void) async throws -> FileVersion {
        let prepared = try prepare(edit, for: url)
        try backup(prepared.original)
        return try await commit(prepared)
    }

    /// Puts the original tag region back (the audio must be the backed-up one).
    public static func restore(_ url: URL, to original: Original) async throws -> FileVersion {
        let url = url.resolvingSymlinksInPath()
        try TagRegion.checkWritable(url)
        let version = try FileVersion(url)
        let file = try TagFile(url)
        let source = try FileSource(url: url)
        guard try TagRegion.sha256(url, try file.audio(source)) == original.audioSHA256 else { throw TagWriteError.unsupported("文件的音频和备份时不同") }
        let fingerprint = try AudioFingerprint.compute(source, format: file.format)
        return try await TagRegion.commit(url, start: file.start, length: file.length, bytes: original.region, expecting: version) { temp in
            try await verify(temp, like: original, fingerprint: fingerprint)
        }
    }

    private static func verify(_ temp: URL, like original: Original, fingerprint: String) async throws {
        let source = try FileSource(url: temp)
        guard try TagRegion.sha256(temp, try TagFile(temp).audio(source)) == original.audioSHA256 else {
            throw TagWriteError.verification("音频数据不一致")
        }
        guard try AudioFingerprint.compute(source, format: original.format) == fingerprint else { throw TagWriteError.verification("音频指纹变了") }
        do { _ = try AVAudioFile(forReading: temp) } catch { throw TagWriteError.verification("无法打开：\(error)") }
    }

    private static func verify(_ temp: URL, reads edit: TagEdit, format: String) async throws {
        let raw = try await TagReader.read(temp)
        let meta = TrackMetadata(tags: raw.tags, fileURL: temp)
        // Names written as one ID3 frame read back split the way the reader splits them.
        func names(_ values: [String]) -> [String] { PersonSplitter.split(format == "flac" ? values : [values.joined(separator: "/")]) }
        var wrong: [String] = []
        if let title = edit.title, meta.title != title || meta.titleSource != .tag { wrong.append("标题") }
        if let artists = edit.artists, meta.names(.artist) != names(artists) { wrong.append("艺人") }
        if let album = edit.album, meta.album != album { wrong.append("专辑") }
        if let artist = edit.albumArtist, meta.albumArtist != artist { wrong.append("专辑艺人") }
        if let number = edit.trackNo, meta.trackNo != number { wrong.append("曲序") }
        if let number = edit.discNo, meta.discNo != number { wrong.append("碟号") }
        if let year = edit.year, meta.year != year { wrong.append("年份") }
        if let genre = edit.genre, meta.genre != genre { wrong.append("流派") }
        if let composers = edit.composers, meta.people.filter({ $0.role == .composer && $0.source == .tag }).map(\.name) != names(composers) {
            wrong.append("作曲")
        }
        if let lyrics = edit.lyrics, meta.lyrics != lyrics.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) { wrong.append("歌词") }
        if let cover = edit.cover {
            let data = try await raw.cover.asyncMap { try await TagReader.coverData(temp, $0) }
            if data != cover.data { wrong.append("封面") }
        }
        guard wrong.isEmpty else { throw TagWriteError.verification("读回的\(wrong.joined(separator: "、"))和写入的不同") }
    }
}

/// The tag region of a FLAC or MP3 file.
private enum TagFile {
    case flac(FLACTagFile)
    case id3(ID3TagFile)

    init(_ url: URL) throws {
        let source = try FileSource(url: url)
        switch url.pathExtension.lowercased() {
        case "flac": self = .flac(try FLACTagFile(source))
        case "mp3": self = .id3(try ID3TagFile(source))
        case let other: throw TagWriteError.unsupported("暂不支持写入 \(other.uppercased()) 文件")
        }
    }

    var format: String {
        switch self {
        case .flac: "flac"
        case .id3: "mp3"
        }
    }

    var start: Int64 {
        switch self {
        case .flac(let file): file.start
        case .id3: 0
        }
    }

    var length: Int64 {
        switch self {
        case .flac(let file): file.length
        case .id3(let file): file.length
        }
    }

    func audio(_ source: ByteSource) throws -> Range<Int64> {
        switch self {
        case .flac(let file): file.start + file.length..<source.size
        case .id3(let file): file.length..<max(file.length, try AudioFingerprint.trailingTagsStart(source))
        }
    }

    mutating func apply(_ edit: TagEdit) throws {
        switch self {
        case .flac(var file):
            try file.apply(edit)
            self = .flac(file)
        case .id3(var file):
            file.apply(edit)
            self = .id3(file)
        }
    }

    func serialized() -> Data {
        switch self {
        case .flac(let file): file.serialized()
        case .id3(let file): file.serialized()
        }
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T?) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}
