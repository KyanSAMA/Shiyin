import Foundation
import Testing
@testable import LocalMusicCore

/// Feeds 1 kHz sine segments `(dBFS, seconds)` on every channel through the analyzer, in pieces of at most `chunk`.
/// 0.1 s holds whole cycles at every rate, so each segment repeats one precomputed 0.1 s buffer.
private func analyze(_ segments: [(Double, Double)], rate: Double, channels: Int = 2, chunk: Int = .max) -> LoudnessResult {
    var analyzer = LoudnessAnalyzer(sampleRate: rate, channels: channels)
    let length = Int(rate / 10)
    for (dbfs, seconds) in segments {
        let amplitude = pow(10, dbfs / 20)
        let tenth = (0..<length).map { Float(amplitude * sin(2 * .pi * 1000 * Double($0) / rate)) }
        tenth.withUnsafeBufferPointer { all in
            for _ in 0..<Int((seconds * 10).rounded()) {
                for start in stride(from: 0, to: length, by: chunk) {
                    let piece = UnsafeBufferPointer(rebasing: all[start..<min(start + chunk, length)])
                    analyzer.process(Array(repeating: piece, count: channels))
                }
            }
        }
    }
    return analyzer.result
}

struct LoudnessTests {
    @Test func reproducesTheReferenceFilterAt48k() {
        let c = KWeighting(sampleRate: 48000).coefficients
        let expected = [1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585,
                        1, -2, 1, -1.99004745483398, 0.99007225036621]
        #expect(zip(c, expected).allSatisfy { abs($0 - $1) < 1e-5 })
    }

    /// EBU Tech 3341 cases 1–5: −23 LUFS, case 2 −33.
    @Test(arguments: [44100.0, 48000, 96000, 192_000])
    func meetsEBUTech3341(rate: Double) throws {
        let cases: [([(Double, Double)], Double)] = [
            ([(-23, 20)], -23),
            ([(-33, 20)], -33),
            ([(-26, 20), (-20, 20.1), (-26, 20)], -23),
            ([(-36, 10), (-23, 60), (-36, 10)], -23),
            ([(-72, 10), (-36, 10), (-23, 60), (-36, 10), (-72, 10)], -23),
        ]
        for (segments, expected) in cases {
            let measured = try #require(analyze(segments, rate: rate).integrated)
            #expect(abs(measured - expected) < 0.1, "\(rate) Hz \(segments): \(measured)")
        }
    }

    @Test func isIndependentOfChunking() throws {
        let whole = try #require(analyze([(-18, 5), (-30, 5)], rate: 48000).integrated)
        let pieces = try #require(analyze([(-18, 5), (-30, 5)], rate: 48000, chunk: 777).integrated)
        #expect(abs(whole - pieces) < 1e-6)
    }

    @Test func reportsSilenceAndShortInputAsUnmeasurable() {
        #expect(analyze([(-120, 5)], rate: 48000).integrated == nil)
        #expect(analyze([(-20, 0.3)], rate: 48000).integrated == nil)
    }

    @Test func measuresSamplePeakAndDuration() {
        let result = analyze([(-6, 2)], rate: 48000)
        #expect(abs(20 * log10(result.samplePeak) + 6) < 0.01 && abs(result.seconds - 2) < 1e-9)
    }

    @Test func countsMonoOnBothSpeakers() throws {
        let mono = try #require(analyze([(-23, 10)], rate: 48000, channels: 1).integrated)
        #expect(abs(mono - -23) < 0.1)   // same level as the identical signal on two channels
    }

    @Test func gatesAlbumLoudnessOverTheUnionOfBlocks() throws {
        let quiet = analyze([(-30, 10)], rate: 48000), loud = analyze([(-20, 30)], rate: 48000)
        let album = try #require(LoudnessAnalyzer.integrated(quiet.blockEnergies + loud.blockEnergies))
        // 97 blocks at 1e-3 and 297 at 1e-2 (mean-square), all above the relative gate: L(0.007784) = −21.09 LUFS,
        // well above the −25 LUFS mean of the two track values.
        #expect(abs(album - -21.09) < 0.1)
    }
}

@Suite(.enabled(if: FFmpeg.path != nil))
struct LoudnessOracleTests {
    private func compare(_ ext: String, _ args: [String], truncate: Bool = false) throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "lm-ln-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: url) }
        try #require(try FFmpeg.run(["-f", "lavfi", "-i", "anoisesrc=color=pink:amplitude=0.3:duration=8:sample_rate=96000:seed=7"]
                                    + args + [url.path]) == 0)
        if truncate {
            let handle = try FileHandle(forUpdating: url)
            try handle.truncate(atOffset: try handle.seekToEnd() / 2)
            try handle.close()
        }
        let ours = try #require(try LoudnessAnalyzer.analyze(url).integrated)
        let theirs = try #require(try FFmpeg.integratedLoudness(url))
        #expect(abs(ours - theirs) < 0.3, "\(args) ours \(ours) ffmpeg \(theirs)")
    }

    @Test func agreesWithFFmpegEBUR128() throws {
        try compare("flac", ["-ac", "2"])
    }

    /// A cut-off download still measures what decodes instead of failing.
    @Test func measuresTruncatedFiles() throws {
        try compare("flac", ["-ac", "2"], truncate: true)
        try compare("mp3", ["-ac", "2"], truncate: true)
    }

    /// Only the left surround carries sound. AAC stores it 4th (C L R Ls Rs LFE), where FLAC keeps LFE, so weighting
    /// by index would drop it; by label it weighs 1.41.
    @Test func weightsSurroundChannelsByLayout() throws {
        try compare("m4a", ["-af", "pan=5.1|BL=c0", "-ar", "48000", "-c:a", "aac", "-b:a", "384k"])
    }
}

extension FFmpeg {
    /// Integrated loudness from `ffmpeg -af ebur128` (the summary's `I:` line).
    static func integratedLoudness(_ url: URL) throws -> Double? {
        let process = Process()
        process.executableURL = URL(filePath: path!)
        process.arguments = ["-hide_banner", "-nostats", "-i", url.path, "-af", "ebur128=framelog=quiet", "-f", "null", "-"]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output.split(separator: "\n").last { $0.contains("I:") && $0.contains("LUFS") }
            .flatMap { $0.split(separator: " ").compactMap { Double($0) }.first }
    }
}

@Suite(.enabled(if: FFmpeg.path != nil))
struct LoudnessServiceTests {
    private let dir = FileManager.default.temporaryDirectory.appending(path: "lm-lsvc-\(UUID().uuidString)")

    private func tone(_ name: String, amplitude: Double) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        try #require(try FFmpeg.run(["-f", "lavfi", "-i", "sine=frequency=1000:duration=2:sample_rate=48000", "-af", "volume=\(amplitude)",
                                     "-ac", "2", url.path]) == 0)
        return url
    }

    private func settle(_ service: LoudnessService) async throws -> LoudnessService.Progress {
        var last = LoudnessService.Progress()
        for await progress in service.progress {
            last = progress
            if progress.pending == 0 { break }
        }
        return last
    }

    @Test func analyzesOnceAndReanalyzesOnlyChangedFiles() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let loud = try tone("loud.flac", amplitude: 0.5)
        _ = try tone("quiet.flac", amplitude: 0.05)
        try Data("not audio".utf8).write(to: dir.appending(path: "broken.wav"))
        let store = try LibraryStore(url: dir.appending(path: ".db/library.sqlite"))
        _ = try await LibraryScanner.scan(store: store, roots: LibraryRoots(include: [dir.path], exclude: []))

        let service = LoudnessService(store: store)
        await service.refresh()
        #expect(try await settle(service) == LoudnessService.Progress(analyzed: 2, total: 2))
        let records = try await store.loudness(for: try await store.rows().map(\.id))
        let loudness = records.values.compactMap(\.integrated).sorted()
        #expect(loudness.count == 2 && abs(loudness[1] - loudness[0] - 20) < 0.1)   // 20 dB apart
        #expect(records.values.allSatisfy { $0.blockEnergies.count == 17 })         // 2 s → (20 hops − 3) blocks

        #expect(try await store.loudnessPending().isEmpty)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: loud.path)
        _ = try await LibraryScanner.scan(store: store, roots: LibraryRoots(include: [dir.path], exclude: []))
        #expect(try await store.loudnessPending().map(\.url.lastPathComponent) == ["loud.flac"])
        #expect(try await store.loudness(for: try await store.rows().map(\.id)).count == 1)   // the stale result is dropped
    }

    @Test func recordsFailuresAndSkipsDeletedTracks() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try tone("a.flac", amplitude: 0.5)
        let store = try LibraryStore(url: dir.appending(path: ".db/library.sqlite"))
        _ = try await LibraryScanner.scan(store: store, roots: LibraryRoots(include: [dir.path], exclude: []))
        let job = try #require(try await store.loudnessPending().first)
        try await store.saveLoudness(job, .failure(TagError.truncated))
        #expect(try await store.loudnessProgress() == LoudnessService.Progress(analyzed: 0, failed: 1, total: 1))
        #expect(try await store.loudness(for: [job.trackID]).isEmpty)
        #expect(try await store.loudnessPending().isEmpty)   // not retried until the file changes

        let gone = LoudnessJob(trackID: 42, url: dir.appending(path: "gone.flac"), size: 1, mtime: 1)
        try await store.saveLoudness(gone, .failure(TagError.truncated))   // no such track: ignored, no FK error
        #expect(try await store.loudness(for: [42]).isEmpty)
    }

    @Test func upgradesAVersion1Database() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appending(path: "v1.sqlite"))
        try db.execute(Schema.migrations[0] + "PRAGMA user_version = 1;")
        try db.run("""
            INSERT INTO track(path, file_size, file_mtime, added_at, scanned_at, format, duration, title_source)
            VALUES ('/a.flac', 1, 0, 0, 0, 'flac', 1, 'tag')
            """)
        try Schema.migrate(db)
        #expect(try db.userVersion() == 2)
        #expect(try db.query("SELECT COUNT(*) FROM track") { $0.int(0) } == [1])
        #expect(try db.query("SELECT COUNT(*) FROM loudness") { $0.int(0) } == [0])
    }
}
