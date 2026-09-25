import Foundation

enum DirectoryWalker {
    struct Result {
        var audio: [String: FileStamp] = [:]
        /// Sidecar `.lrc` modification times keyed by the NFC path without extension.
        var sidecars: [String: Double] = [:]
        /// Roots or subtrees that could not be listed (unmounted drive, TCC denial). Tracks under them are kept.
        var unreachable: [String] = []

        func isUnreachable(_ key: String) -> Bool {
            unreachable.contains { key == $0 || key.hasPrefix($0 + "/") }
        }
    }

    static func walk(_ configured: LibraryRoots) -> Result {
        let roots = configured.resolved
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]
        var result = Result()
        for root in roots.include {
            var isDirectory: ObjCBool = false
            var failed: [String] = []
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue,
                  let enumerator = FileManager.default.enumerator(
                      at: URL(filePath: root), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants],
                      errorHandler: { url, _ in failed.append(url.path.pathKey); return true })
            else {
                result.unreachable.append(root)
                continue
            }
            // Only exclusions inside this root apply; an include root nested in an excluded folder is still scanned.
            let excluded = LibraryRoots(include: [], exclude: roots.exclude.filter { $0.hasPrefix(root + "/") })
            while let url = enumerator.nextObject() as? URL {
                let key = url.path.pathKey
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isDirectory == true {
                    if excluded.isExcluded(key) { enumerator.skipDescendants() }
                    continue
                }
                guard values.isRegularFile == true, !excluded.isExcluded(key) else { continue }
                let ext = url.pathExtension.lowercased()
                let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                if TagReader.audioExtensions.contains(ext) {
                    result.audio[key] = FileStamp(path: url.path, size: Int64(values.fileSize ?? 0), mtime: mtime,
                                                  created: values.creationDate?.timeIntervalSince1970 ?? mtime)
                } else if ext == "lrc" {
                    result.sidecars[url.deletingPathExtension().path.pathKey] = mtime
                }
            }
            result.unreachable += failed
        }
        return result
    }
}

public enum LibraryScanner {
    private static let parallelism = 4
    private static let batchSize = 200

    /// Walks the roots, re-parses only new or changed files (persisting every `batchSize`) and prunes vanished ones.
    public static func scan(store: LibraryStore, roots: LibraryRoots) async throws -> ScanReport {
        let clock = ContinuousClock(), start = clock.now
        let walk = DirectoryWalker.walk(roots)
        let stored = try await store.stamps()

        var pending: [(FileStamp, Double?, Int64?)] = []
        for (key, stamp) in walk.audio {
            let sidecar = walk.sidecars[URL(filePath: key).deletingPathExtension().path]
            let old = stored[key]
            if let old, old.size == stamp.size, old.mtime == stamp.mtime, old.sidecarMtime == sidecar, !old.needsFingerprint { continue }
            pending.append((stamp, sidecar, old?.id))
        }
        // A moved or renamed file keeps its size and modification time: it takes over the vanished row, keeping its
        // likes, playlist entries, loudness analysis and added date.
        var vanished: [String: [Int64]] = [:]
        for (key, old) in stored where walk.audio[key] == nil && !walk.isUnreachable(key) {
            vanished["\(old.size) \(old.mtime)", default: []].append(old.id)
        }
        for i in pending.indices where pending[i].2 == nil {
            pending[i].2 = vanished["\(pending[i].0.size) \(pending[i].0.mtime)"]?.popLast()
        }
        let removed = vanished.values.flatMap(\.self)

        var report = ScanReport()
        try await withThrowingTaskGroup(of: ScannedTrack.self) { group in
            var queue = pending.makeIterator()
            func enqueue() {
                guard let (stamp, sidecar, id) = queue.next() else { return }
                group.addTask { await parse(stamp, sidecar: sidecar, storedID: id) }
            }
            for _ in 0..<parallelism { enqueue() }
            var batch: [ScannedTrack] = []
            for try await track in group {
                batch.append(track)
                if track.storedID == nil { report.added += 1 } else { report.updated += 1 }
                if case .failure(let failure) = track.result { report.failures.append("\(track.stamp.path): \(failure.message)") }
                if batch.count == batchSize {
                    try await store.apply(batch, removing: [])
                    batch = []
                }
                enqueue()
            }
            try await store.apply(batch, removing: removed)
        }
        report.total = walk.audio.count
        report.parsed = pending.count
        report.removed = removed.count
        report.milliseconds = (clock.now - start) / .milliseconds(1)
        return report
    }

    private static func parse(_ stamp: FileStamp, sidecar: Double?, storedID: Int64?) async -> ScannedTrack {
        let url = URL(filePath: stamp.path)
        let lyrics = sidecar.flatMap { _ in readText(url.deletingPathExtension().appendingPathExtension("lrc")) }
        let result: Result<(RawTrack, TrackMetadata), ScanFailure>
        do {
            let raw = try await TagReader.read(url)
            result = .success((raw, TrackMetadata(tags: raw.tags, fileURL: url)))
        } catch {
            result = .failure(ScanFailure(message: String(describing: error)))
        }
        return ScannedTrack(stamp: stamp, storedID: storedID, sidecarMtime: sidecar, sidecarLyrics: lyrics, result: result)
    }

    /// Sidecar LRC files from Chinese sources are often GB18030 rather than UTF-8.
    private static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: gb18030)
    }
}
