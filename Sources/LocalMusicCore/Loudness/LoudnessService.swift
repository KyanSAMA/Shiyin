import Foundation

public struct LoudnessRecord: Sendable, Equatable {
    public var integrated: Double?
    public var samplePeak: Double
    public var blockEnergies: [Float]
}

struct LoudnessJob: Sendable, Equatable {
    let trackID: Int64
    let url: URL
    let size: Int64
    let mtime: Double
}

/// Background analysis of the library: two workers at utility priority, prioritized ids first (current track, queue).
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

    public nonisolated let progress: AsyncStream<Progress>
    private let continuation: AsyncStream<Progress>.Continuation
    private let store: LibraryStore
    private var queue: [LoudnessJob] = []
    private var priority: [Int64] = []
    private var inFlight: [Int64: LoudnessJob] = [:]
    private static let workers = 2
    private static let decoder = DispatchQueue(label: "loudness", qos: .utility, attributes: .concurrent)

    public init(store: LibraryStore) {
        self.store = store
        (progress, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Re-reads what needs analysis (after a scan) and keeps the workers busy.
    public func refresh() async {
        let pending = (try? await store.loudnessPending()) ?? []
        queue = pending.filter { inFlight[$0.trackID] != $0 }
        reorder()
        await publish()
        pump()
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
        await publish()
        pump()
    }

    private func publish() async {
        guard let progress = try? await store.loudnessProgress() else { return }
        continuation.yield(progress)
    }
}
