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
    private(set) var playlists: [Playlist] = []

    @ObservationIgnored let store: LibraryStore
    /// Files with a tag backup (written to by the app), which 恢复原标签 can put back.
    private(set) var backedUp: Set<String> = []
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var rescanRequested = false
    @ObservationIgnored private var writes: Task<Void, Never>?
    @ObservationIgnored private var reloads = 0
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
            playlists = try await store.playlists()
            try await store.recoverTagWrites()
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

    /// Manual edits (nil removes one) for these recordings; returns once the library shows them. A manual cover (a file
    /// in the covers directory) that's replaced or removed is deleted, and so is a new one that couldn't be stored.
    func setUserEdits(_ fingerprints: [String], _ edits: [EnrichField: String?]) async {
        write { store in
            let cover = edits[.cover] ?? nil
            var replaced: [String] = []
            if edits[.cover] != nil {
                for fingerprint in fingerprints { if let old = try await store.enrichment(fingerprint, source: .user)[.cover] { replaced.append(old) } }
            }
            let covers = store.coversDirectory
            do { try await store.setEnrichment(fingerprints, edits, source: .user) } catch {
                if let cover { try? FileManager.default.removeItem(at: covers.appending(path: cover)) }
                throw error
            }
            for old in replaced where old != cover { try? FileManager.default.removeItem(at: covers.appending(path: old)) }
        }
        await reloadAfterWrites()
    }

    /// Also deletes the manual covers' files.
    func revertUserEdits(_ fingerprints: [String]) async {
        write { store in
            var covers: [String] = []
            for fingerprint in fingerprints { if let cover = try await store.enrichment(fingerprint, source: .user)[.cover] { covers.append(cover) } }
            try await store.clearEnrichment(fingerprints, source: .user)
            for cover in covers { try? FileManager.default.removeItem(at: store.coversDirectory.appending(path: cover)) }
        }
        await reloadAfterWrites()
    }

    func embeddedLyrics(_ trackID: Int64) async -> String? {
        (try? await store.embeddedLyrics(trackID: trackID)) ?? nil
    }

    func enrichedLyrics(_ fingerprint: String) async -> (text: String, manual: Bool)? {
        (try? await store.enrichedLyrics(fingerprint)) ?? nil
    }

    func userEdits(_ fingerprint: String) async -> [EnrichField: String] {
        (try? await store.enrichment(fingerprint, source: .user)) ?? [:]
    }

    /// The songs as they'd show without these layers.
    func rows(_ ids: [Int64], without sources: [EnrichSource]) async -> [TrackRow] {
        (try? await store.rows(ids, without: sources)) ?? []
    }

    /// One recording's online layers; covers as paths.
    func layers(_ fingerprint: String) async -> [OnlineSource: [EnrichField: String]] {
        var layers: [OnlineSource: [EnrichField: String]] = [:]
        for source in OnlineSource.allCases {
            var values = (try? await store.enrichment(fingerprint, source: .online(source))) ?? [:]
            values[.cover] = values[.cover].map { store.coversDirectory.appending(path: $0).path }
            if !values.isEmpty { layers[source] = values }
        }
        return layers
    }

    /// After enrichment stored new values.
    func refresh() async {
        do { try await reload() } catch { lastError = String(describing: error) }
    }

    private func reloadAfterWrites() async {
        await writes?.value
        await refresh()
    }

    func playlist(_ id: Int64) -> Playlist? { playlists.first { $0.id == id } }

    /// Returns once stored: the id comes from the store.
    func createPlaylist(_ name: String, tracks: [Int64]) async -> Playlist? {
        let store = store
        let create = Task.detached { [previous = writes] in
            await previous?.value
            return try await store.createPlaylist(name, tracks: tracks)
        }
        writes = Task.detached { _ = try? await create.value }
        do {
            let playlist = try await create.value
            playlists.append(playlist)
            return playlist
        } catch {
            lastError = String(describing: error)
            return nil
        }
    }

    func renamePlaylist(_ id: Int64, _ name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].name = name
        write { try await $0.renamePlaylist(id, name) }
    }

    func deletePlaylist(_ id: Int64) {
        playlists.removeAll { $0.id == id }
        write { try await $0.deletePlaylist(id) }
    }

    /// Tracks already in the playlist keep their place.
    func addToPlaylist(_ id: Int64, _ tracks: [Int64]) {
        guard let playlist = playlist(id) else { return }
        setTracks(id, playlist.trackIDs + tracks)
    }

    func removeFromPlaylist(_ id: Int64, _ tracks: Set<Int64>) {
        guard let playlist = playlist(id) else { return }
        setTracks(id, playlist.trackIDs.filter { !tracks.contains($0) })
    }

    /// Moves `tracks` together, in playlist order, to before position `target` (as counted before the move).
    func movePlaylistTracks(_ id: Int64, _ tracks: Set<Int64>, to target: Int) {
        guard let ids = playlist(id)?.trackIDs else { return }
        let target = min(max(target, 0), ids.count)
        let rest = { (slice: ArraySlice<Int64>) in slice.filter { !tracks.contains($0) } }
        setTracks(id, rest(ids[..<target]) + ids.filter(tracks.contains) + rest(ids[target...]))
    }

    private func setTracks(_ id: Int64, _ tracks: [Int64]) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        var seen = Set<Int64>()
        let unique = tracks.filter { index.tracks[$0] != nil && seen.insert($0).inserted }   // as the store keeps them
        guard unique != playlists[i].trackIDs else { return }
        playlists[i].trackIDs = unique
        write { try await $0.setPlaylistTracks(id, unique) }
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

    /// Only the latest of overlapping reloads (a scan's, an edit's) lands: it read the newest rows.
    private func reload() async throws {
        reloads += 1
        let generation = reloads
        let rows = try await store.rows()
        let index = await Task.detached { LibraryIndex(rows: rows) }.value
        guard generation == reloads else { return }
        self.index = index
        backedUp = (try? await store.tagBackupPaths()) ?? []
        // The store dropped removed tracks' likes and playlist entries itself.
        liked = liked.filter { index.tracks[$0.key] != nil }
        for i in playlists.indices { playlists[i].trackIDs.removeAll { index.tracks[$0] == nil } }
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
