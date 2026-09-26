import CoreServices
import Foundation
import Testing
@testable import LocalMusicCore

/// Temp library of synthetic FLAC headers (the scanner never decodes audio, so no real frames are needed).
final class TempLibrary {
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
    func run(_ sql: String) throws { try db.run(sql) }
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

    @Test func movedFilesKeepTheirRowAndLikes() async throws {
        let lib = try TempLibrary()
        let one = try lib.flac("One.flac", ["TITLE=One"])
        try lib.flac("Two.flac", ["TITLE=Two"])
        _ = try await lib.scan()
        let ids = Dictionary(uniqueKeysWithValues: try await lib.store.rows().map { ($0.title, $0.id) })
        try await lib.store.setLiked([ids["One"]!, ids["Two"]!], true)

        try FileManager.default.createDirectory(at: lib.root.appending(path: "Sub"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: one, to: lib.root.appending(path: "Sub/Renamed.flac"))
        let moved = try await lib.scan()
        #expect(moved.removed == 0 && moved.added == 0 && moved.updated == 1)
        let row = try #require(try await lib.store.rows().first { $0.title == "One" })
        #expect(row.id == ids["One"] && row.path.hasSuffix("Sub/Renamed.flac"))
        // An analysis queued before the move names the old path: dropped rather than recorded as a failure.
        let stale = LoudnessJob(trackID: row.id, url: one, size: 0, mtime: row.fileMtime)
        try await lib.store.saveLoudness(stale, .failure(CocoaError(.fileNoSuchFile)))
        #expect(try await lib.count("SELECT COUNT(*) FROM loudness") == 0)

        try FileManager.default.removeItem(at: lib.root.appending(path: "Two.flac"))
        #expect(try await lib.scan().removed == 1)
        try await lib.store.setLiked([ids["Two"]!, ids["One"]!], true)   // Two is gone: skipped, not a failed transaction
        #expect(try await Set(lib.store.liked().keys) == [ids["One"]!])
        try await lib.store.setLiked([ids["One"]!], false)
        #expect(try await lib.store.liked().isEmpty)
    }

    @Test func playlistsKeepOrderAndFollowTrackRemoval() async throws {
        let lib = try TempLibrary()
        for title in ["A", "B", "C"] { try lib.flac("\(title).flac", ["TITLE=\(title)"]) }
        _ = try await lib.scan()
        let ids = Dictionary(uniqueKeysWithValues: try await lib.store.rows().map { ($0.title, $0.id) })
        let (a, b, c) = (ids["A"]!, ids["B"]!, ids["C"]!)

        let first = try await lib.store.createPlaylist("一", tracks: [c, a, c, 999])
        #expect(first.trackIDs == [c, a])
        let second = try await lib.store.createPlaylist("二", tracks: [])
        try await lib.store.setPlaylistTracks(first.id, [a, b, c])
        try await lib.store.renamePlaylist(second.id, "Two")
        #expect(try await lib.store.playlists() == [Playlist(id: first.id, name: "一", trackIDs: [a, b, c]),
                                                    Playlist(id: second.id, name: "Two", trackIDs: [])])

        try FileManager.default.removeItem(at: lib.root.appending(path: "B.flac"))
        _ = try await lib.scan()
        #expect(try await lib.store.playlists()[0].trackIDs == [a, c])
        try await lib.store.deletePlaylist(first.id)
        #expect(try await lib.store.playlists().map(\.name) == ["Two"])
        #expect(try await lib.count("SELECT COUNT(*) FROM playlist_item") == 0)
    }

    @Test func enrichmentFillsGapsEditsWinAndBothFollowTheRecording() async throws {
        let lib = try TempLibrary()
        let url = try lib.flac("01 From Name.flac", ["ARTIST=A", "ALBUM=Tagged"])
        _ = try await lib.scan()
        let fingerprint = try #require(try await lib.store.rows().first?.fingerprint)
        let netease: [EnrichField: String?] = [.title: "Net", .album: "Net Album", .year: "2020", .artists: EnrichField.encode(["N"]),
                                               .composers: EnrichField.encode(["C"]), .lyrics: "[00:01.00]hi"]
        try await lib.store.setEnrichment([fingerprint], netease, source: .online(.netease))
        var row = try #require(try await lib.store.rows().first)
        #expect(row.title == "Net" && row.album == "Tagged" && row.year == 2020 && row.artists == ["A"] && row.composers == ["C"])
        #expect(row.hasLyrics && row.trackNo == 1 && row.inferred == [.trackNo])
        try await lib.store.setEnrichment([fingerprint], [.trackNo: "7"], source: .online(.netease))
        row = try #require(try await lib.store.rows().first)
        #expect(row.trackNo == 7 && row.inferred.isEmpty)   // "01 From Name" only inferred it
        guard case .synced(let lines)? = try await lib.store.lyrics(for: row.id) else { Issue.record("no enriched lyrics"); return }
        #expect(lines.map(\.text) == ["hi"])

        try await lib.store.setEnrichment([fingerprint], [.title: "Mine", .album: "My Album"], source: .user)
        let bytes = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        _ = try await lib.scan()
        try bytes.write(to: lib.root.appending(path: "Back.flac"))
        _ = try await lib.scan()
        row = try #require(try await lib.store.rows().first)
        #expect(row.title == "Mine" && row.album == "My Album" && row.fingerprint == fingerprint)
        #expect(try await lib.store.rows([row.id], without: [.user]).first?.title == "Net")

        try await lib.store.clearEnrichment([fingerprint], source: .user)
        #expect(try await lib.store.rows().first?.album == "Tagged")

        // Online layers show in the user's order.
        try await lib.store.setEnrichment([fingerprint], [.title: "QQ", .genre: "Pop", .lyrics: "[00:01.00]qq"], source: .online(.qq))
        row = try #require(try await lib.store.rows().first)
        #expect(row.title == "Net" && row.genre == "Pop")
        try await lib.store.setSetting(OnlineSettings.key, OnlineSettings(order: [.qq], disabled: [], storefront: "jp"))
        #expect(try await lib.store.rows().first?.title == "QQ")
        guard case .synced(let qq)? = try await lib.store.lyrics(for: row.id) else { Issue.record("no enriched lyrics"); return }
        #expect(qq.map(\.text) == ["qq"])
        #expect(try await lib.store.rows(without: EnrichSource.allOnline).first?.title == "Back")

        try await lib.store.run("UPDATE track SET fingerprint = NULL")
        #expect(try await lib.scan().parsed == 1)
        #expect(try await lib.store.rows().first?.fingerprint == fingerprint)
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

    @Test func manualCoversAndLyricsShowOverTheFilesOwn() async throws {
        let lib = try TempLibrary()
        try lib.flac("One.flac", ["TITLE=One", "LYRICS=[00:01.00]file"])
        try Data("jpeg".utf8).write(to: lib.root.appending(path: "cover.jpg"))
        _ = try await lib.scan()
        var row = try #require(try await lib.store.rows().first)
        let fingerprint = try #require(row.fingerprint)
        func lyrics() async throws -> [String] {
            guard case .synced(let lines)? = try await lib.store.lyrics(for: row.id) else { return [] }
            return lines.map(\.text)
        }
        try await lib.store.setEnrichment([fingerprint], [.lyrics: "[00:01.00]online", .cover: "online.jpg"], source: .online(.qq))
        row = try #require(try await lib.store.rows().first)
        #expect(try await lyrics() == ["file"] && ArtworkCache.source(for: row)?.key.hasPrefix("f") == true)
        try await lib.store.setEnrichment([fingerprint], [.lyrics: "[00:01.00]mine", .cover: "mine.jpg"], source: .user)
        row = try #require(try await lib.store.rows().first)
        #expect(try await lyrics() == ["mine"] && row.userCover && ArtworkCache.source(for: row)?.folderImage?.lastPathComponent == "mine.jpg")
    }

    @Test func flagsWhatTheTagsDontCarryYet() async throws {
        let lib = try TempLibrary()
        try lib.flac("One.flac", ["TITLE=One", "ALBUM=Tagged", "TRACKNUMBER=1", "LYRICS=[00:00.00]作曲 : X\n[00:01.00]file"])
        _ = try await lib.scan()
        let fingerprint = try #require(try await lib.store.rows().first { $0.title == "One" }?.fingerprint)
        func unwritten() async throws -> Bool { try #require(try await lib.store.rows().first { $0.title == "One" }).unwritten }
        #expect(try await !unwritten())
        try await lib.store.setEnrichment([fingerprint], [.album: "Tagged", .year: "2020"], source: .online(.qq))
        #expect(try await unwritten())                          // an online year the file lacks
        try await lib.store.setEnrichment([fingerprint], [.year: nil], source: .online(.qq))
        #expect(try await !unwritten())                         // an online album the file has isn't written
        try await lib.store.setEnrichment([fingerprint], [.album: "Tagged"], source: .user)
        #expect(try await !unwritten())                         // a manual value equal to the file's
        try await lib.store.setEnrichment([fingerprint], [.album: "Mine"], source: .user)
        #expect(try await unwritten())
        try await lib.store.setEnrichment([fingerprint], [.album: nil, .trackNo: "01", .composers: EnrichField.encode(["X"])], source: .user)
        #expect(try await !unwritten())                         // "01" is the file's 1; the credited composer is the file's
        try await lib.store.setEnrichment([fingerprint], [.trackNo: nil, .composers: nil, .lyrics: "[00:00.00]作曲 : X\n[00:01.00]file\n"], source: .user)
        #expect(try await !unwritten())                         // manual lyrics the file embeds (compared trimmed)
        try await lib.store.setEnrichment([fingerprint], [.lyrics: nil], source: .user)
        try await lib.store.setEnrichment([fingerprint], [.lyrics: "[00:01.00]online"], source: .online(.qq))
        #expect(try await !unwritten())                         // online lyrics don't replace the file's
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
