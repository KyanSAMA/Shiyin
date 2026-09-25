import CommonCrypto
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

struct NeteaseTests {
    /// Trimmed from real responses (2026-09).
    static let search = #"""
        {"code":200,"result":{"songCount":3,"songs":[
         {"id":1472480890,"name":"群青","ar":[{"name":"YOASOBI"}],"al":{"name":"群青","picUrl":"http://p2.music.126.net/a/1.jpg"},"dt":248444,"no":1,"cd":"01","publishTime":1598889600000},
         {"id":1500151581,"name":"群青","ar":[{"name":"YOASOBI"}],"al":{"name":"THE BOOK","picUrl":"http://p2.music.126.net/b/2.jpg"},"dt":248444,"no":6,"cd":"01","publishTime":1609862400000},
         {"id":2007396062,"name":"群青 (Remix)","ar":[{"name":"DJ Agos"},{"name":"Ayase"}],"al":{"name":"My Soul"},"dt":245351,"no":5,"cd":"01","publishTime":1671120000000}]}}
        """#
    static let detail = #"""
        {"code":200,"songs":[{"id":418602075,"name":"シャンランラン feat.96猫","artists":[{"name":"miwa"},{"name":"96猫"}],"no":1,"disc":"1","duration":243026,
         "album":{"name":"Princess(期間生産限定アニメ盤)","picUrl":"https://p2.music.126.net/c/3.jpg","publishTime":1466524800007}}]}
        """#
    static let lyric = #"""
        {"code":200,"lrc":{"lyric":"[00:00.00] 作词 : miwa\n[00:00.07] 作曲 : miwa/NAOKI-T\n[00:00.44]シャンランランラン\n[00:03.45]空を飛んでこの街を見渡すの\n"},
         "tlyric":{"lyric":"[by:someone]\n[00:00.440]莎啦啦啦\n[00:03.45]飞上天空眺望这条街道\n"}}
        """#

    private func client() throws -> NeteaseClient {
        let directory = FileManager.default.temporaryDirectory.appending(path: "lm-netease-\(UUID().uuidString)")
        for (file, body) in [("search/群青 YOASOBI.json", Self.search), ("song/418602075.json", Self.detail), ("lyric/418602075.json", Self.lyric)] {
            let url = directory.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(body.utf8).write(to: url)
        }
        return NeteaseClient(configuration: NeteaseFixtures.configuration(directory: directory))
    }

    @Test func parsesSearchDetailAndMergedLyrics() async throws {
        let client = try client()
        let songs = try await client.search("群青 YOASOBI")
        #expect(songs.map(\.id) == [1472480890, 1500151581, 2007396062])
        #expect(songs[1] == NeteaseSong(id: 1500151581, title: "群青", artists: ["YOASOBI"], album: "THE BOOK",
                                        coverURL: URL(string: "http://p2.music.126.net/b/2.jpg"), duration: 248.444, trackNo: 6, discNo: 1, year: 2021))
        let song = try #require(try await client.song(418602075))
        #expect(song.artists == ["miwa", "96猫"] && song.discNo == 1 && song.year == 2016 && song.duration == 243.026)
        #expect(try await client.search("nothing").isEmpty)
        let lyrics = try #require(try await client.lyrics(418602075))
        guard case .synced(let lines)? = LRCParser.parse(lyrics) else { Issue.record("unsynced"); return }
        #expect(lines.first { $0.text == "シャンランランラン" }?.translation == "莎啦啦啦")
        #expect(LRCParser.parse(lyrics)?.credits.composers == ["miwa", "NAOKI-T"])
        #expect(try await client.lyrics(1) == nil)
    }

    @Test func decodesThe163Key() throws {
        let json = #"music:{"musicId":418602075,"musicName":"シャンランラン"}"#
        var out = Data(count: json.utf8.count + 32)
        var written = 0
        let key = Array("#14ljk_!\\]&0U<'(".utf8), plain = Data(json.utf8)
        _ = out.withUnsafeMutableBytes { o in
            plain.withUnsafeBytes { i in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        key, key.count, nil, i.baseAddress, plain.count, o.baseAddress, o.count, &written)
            }
        }
        let comment = "163 key(Don't modify):" + out.prefix(written).base64EncodedString()
        #expect(NCMKey.songID(comment) == 418602075)
        #expect(NCMKey.songID("163 key(Don't modify):bm90IGEga2V5") == nil)
    }

    @Test func matchesByTitleArtistAndDurationWithTheAlbumBreakingTies() throws {
        let songs = try JSONSerialization.jsonObject(with: Data(Self.search.utf8)) as! [String: Any]
        let candidates = ((songs["result"] as! [String: Any])["songs"] as! [[String: Any]]).compactMap(NeteaseClient.searchSong)
        func match(_ title: String, _ artists: [String], album: String? = nil, duration: Double = 248.4) -> MatchResult {
            Matcher.match(MatchQuery(title: title, artists: artists, album: album, duration: duration), candidates: candidates)
        }
        guard case .confident(let best, _) = match("群青", ["YOASOBI"], album: "THE BOOK") else { Issue.record("not confident"); return }
        #expect(best.id == 1500151581)
        guard case .confident(let single, _) = match("群青", ["YOASOBI"]) else { Issue.record("not confident"); return }
        #expect(single.id == 1472480890)
        guard case .uncertain(let options) = match("群青", ["Someone Else"]) else { Issue.record("not uncertain"); return }
        #expect(options.count == 3)
        guard case .uncertain = match("群青", ["YOASOBI"], duration: 200) else { Issue.record("duration ignored"); return }
        #expect(match("完全不同", ["YOASOBI"]) == .none)
        #expect(Matcher.normalized("シャンランラン feat.96猫") == Matcher.normalized("シャンランラン"))
        #expect(Matcher.normalized("ＧＵＮＪＯ (TV size)") == Matcher.normalized("gunjo"))
        #expect(Matcher.normalized("Light as a Feather") != Matcher.normalized("Light as a"))
        #expect(Matcher.normalized("「さよなら」の意味") != Matcher.normalized("「ありがとう」の意味"))
    }

    @Test func mergesTranslationsUnderEveryTimestampAsWritten() {
        let merged = LyricsMerge.merge("[ti:x]\r\n[00:12.345]原文\n[00:01.00] [00:30.00]副歌\n[00:40.00]", translation: "[00:12.34]译\n[00:01.00][00:30.00]合唱\n[00:40.00]空")
        guard case .synced(let lines)? = LRCParser.parse(merged) else { Issue.record("unsynced"); return }
        #expect(lines.map(\.text) == ["副歌", "原文", "副歌", ""])   // the empty line is a pause; its translation is dropped
        #expect(lines.map(\.translation) == ["合唱", "译", "合唱", nil])
    }
}
