import Foundation
import Observation
import LocalMusicCore

@Observable final class LibraryModel {
    private(set) var index = LibraryIndex(rows: [])
    private(set) var roots = LibraryRoots(include: [], exclude: [])
    private(set) var started = false
    private(set) var scanning = false
    private(set) var lastScan: ScanReport?
    private(set) var lastError: String?
    private(set) var liked: [Int64: Date] = [:]

    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var rescanRequested = false
    @ObservationIgnored private var writes: Task<Void, Never>?
    @ObservationIgnored var onReload: (() -> Void)?

    init(store: LibraryStore) {
        self.store = store
    }

    /// Loads the cached snapshot, starts watching, then brings the index up to date. `roots` overrides stored ones.
    func start(roots override: LibraryRoots? = nil) async {
        guard !started else { return }
        started = true
        do {
            if let override { try await store.setRoots(override) }
            roots = try await store.roots()
            liked = try await store.liked()
            try await reload()
        } catch {
            lastError = String(describing: error)
            return
        }
        watch()
        await scan()
    }

    /// Returns once a scan that began after this call has finished; concurrent requests coalesce into one extra pass.
    /// The scan runs in its own task, so cancelling a caller (debounce, view task) never interrupts it.
    func scan() async {
        rescanRequested = true
        if let scanTask { return await scanTask.value }
        let task = Task {
            await runScans()
            scanTask = nil   // same job as the loop's exit check, so no request can slip in between
        }
        scanTask = task
        await task.value
    }

    private func runScans() async {
        scanning = true
        while rescanRequested {
            rescanRequested = false
            do {
                let report = try await LibraryScanner.scan(store: store, roots: roots)
                lastScan = report
                if report.parsed + report.removed > 0 { try await reload() }
                lastError = nil
            } catch {
                lastError = String(describing: error)
            }
        }
        scanning = false
    }

    func add(_ url: URL, excluded: Bool) async {
        let path = url.standardizedFileURL.path
        guard !roots.include.contains(path), !roots.exclude.contains(path) else { return }
        var updated = roots
        if excluded { updated.exclude.append(path) } else { updated.include.append(path) }
        await apply(updated)
    }

    func remove(_ path: String) async {
        var updated = roots
        updated.include.removeAll { $0 == path }
        updated.exclude.removeAll { $0 == path }
        await apply(updated)
    }

    private func apply(_ updated: LibraryRoots) async {
        do {
            try await store.setRoots(updated)
            roots = updated
        } catch {
            lastError = String(describing: error)
            return
        }
        watch()
        await scan()
    }

    func setLiked(_ ids: [Int64], _ on: Bool) {
        for id in ids { liked[id] = on ? liked[id] ?? .now : nil }
        write { try await $0.setLiked(ids, on) }
    }

    /// Store writes run one after another, in call order, off the main actor so a quit can wait for them.
    private func write(_ body: @escaping @Sendable (LibraryStore) async throws -> Void) {
        let store = store
        writes = Task.detached { [previous = writes, weak self] in
            await previous?.value
            do { try await body(store) } catch { await MainActor.run { self?.lastError = String(describing: error) } }
        }
    }

    /// On quit, blocking, like `PlayerModel.saveBeforeQuit`.
    func finishWrites() {
        guard let writes else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await writes.value
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    func lyrics(for trackID: Int64) async -> Lyrics? {
        (try? await store.lyrics(for: trackID)) ?? nil
    }

    private func reload() async throws {
        let rows = try await store.rows()
        index = await Task.detached { LibraryIndex(rows: rows) }.value
        liked = liked.filter { index.tracks[$0.key] != nil }   // the store dropped removed tracks' likes itself
        onReload?()
    }

    private func watch() {
        watchTask?.cancel()
        let watcher = FSEventsWatcher(paths: roots.include)
        let resolved = roots.resolved
        watchTask = Task { [weak self] in
            for await events in watcher.events where events.contains(where: resolved.isRelevant) {
                self?.scheduleScan()
            }
        }
    }

    private func scheduleScan() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await self?.scan()
        }
    }
}
