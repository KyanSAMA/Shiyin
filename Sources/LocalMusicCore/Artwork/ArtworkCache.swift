import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Cover thumbnails: memory LRU (by bytes) over a JPEG disk cache over the source image. The source is the embedded
/// picture, or else a conventional image in the track's folder, which is keyed by its own path and mtime so a folder
/// of tracks shares one decode and a replaced `cover.jpg` is picked up. Work runs in the caller's task, so a cover
/// that scrolled away (cancelled `.task`) is skipped instead of decoded; at most `parallelism` decodes at once.
public actor ArtworkCache {
    static let folderImageNames = ["cover.jpg", "cover.png", "folder.jpg", "folder.png", "front.jpg", "front.png"]

    private let directory: URL
    private let budget: Int
    private var memory: [String: (image: CGImage, cost: Int, used: UInt64)] = [:]
    private var bytes = 0
    private var clock: UInt64 = 0
    private let limiter = Limiter(4)

    public init(directory: URL, budget: Int = 150 << 20) {
        self.directory = directory
        self.budget = budget
    }

    public func image(for row: TrackRow, pixels: Int) async -> CGImage? {
        guard let source = Self.source(for: row) else { return nil }
        let key = "\(source.key)-\(pixels)"
        if let hit = memory[key] {
            clock += 1
            memory[key]?.used = clock
            return hit.image
        }
        let image = await Self.load(source, pixels: pixels, cacheFile: directory.appending(path: key + ".jpg"), limiter: limiter)
        if let image { remember(key, image) }
        return image
    }

    private func remember(_ key: String, _ image: CGImage) {
        let cost = image.bytesPerRow * image.height
        clock += 1
        if let old = memory.updateValue((image, cost, clock), forKey: key) { bytes -= old.cost }
        bytes += cost
        while bytes > budget, let oldest = memory.min(by: { $0.value.used < $1.value.used }) {
            bytes -= oldest.value.cost
            memory[oldest.key] = nil
        }
    }

    struct Source {
        let key: String
        let track: TrackRow
        let folderImage: URL?
    }

    /// Embedded art keyed by track and file mtime; folder art by the image's path and mtime; then an enrichment cover
    /// (a new name for each download).
    static func source(for row: TrackRow) -> Source? {
        if row.hasCover { return Source(key: "t\(row.id)-\(Int(row.fileMtime))", track: row, folderImage: nil) }
        guard let url = folderImage(near: row),
              let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else {
            return row.coverFile.map { Source(key: "e" + TagReader.sha256(Data($0.utf8)).prefix(16), track: row, folderImage: URL(filePath: $0)) }
        }
        return Source(key: "f" + TagReader.sha256(Data(url.path.utf8)).prefix(16) + "-\(Int(mtime.timeIntervalSince1970))",
                      track: row, folderImage: url)
    }

    private static func load(_ source: Source, pixels: Int, cacheFile: URL, limiter: Limiter) async -> CGImage? {
        await limiter.acquire()
        defer { Task { await limiter.release() } }
        guard !Task.isCancelled else { return nil }
        if let cached = thumbnail(CGImageSourceCreateWithURL(cacheFile as CFURL, nil), pixels: pixels) { return cached }
        var image = source.folderImage.flatMap { thumbnail(CGImageSourceCreateWithURL($0 as CFURL, nil), pixels: pixels) }
        if source.folderImage == nil {
            let track = source.track
            let ref = CoverRef(offset: track.coverOffset, length: track.coverLength ?? 0, mime: nil, pictureType: 3)
            image = (try? await TagReader.coverData(track.url, ref)).flatMap { thumbnail(CGImageSourceCreateWithData($0 as CFData, nil), pixels: pixels) }
            // A stale offset (file rewritten with the same size and mtime) decodes to nil: fall back to folder art.
            if image == nil, let folder = folderImage(near: track) {
                image = thumbnail(CGImageSourceCreateWithURL(folder as CFURL, nil), pixels: pixels)
            }
        }
        if let image { write(image, to: cacheFile) }
        return image
    }

    /// A cover.jpg / folder.jpg-style image beside the file (shown when it has no embedded cover).
    public static func hasFolderImage(near row: TrackRow) -> Bool { folderImage(near: row) != nil }

    private static func folderImage(near row: TrackRow) -> URL? {
        let folder = row.url.deletingLastPathComponent()
        return folderImageNames.lazy.map { folder.appending(path: $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func thumbnail(_ source: CGImageSource?, pixels: Int) -> CGImage? {
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Encode in memory, then an atomic write: a crash mid-write must not leave a truncated JPEG that still decodes.
    private static func write(_ image: CGImage, to url: URL) {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (data as Data).write(to: url, options: .atomic)
    }
}

/// Async counting semaphore.
actor Limiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ count: Int) { available = count }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}
