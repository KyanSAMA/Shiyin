import CryptoKit
import Foundation

public struct AudioProperties: Sendable, Equatable {
    public var format: String
    public var codec: String?
    public var sampleRate: Int?
    public var bitDepth: Int?
    public var channels: Int?
    public var frameCount: Int64?
    public var duration: Double
}

/// Location of embedded cover bytes; `offset == nil` means they must be re-extracted (unsynced ID3, M4A, WAV).
public struct CoverRef: Sendable, Equatable {
    public var offset: Int64?
    public var length: Int
    public var mime: String?
    public var pictureType: Int
}

/// Raw tag fields keyed by upper-cased Vorbis-style names (TITLE, ARTIST, …); blank values are dropped.
public struct RawTags: Sendable, Equatable {
    public private(set) var fields: [String: [String]] = [:]

    public init() {}

    public mutating func add(_ key: String, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard !trimmed.isEmpty else { return }
        fields[key.uppercased(), default: []].append(trimmed)
    }

    public subscript(key: String) -> [String] { fields[key] ?? [] }

    public func first(_ keys: String...) -> String? {
        keys.lazy.compactMap { self.fields[$0]?.first }.first
    }
}

public struct RawTrack: Sendable, Equatable {
    public var properties: AudioProperties
    public var tags: RawTags
    public var cover: CoverRef?
    /// Bytes the tag parser read from disk (diagnostics; excludes AVFoundation reads).
    public var bytesRead: Int64 = 0
    /// See `AudioFingerprint`; nil only if the audio payload couldn't be read.
    public var fingerprint: String?
}

public enum TagReader {
    public static let audioExtensions: Set<String> = ["flac", "mp3", "wav", "m4a"]

    public static func read(_ url: URL) async throws -> RawTrack {
        let format = url.pathExtension.lowercased()
        let source = try FileSource(url: url)
        var track = try await read(url, format: format, source: source)
        track.bytesRead = source.bytesRead
        track.fingerprint = try? AudioFingerprint.compute(FileSource(url: url), format: format)
        return track
    }

    private static func read(_ url: URL, format: String, source: FileSource) async throws -> RawTrack {
        switch format {
        case "flac":
            var track = try FLACReader.read(source)
            if track.properties.frameCount == 0 {
                let decoded = try AVTagReader.properties(url: url, format: format)
                track.properties.frameCount = decoded.frameCount
                track.properties.duration = decoded.duration
            }
            return track
        case "mp3":
            let properties = try AVTagReader.properties(url: url, format: format)
            if let id3 = try ID3Reader.read(source) {
                return RawTrack(properties: properties, tags: id3.tags, cover: id3.cover)
            }
            let (tags, cover) = try await AVTagReader.metadata(url: url)
            return RawTrack(properties: properties, tags: tags, cover: cover)
        case "wav", "m4a":
            let (tags, cover) = try await AVTagReader.metadata(url: url)
            return RawTrack(properties: try AVTagReader.properties(url: url, format: format), tags: tags, cover: cover)
        default:
            throw TagError.unsupported(format)
        }
    }

    public static func coverData(_ url: URL, _ cover: CoverRef) async throws -> Data? {
        if let offset = cover.offset {
            return try FileSource(url: url).read(at: offset, count: cover.length)
        }
        if url.pathExtension.lowercased() == "mp3", let id3 = try ID3Reader.read(FileSource(url: url), includeCoverData: true) {
            return id3.coverData
        }
        return try await AVTagReader.artwork(url: url)
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
