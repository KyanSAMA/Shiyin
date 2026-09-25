import Foundation
import Testing
@testable import LocalMusicCore

struct AudioFingerprintTests {
    private let audio = Data((0..<40_000).map { UInt8($0 % 251) })

    private func print(_ data: Data, _ format: String) throws -> String { try AudioFingerprint.compute(DataSource(data), format: format) }

    @Test func flacHashesTheFramesPastTheMetadataUnlessStreamInfoHasAnMD5() throws {
        var info = FLACBuilder.streamInfo(rate: 44100, channels: 2, bitDepth: 16, total: 1000)
        func file(_ comments: [String], _ frames: Data) -> Data { FLACBuilder.file([(0, info), (4, FLACBuilder.comments(comments))]) + frames }
        let tagged = try print(file(["TITLE=a"], audio), "flac")
        #expect(tagged.hasPrefix("sha:"))
        #expect(try print(file(["TITLE=b", "ARTIST=c"], audio), "flac") == tagged)
        #expect(try print(file(["TITLE=a"], audio + Data([1])), "flac") != tagged)
        info.replaceSubrange(18..<34, with: Data(repeating: 0xAB, count: 16))
        #expect(try print(file([], audio), "flac") == "flac:" + String(repeating: "ab", count: 16))
    }

    @Test func mp3SkipsID3v2AndTrailingTags() throws {
        func tag(_ title: String) -> Data { ID3Builder.tag(major: 3, [ID3Builder.frame("TIT2", ID3Builder.text([title]), major: 3)]) }
        let v1 = Data("TAG".utf8) + Data(count: 125)
        let apeBody = Data(repeating: 7, count: 40)
        let ape = apeBody + Data("APETAGEX".utf8) + le32(2000) + le32(apeBody.count + 32) + le32(1) + le32(0) + Data(count: 8)
        let lyrics3 = Data("LYRICSBEGIN".utf8) + Data("IND00002".utf8) + Data("10".utf8)
        let lyrics3Tag = lyrics3 + Data(String(format: "%06d", lyrics3.count).utf8) + Data("LYRICS200".utf8)
        let plain = try print(tag("a") + audio, "mp3")
        #expect(try print(tag("a longer title") + audio + v1, "mp3") == plain)
        #expect(try print(audio + ape + lyrics3Tag + v1, "mp3") == plain)
        #expect(try print(audio, "mp3") == plain)
    }

    @Test func malformedContainersFallBackToTheWholeFile() throws {
        let oversized = Data("ID3".utf8) + Data([3, 0, 0]) + ID3Builder.syncsafe(1 << 20) + audio
        #expect(try print(oversized, "mp3").hasPrefix("sha:"))
        let hugeAtom = be(1, 4) + Data("free".utf8) + Data(repeating: 0x7F, count: 8) + audio
        #expect(try print(hugeAtom, "m4a").hasPrefix("sha:"))
        let silentIntro = Data(count: 20_000)
        #expect(try print(silentIntro + audio, "mp3") != print(silentIntro + audio.reversed(), "mp3"))
    }

    @Test func wavHashesTheDataChunkOnly() throws {
        func wav(_ list: String) -> Data {
            let info = Data(list.utf8)
            let chunks = Data("fmt ".utf8) + le32(16) + Data(count: 16) + Data("LIST".utf8) + le32(info.count) + info
                + Data(count: info.count & 1) + Data("data".utf8) + le32(audio.count) + audio
            return Data("RIFF".utf8) + le32(4 + chunks.count) + Data("WAVE".utf8) + chunks
        }
        #expect(try print(wav("INFOodd"), "wav") == print(wav("INFOeven"), "wav"))
    }

    @Test func m4aHashesTheMdatAtomOnly() throws {
        func atom(_ type: String, _ body: Data) -> Data { be(8 + body.count, 4) + Data(type.utf8) + body }
        let short = atom("ftyp", Data("M4A ".utf8)) + atom("moov", Data("tags".utf8)) + atom("mdat", audio)
        let wide = atom("ftyp", Data("M4A ".utf8)) + atom("moov", Data("other tags".utf8)) + be(1, 4) + Data("mdat".utf8)
            + be(16 + audio.count, 8) + audio
        #expect(try print(short, "m4a") == print(wide, "m4a"))
    }
}
