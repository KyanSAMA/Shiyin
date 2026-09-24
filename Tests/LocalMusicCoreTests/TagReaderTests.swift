import Foundation
import Testing
@testable import LocalMusicCore

struct FLACReaderTests {
    private let image = Data((0..<5000).map { UInt8($0 % 251) })

    private func sample() -> Data {
        FLACBuilder.file([
            (0, FLACBuilder.streamInfo(rate: 48000, channels: 2, bitDepth: 24, total: 11_925_333)),
            (4, FLACBuilder.comments(["artist=小山百代", "ARTIST=三森すずこ", "date=", "genre= ", "Title=スペクタクル",
                                      "lyrics=[00:01.00]a\n[00:02.00]b"])),
            (6, FLACBuilder.picture(type: 4, image: Data([1, 2, 3]))),
            (6, FLACBuilder.picture(type: 3, description: "front", image: image)),
            (1, Data(count: 64)),
        ])
    }

    @Test(arguments: [(44100, 2, 16), (48000, 2, 24), (96000, 2, 24), (192_000, 2, 24), (44100, 1, 16)])
    func decodesStreamInfo(rate: Int, channels: Int, bitDepth: Int) throws {
        let total: Int64 = 5_000_000_123
        let data = FLACBuilder.file([(0, FLACBuilder.streamInfo(rate: rate, channels: channels, bitDepth: bitDepth, total: total))])
        let p = try FLACReader.read(DataSource(data)).properties
        #expect(p.sampleRate == rate && p.channels == channels && p.bitDepth == bitDepth && p.frameCount == total)
        #expect(abs(p.duration - Double(total) / Double(rate)) < 1e-9)
    }

    @Test func readsCommentsCaseInsensitivelyKeepingMultipleValues() throws {
        let tags = try FLACReader.read(DataSource(sample())).tags
        #expect(tags["ARTIST"] == ["小山百代", "三森すずこ"])
        #expect(tags.first("TITLE") == "スペクタクル")
        #expect(tags.first("DATE") == nil && tags.first("GENRE") == nil)
        #expect(tags.first("LYRICS") == "[00:01.00]a\n[00:02.00]b")
    }

    @Test func locatesFrontCoverWithoutReadingIt() throws {
        let data = sample()
        let cover = try #require(try FLACReader.read(DataSource(data)).cover)
        #expect(cover.pictureType == 3 && cover.mime == "image/png" && cover.length == image.count)
        #expect(try DataSource(data).read(at: cover.offset!, count: cover.length) == image)
    }

    @Test func skipsLeadingID3Tag() throws {
        let data = ID3Builder.tag(major: 3, [ID3Builder.frame("TIT2", ID3Builder.text(["x"]), major: 3)]) + sample()
        #expect(try FLACReader.read(DataSource(data)).tags.first("TITLE") == "スペクタクル")
    }

    @Test func rejectsMalformedInput() {
        #expect(throws: TagError.invalid("missing fLaC marker")) { try FLACReader.read(DataSource(Data("OggS....".utf8))) }
        #expect(throws: TagError.invalid("missing STREAMINFO")) {
            try FLACReader.read(DataSource(FLACBuilder.file([(4, FLACBuilder.comments([]))])))
        }
    }

    @Test func keepsTagsWhenPictureBlockIsMalformed() throws {
        let data = FLACBuilder.file([
            (0, FLACBuilder.streamInfo(rate: 44100, channels: 2, bitDepth: 16, total: 1000)),
            (6, Data([0, 0, 0, 3, 0xFF, 0xFF, 0xFF, 0xFF])),
            (4, FLACBuilder.comments(["TITLE=ok"])),
        ])
        let track = try FLACReader.read(DataSource(data))
        #expect(track.tags.first("TITLE") == "ok" && track.cover == nil)
    }

    @Test func truncatedFilesThrowInsteadOfCrashing() {
        let data = sample()
        for cut in stride(from: 0, to: data.count, by: max(1, data.count / 200)) {
            #expect(throws: TagError.self) { try FLACReader.read(DataSource(data.prefix(cut))) }
        }
    }
}

struct ID3ReaderTests {
    private func parse(_ data: Data, coverData: Bool = false) throws -> ID3Reader.Tag {
        try #require(try ID3Reader.read(DataSource(data), includeCoverData: coverData))
    }

    @Test(arguments: [UInt8(3), 4], [UInt8(0), 1, 2, 3])
    func decodesEveryTextEncoding(major: UInt8, encoding: UInt8) throws {
        let title = encoding == 0 ? "Café ÿ" : "群青 — YOASOBI"
        let tag = try parse(ID3Builder.tag(major: major, [ID3Builder.frame("TIT2", ID3Builder.text([title], encoding: encoding), major: major)]))
        #expect(tag.tags.first("TITLE") == title)
    }

    @Test func splitsNULSeparatedValues() throws {
        let tag = try parse(ID3Builder.tag(major: 4, [ID3Builder.frame("TPE1", ID3Builder.text(["miwa", "96猫"], encoding: 1), major: 4)]))
        #expect(tag.tags["ARTIST"] == ["miwa", "96猫"])
    }

    @Test func toleratesITunesPlainFrameSizesInV24() throws {
        let long = String(repeating: "长", count: 100)
        let data = ID3Builder.tag(major: 4, [
            ID3Builder.frame("TIT2", ID3Builder.text([long]), major: 4, plainSize: true),
            ID3Builder.frame("TALB", ID3Builder.text(["Album"]), major: 4, plainSize: true),
        ])
        let tag = try parse(data)
        #expect(tag.tags.first("TITLE") == long && tag.tags.first("ALBUM") == "Album")
    }

    @Test func plainSizeDetectionIsNotFooledByFrameContent() throws {
        // A 300-byte USLT body: read as syncsafe its size is 172, landing inside the text right on "LOVE".
        let text = String(repeating: "x", count: 167) + "LOVE" + String(repeating: "y", count: 124)
        let body = ID3Builder.lyrics(text, encoding: 0)
        #expect(body.count == 300 && ID3Builder.syncsafe(172) == Data([0, 0, 1, 0x2C]) && body.subdata(in: 172..<176) == Data("LOVE".utf8))
        let data = ID3Builder.tag(major: 4, [
            ID3Builder.frame("USLT", body, major: 4, plainSize: true),
            ID3Builder.frame("TIT2", ID3Builder.text(["Title"]), major: 4, plainSize: true),
        ])
        let tags = try parse(data).tags
        #expect(tags.first("LYRICS") == text && tags.first("TITLE") == "Title")
    }

    @Test func honoursV24TagLevelUnsynchronisation() throws {
        let frame = ID3Builder.frame("TIT2", ID3Builder.unsync(ID3Builder.text(["标题"], encoding: 1)), major: 4)
        #expect(try parse(ID3Builder.tag(major: 4, [frame], flags: 0x80)).tags.first("TITLE") == "标题")
    }

    @Test func survivesAMalformedFrame() throws {
        let data = ID3Builder.tag(major: 3, [ID3Builder.frame("USLT", Data([3, 0x65]), major: 3),
                                             ID3Builder.frame("TIT2", ID3Builder.text(["ok"]), major: 3)])
        #expect(try parse(data).tags.first("TITLE") == "ok")
    }

    @Test func locatesCoverBehindALongDescription() throws {
        let image = Data((0..<100).map { UInt8($0) })
        let data = ID3Builder.tag(major: 3, [ID3Builder.frame("APIC", ID3Builder.picture(type: 3, image: image,
                                                                                         description: String(repeating: "d", count: 5000), encoding: 0), major: 3)])
        let cover = try #require(try parse(data).cover)
        #expect(cover.length == image.count)
        #expect(try DataSource(data).read(at: cover.offset!, count: cover.length) == image)
    }

    @Test func removesFrameUnsynchronisationInV24() throws {
        let body = ID3Builder.unsync(ID3Builder.text(["aÿb"], encoding: 0))
        let tag = try parse(ID3Builder.tag(major: 4, [ID3Builder.frame("TIT2", body, major: 4, formatFlags: 0x02)]))
        #expect(tag.tags.first("TITLE") == "aÿb")
    }

    @Test func removesTagUnsynchronisationInV23AndDropsCoverOffset() throws {
        let image = Data([0x89, 0xFF, 0x00, 0xFF, 0xE0, 0x42])
        let frames = [ID3Builder.frame("TIT2", ID3Builder.text(["aÿb"], encoding: 0), major: 3),
                      ID3Builder.frame("APIC", ID3Builder.picture(type: 3, image: image), major: 3)]
        let body = ID3Builder.unsync(Data(frames.joined()))
        let data = Data("ID3".utf8) + Data([3, 0, 0x80]) + ID3Builder.syncsafe(body.count) + body
        let tag = try parse(data, coverData: true)
        #expect(tag.tags.first("TITLE") == "aÿb")
        #expect(tag.cover?.offset == nil && tag.coverData == image)
    }

    @Test(arguments: [UInt8(3), 4])
    func skipsExtendedHeader(major: UInt8) throws {
        let extended = major == 4 ? ID3Builder.syncsafe(6) + Data([1, 0]) : be(6, 4) + Data(count: 6)
        let data = ID3Builder.tag(major: major, [ID3Builder.frame("TALB", ID3Builder.text(["X"]), major: major)],
                                  flags: 0x40, extendedHeader: extended)
        #expect(try parse(data).tags.first("ALBUM") == "X")
    }

    @Test func locatesPreferredPictureAndLoadsItOnRequest() throws {
        let front = Data((0..<3000).map { UInt8($0 % 7) }), other = Data([9, 9, 9])
        let data = ID3Builder.tag(major: 3, [
            ID3Builder.frame("APIC", ID3Builder.picture(type: 0, image: other), major: 3),
            ID3Builder.frame("APIC", ID3Builder.picture(type: 3, image: front), major: 3),
        ])
        let cover = try #require(try parse(data).cover)
        #expect(cover.pictureType == 3 && cover.mime == "image/png" && cover.length == front.count)
        #expect(try DataSource(data).read(at: cover.offset!, count: cover.length) == front)
        #expect(try parse(data, coverData: true).coverData == front)
    }

    @Test func readsLyricsNeteaseKeyAndReplayGain() throws {
        let key = ID3Reader.ncmKeyPrefix + "L64FU3W4"
        let data = ID3Builder.tag(major: 3, [
            ID3Builder.frame("USLT", ID3Builder.lyrics("[00:01.00]歌词", encoding: 1), major: 3),
            ID3Builder.frame("COMM", ID3Builder.lyrics(key, encoding: 0), major: 3),
            ID3Builder.frame("COMM", ID3Builder.lyrics("ordinary comment"), major: 3),
            ID3Builder.frame("TXXX", ID3Builder.userText("replaygain_track_gain", "-6.54 dB"), major: 3),
            ID3Builder.frame("TXXX", ID3Builder.userText("OTHER", "x"), major: 3),
        ])
        let tags = try parse(data).tags
        #expect(tags.first("LYRICS") == "[00:01.00]歌词")
        #expect(tags["NCM_KEY"] == [key])
        #expect(tags.first("REPLAYGAIN_TRACK_GAIN") == "-6.54 dB" && tags.first("OTHER") == nil)
    }

    @Test(arguments: [("(17)", "Rock"), ("17", "Rock"), ("(17)Rock & Roll", "Rock & Roll"), ("(RX)", "Remix"), ("Anime", "Anime"), ("(999)", "(999)")])
    func resolvesGenreReferences(raw: String, expected: String) {
        #expect(ID3Genres.resolve(raw) == expected)
    }

    @Test func ignoresAbsentOrUnsupportedTags() throws {
        #expect(try ID3Reader.read(DataSource(Data(count: 64))) == nil)
        let v22 = Data("ID3".utf8) + Data([2, 0, 0]) + ID3Builder.syncsafe(0)
        #expect(try ID3Reader.read(DataSource(v22)) == nil)
    }

    @Test func truncatedTagsNeverCrash() {
        let data = ID3Builder.tag(major: 4, [
            ID3Builder.frame("TIT2", ID3Builder.text(["标题"], encoding: 1), major: 4),
            ID3Builder.frame("APIC", ID3Builder.picture(type: 3, image: Data(count: 500)), major: 4),
            ID3Builder.frame("USLT", ID3Builder.lyrics("x"), major: 4),
        ], padding: 0)
        for cut in 0..<data.count {
            _ = try? ID3Reader.read(DataSource(data.prefix(cut)))
        }
    }
}

@Suite(.enabled(if: FFmpeg.path != nil))
struct AVFormatTests {
    private func temp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "lm-av-\(UUID().uuidString)-\(name)")
    }

    private func sine(_ url: URL, _ extra: [String]) throws {
        let status = try FFmpeg.run(["-f", "lavfi", "-i", "sine=frequency=440:duration=0.3:sample_rate=48000"] + extra + [url.path])
        try #require(status == 0)
    }

    @Test func readsALACInM4A() async throws {
        let url = temp("a.m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try sine(url, ["-c:a", "alac", "-sample_fmt", "s16p", "-metadata", "title=春日影", "-metadata", "artist=MyGO!!!!!",
                       "-metadata", "album=迷跡波", "-metadata", "composer=藤田淳平", "-metadata", "track=3/10", "-metadata", "date=2023"])
        let track = try await TagReader.read(url)
        #expect(track.properties.codec == "alac" && track.properties.bitDepth == 16 && track.properties.sampleRate == 48000)
        let meta = TrackMetadata(tags: track.tags, fileURL: url)
        #expect(meta.title == "春日影" && meta.names(.artist) == ["MyGO!!!!!"] && meta.album == "迷跡波")
        #expect(meta.names(.composer) == ["藤田淳平"] && meta.trackNo == 3 && meta.trackTotal == 10 && meta.year == 2023)
    }

    @Test func readsPCMWave() async throws {
        let url = temp("a.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try sine(url, ["-c:a", "pcm_s24le"])
        let p = try await TagReader.read(url).properties
        #expect(p.codec == "pcm" && p.bitDepth == 24 && p.sampleRate == 48000 && abs(p.duration - 0.3) < 0.01)
    }

    @Test(arguments: ["3", "4"])
    func readsFFmpegWrittenMP3(id3Version: String) async throws {
        let url = temp("a.mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        try sine(url, ["-c:a", "libmp3lame", "-b:a", "128k", "-id3v2_version", id3Version,
                       "-metadata", "title=直到大地变成一颗酸橙", "-metadata", "artist=塞壬唱片-MSR/平林佑人", "-metadata", "track=2"])
        let track = try await TagReader.read(url)
        #expect(track.properties.codec == "mp3" && track.properties.sampleRate == 48000)
        let meta = TrackMetadata(tags: track.tags, fileURL: url)
        #expect(meta.title == "直到大地变成一颗酸橙" && meta.names(.artist) == ["塞壬唱片-MSR", "平林佑人"] && meta.trackNo == 2)
    }
}
