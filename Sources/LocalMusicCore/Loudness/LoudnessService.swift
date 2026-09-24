import Foundation

struct LoudnessRecord: Sendable, Equatable {
    var integrated: Double?
    var samplePeak: Double
    var blockEnergies: [Float]
}

struct LoudnessSummary: Sendable, Equatable {
    let integrated: Double?
    /// nil when the analysis failed.
    let samplePeak: Double?
}

struct LoudnessJob: Sendable, Equatable {
    let trackID: Int64
    let url: URL
    let size: Int64
    let mtime: Double
}

/// Background analysis of the library and the gains derived from it: two workers at utility priority, prioritized ids
/// first (current track, its album, the queue).
public actor LoudnessService {
    public struct Progress: Sendable, Equatable {
        public var analyzed = 0
        public var failed = 0
        public var total = 0
        public var pending: Int { total - analyzed - failed }

        public init(analyzed: Int = 0, failed: Int = 0, total: Int = 0) {
            self.analyzed = analyzed
            self.failed = failed
            self.total = total
        }
    }

    public struct Update: Sendable {
        public var progress: Progress
        public var gains: GainTable
    }

    public nonisolated let updates: AsyncStream<Update>
    private let continuation: AsyncStream<Update>.Continuation
    private let store: LibraryStore
    private var queue: [LoudnessJob] = []
    private var priority: [Int64] = []
    private var inFlight: [Int64: LoudnessJob] = [:]
    private var albums: [[Int64]] = []
    /// By member ids, reused while every member's analysis is unchanged.
    private var albumGains: [[Int64]: AlbumGain] = [:]
    private var publishing = false
    private var republish = false
    private static let workers = 2
    private static let decoder = DispatchQueue(label: "loudness", qos: .utility, attributes: .concurrent)

    public init(store: LibraryStore) {
        self.store = store
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Re-reads what needs analysis (after a scan) and keeps the workers busy. `albums`: the track ids of each album
    /// that should get an album gain.
    public func refresh(albums: [[Int64]]) async {
        self.albums = albums
        let pending = (try? await store.loudnessPending()) ?? []
        queue = pending.filter { inFlight[$0.trackID] != $0 }
        reorder()
        pump()
        await publish()
    }

    public func prioritize(_ ids: [Int64]) {
        priority = ids
        reorder()
        pump()
    }

    private func reorder() {
        let rank = Dictionary(priority.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        queue.sort { (rank[$0.trackID] ?? .max, $0.trackID) < (rank[$1.trackID] ?? .max, $1.trackID) }
    }

    /// A file that changed while being analyzed waits in the queue until its stale job finishes.
    private func pump() {
        while inFlight.count < Self.workers, let next = queue.firstIndex(where: { inFlight[$0.trackID] == nil }) {
            let job = queue.remove(at: next)
            inFlight[job.trackID] = job
            Task {
                // Decoding blocks, so it runs on a dispatch queue rather than tying up the cooperative pool.
                let result = await withCheckedContinuation { continuation in
                    Self.decoder.async { continuation.resume(returning: Result { try LoudnessAnalyzer.analyze(job.url) }) }
                }
                await finish(job, result)
            }
        }
    }

    private func finish(_ job: LoudnessJob, _ result: Result<LoudnessResult, Error>) async {
        try? await store.saveLoudness(job, result)
        inFlight[job.trackID] = nil
        pump()
        await publish()
    }

    /// Serialized, so the last update reflects the latest analyses however the awaits interleave.
    private func publish() async {
        guard !publishing else { return republish = true }
        publishing = true
        repeat {
            republish = false
            guard let progress = try? await store.loudnessProgress(), let summaries = try? await store.loudnessSummaries() else { break }
            var table = GainTable(tracks: summaries.compactMapValues { summary in
                summary.samplePeak.map { GainTable.gain(integrated: summary.integrated, peak: $0) }
            })
            var gains: [[Int64]: AlbumGain] = [:]
            // An album gets its gain once none of its tracks is pending; failed ones are left out.
            for ids in albums {
                let members = ids.compactMap { summaries[$0] }
                guard members.count == ids.count, members.contains(where: { $0.samplePeak != nil }) else { continue }
                if let cached = albumGains[ids], cached.members == members {
                    gains[ids] = cached
                    continue
                }
                let analyzed = zip(ids, members).compactMap { $1.samplePeak == nil ? nil : $0 }
                guard let records = try? await store.loudness(for: analyzed), records.count == analyzed.count else { continue }
                // Gated over the union of the album's blocks, so quiet interludes don't drag the album level down.
                let integrated = LoudnessAnalyzer.integrated(analyzed.flatMap { records[$0]!.blockEnergies })
                gains[ids] = AlbumGain(members: members, gainDb: GainTable.gain(integrated: integrated, peak: members.compactMap(\.samplePeak).max()!))
            }
            albumGains = gains
            // A failed track's peak is unknown, so it stays on the fallback rather than risk an album boost.
            for (ids, album) in gains { for id in ids where table.isMeasured(id) { table.albums[id] = album.gainDb } }
            continuation.yield(Update(progress: progress, gains: table))
        } while republish
        publishing = false
    }

    private struct AlbumGain {
        let members: [LoudnessSummary]
        let gainDb: Double
    }
}
