import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LocalMusicCore

private func row(_ id: Int64, _ title: String, album: String? = nil, artists: [String] = [], composers: [String] = [],
                 path: String? = nil, cover: (Int64, Int)? = nil, mtime: Double = 1) -> TrackRow {
    TrackRow(id: id, path: path ?? "/lib/\(id).flac", title: title, album: album, albumArtist: nil, artists: artists,
             composers: composers, trackNo: path.flatMap { Int(URL(filePath: $0).deletingPathExtension().lastPathComponent) }, discNo: nil, year: nil, genre: nil, duration: 1, format: "flac",
             sampleRate: 44100, bitDepth: 16, hasCover: cover != nil, coverOffset: cover?.0, coverLength: cover?.1,
             hasLyrics: false, addedAt: .now, fileMtime: mtime)
}

struct SearchTests {
    private let index = LibraryIndex(rows: [
        row(1, "晴る", album: "ヨルシカ Best", artists: ["ヨルシカ"], composers: ["n-buna"]),
        row(2, "ABC Song", artists: ["Café Tacvba"]),
        row(3, "群青", album: "THE BOOK", artists: ["YOASOBI"]),
    ])

    @Test func foldsKanaWidthCaseAndDiacritics() {
        func ids(_ query: String) -> [Int64] { index.filter(index.songs, matching: query).map(\.id) }
        #expect(ids("よるしか") == [1])
        #expect(ids("ＡＢＣ") == [2])
        #expect(ids("cafe") == [2])
        #expect(ids("N-BUNA") == [1])
        #expect(ids("  ").count == 3)
        #expect(ids("zzz").isEmpty)
        let reversed = Array(index.songs.reversed())
        #expect(index.filter(reversed, matching: "o").map(\.id) == reversed.map(\.id).filter { ids("o").contains($0) })
    }

    @Test func filtersAlbumsAndPeople() {
        #expect(index.albums(matching: "the book").map(\.title) == ["THE BOOK"])
        #expect(index.people(.artist, matching: "yoa").map(\.name) == ["YOASOBI"])
    }

    @Test func sortsTitlesLikeFinder() {
        let rows = [row(1, "Track 10"), row(2, "Track 2"), row(3, "track 1")]
        #expect(rows.sorted(using: KeyPathComparator(\TrackRow.title, comparator: .localizedStandard)).map(\.id) == [3, 2, 1])
    }
}

struct ArtworkTests {
    private let dir = FileManager.default.temporaryDirectory.appending(path: "lm-art-\(UUID().uuidString)")

    private func png(width: Int, height: Int) throws -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// A synthetic FLAC whose PICTURE block holds `image`; returns the row pointing at it.
    private func track(_ id: Int64, image: Data?) throws -> TrackRow {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var blocks: [(type: UInt8, body: Data)] = [(0, FLACBuilder.streamInfo(rate: 44100, channels: 2, bitDepth: 16, total: 44100))]
        if let image { blocks.append((6, FLACBuilder.picture(image: image))) }
        let url = dir.appending(path: "\(id).flac")
        let bytes = FLACBuilder.file(blocks)
        try bytes.write(to: url)
        let cover = try FLACReader.read(DataSource(bytes)).cover
        return row(id, "t\(id)", path: url.path, cover: cover.map { ($0.offset!, $0.length) })
    }

    @Test func makesAspectPreservingThumbnails() throws {
        let image = try #require(ArtworkCache.thumbnail(CGImageSourceCreateWithData(try png(width: 1200, height: 600) as CFData, nil), pixels: 200))
        #expect(image.width == 200 && image.height == 100)
    }

    @Test func servesFromMemoryThenDisk() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let cacheDir = dir.appending(path: "cache")
        let row = try track(1, image: try png(width: 800, height: 800))
        let first = try #require(await ArtworkCache(directory: cacheDir).image(for: row, pixels: 64))
        #expect(first.width == 64)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cacheDir.path).count == 1)

        try FileManager.default.removeItem(atPath: row.path)   // a fresh cache must now come from disk
        #expect(await ArtworkCache(directory: cacheDir).image(for: row, pixels: 64)?.width == 64)
    }

    @Test func evictsLeastRecentlyUsedOverBudget() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ArtworkCache(directory: dir.appending(path: "cache"), budget: 64 * 64 * 4 * 2)
        let rows = try (1...3).map { try track($0, image: try png(width: 300, height: 300)) }
        for row in rows { _ = await cache.image(for: row, pixels: 64) }
        for row in rows { try FileManager.default.removeItem(atPath: row.path) }
        try FileManager.default.removeItem(at: dir.appending(path: "cache"))
        #expect(await cache.image(for: rows[0], pixels: 64) == nil)   // evicted, and no source left
        #expect(await cache.image(for: rows[2], pixels: 64) != nil)   // still in memory
    }

    @Test func fallsBackToAFolderImageAndNoticesItChanging() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let row = try track(7, image: nil)
        let cache = ArtworkCache(directory: dir.appending(path: "cache"))
        #expect(await cache.image(for: row, pixels: 64) == nil)
        let cover = dir.appending(path: "cover.png")
        try png(width: 100, height: 100).write(to: cover)
        #expect(await cache.image(for: row, pixels: 64)?.width == 64)
        try png(width: 100, height: 50).write(to: cover)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: cover.path)
        #expect(await cache.image(for: row, pixels: 64)?.height == 32)
    }

    @Test func fallsBackToFolderArtWhenTheEmbeddedOffsetIsStale() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = try track(8, image: try png(width: 100, height: 100))
        let stale = TrackRow(id: 9, path: good.path, title: "x", album: nil, albumArtist: nil, artists: [], composers: [],
                             trackNo: nil, discNo: nil, year: nil, genre: nil, duration: 1, format: "flac", sampleRate: nil,
                             bitDepth: nil, hasCover: true, coverOffset: 0, coverLength: 16, hasLyrics: false, addedAt: .now, fileMtime: 1)
        try png(width: 40, height: 40).write(to: dir.appending(path: "folder.png"))
        #expect(await ArtworkCache(directory: dir.appending(path: "cache")).image(for: stale, pixels: 64)?.width == 40)
    }

    @Test func dedupesPeopleByFoldedNamePerTrack() {
        let index = LibraryIndex(rows: [row(1, "a", artists: ["YOASOBI", "yoasobi"])])
        #expect(index.artists.map(\.trackIDs) == [[1]])
    }

    @Test func derivesDiscsFromFoldersAndUsesFolderArtForAlbumCovers() {
        let rows = [row(1, "b", album: "Box", path: "/l/Box/CD2/01.flac"), row(2, "a", album: "Box", path: "/l/Box/CD1/01.flac"),
                    row(3, "c", album: "Box", path: "/l/Box/CD1/02.flac")]
        let album = LibraryIndex(rows: rows).albums[0]
        #expect(album.trackIDs == [2, 3, 1] && album.coverTrackID == 2)
    }
}
