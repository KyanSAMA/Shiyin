import CoreServices
import Foundation
import Testing
@testable import LocalMusicCore

/// Temp library of synthetic FLAC headers (the scanner never decodes audio, so no real frames are needed).
private final class TempLibrary {
    let root = FileManager.default.temporaryDirectory.appending(path: "lm-lib-\(UUID().uuidString)")
    let store: LibraryStore

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try LibraryStore(url: root.appending(path: ".data/library.sqlite"))
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var roots: LibraryRoots { LibraryRoots(include: [root.path], exclude: [root.appending(path: "Excluded").path]) }

    @discardableResult
    func flac(_ relative: String, _ comments: [String]) throws -> URL {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FLACBuilder.file([(0, FLACBuilder.streamInfo(rate: 44100, channels: 2, bitDepth: 16, total: 441_000)),
                              (4, FLACBuilder.comments(comments))]).write(to: url)
        return url
    }

    func write(_ relative: String, _ text: String) throws {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func touch(_ url: URL, secondsAgo: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -secondsAgo)], ofItemAtPath: url.path)
    }

    func scan() async throws -> ScanReport { try await LibraryScanner.scan(store: store, roots: roots) }

    func count(_ sql: String) async throws -> Int {
        try await store.count(sql)
    }
}

extension LibraryStore {
    func count(_ sql: String) throws -> Int { try db.query(sql) { $0.int(0) ?? 0 }.first ?? 0 }
}

struct DirectoryWalkerTests {
    @Test func collectsAudioAndSidecarsHonouringExclusions() throws {
        let lib = try TempLibrary()
        try lib.flac("a/One.FLAC", [])
        try lib.write("a/One.lrc", "[00:01.00]x")
        try lib.write("a/cover.jpg", "jpg")
        try lib.write("a/.hidden.flac", "x")
        try lib.write("Excluded/skip.flac", "x")
        try lib.write("a/Bundle.app/Contents/inner.flac", "x")
        try FileManager.default.createSymbolicLink(at: lib.root.appending(path: "link"), withDestinationURL: lib.root.appending(path: "a"))

        let walk = DirectoryWalker.walk(lib.roots)
        #expect(walk.audio.values.map { $0.path.replacingOccurrences(of: LibraryRoots(include: [lib.root.path], exclude: []).resolved.include[0], with: "") }.sorted() == ["/a/One.FLAC"])
        #expect(walk.sidecars.count == 1)
    }
}

struct LibraryScannerTests {
    @Test func scansIncrementallyAndPrunesDeletedFiles() async throws {
        let lib = try TempLibrary()
        let one = try lib.flac("One.flac", ["TITLE=One", "ARTIST=A/B", "LYRICS=[00:00.00]作曲 : C\n[00:01.00]x"])
        try lib.flac("Two.flac", ["TITLE=Two"])
        try lib.touch(one, secondsAgo: 60)

        let first = try await lib.scan()
        #expect(first.total == 2 && first.parsed == 2 && first.added == 2 && first.failures.isEmpty)
        #expect(try await lib.count("SELECT COUNT(*) FROM track_person") == 3)
        #expect(try await lib.scan().parsed == 0)

        try lib.touch(one, secondsAgo: 0)
        let changed = try await lib.scan()
        #expect(changed.parsed == 1 && changed.updated == 1)

        try FileManager.default.removeItem(at: one)
        #expect(try await lib.scan().removed == 1)
        #expect(try await lib.count("SELECT COUNT(*) FROM track_person") == 0)
        #expect(try await lib.count("SELECT COUNT(*) FROM lyrics") == 0)
        #expect(try await lib.store.rows().map(\.title) == ["Two"])
    }

    @Test func sidecarLyricsMarkTheTrackDirty() async throws {
        let lib = try TempLibrary()
        try lib.flac("Song.flac", ["TITLE=Song"])
        _ = try await lib.scan()
        #expect(try await lib.store.rows().first?.hasLyrics == false)

        try lib.write("Song.lrc", "[00:01.00]旁挂歌词")
        #expect(try await lib.scan().parsed == 1)
        #expect(try await lib.store.rows().first?.hasLyrics == true)
        #expect(try await lib.count("SELECT COUNT(*) FROM lyrics WHERE source = 'sidecar'") == 1)
    }

    @Test func remembersFailuresWithoutReparsingOrListingThem() async throws {
        let lib = try TempLibrary()
        try lib.write("Broken.flac", "definitely not flac")
        let first = try await lib.scan()
        #expect(first.failures.count == 1)
        #expect(try await lib.store.rows().isEmpty)
        #expect(try await lib.scan().parsed == 0)
    }

    @Test func decomposedFilenamesDoNotChurn() async throws {
        let lib = try TempLibrary()
        try lib.flac("ゴーストルール".decomposedStringWithCanonicalMapping + ".flac", ["TITLE=x"])
        #expect(try await lib.scan().parsed == 1)
        #expect(try await lib.scan().parsed == 0)
    }

    @Test func keepsTracksOfAnUnreachableRoot() async throws {
        let lib = try TempLibrary()
        let drive = lib.root.appending(path: "Drive")
        try lib.flac("Drive/a.flac", ["TITLE=a"])
        try lib.flac("Drive/b.flac", ["TITLE=b"])
        let roots = LibraryRoots(include: [drive.path], exclude: [])
        #expect(try await LibraryScanner.scan(store: lib.store, roots: roots).added == 2)

        let ejected = lib.root.appending(path: "Ejected")
        try FileManager.default.moveItem(at: drive, to: ejected)
        #expect(try await LibraryScanner.scan(store: lib.store, roots: roots).removed == 0)
        #expect(try await lib.store.rows().count == 2)

        try FileManager.default.moveItem(at: ejected, to: drive)
        #expect(try await LibraryScanner.scan(store: lib.store, roots: roots).parsed == 0)
    }

    @Test func recreatingANameInAnotherNormalizationUpdatesTheSameRow() async throws {
        let lib = try TempLibrary()
        let name = "ゴーストルール"
        let nfd = try lib.flac(name.decomposedStringWithCanonicalMapping + ".flac", ["TITLE=x"])
        _ = try await lib.scan()
        try FileManager.default.removeItem(at: nfd)
        try lib.flac(name.precomposedStringWithCanonicalMapping + ".flac", ["TITLE=y"])
        #expect(try await lib.scan().updated == 1)
        #expect(try await lib.store.rows().map(\.title) == ["y"])
        #expect(try await lib.scan().parsed == 0)
    }

    @Test func scansAnIncludeRootNestedInAnExcludedFolder() async throws {
        let lib = try TempLibrary()
        try lib.flac("Excluded/Kept/a.flac", ["TITLE=a"])
        try lib.flac("Excluded/b.flac", ["TITLE=b"])
        let roots = LibraryRoots(include: [lib.root.path, lib.root.appending(path: "Excluded/Kept").path],
                                 exclude: [lib.root.appending(path: "Excluded").path])
        _ = try await LibraryScanner.scan(store: lib.store, roots: roots)
        #expect(try await lib.store.rows().map(\.title) == ["a"])
    }

    @Test func seedsDefaultRootsOnlyOnce() async throws {
        let lib = try TempLibrary()
        #expect(try await lib.store.roots() == .defaults)
        let custom = LibraryRoots(include: ["/a", "/b"], exclude: ["/a/x"])
        try await lib.store.setRoots(custom)
        #expect(try await lib.store.roots() == custom)
        try await lib.store.setRoots(LibraryRoots(include: [], exclude: []))
        #expect(try await lib.store.roots() == LibraryRoots(include: [], exclude: []))

        let fresh = try TempLibrary()
        try await fresh.store.setRoots(custom)
        #expect(try await fresh.store.roots() == custom)
    }
}

struct LibraryIndexTests {
    private func row(_ id: Int64, _ title: String, album: String? = nil, albumArtist: String? = nil, artists: [String] = [],
                     composers: [String] = [], dir: String = "/lib", track: Int? = nil) -> TrackRow {
        TrackRow(id: id, path: "\(dir)/\(title).flac", title: title, album: album, albumArtist: albumArtist, artists: artists,
                 composers: composers, trackNo: track, discNo: nil, year: nil, genre: nil, duration: 1, format: "flac", codec: "flac",
                 sampleRate: 44100, bitDepth: 16, hasCover: id % 2 == 0, coverOffset: nil, coverLength: nil, hasLyrics: false,
                 addedAt: .now, fileMtime: 0)
    }

    @Test func groupsAlbumsByAlbumArtistOrFolder() {
        let index = LibraryIndex(rows: [
            // One OST whose tracks credit different artists, same folder, no ALBUMARTIST: stays one album.
            row(1, "b", album: "叙拉古人OST", artists: ["塞壬唱片-MSR", "X"], track: 2),
            row(2, "a", album: "叙拉古人OST", artists: ["塞壬唱片-MSR"], track: 1),
            row(3, "c", album: "叙拉古人OST", artists: ["Y"], track: 3),
            // Same title in another folder is another album.
            row(4, "d", album: "叙拉古人OST", artists: ["Z"], dir: "/other"),
            // Tagged album artist wins over folder; width/case-folded.
            row(5, "e", album: "THE BOOK", albumArtist: "YOASOBI", artists: ["YOASOBI"], dir: "/x"),
            row(6, "f", album: "ＴＨＥ ＢＯＯＫ", albumArtist: "yoasobi", artists: ["YOASOBI"], dir: "/y"),
            // Untitled albums group per primary artist.
            row(7, "g", artists: ["miwa"]), row(8, "h", artists: ["miwa"]), row(9, "i"),
        ])
        #expect(index.albums.count == 5)
        let ost = index.albums.first { $0.trackIDs.contains(1) }!
        #expect(ost.trackIDs == [2, 1, 3] && ost.artist == "塞壬唱片-MSR" && ost.coverTrackID == 2)
        #expect(index.albums.first { $0.trackIDs.contains(5) }!.trackIDs.sorted() == [5, 6])
        #expect(index.albums.filter { $0.title == LibraryIndex.unknownAlbum }.map(\.trackIDs.count).sorted() == [1, 2])
    }

    @Test func mergesDiscFoldersAndPartiallyTaggedAlbums() {
        let index = LibraryIndex(rows: [
            row(1, "a", album: "Box", artists: ["X"], dir: "/lib/Box/CD1"), row(2, "b", album: "Box", artists: ["X"], dir: "/lib/Box/Disc 2"),
            row(3, "c", album: "Mixed", albumArtist: "Y", artists: ["Y"]), row(4, "d", album: "Mixed", artists: ["Z"]),
        ])
        #expect(index.albums.map { $0.trackIDs.sorted() } == [[1, 2], [3, 4]])
    }

    @Test func ordersSameTitledAlbumsDeterministically() {
        let rows = [row(1, "a", artists: ["B"]), row(2, "b", artists: ["A"]), row(3, "c", album: "S", artists: ["C"], dir: "/2"),
                    row(4, "d", album: "S", artists: ["C"], dir: "/1")]
        let orders = (0..<5).map { _ in LibraryIndex(rows: rows.shuffled()).albums.map(\.id) }
        #expect(Set(orders.map { $0.joined(separator: "|") }).count == 1)
    }

    @Test func fallsBackToVariousArtistsWithoutMajority() {
        let index = LibraryIndex(rows: [row(1, "a", album: "Mix", artists: ["A"]), row(2, "b", album: "Mix", artists: ["B"])])
        #expect(index.albums.first?.artist == LibraryIndex.variousArtists)
    }

    @Test func groupsPeopleWithAnUnknownBucketLast() {
        let index = LibraryIndex(rows: [
            row(1, "x", artists: ["ヨルシカ"], composers: ["n-buna"]), row(2, "y", artists: ["ﾖﾙｼｶ", "suis"]), row(3, "z"),
        ])
        #expect(index.artists.map(\.name) == ["suis", "ヨルシカ", LibraryIndex.unknown])
        #expect(index.artists.first { $0.name == "ヨルシカ" }!.trackIDs == [1, 2])
        #expect(index.composers.map(\.name) == ["n-buna", LibraryIndex.unknown])
        #expect(index.composers.last!.isUnknown && index.composers.last!.trackIDs == [2, 3])
    }
}

struct FileEventRelevanceTests {
    private let roots = LibraryRoots(include: ["/m"], exclude: ["/m/Music"])
    private let dir = UInt32(kFSEventStreamEventFlagItemIsDir), file = UInt32(kFSEventStreamEventFlagItemIsFile)

    @Test func filtersEventsThatCannotChangeTheLibrary() {
        #expect(roots.isRelevant(FileEvent(path: "/m/Vol.2", flags: dir)))
        #expect(roots.isRelevant(FileEvent(path: "/m/a.FLAC", flags: file)))
        #expect(roots.isRelevant(FileEvent(path: "/m/a.lrc", flags: file)))
        #expect(!roots.isRelevant(FileEvent(path: "/m/.DS_Store", flags: file)))
        #expect(!roots.isRelevant(FileEvent(path: "/m/cover.jpg", flags: file)))
        #expect(!roots.isRelevant(FileEvent(path: "/m/Music/x.flac", flags: file)))
        #expect(roots.isRelevant(FileEvent(path: "/m", flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs))))
    }
}

struct FSEventsWatcherTests {
    @Test func reportsFileChanges() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "lm-fs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = FSEventsWatcher(paths: [dir.path], latency: 0.1)
        try await Task.sleep(for: .milliseconds(300))
        try Data("x".utf8).write(to: dir.appending(path: "new.flac"))

        let received = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await events in watcher.events where events.contains(where: { $0.path.hasSuffix("new.flac") }) { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(received)
    }
}
