import Foundation

public struct LibraryRoots: Sendable, Equatable {
    public var include: [String]
    public var exclude: [String]

    public init(include: [String], exclude: [String]) {
        self.include = include
        self.exclude = exclude
    }

    /// Canonical paths, matching what directory enumeration and FSEvents report.
    public var resolved: LibraryRoots {
        LibraryRoots(include: include.map(canonicalPath), exclude: exclude.map(canonicalPath))
    }

    public func isExcluded(_ path: String) -> Bool {
        let key = path.pathKey
        return exclude.contains { key == $0 || key.hasPrefix($0 + "/") }
    }

    /// The system Music folder, minus the Apple Music library inside it (TCC-protected, not ours to scan).
    public static var defaults: LibraryRoots {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        return LibraryRoots(include: [music.path], exclude: [music.appending(path: "Music").path])
    }
}

/// A user playlist; each track appears at most once.
public struct Playlist: Sendable, Identifiable, Hashable {
    public let id: Int64
    public var name: String
    public var trackIDs: [Int64]

    public init(id: Int64, name: String, trackIDs: [Int64]) {
        self.id = id
        self.name = name
        self.trackIDs = trackIDs
    }
}

public struct TrackRow: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let path: String
    public let title: String
    public let album: String?
    public let albumArtist: String?
    public let artists: [String]
    public let composers: [String]
    public let trackNo: Int?
    public let discNo: Int?
    public let year: Int?
    public let genre: String?
    public let duration: Double
    public let format: String
    public let codec: String?
    public let sampleRate: Int?
    public let bitDepth: Int?
    public let hasCover: Bool
    public let coverOffset: Int64?
    public let coverLength: Int?
    public let hasLyrics: Bool
    public let addedAt: Date
    public let fileMtime: Double
    public var fingerprint: String? = nil
    /// A downloaded or chosen cover, for a file without its own.
    public var coverFile: String? = nil

    public var url: URL { URL(filePath: path) }
    public var hasArtwork: Bool { hasCover || coverFile != nil }
    public var artistText: String { artists.joined(separator: " / ") }

    // Non-optional sort keys for table columns.
    public var albumTitle: String { album ?? "" }
    public var yearSortKey: Int { year ?? 0 }
}

public struct ScanReport: Sendable {
    public var total = 0
    public var parsed = 0
    public var added = 0
    public var updated = 0
    public var removed = 0
    public var failures: [String] = []
    public var milliseconds = 0.0
}

/// On-disk identity used to decide whether a file must be re-parsed.
struct FileStamp: Sendable {
    let path: String
    let size: Int64
    let mtime: Double
    let created: Double
}

struct StoredStamp: Sendable {
    let id: Int64
    let size: Int64
    let mtime: Double
    let sidecarMtime: Double?
    /// Parsed before fingerprints existed: parse once more to fill it in.
    var needsFingerprint = false
}

struct ScannedTrack: Sendable {
    let stamp: FileStamp
    let storedID: Int64?
    let sidecarMtime: Double?
    let sidecarLyrics: String?
    let result: Result<(RawTrack, TrackMetadata), ScanFailure>
}

struct ScanFailure: Error, Sendable {
    let message: String
}

/// NFC path with symlinks resolved on its deepest existing ancestor, so it also works for paths that are missing
/// (an ejected drive) or not yet created. Uses `realpath`, which, unlike `resolvingSymlinksInPath`, keeps `/private/var`.
public func canonicalPath(_ path: String) -> String {
    var base = URL(filePath: path).standardizedFileURL
    var missing: [String] = []
    while true {
        if let resolved = realpath(base.path, nil) {
            defer { free(resolved) }
            return missing.reduce(URL(filePath: String(cString: resolved))) { $0.appending(path: $1) }.path.pathKey
        }
        guard base.path != "/" else { return path.pathKey }
        missing.insert(base.lastPathComponent, at: 0)
        base.deleteLastPathComponent()
    }
}

extension String {
    /// Filesystems hand back NFD for many Japanese names; compare paths in NFC.
    var pathKey: String { precomposedStringWithCanonicalMapping }
}
