import AVFAudio
import Foundation
import LocalMusicCore

// Developer CLI: dumps what LocalMusicCore parses, as JSON, for validation scripts.
//   lmtool tags [--stats] [--sha] <file|dir>...
//   lmtool lrc <audio-file|.lrc>
//   lmtool scan <db> [<root>...]      (default roots: the system Music folder minus its Apple Music library)
//   lmtool decode-check <file|dir>...  (decodes a chunk at the start and at 50% of every file)

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
        "path": url.path,
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

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "tags" where arguments.count > 1:
    await tags(Array(arguments.dropFirst()))
case "lrc" where arguments.count == 2:
    try await lrc(arguments[1])
case "decode-check" where arguments.count > 1:
    decodeCheck(Array(arguments.dropFirst()))
case "scan" where arguments.count >= 2:
    try await scan(arguments[1], Array(arguments.dropFirst(2)))
default:
    FileHandle.standardError.write(Data("usage: lmtool tags [--stats] [--sha] <paths>... | lmtool lrc <file> | lmtool scan <db> [<root>...] | lmtool decode-check <paths>...\n".utf8))
    exit(64)
}
