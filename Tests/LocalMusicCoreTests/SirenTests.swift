import AVFAudio
import Foundation
import Synchronization
import Testing
@testable import LocalMusicCore

/// Serialized: the tests serve different audio under one recorded name.
@Suite(.serialized) struct SirenTests {
    static let albums = #"{"code":0,"data":[{"cid":"8928","name":" 直到大地变成一颗酸橙OST","coverUrl":"https://web.hycdn.cn/siren/pic/a.png","artistes":["塞壬唱片-MSR"]}]}"#
    static let songs = #"{"code":0,"data":{"list":[{"cid":"697674","name":"直到大地变成一颗酸橙","albumCid":"8928","artists":["塞壬唱片-MSR"]}],"autoplay":null}}"#
    static let album = #"""
        {"code":0,"data":{"cid":"8928","name":" 直到大地变成一颗酸橙OST","intro":"启程吧。","coverUrl":"https://web.hycdn.cn/siren/pic/a.png",
         "songs":[{"cid":"232219","name":"用不上的雨刷","artistes":["塞壬唱片-MSR"]},{"cid":"697674","name":"直到大地变成一颗酸橙","artistes":["塞壬唱片-MSR"]}]}}
        """#
    static let song = #"""
        {"code":0,"data":{"cid":"697674","name":"直到大地变成一颗酸橙","albumCid":"8928","sourceUrl":"https://res01.hycdn.cn/x/siren/audio/t-697674.wav",
         "lyricUrl":"https://web.hycdn.cn/siren/lyric/t-697674.lrc","artists":["塞壬唱片-MSR"," 平林佑人"]}}
        """#

    private func client(audio: Data = Data("RIFF".utf8)) throws -> OnlineClient {
        try OnlineTestFixtures.client([("siren/albums.json", Data(Self.albums.utf8)), ("siren/songs.json", Data(Self.songs.utf8)),
                                       ("siren/album/8928.json", Data(Self.album.utf8)), ("siren/song/697674.json", Data(Self.song.utf8)),
                                       ("siren/lyric/t-697674.lrc", Data("[00:01.27]监制: MSR\n\n[00:29.67]Beyond silent skies\n\n".utf8)),
                                       ("siren/audio/t-697674.wav", audio)])
    }

    private func temporary(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "lm-siren-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: name)
    }

    @Test func parsesTheCatalogue() async throws {
        let client = try client()
        let albums = try await client.sirenAlbums()
        #expect(albums == [Siren.Album(id: "8928", name: "直到大地变成一颗酸橙OST", coverURL: URL(string: "https://web.hycdn.cn/siren/pic/a.png"),
                                       artists: ["塞壬唱片-MSR"])])
        #expect(try await client.sirenSongs().map(\.albumID) == ["8928"])
        let detail = try await client.sirenAlbum("8928")
        #expect(detail.songs.map(\.name) == ["用不上的雨刷", "直到大地变成一颗酸橙"] && detail.intro == "启程吧。")
        let source = try await client.sirenSource("697674")
        #expect(source.format == "wav" && source.artists == ["塞壬唱片-MSR", "平林佑人"])
        #expect(try await client.sirenLyrics(source) == "[00:01.27]监制: MSR\n[00:29.67]Beyond silent skies")
        let edit = Siren.edit(detail.songs[1], in: detail, artists: source.artists, lyrics: nil, cover: nil)
        #expect(edit.trackNo == 2 && edit.album == "直到大地变成一颗酸橙OST" && edit.albumArtist == "塞壬唱片-MSR")
    }

    @Test func downloadsWithProgressAndNeverReplacesAFile() async throws {
        let audio = Data((0..<300_000).map { UInt8($0 & 0xff) })
        let client = try client(audio: audio)
        let url = URL(string: "https://res01.hycdn.cn/x/siren/audio/t-697674.wav")!
        let file = try temporary("a.wav")
        let seen = Mutex<[(Int64, Int64?)]>([])
        try await client.download(url, to: file) { received, expected in seen.withLock { $0.append((received, expected)) } }
        #expect(try Data(contentsOf: file) == audio)
        #expect(seen.withLock { $0.last.map { $0.0 == 300_000 && $0.1 == 300_000 } } == true)
        await #expect(throws: OnlineError.self) { try await client.download(url, to: file) { _, _ in } }
        #expect(try Data(contentsOf: file) == audio)
        let missing = try temporary("b.wav")
        await #expect(throws: OnlineError.http(404)) {
            try await client.download(URL(string: "https://res01.hycdn.cn/x/siren/audio/none.wav")!, to: missing) { _, _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func aCancelledDownloadEndsAndLeavesNothing() async throws {
        let client = try client(audio: Data(count: 300_000))
        let file = try temporary("c.wav")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await client.download(URL(string: "https://res01.hycdn.cn/x/siren/audio/t-697674.wav")!, to: file) { _, _ in }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test(arguments: [(16, 44100.0, 2), (24, 48000.0, 2), (24, 96000.0, 2), (16, 44100.0, 1)])
    func convertsWAVSampleForSample(bits: Int, rate: Double, channels: Int) async throws {
        let wav = try temporary("t.wav"), flac = wav.deletingPathExtension().appendingPathExtension("flac")
        let common: AVAudioCommonFormat = bits == 16 ? .pcmFormatInt16 : .pcmFormatInt32
        do {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                                           AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            let file = try AVAudioFile(forWriting: wav, settings: settings, commonFormat: common, interleaved: false)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 70_001))
            buffer.frameLength = 70_001
            var generator = SystemRandomNumberGenerator()
            for channel in 0..<channels {
                for i in 0..<Int(buffer.frameLength) {
                    if bits == 16 { buffer.int16ChannelData![channel][i] = Int16.random(in: .min ... .max, using: &generator) }
                    else { buffer.int32ChannelData![channel][i] = Int32.random(in: .min ... .max, using: &generator) & ~0xff }
                }
            }
            try file.write(from: buffer)
            file.close()
        }
        try FLACConvert.convert(wav, to: flac)
        func samples(_ url: URL) throws -> [[Int32]] {
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt32, interleaved: false)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            return (0..<channels).map { Array(UnsafeBufferPointer(start: buffer.int32ChannelData![$0], count: Int(buffer.frameLength))) }
        }
        #expect(try samples(flac) == samples(wav))
        let raw = try await TagReader.read(flac)
        #expect(raw.properties.bitDepth == bits && raw.properties.sampleRate == Int(rate) && raw.fingerprint != nil)
    }

    @Test func downloadsAWAVAsATaggedFLAC() async throws {
        let wav = try temporary("src.wav")
        do {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000.0, AVNumberOfChannelsKey: 2,
                                           AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            let file = try AVAudioFile(forWriting: wav, settings: settings, commonFormat: .pcmFormatInt32, interleaved: false)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800))
            buffer.frameLength = 4800
            for channel in 0..<2 { for i in 0..<4800 { buffer.int32ChannelData![channel][i] = Int32(truncatingIfNeeded: i &* 7919 &* (channel + 3)) << 8 } }
            try file.write(from: buffer)
            file.close()
        }
        let client = try client(audio: try Data(contentsOf: wav))
        let detail = try await client.sirenAlbum("8928"), folder = wav.deletingLastPathComponent().appending(path: "lib")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: "直到大地变成一颗酸橙.flac"))
        let placed = try await Siren.download(detail.songs[1], in: detail, cover: nil, client: client, to: folder, naming: .title) { _, _ in }
        #expect(placed.lastPathComponent == "直到大地变成一颗酸橙 (直到大地变成一颗酸橙OST).flac")
        let raw = try await TagReader.read(placed)
        let meta = TrackMetadata(tags: raw.tags, fileURL: placed)
        #expect(raw.properties.bitDepth == 24 && meta.trackNo == 2 && meta.albumArtist == "塞壬唱片-MSR" && meta.names(.artist) == ["塞壬唱片-MSR", "平林佑人"])
        #expect(meta.lyrics == "[00:01.27]监制: MSR\n[00:29.67]Beyond silent skies")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == [placed.lastPathComponent, "直到大地变成一颗酸橙.flac"].sorted())
    }

    @Test func ownsByTitleButNotAnotherVersion() {
        func row(_ title: String) -> TrackRow {
            TrackRow(id: 1, path: "/m/\(title).mp3", title: title, album: nil, albumArtist: nil, artists: [], composers: [], trackNo: nil,
                     discNo: nil, year: nil, genre: nil, duration: 1, format: "mp3", codec: nil, sampleRate: nil, bitDepth: nil,
                     hasCover: false, coverOffset: nil, coverLength: nil, hasLyrics: false, addedAt: .now, fileMtime: 0)
        }
        let owned = Siren.Owned([row("直到大地變成一顆酸橙"), row("Beyond Silent Skies")])
        func song(_ name: String) -> Siren.Song { Siren.Song(id: "1", name: name, albumID: "1", artists: []) }
        #expect(owned.rows(song("直到大地变成一颗酸橙")).count == 1)
        #expect(owned.rows(song("beyond silent skies")).count == 1)
        #expect(owned.rows(song("直到大地变成一颗酸橙 (Instrumental)")).isEmpty)
        #expect(Siren.Owned([row("♪")]).rows(song("……")).isEmpty)
    }
}
