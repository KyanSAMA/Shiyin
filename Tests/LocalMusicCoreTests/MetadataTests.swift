import Foundation
import Testing
@testable import LocalMusicCore

struct MetadataTests {
    private func meta(_ fields: [(String, String)], file: String = "/m/曲.flac") -> TrackMetadata {
        var tags = RawTags()
        for (key, value) in fields { tags.add(key, value) }
        return TrackMetadata(tags: tags, fileURL: URL(filePath: file))
    }

    @Test(arguments: [
        ("53.Knife to the Throat", 53, "Knife to the Throat"), ("01 Title", 1, "Title"), ("1. Intro", 1, "Intro"),
        ("07 - Song", 7, "Song"), ("2.5次元の誘惑", nil, "2.5次元の誘惑"), ("3月9日", nil, "3月9日"), ("群青", nil, "群青"),
        ("99 Luftballons", nil, "99 Luftballons"), ("０１ 全角", nil, "０１ 全角"),
    ] as [(String, Int?, String)])
    func parsesFilenames(stem: String, track: Int?, title: String) {
        let parsed = FilenameParser.parse(stem)
        #expect(parsed.track == track && parsed.title == title)
    }

    @Test func fallsBackToFilenameForTitleAndTrack() {
        let m = meta([("ARTIST", "Evan Call")], file: "/m/53.Knife to the Throat.flac")
        #expect(m.title == "Knife to the Throat" && m.titleSource == .filename && m.trackNo == 53)
        let tagged = meta([("TITLE", "Real"), ("TRACKNUMBER", "4")], file: "/m/53.Knife.flac")
        #expect(tagged.title == "Real" && tagged.titleSource == .tag && tagged.trackNo == 4)
    }

    @Test func splitsPeopleConservatively() {
        #expect(PersonSplitter.split(["塞壬唱片-MSR/DAZBEE"]) == ["塞壬唱片-MSR", "DAZBEE"])
        #expect(PersonSplitter.split(["miwa, 96猫"]) == ["miwa", "96猫"])
        let unit = "イタズラ☆ストレート<アリス(CV:田中美海)、アル(CV:近藤玲奈)>"
        #expect(PersonSplitter.split([unit]) == [unit])
        #expect(PersonSplitter.split(["AC/DC", "B"]) == ["AC/DC", "B"])
        #expect(PersonSplitter.split(["A / A"]) == ["A"])
        #expect(PersonSplitter.split(["A", " "]) == ["A"])
    }

    @Test func prefersComposerTagOverLyricCredits() {
        let lyrics = "[00:00.000] 作词 : 山口一郎\n[00:00.273] 作曲 : o-saka/Diggy-MO'\n[00:00.546] 编曲 : サカナクション\n[00:01.00]本文"
        let credited = meta([("LYRICS", lyrics)])
        #expect(credited.names(.composer) == ["o-saka", "Diggy-MO'"])
        #expect(credited.people.first { $0.role == .composer }?.source == .lyricsCredit)
        #expect(credited.names(.lyricist) == ["山口一郎"] && credited.names(.arranger) == ["サカナクション"])
        let tagged = meta([("LYRICS", lyrics), ("COMPOSER", "Ayase")])
        #expect(tagged.names(.composer) == ["Ayase"] && tagged.people.first { $0.role == .composer }?.source == .tag)
    }

    @Test func parsesNumbersDatesAndGain() {
        let m = meta([("TRACKNUMBER", "3/12"), ("DISCNUMBER", "2"), ("DISCTOTAL", "2"), ("DATE", "2017-05-03"),
                      ("ALBUM ARTIST", "Evan Call"), ("REPLAYGAIN_TRACK_GAIN", "-6.54 dB"), ("REPLAYGAIN_TRACK_PEAK", "0.98")])
        #expect(m.trackNo == 3 && m.trackTotal == 12 && m.discNo == 2 && m.discTotal == 2)
        #expect(m.year == 2017 && m.date == "2017-05-03" && m.albumArtist == "Evan Call")
        #expect(m.replayGain.trackGain == -6.54 && m.replayGain.trackPeak == 0.98)
        #expect(meta([("TRACKTOTAL", "9"), ("TRACKNUMBER", "1")]).trackTotal == 9)
        #expect(meta([("REPLAYGAIN_TRACK_GAIN", "-.5 dB")]).replayGain.trackGain == -0.5)
    }
}

struct LRCParserTests {
    private func lines(_ text: String) throws -> [LyricLine] {
        guard case .synced(let lines) = try #require(LRCParser.parse(text)) else { throw TagError.invalid("not synced") }
        return lines
    }

    @Test func parsesAllTimestampForms() throws {
        let parsed = try lines("[01:02]a\n[01:02.3]b\n[01:02.34]c\n[01:02.345]d\n[01:03:34]e\n[100:00.00]f")
        #expect(parsed.map(\.time) == [62, 62.3, 62.34, 62.345, 63.34, 6000])
    }

    @Test func expandsMultipleStampsAndAppliesOffset() throws {
        let parsed = try lines("[ti:Title]\n[offset:500]\n[00:10.00][00:20.00]chorus\n[00:15.00]verse")
        #expect(parsed.map(\.time) == [9.5, 14.5, 19.5])
        #expect(parsed.map(\.text) == ["chorus", "verse", "chorus"])
    }

    @Test func handlesBOMAndCRLF() throws {
        #expect(try lines("\u{FEFF}[00:01.00]a\r\n[00:02.00]b\r[00:03.00]c").map(\.text) == ["a", "b", "c"])
    }

    @Test func deduplicatesDoubledLyrics() throws {
        let once = "[00:00.000] 作词 : X\n[00:01.00]一\n[00:02.00]二\n[00:03.00]"
        #expect(try lines(once + "\n" + once) == lines(once))
        #expect(try lines(once).count == 4)
    }

    @Test func pairsTranslationsSharingATimestamp() throws {
        let parsed = try lines("[00:01.00]夜に駆ける\n[00:01.00]奔向夜晚\n[00:02.00]沈むように\n[00:02.00]沈むように\n[00:02.00]")
        #expect(parsed[0].text == "夜に駆ける" && parsed[0].translation == "奔向夜晚")
        #expect(parsed[1].text == "沈むように" && parsed[1].translation == nil)
    }

    @Test func marksOnlyTheLeadingCreditBlock() throws {
        let parsed = try lines("[00:00.00]\n[00:00.10] 作词 : A\n[00:00.20]作曲：B\n[00:00.30] 制作人 : C\n[00:05.00]正文\n[00:06.00] 作曲 : D")
        #expect(parsed.map(\.isCredit) == [false, true, true, true, false, false])
        let credits = Lyrics.synced(parsed).credits
        #expect(credits.lyricists == ["A"] && credits.composers == ["B"] && credits.arrangers.isEmpty)
    }

    @Test func findsCreditsAfterATitleLineAndInEnglish() throws {
        let parsed = try lines("[00:00.00]リセット - 松たか子\n[00:00.50]Lyrics by：A\n[00:01.00]Composed by：B\n[00:01.50]Arranged by：C\n[00:10.00]本文")
        #expect(parsed.map(\.isCredit) == [false, true, true, true, false])
        let credits = Lyrics.synced(parsed).credits
        #expect(credits.lyricists == ["A"] && credits.composers == ["B"] && credits.arrangers == ["C"])
    }

    @Test func doesNotTreatDialogueAsCredits() throws {
        let parsed = try lines("[00:00.00]作曲 : B\n[00:12.00]男：你好\n[00:15.00]女：再见")
        #expect(parsed.map(\.isCredit) == [true, false, false])
    }

    @Test func keepsCreditsSharingATimestampAsSeparateLines() throws {
        let parsed = try lines("[00:00.00]作词 : A\n[00:00.00]作曲 : B\n[00:00.00]编曲 : C\n[00:01.00]本文")
        #expect(parsed.map(\.text) == ["作词 : A", "作曲 : B", "编曲 : C", "本文"])
        #expect(parsed.allSatisfy { $0.translation == nil })
        let credits = Lyrics.synced(parsed).credits
        #expect(credits.lyricists == ["A"] && credits.composers == ["B"] && credits.arrangers == ["C"])
    }

    @Test func survivesHostileOffsetsAndNonASCIIDigits() throws {
        #expect(try lines("[offset:-9223372036854775000]\n[00:01.00]a").map(\.text) == ["a"])
        #expect(LRCParser.parse("[０１:３０.００]歌词") == .unsynced(["[０１:３０.００]歌词"]))
    }

    @Test func keepsBracketsInsideTextAndStripsWordTimes() throws {
        let parsed = try lines("[00:10.00][ face ] Crucifix\n[00:11.00]<00:11.00>逐<00:11.50>字")
        #expect(parsed.map(\.text) == ["[ face ] Crucifix", "逐字"])
    }

    @Test func fallsBackToUnsyncedText() {
        #expect(LRCParser.parse("第一行\n\n第二行") == .unsynced(["第一行", "第二行"]))
        #expect(LRCParser.parse(" \n[ar:x]\n") == nil)
    }

    @Test func findsCurrentLineWithLead() throws {
        let lyrics = Lyrics.synced(try lines("[00:01.00]a\n[00:02.00]b\n[00:03.00]c"))
        #expect(lyrics.index(at: 0.5) == nil)
        #expect(lyrics.index(at: 0.9) == 0)
        #expect(lyrics.index(at: 1.5) == 0)
        #expect(lyrics.index(at: 2.0) == 1)
        #expect(lyrics.index(at: 99) == 2)
        #expect(Lyrics.unsynced(["x"]).index(at: 5) == nil)
    }
}
