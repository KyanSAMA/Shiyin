import Foundation
import Testing
@testable import LocalMusicCore

struct TagFileTests {
    private let info = FLACBuilder.streamInfo(rate: 44100, channels: 2, bitDepth: 16, total: 1000)
    private let frames = Data([0xFF, 0xF8, 1, 2, 3, 4])

    private func edited(_ file: Data, _ edit: TagEdit) throws -> (FLACTagFile, Data) {
        var tags = try FLACTagFile(DataSource(file))
        try tags.apply(edit)
        let region = tags.serialized()
        let prefix = file.prefix(Int(tags.start)), rest = file.dropFirst(Int(tags.start + tags.length))
        return (tags, prefix + region + rest)
    }

    private func comments(_ file: Data) throws -> [String] {
        let tags = try FLACTagFile(DataSource(file))
        return try FLACTagFile.Comments(try #require(tags.blocks.first { $0.type == 4 }).body).entries.map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func flacCommentsReplaceAliasesCaseInsensitivelyAndKeepTheRest() throws {
        let file = FLACBuilder.file([(0, info), (4, FLACBuilder.comments(["title=Old", "ARTIST=A", "ENCODER=x", "TRACKNUMBER=3/12", "YEAR=1999",
                                                                          "unsyncedlyrics=old", "COMMENT=ad"], vendor: "vendor")),
                                     (1, Data(count: 4096))]) + frames
        var edit = TagEdit()
        (edit.title, edit.artists, edit.trackNo, edit.year, edit.lyrics) = ("New", ["B", "C"], 5, 2020, "[00:01.00]hi")
        let (_, out) = try edited(file, edit)
        #expect(try comments(out) == ["TITLE=New", "ARTIST=B", "ARTIST=C", "ENCODER=x", "TRACKNUMBER=5/12", "DATE=2020", "LYRICS=[00:01.00]hi", "COMMENT=ad"])
        #expect(try FLACTagFile.Comments(try #require(try FLACTagFile(DataSource(out)).blocks.first { $0.type == 4 }).body).vendor == Data("vendor".utf8))
        #expect(out.count == file.count && out.suffix(frames.count) == frames)   // fitted into the old padding
        let read = try FLACReader.read(DataSource(out))
        #expect(read.tags["ARTIST"] == ["B", "C"] && read.tags.first("TITLE") == "New")
    }

    @Test func flacKeepsEntriesInOtherEncodingsByteForByte() throws {
        let gbk = Data("ARTIST=".utf8) + Data([0xB4, 0xBA, 0xC8, 0xD5])   // "春日" in GBK, not UTF-8
        var comments = le32(1) + Data("v".utf8) + le32(2)
        for entry in [Data("TITLE=a".utf8), gbk] { comments += le32(entry.count) + entry }
        var edit = TagEdit()
        edit.title = "b"
        let out = try edited(FLACBuilder.file([(0, info), (4, comments)]) + frames, edit).1
        #expect(try FLACTagFile.Comments(try #require(try FLACTagFile(DataSource(out)).blocks.first { $0.type == 4 }).body).entries
                == [Data("TITLE=b".utf8), gbk])
    }

    @Test func flacKeepsOtherBlocksAndReplacesOnlyFrontCovers() throws {
        let seek = Data(repeating: 7, count: 18), app = Data("APPLxyz".utf8)
        let back = FLACBuilder.picture(type: 4, image: Data([9])), front = FLACBuilder.picture(type: 3, image: Data([1]))
        let other = FLACBuilder.picture(type: 0, image: Data([2]))
        let id3 = ID3Builder.tag(major: 3, [ID3Builder.frame("TIT2", ID3Builder.text(["x"], encoding: 0), major: 3)])
        let file = FLACBuilder.file([(0, info), (3, seek), (6, front), (2, app), (6, back), (6, other)], prefix: id3) + frames
        var edit = TagEdit()
        edit.cover = try TagEdit.Cover(Self.png)
        let (tags, out) = try edited(file, edit)
        #expect(out.prefix(id3.count) == id3 && tags.start == Int64(id3.count + 4))
        let blocks = try FLACTagFile(DataSource(out)).blocks
        #expect(blocks.map(\.type) == [0, 4, 3, 6, 2, 6])
        #expect(blocks[2].body == seek && blocks[4].body == app && blocks[5].body == back)
        #expect(try FLACReader.read(DataSource(out)).cover?.length == Self.png.count)
        #expect(out.count > file.count && out.suffix(frames.count) == frames)   // no padding before: grown, 8 KiB left
        #expect(try FLACTagFile(DataSource(out)).length == Int64(blocks.reduce(0) { $0 + 4 + $1.body.count } + 4 + FLACTagFile.growPadding))
    }

    @Test func flacGrowsRatherThanLeaveTooLittleForAPaddingHeader() throws {
        func file(padding: Int?) -> Data {
            let blocks: [(type: UInt8, body: Data)] = [(0, info), (4, FLACBuilder.comments([], vendor: "v"))] + (padding.map { [(type: UInt8(1), body: Data(count: $0))] } ?? [])
            return FLACBuilder.file(blocks) + frames
        }
        var edit = TagEdit()
        edit.album = "ab"   // "ALBUM=ab" and its 4-byte length: 12 bytes more
        #expect(try edited(file(padding: nil), edit).1.count == file(padding: nil).count + 12 + 4 + FLACTagFile.growPadding)
        #expect(try edited(file(padding: 8), edit).1.count == file(padding: 8).count)     // exactly the old length, no padding block
        #expect(try edited(file(padding: 20), edit).1.count == file(padding: 20).count)   // the rest stays padding
        // 14 bytes free: 2 over a padding block's header, too few for another; grown instead.
        #expect(try edited(file(padding: 10), edit).1.count == file(padding: 10).count - 14 + 12 + 4 + FLACTagFile.growPadding)
    }

    @Test func id3KeepsItsVersionAndUnknownFramesVerbatim() throws {
        for major: UInt8 in [3, 4] {
            let comm = ID3Builder.frame("COMM", Data([0]) + Data("eng".utf8) + Data([0]) + Data((ID3Reader.ncmKeyPrefix + "abc").utf8), major: major)
            let txxx = ID3Builder.frame("TXXX", ID3Builder.userText("REPLAYGAIN_TRACK_GAIN", "-6 dB", encoding: 0), major: major)
            let back = ID3Builder.frame("APIC", ID3Builder.picture(type: 4, image: Data([9])), major: major)
            let tag = ID3Builder.tag(major: major, [
                ID3Builder.frame("TIT2", ID3Builder.text(["Old"], encoding: 0), major: major), comm,
                ID3Builder.frame("TRCK", ID3Builder.text(["2/9"], encoding: 0), major: major), txxx,
                ID3Builder.frame("APIC", ID3Builder.picture(type: 3, image: Data([1])), major: major), back,
                ID3Builder.frame("USLT", ID3Builder.lyrics("old", encoding: 0), major: major),
            ], padding: 2048)
            var file = try ID3TagFile(DataSource(tag + frames))
            var edit = TagEdit()
            (edit.title, edit.artists, edit.trackNo, edit.lyrics) = ("春日影", ["A", "B"], 5, "[00:01.00]新")
            edit.cover = try TagEdit.Cover(Self.png)
            file.apply(edit)
            let out = file.serialized()
            #expect(out.count == tag.count && out[3] == major)
            #expect(out.range(of: comm) != nil && out.range(of: txxx) != nil && out.range(of: back) != nil)
            let read = try #require(try ID3Reader.read(DataSource(out + frames), includeCoverData: true))
            #expect(read.tags.first("TITLE") == "春日影" && PersonSplitter.split(read.tags["ARTIST"]) == ["A", "B"] && read.tags.first("TRACKNUMBER") == "5/9")
            #expect(read.tags.first("LYRICS") == "[00:01.00]新" && read.coverData == Self.png && read.tags.first("NCM_KEY") != nil)
            #expect(try ID3TagFile(DataSource(out)).frames.first { $0.id == "USLT" }?.body.dropFirst().prefix(3) == Data("eng".utf8))
        }
    }

    @Test func id3HandlesUnsyncITunesSizesMissingTagsAndRefusesV22() throws {
        let v23 = ID3Builder.tag(major: 3, [ID3Builder.frame("TIT2", ID3Builder.text(["\u{FF}x"], encoding: 0), major: 3)], flags: 0x80)
        let unsynced = v23.prefix(10) + ID3Builder.unsync(v23.dropFirst(10))
        var file = try ID3TagFile(DataSource(Data(unsynced)))
        #expect(file.frames.first?.body == ID3Builder.text(["\u{FF}x"], encoding: 0))
        file.apply(TagEdit())
        #expect(file.serialized()[5] == 0)   // written without tag-level unsync

        let plain = ID3Builder.tag(major: 4, [ID3Builder.frame("TIT2", ID3Builder.text([String(repeating: "a", count: 200)]), major: 4, plainSize: true),
                                              ID3Builder.frame("TALB", ID3Builder.text(["b"]), major: 4, plainSize: true)])
        var itunes = try ID3TagFile(DataSource(plain))
        #expect(itunes.frames.map(\.id) == ["TIT2", "TALB"])
        var edit = TagEdit()
        edit.album = "c"
        itunes.apply(edit)
        #expect(try ID3Reader.read(DataSource(itunes.serialized()))?.tags.first("ALBUM") == "c")

        let garbage = ID3Builder.tag(major: 3, [ID3Builder.frame("TIT2", ID3Builder.text(["x"], encoding: 0), major: 3), Data("COM x".utf8)], padding: 8)
        #expect(throws: TagWriteError.self) { try ID3TagFile(DataSource(garbage)) }   // the rest would be lost

        var none = try ID3TagFile(DataSource(frames))
        none.apply(edit)
        let created = none.serialized()
        #expect(created[3] == 3 && created.count == 10 + 11 + 1 + ID3TagFile.growPadding)
        #expect(throws: TagWriteError.self) { try ID3TagFile(DataSource(Data("ID3".utf8) + Data([2, 0, 0, 0, 0, 0, 0]))) }
    }

    /// A 1×1 PNG.
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
}

@Suite(.enabled(if: FFmpeg.path != nil))
struct TagWriterTests {
    private func audio(_ name: String, _ extra: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "lm-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        #expect(try FFmpeg.run(["-f", "lavfi", "-i", "sine=frequency=440:duration=1:sample_rate=44100"] + extra + [url.path]) == 0)
        return url
    }

    @Test(arguments: [("a.flac", ["-metadata", "title=Old", "-metadata", "artist=X"]),
                      ("a.mp3", ["-c:a", "libmp3lame", "-id3v2_version", "3", "-metadata", "title=Old"]),
                      ("b.mp3", ["-c:a", "libmp3lame", "-id3v2_version", "4", "-metadata", "title=Old"])])
    func writesVerifiesAndRestoresByteForByte(name: String, extra: [String]) async throws {
        let url = try audio(name, extra)
        let before = try Data(contentsOf: url), fingerprint = try await TagReader.read(url).fingerprint
        var edit = TagEdit()
        (edit.title, edit.artists, edit.album, edit.year, edit.lyrics) = ("春日影", ["MyGO!!!!!", "B"], "迷跡波", 2023, "[00:00.50]悴んだ心")
        edit.cover = try TagEdit.Cover(TagFileTests.png)
        var original: TagWriter.Original?
        _ = try await TagWriter.write(edit, to: url) { original = $0 }
        let raw = try await TagReader.read(url)
        let meta = TrackMetadata(tags: raw.tags, fileURL: url)
        #expect(meta.title == "春日影" && meta.names(.artist) == ["MyGO!!!!!", "B"] && meta.album == "迷跡波" && meta.year == 2023)
        #expect(meta.lyrics == "[00:00.50]悴んだ心" && raw.fingerprint == fingerprint)
        let cover = try await TagReader.coverData(url, try #require(raw.cover))
        #expect(cover == TagFileTests.png)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).contains { $0.contains(TagRegion.temporaryMarker) })

        _ = try await TagWriter.restore(url, to: try #require(original))
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func refusesUnsafeFilesAndLeavesTheOriginalWhenVerificationFails() async throws {
        let url = try audio("c.mp3", ["-c:a", "libmp3lame", "-metadata", "title=Old"])
        let before = try Data(contentsOf: url)
        let version = try FileVersion(url)
        await #expect(throws: TagWriteError.verification("x")) {
            _ = try await TagRegion.commit(url, start: 0, length: 0, bytes: Data("x".utf8), expecting: version) { _ in throw TagWriteError.verification("x") }
        }
        #expect(try Data(contentsOf: url) == before)

        // Changed underneath: the original wins.
        await #expect(throws: TagWriteError.changed) {
            _ = try await TagRegion.commit(url, start: 0, length: 0, bytes: Data(), expecting: version) { _ in
                try Data(before + Data([0])).write(to: url)
            }
        }
        #expect(try !FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).contains { $0.contains(TagRegion.temporaryMarker) })

        // A rewrite that grows the file gets a new modification time (caches and the scanner go by it).
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        var cover = TagEdit()
        cover.cover = try TagEdit.Cover(Data(count: 0) + TagFileTests.png)
        cover.lyrics = String(repeating: "[00:01.00]歌\n", count: 2000)
        _ = try await TagWriter.write(cover, to: url) { _ in }
        #expect(try FileVersion(url).mtime > old.timeIntervalSince1970 + 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        await #expect(throws: TagWriteError.self) { _ = try await TagWriter.write(cover, to: url) { _ in } }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        let link = url.deletingLastPathComponent().appending(path: "link.mp3")
        try FileManager.default.linkItem(at: url, to: link)
        var edit = TagEdit()
        edit.genre = "Rock"
        await #expect(throws: TagWriteError.self) { _ = try await TagWriter.write(edit, to: link) { _ in } }
        let wav = try audio("d.wav", [])
        await #expect(throws: TagWriteError.self) { _ = try await TagWriter.write(edit, to: wav) { _ in } }
    }
}
