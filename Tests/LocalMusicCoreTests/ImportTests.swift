import Foundation
import Testing
@testable import LocalMusicCore

struct ImportNamingTests {
    @Test func namesByTheChosenSchemeAndTriesOthersOnConflict() {
        let names = { (naming: ImportNaming) in naming.candidates(title: "春日影", artists: ["MyGO!!!!!", "B"], album: "迷跡波", trackNo: 3, ext: "flac") }
        #expect(Array(names(.title).prefix(3)) == ["春日影.flac", "春日影 (迷跡波).flac", "春日影 2.flac"])
        #expect(names(.artistTitle).first == "MyGO!!!!!, B - 春日影.flac" && names(.titleArtist).first == "春日影 - MyGO!!!!!, B.flac")
        #expect(Array(names(.albumTrack).prefix(2)) == ["迷跡波/03 春日影.flac", "迷跡波/03 春日影 2.flac"])
        #expect(ImportNaming.component("..a/b:c\u{7}") == "a／b：c" && ImportNaming.component(" ") == "未命名")
        let long = ImportNaming.title.candidates(title: String(repeating: "长", count: 200), artists: [], album: "专辑", trackNo: nil, ext: "flac")
        #expect(Set(long).count == long.count && long.allSatisfy { $0.utf8.count <= 255 && $0.hasSuffix(".flac") })   // suffixes survive
    }
}

@Suite(.enabled(if: FFmpeg.path != nil))
struct NCMTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "lm-ncm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func audio(_ name: String, in folder: URL, _ extra: [String]) throws -> URL {
        let url = folder.appending(path: name)
        #expect(try FFmpeg.run(["-f", "lavfi", "-i", "sine=frequency=500:duration=1:sample_rate=44100"] + extra + [url.path]) == 0)
        return url
    }

    private static let meta = #"music:{"musicId":"418602075","musicName":"シャンランラン","artist":[["miwa","1"],["96猫","2"]],"album":"Princess","albumPic":"https://p1.music.126.net/x.jpg","format":"flac"}"#

    @Test(arguments: [("a.flac", [String]()), ("a.mp3", ["-c:a", "libmp3lame"])])
    func decryptsWhatItEncodes(name: String, extra: [String]) throws {
        let dir = try folder(), source = try audio(name, in: dir, extra)
        let original = try Data(contentsOf: source), ncm = dir.appending(path: "x.ncm")
        try NCMFile.encode(audio: original, meta: Self.meta.replacing("\"flac\"", with: "\"\(name.dropFirst(2))\""), cover: TagFileTests.png).write(to: ncm)
        let file = try NCMFile(ncm)
        #expect(file.meta?.musicId == 418602075 && file.meta?.title == "シャンランラン" && file.meta?.artists == ["miwa", "96猫"])
        #expect(file.meta?.album == "Princess" && file.cover == TagFileTests.png && NCMKey.songID(file.meta!.key163) == 418602075)
        #expect(try file.audioFormat() == String(name.dropFirst(2)))
        let out = dir.appending(path: "out." + name.dropFirst(2))
        try file.decrypt(to: out)
        #expect(try Data(contentsOf: out) == original)
    }

    @Test func readsOtherShapesOfMetadata() throws {
        let dir = try folder(), original = try Data(contentsOf: try audio("b.flac", in: dir, []))
        func meta(_ text: String?) throws -> NCMFile.Meta? {
            let url = dir.appending(path: "\(UUID().uuidString).ncm")
            try NCMFile.encode(audio: original, meta: text, cover: nil).write(to: url)
            let file = try NCMFile(url)
            #expect(try file.audioFormat() == "flac" && file.cover == nil)
            return file.meta
        }
        let dj = try meta(#"dj:{"programName":"节目","mainMusic":{"musicId":7,"musicName":"歌","artist":["甲"],"album":"专辑"}}"#)
        #expect(dj?.title == "节目" && dj?.musicId == 7 && dj?.artists == ["甲"])
        #expect(try meta(nil) == nil)
        #expect(throws: TagWriteError.self) { try NCMFile(dir.appending(path: "b.flac")) }
    }

    @Test func convertsNetEaseSidecarLyrics() {
        let text = #"{"t":0,"c":[{"tx":"作词: "},{"tx":"甲"}]}"# + "\n" + #"{"t":61230,"c":[{"tx":"作曲: 乙"}]}"# + "\n[01:02.00]歌"
        #expect(NCMFile.lyrics(fromSidecar: text) == "[00:00.00]作词: 甲\n[01:01.23]作曲: 乙\n[01:02.00]歌")
    }

    @Test(arguments: ["c.flac", "c.mp3"])
    func placesWithoutReplacingAndKeepsTheNetEaseKey(name: String) async throws {
        let dir = try folder(), source = try audio(name, in: dir, name.hasSuffix("mp3") ? ["-c:a", "libmp3lame", "-metadata", "title=junk"] : ["-metadata", "title=junk"])
        let ext = String(name.dropFirst(2)), target = dir.appending(path: "lib")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("taken".utf8).write(to: target.appending(path: "歌.\(ext)"))   // the first name is taken
        // Through a link to a read-only source: the source stays as it was.
        let link = dir.appending(path: "link.\(ext)"), before = try Data(contentsOf: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: source.path)
        let staged = Importer.staging(in: target, ext: ext)
        try Importer.stage(copyOf: link, to: staged)
        var edit = TagEdit()
        (edit.title, edit.artists, edit.replaceAll) = ("歌", ["甲"], true)
        edit.title = Importer.ncmEdit(nil, song: OnlineSong(source: .netease, id: "1", title: " 歌\u{200B}", artists: [], album: "", coverURL: nil,
                                                             duration: 0, trackNo: nil, discNo: nil, year: nil), lyrics: nil, cover: nil).title
        edit.ncmKey = try NCMFile(try { let u = dir.appending(path: "k.ncm"); try NCMFile.encode(audio: Data(), meta: Self.meta, cover: nil).write(to: u); return u }()).meta?.key163
        let placed = try await Importer.place(staged, edit: edit, in: target, candidates: ImportNaming.title.candidates(title: "歌", artists: ["甲"], album: "专辑", trackNo: nil, ext: ext))
        #expect(try Data(contentsOf: target.appending(path: "歌.\(ext)")) == Data("taken".utf8) && placed.lastPathComponent == "歌 (专辑).\(ext)")
        let meta = TrackMetadata(tags: try await TagReader.read(placed).tags, fileURL: placed)
        #expect(meta.title == "歌" && meta.names(.artist) == ["甲"] && meta.ncmKey.flatMap(NCMKey.songID) == 418602075)
        #expect(try Data(contentsOf: source) == before)

        let (old, fresh) = (Importer.staging(in: target, ext: ext), Importer.staging(in: target, ext: ext))
        try Data().write(to: old)
        try Data().write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: old.path)
        Importer.sweepStaging(in: target)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).sorted() == ["歌 (专辑).\(ext)", "歌.\(ext)", fresh.lastPathComponent].sorted())
    }
}
