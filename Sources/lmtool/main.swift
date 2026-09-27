import AVFAudio
import Foundation
import LocalMusicCore

// Developer CLI: dumps what LocalMusicCore parses, as JSON, for validation scripts.
//   lmtool tags [--stats] [--sha] <file|dir>...
//   lmtool lrc <audio-file|.lrc>
//   lmtool scan <db> [<root>...]      (default roots: the system Music folder minus its Apple Music library)
//   lmtool decode-check <file|dir>...  (decodes a chunk at the start and at 50% of every file)
//   lmtool loudness [--album] <file|dir>...  (BS.1770 integrated loudness and sample peak per file)
//   lmtool online search|lyric <netease|qq|itunes|lrclib> <keywords> | song <netease id> | match <file>
//     (live requests; `lyric` prints the top result's lyrics, `match` tries every source like batch enrichment)
//   lmtool write-tags <file> --backup <json> [--set title|artists|album|albumArtist|trackNo|discNo|year|genre|composers=<value>]...
//          [--cover <image>] [--lyrics <file>]   (artists / composers split on "/"; never under ~/Music)
//   lmtool restore-tags <file> --backup <json>
//   lmtool ncm <file.ncm> [--out <dir>] [--fill]   (metadata as JSON; --out puts the tagged FLAC / MP3 there, named
//          like an import; --fill asks NetEase (live) for track, year, lyrics and a missing cover; never under ~/Music)
//   lmtool siren albums | album <cid> | get <song cid> <dir>   (塞壬唱片, live; `get` downloads the song into <dir> as an
//          import would — WAV as FLAC, tagged; never under ~/Music)

func value<T>(_ optional: T?) -> Any { optional.map { $0 as Any } ?? NSNull() }

func emit(_ object: Any) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func audioFiles(_ paths: [String]) -> [URL] {
    paths.flatMap { path -> [URL] in
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return [] }
        let url = URL(filePath: path)
        guard isDirectory.boolValue else { return [url] }
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                        errorHandler: { _, _ in true })
        return (enumerator?.allObjects as? [URL] ?? [])
            .filter { TagReader.audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
    }
}

func describe(_ url: URL, _ raw: RawTrack, _ meta: TrackMetadata) -> [String: Any] {
    let p = raw.properties
    let lyrics = meta.lyrics.flatMap(LRCParser.parse)
    let lineCount: Int? = switch lyrics {
    case .synced(let lines): lines.count
    case .unsynced(let lines): lines.count
    case nil: nil
    }
    return [
        "path": url.path, "fingerprint": value(raw.fingerprint),
        "format": p.format, "codec": value(p.codec), "sampleRate": value(p.sampleRate), "bitDepth": value(p.bitDepth),
        "channels": value(p.channels), "frameCount": value(p.frameCount), "duration": p.duration,
        "tags": raw.tags.fields,
        "cover": value(raw.cover.map { ["offset": value($0.offset), "length": $0.length, "mime": value($0.mime), "type": $0.pictureType] }),
        "meta": [
            "title": meta.title, "titleSource": meta.titleSource.rawValue,
            "album": value(meta.album), "albumArtist": value(meta.albumArtist),
            "people": meta.people.map { ["role": $0.role.rawValue, "name": $0.name, "source": $0.source.rawValue] },
            "trackNo": value(meta.trackNo), "trackTotal": value(meta.trackTotal),
            "discNo": value(meta.discNo), "discTotal": value(meta.discTotal),
            "year": value(meta.year), "genre": value(meta.genre), "lyricLines": value(lineCount),
        ] as [String: Any],
    ]
}

func tags(_ arguments: [String]) async {
    let statsOnly = arguments.contains("--stats"), withSHA = arguments.contains("--sha")
    let files = audioFiles(arguments.filter { !$0.hasPrefix("--") })
    let clock = ContinuousClock(), start = clock.now
    var results: [[String: Any]] = []
    var bytesRead: Int64 = 0, failures: [String] = [], covers = 0, lyrics = 0, composers = 0
    for url in files {
        do {
            let raw = try await TagReader.read(url)
            let meta = TrackMetadata(tags: raw.tags, fileURL: url)
            bytesRead += raw.bytesRead
            if raw.cover != nil { covers += 1 }
            if meta.lyrics != nil { lyrics += 1 }
            if !meta.names(.composer).isEmpty { composers += 1 }
            guard !statsOnly else { continue }
            var entry = describe(url, raw, meta)
            if withSHA, let cover = raw.cover, let data = try await TagReader.coverData(url, cover) {
                entry["coverSHA256"] = TagReader.sha256(data)
            }
            results.append(entry)
        } catch {
            failures.append("\(url.path): \(error)")
            if !statsOnly { results.append(["path": url.path, "error": "\(error)"]) }
        }
    }
    let elapsed = clock.now - start
    guard statsOnly else { return emit(results) }
    emit(["files": files.count, "failures": failures, "withCover": covers, "withLyrics": lyrics, "withComposer": composers,
          "bytesRead": bytesRead, "seconds": elapsed / .seconds(1)])
}

func lrc(_ path: String) async throws {
    let url = URL(filePath: path)
    let text = url.pathExtension.lowercased() == "lrc"
        ? try String(contentsOf: url, encoding: .utf8)
        : TrackMetadata(tags: try await TagReader.read(url).tags, fileURL: url).lyrics ?? ""
    switch LRCParser.parse(text) {
    case .synced(let lines)?:
        let credits = Lyrics.synced(lines).credits
        emit(["lines": lines.map { ["time": $0.time, "text": $0.text, "translation": value($0.translation), "isCredit": $0.isCredit] },
              "credits": ["composers": credits.composers, "lyricists": credits.lyricists, "arrangers": credits.arrangers]])
    case .unsynced(let lines)?:
        emit(["unsynced": lines])
    case nil:
        emit(["lines": []])
    }
}

func scan(_ database: String, _ roots: [String]) async throws {
    let store = try LibraryStore(url: URL(filePath: database))
    let roots = roots.isEmpty ? .defaults : LibraryRoots(include: roots, exclude: [])
    let first = try await LibraryScanner.scan(store: store, roots: roots)
    let second = try await LibraryScanner.scan(store: store, roots: roots)
    let index = LibraryIndex(rows: try await store.rows())
    emit(["first": ["total": first.total, "parsed": first.parsed, "failures": first.failures, "ms": first.milliseconds],
          "second": ["parsed": second.parsed, "ms": second.milliseconds],
          "songs": index.songs.count, "albums": index.albums.count, "artists": index.artists.count, "composers": index.composers.count,
          "albumList": index.albums.map { "\($0.title) — \($0.artist) (\($0.trackIDs.count))" }])
}

func decodeCheck(_ paths: [String]) {
    var failures: [String] = []
    let files = audioFiles(paths)
    for url in files {
        do {
            let file = try AVAudioFile(forReading: url)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
            try file.read(into: buffer)
            file.framePosition = file.length / 2
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { throw TagError.truncated }
        } catch {
            failures.append("\(url.path): \(error)")
        }
    }
    emit(["files": files.count, "failures": failures])
}

func loudness(_ arguments: [String]) {
    let files = audioFiles(arguments.filter { !$0.hasPrefix("--") })
    var tracks: [[String: Any]] = [], union: [Float] = []
    for url in files {
        let clock = ContinuousClock(), start = clock.now
        do {
            let r = try LoudnessAnalyzer.analyze(url)
            let elapsed = (clock.now - start) / .seconds(1)
            union += r.blockEnergies
            tracks.append(["path": url.path, "integrated": value(r.integrated), "samplePeakDb": 20 * log10(max(r.samplePeak, 1e-9)),
                           "seconds": r.seconds, "speed": r.seconds / max(elapsed, 1e-9)])
        } catch {
            tracks.append(["path": url.path, "error": "\(error)"])
        }
    }
    emit(arguments.contains("--album") ? ["tracks": tracks, "album": value(LoudnessAnalyzer.integrated(union))] as [String: Any] : tracks)
}

func describe(_ song: OnlineSong) -> [String: Any] {
    ["source": song.source.rawValue, "id": song.id, "title": song.title, "artists": song.artists, "album": song.album,
     "cover": value(song.coverURL?.absoluteString), "duration": song.duration, "trackNo": value(song.trackNo),
     "discNo": value(song.discNo), "year": value(song.year), "genre": value(song.genre),
     "lyricLines": value(song.lyrics?.split(whereSeparator: \.isNewline).count)]
}

func online(_ arguments: [String]) async throws {
    let client = OnlineClient()
    switch (arguments.first, arguments.count) {
    case ("search", 3), ("lyric", 3):
        guard let source = OnlineSource(rawValue: arguments[1]) else { throw OnlineError.malformed }
        let songs = try await client.search(source, arguments[2])
        if arguments[0] == "search" { emit(songs.map(describe)) } else if let song = songs.first { print(try await client.lyrics(song) ?? "") }
    case ("song", 2):
        guard let id = Int64(arguments[1]) else { throw OnlineError.malformed }
        emit(try await client.neteaseSong(id).map(describe) ?? NSNull())
    case ("match", 2):
        let url = URL(filePath: arguments[1])
        let raw = try await TagReader.read(url)
        let meta = TrackMetadata(tags: raw.tags, fileURL: url)
        let query = MatchQuery(title: meta.title, artists: meta.names(.artist), album: meta.album, duration: raw.properties.duration)
        var results: [String: Any] = ["keywords": query.keywords, "ncmKey": value(meta.ncmKey.flatMap(NCMKey.songID))]
        for source in OnlineSource.allCases {
            let songs = try await client.search(source, query.keywords)
            results[source.rawValue] = switch Matcher.match(query, candidates: songs) {
            case .confident(let song, let score): ["confident": describe(song), "score": score] as [String: Any]
            case .uncertain(let songs): ["uncertain": songs.map(describe)]
            case .none: "none"
            }
        }
        emit(results)
    default:
        throw OnlineError.malformed
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
/// Tag writing for validation runs on copies: refuses anything in the user's Music folder.
func writableCopy(_ path: String) throws -> URL {
    let url = URL(filePath: path).resolvingSymlinksInPath()
    // Case-insensitive, and past the Data-volume firmlink.
    func folded(_ path: String) -> String { path.replacing(/^\/System\/Volumes\/Data/, with: "").lowercased() }
    let music = folded(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Music").resolvingSymlinksInPath().path + "/")
    guard !folded(url.path + "/").hasPrefix(music) else { throw TagWriteError.unsupported("拒绝写入 ~/Music 下的文件") }
    return url
}

func writeTags(_ arguments: [String]) async throws {
    let url = try writableCopy(arguments[0])
    var edit = TagEdit(), backup: String?
    var rest = arguments.dropFirst()
    while let flag = rest.popFirst() {
        guard let value = rest.popFirst() else { throw TagWriteError.unsupported("\(flag) needs a value") }
        func number() throws -> Int {
            guard let number = Int(value.drop { $0 != "=" }.dropFirst()) else { throw TagWriteError.unsupported("not a number: \(value)") }
            return number
        }
        switch flag {
        case "--backup": backup = value
        case "--cover": edit.cover = try TagEdit.Cover(Data(contentsOf: URL(filePath: value)))
        case "--lyrics": edit.lyrics = try String(contentsOf: URL(filePath: value), encoding: .utf8)
        case "--set":
            let key = String(value.prefix { $0 != "=" }), text = String(value.drop { $0 != "=" }.dropFirst())
            let names = text.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            switch key {
            case "title": edit.title = text
            case "artists": edit.artists = names
            case "album": edit.album = text
            case "albumArtist": edit.albumArtist = text
            case "trackNo": edit.trackNo = try number()
            case "discNo": edit.discNo = try number()
            case "year": edit.year = try number()
            case "genre": edit.genre = text
            case "composers": edit.composers = names
            default: throw TagWriteError.unsupported("unknown field \(key)")
            }
        default: throw TagWriteError.unsupported("unknown flag \(flag)")
        }
    }
    // The first backup is the true original: a second write to the same one would overwrite it.
    guard let backup, !FileManager.default.fileExists(atPath: backup) else { throw TagWriteError.unsupported("--backup is required and must not exist") }
    let version = try await TagWriter.write(edit, to: url) { try JSONEncoder().encode($0).write(to: URL(filePath: backup)) }
    emit(["size": version.size, "mtime": version.mtime])
}

func restoreTags(_ path: String, backup: String) async throws {
    let original = try JSONDecoder().decode(TagWriter.Original.self, from: Data(contentsOf: URL(filePath: backup)))
    let version = try await TagWriter.restore(try writableCopy(path), to: original)
    emit(["size": version.size, "mtime": version.mtime])
}

func ncm(_ arguments: [String]) async throws {
    let url = URL(filePath: arguments[0]), file = try NCMFile(url), format = try file.audioFormat()
    let out = arguments.firstIndex(of: "--out").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }, fill = arguments.contains("--fill")
    var info: [String: Any] = ["format": format, "hasCover": file.cover != nil, "musicId": value(file.meta?.musicId),
                               "title": value(file.meta?.title), "artists": file.meta?.artists ?? [], "album": value(file.meta?.album)]
    guard let out else { return emit(info) }
    let folder = try writableCopy(out)
    var song: OnlineSong?, lyrics: String?, cover = file.cover
    if fill, let id = file.meta?.musicId {
        let client = OnlineClient()
        song = try await client.neteaseSong(id)
        if let song {
            lyrics = try await client.lyrics(song)
            if cover == nil { cover = try await client.cover(song) }
        }
    }
    let sidecar = url.deletingPathExtension().appendingPathExtension("lrc")
    if lyrics == nil, let text = try? String(contentsOf: sidecar, encoding: .utf8) { lyrics = NCMFile.lyrics(fromSidecar: text) }
    let edit = Importer.ncmEdit(file.meta, song: song, lyrics: lyrics, cover: cover)
    let staged = Importer.staging(in: folder, ext: format)
    defer { try? FileManager.default.removeItem(at: staged) }
    try file.decrypt(to: staged)
    let names = ImportNaming.title.candidates(title: edit.title ?? url.deletingPathExtension().lastPathComponent, artists: edit.artists ?? [],
                                              album: edit.album, trackNo: edit.trackNo, ext: format)
    info["placed"] = try await Importer.place(staged, edit: edit, in: folder, candidates: names).path
    emit(info)
}

func siren(_ arguments: [String]) async throws {
    let client = OnlineClient()
    switch (arguments.first, arguments.count) {
    case ("albums", 1):
        let albums = try await client.sirenAlbums()
        emit(albums.map { ["cid": $0.id, "name": $0.name, "artists": $0.artists] })
    case ("album", 2):
        let detail = try await client.sirenAlbum(arguments[1])
        emit(["name": detail.album.name, "intro": detail.intro, "cover": value(detail.album.coverURL?.absoluteString),
              "songs": detail.songs.map { ["cid": $0.id, "name": $0.name, "artists": $0.artists] }])
    case ("get", 3):
        let folder = try writableCopy(arguments[2])
        let songs = try await client.sirenSongs()
        guard let song = songs.first(where: { $0.id == arguments[1] }) else { throw OnlineError.malformed }
        let detail = try await client.sirenAlbum(song.albumID)
        let cover = try await client.sirenCover(detail.album)
        let started = Date()
        let placed = try await Siren.download(song, in: detail, cover: cover, client: client, to: folder, naming: .title) { received, expected in
            FileHandle.standardError.write(Data("\r\(received / 1024) / \(expected.map { String($0 / 1024) } ?? "?") KB".utf8))
        }
        emit(["placed": placed.path, "seconds": Date().timeIntervalSince(started)])
    default:
        throw TagWriteError.unsupported("lmtool siren albums | album <cid> | get <song cid> <dir>")
    }
}

switch arguments.first {
case "devices":
    // Read-only: the output devices, their rates and the default.
    let devices = HALOutputDevices()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(devices.devices), as: UTF8.self))
    print("default: \(devices.defaultUID ?? "none")")
case "siren" where arguments.count > 1:
    try await siren(Array(arguments.dropFirst()))
case "tags" where arguments.count > 1:
    await tags(Array(arguments.dropFirst()))
case "lrc" where arguments.count == 2:
    try await lrc(arguments[1])
case "loudness" where arguments.count > 1:
    loudness(Array(arguments.dropFirst()))
case "decode-check" where arguments.count > 1:
    decodeCheck(Array(arguments.dropFirst()))
case "scan" where arguments.count >= 2:
    try await scan(arguments[1], Array(arguments.dropFirst(2)))
case "online" where arguments.count > 2:
    try await online(Array(arguments.dropFirst()))
case "ncm" where arguments.count > 1:
    try await ncm(Array(arguments.dropFirst()))
case "write-tags" where arguments.count > 1:
    try await writeTags(Array(arguments.dropFirst()))
case "restore-tags" where arguments.count == 4 && arguments[2] == "--backup":
    try await restoreTags(arguments[1], backup: arguments[3])
default:
    FileHandle.standardError.write(Data("usage: lmtool devices | lmtool tags [--stats] [--sha] <paths>... | lmtool lrc <file> | lmtool scan <db> [<root>...] | lmtool decode-check <paths>... | lmtool loudness [--album] <paths>... | lmtool online search|lyric <source> <keywords> | song <id> | match <file> | lmtool write-tags <file> --backup <json> [--set k=v]... [--cover img] [--lyrics file] | lmtool restore-tags <file> --backup <json> | lmtool ncm <file.ncm> [--out <dir>] [--fill] | lmtool siren albums | album <cid> | get <cid> <dir>\n".utf8))
    exit(64)
}
