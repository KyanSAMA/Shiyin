import CoreAudio
import Foundation
import Observation
import LocalMusicCore

/// Queue + transport state for the UI. Views that read `position` should be small leaves: it changes at 20 Hz.
@Observable final class PlayerModel {
    private(set) var queue = PlayQueue()
    private(set) var current: TrackRow?
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var volume: Float = 1
    private(set) var lastError: String?
    /// Following songs' rates stopped: the device wouldn't switch.
    private(set) var switchFailure: String?
    private(set) var lyrics: Lyrics?
    /// True between a track change and its lyrics arriving (so the page doesn't flash 暂无歌词).
    private(set) var lyricsLoading = false
    /// Changes only when playback crosses a line, so the lyric list doesn't re-render at 20 Hz.
    private(set) var lyricIndex: Int?
    /// Slider value while the user drags the scrubber.
    var scrubbing: Double?
    /// Shown for a few seconds after an unplayable entry (a missing file, say) was skipped.
    private(set) var skipNotice: String?

    @ObservationIgnored let engine: PlaybackEngine
    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private weak var loudness: LoudnessModel?
    @ObservationIgnored private let muted: Bool
    @ObservationIgnored private var rng = SystemRandomNumberGenerator()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var lyricsTrack: Int64?
    @ObservationIgnored private var prioritized: [Int64] = []
    /// Where a restored track resumes, until the library has loaded it.
    @ObservationIgnored private var restoredPosition: Double?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Nothing is saved before the last session was read, so an early change or quit can't overwrite it.
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var savedAt = Date.distantPast
    @ObservationIgnored var onChange: (() -> Void)?
    private static let stateKey = "playback"

    nonisolated private struct SavedState: Codable, Sendable {
        var queue: PlayQueue
        var position: Double
        var volume: Float
    }

    init(library: LibraryModel, store: LibraryStore, loudness: LoudnessModel?, muted: Bool) throws {
        self.library = library
        self.store = store
        self.loudness = loudness
        self.muted = muted
        engine = try PlaybackEngine()
        engine.volume = muted ? 0 : volume
        engine.nextItem = { [weak self] in self?.nextPlayable() }
        engine.onEvent = { [weak self] in self?.handle($0) }
    }

    // MARK: Commands

    /// `shuffle: nil` keeps the current shuffle mode (double-click in a list); the explicit 播放 / 随机播放 buttons set it.
    func play(_ tracks: [Int64], startAt index: Int, shuffle: Bool? = nil) {
        queue.replace(with: tracks, start: index, shuffle: shuffle, using: &rng)
        startCurrent()
    }

    func shufflePlay(_ tracks: [Int64]) {
        guard !tracks.isEmpty else { return }
        play(tracks, startAt: Int.random(in: tracks.indices, using: &rng), shuffle: true)
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        if engine.current == nil {
            startCurrent()
        } else {
            perform { try engine.resume() }
        }
    }

    func pause() {
        engine.pause()
        sync()
    }

    func next() {
        guard queue.skipForward() != nil else { return }
        startCurrent()
    }

    /// Restarts the track after the first few seconds, like every other player.
    func previous() {
        if position > 3 || queue.skipBackward() == nil {
            seek(to: 0)
        } else {
            startCurrent()
        }
    }

    func seek(to seconds: Double) {
        perform { try engine.seek(to: seconds) }
    }

    func seekToLyric(_ index: Int) {
        guard case .synced(let lines) = lyrics, lines.indices.contains(index) else { return }
        seek(to: lines[index].time)
    }

    func remove(_ entries: Set<Int>) {
        if queue.remove(entries) { return startCurrent() }
        queueEdited()
    }

    func moveUpcoming(_ entries: [Int], before target: Int?) {
        queue.moveUpcoming(entries, before: target)
        queueEdited()
    }

    /// After a rescan: refresh the current row and re-read its lyrics (a sidecar may have changed).
    func libraryReloaded() {
        lyricsTrack = nil
        loadRestored()
        sync()
    }

    func clearUpcoming() {
        queue.clearUpcoming()
        queueEdited()
    }

    func setShuffle(_ on: Bool) {
        queue.setShuffle(on, using: &rng)
        engine.nextChanged()
        sync()
    }

    func setRepeat(_ mode: RepeatMode) {
        queue.repeatMode = mode
        engine.nextChanged()
        sync()
    }

    /// The playing track leaves the fallback only for its own analysis or a mode change, not for the median drifting as
    /// other tracks get analyzed.
    func gainsChanged(modeChanged: Bool) {
        let playing = engine.current?.entryID
        engine.updateGains { item in
            if item.entryID == playing, !modeChanged, loudness?.isMeasured(item.trackID) == false { return item.gainDb }
            return gainDb(for: item.trackID)
        }
    }

    /// Moves playback to another output, carrying on from what was heard; false if it failed (paused where it was).
    func setOutput(device: AudioDeviceID?, rate: Double?) -> Bool {
        perform { try engine.setOutput(device: device, rate: rate) }
        return lastError == nil
    }

    func setVolume(_ value: Float) {
        volume = min(max(value, 0), 1)
        engine.volume = muted ? 0 : volume
        scheduleSave()
    }

    // MARK: Persistence

    /// Last session's queue, modes, volume and position, loaded paused.
    func restore() async {
        defer { restored = true }
        guard let state = try? await store.setting(Self.stateKey, as: SavedState.self),
              state.queue.index.map(state.queue.entries.indices.contains) ?? true, queue.entries.isEmpty else { return }
        queue = state.queue
        volume = min(max(state.volume, 0), 1)
        engine.volume = muted ? 0 : volume
        restoredPosition = state.position
        loadRestored()
    }

    private func loadRestored() {
        guard let position = restoredPosition, engine.current == nil, let entry = queue.current, let item = item(entry) else { return }
        restoredPosition = nil
        perform { try engine.play(item, at: position, autoplay: false) }
    }

    /// A track played to its end starts over next time; a restore still waiting for the library keeps its position.
    private var savedState: SavedState {
        let finished = duration > 0 && position >= duration - 0.5
        return SavedState(queue: queue, position: restoredPosition ?? (finished ? 0 : position), volume: volume)
    }

    /// On quit, blocking: while a termination is pending, AppKit's run loop mode doesn't run main-actor tasks.
    func saveBeforeQuit() {
        guard restored else { return }
        let state = savedState, store = store, key = Self.stateKey
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            try? await store.setSetting(key, state)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    /// Coalesces a burst of changes (a volume drag, skipping through tracks) into one write.
    private func scheduleSave() {
        guard restored, saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            saveTask = nil
            savedAt = .now
            try? await store.setSetting(Self.stateKey, savedState)
        }
    }

    func playNext(_ tracks: [Int64]) {
        queue.insertNext(tracks)
        queueEdited()
    }

    func addToQueue(_ tracks: [Int64]) {
        queue.append(tracks)
        queueEdited()
    }

    // MARK: Engine plumbing

    private func queueEdited() {
        engine.nextChanged()
        sync()
    }

    /// What automatic advance would play, skipping entries whose track left the library.
    private func nextPlayable() -> PlaybackItem? {
        var probe = queue
        for _ in queue.entries.indices {
            guard let entry = probe.advance() else { return nil }
            if let item = item(entry) { return item }
        }
        return nil
    }

    private func item(_ entry: QueueEntry) -> PlaybackItem? {
        library.index.tracks[entry.trackID].map { PlaybackItem(entryID: entry.id, trackID: $0.id, url: $0.url, gainDb: gainDb(for: $0.id)) }
    }

    private func gainDb(for track: Int64) -> Float {
        loudness?.gainDb(for: track) ?? 0
    }

    /// Plays the current entry; an unplayable one is skipped, at most once per queue entry so an all-bad queue on
    /// repeat can't spin.
    private func startCurrent(attempt: Int = 0) {
        restoredPosition = nil
        guard let entry = queue.current else {
            engine.stop()
            return sync()
        }
        do {
            guard let item = item(entry) else { throw PlaybackError.unavailable }
            try engine.play(item)
            lastError = nil
        } catch {
            lastError = String(describing: error)
            noteSkipped(library.index.tracks[entry.trackID]?.title)
            engine.stop()
            if attempt + 1 < queue.entries.count, queue.skipForward() != nil { return startCurrent(attempt: attempt + 1) }
        }
        sync()
    }

    private func noteSkipped(_ title: String?) {
        skipNotice = "无法播放「\(title ?? "已移出曲库的曲目")」"
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { self?.skipNotice = nil }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        sync()
    }

    private func handle(_ event: PlaybackEngine.Event) {
        switch event {
        case .advanced(let item):
            queue.select(item.entryID)
        case .ended, .restarted:
            break
        case .failed(let item, let message):
            lastError = message
            noteSkipped(library.index.tracks[item.trackID]?.title ?? item.url.deletingPathExtension().lastPathComponent)
            queue.select(item.entryID)
            if queue.skipForward() != nil { return startCurrent(attempt: 1) }
        }
        sync()
    }

    private func sync() {
        // Keep showing a track that left the library mid-play (deleted, folder excluded) until it stops.
        current = engine.current.flatMap { library.index.tracks[$0.trackID] ?? (current?.id == $0.trackID ? current : nil) }
        isPlaying = engine.isPlaying
        duration = engine.duration
        position = engine.position
        switchFailure = engine.switchFailure
        loadLyricsIfNeeded()
        updateLyricIndex()
        prioritizeLoudness()
        scheduleSave()
        if isPlaying, ticker == nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    tick()
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Playing audio")
        } else if !isPlaying, let ticker {
            ticker.cancel()
            self.ticker = nil
            activity.map(ProcessInfo.processInfo.endActivity)
            activity = nil
        }
        onChange?()
    }

    private func tick() {
        engine.tick()
        if engine.current?.trackID != current?.id || engine.isPlaying != isPlaying {
            sync()
        } else {
            position = engine.position
            updateLyricIndex()
            if isPlaying, savedAt.timeIntervalSinceNow < -10 { scheduleSave() }
        }
    }

    private func loadLyricsIfNeeded() {
        guard current?.id != lyricsTrack else { return }
        lyricsTrack = current?.id
        lyrics = nil
        guard let track = current, track.hasLyrics else { return lyricsLoading = false }
        lyricsLoading = true
        Task {
            let loaded = await library.lyrics(for: track.id)
            guard lyricsTrack == track.id else { return }
            lyrics = loaded
            lyricsLoading = false
            updateLyricIndex()
        }
    }

    /// The current track, its album and the next queued tracks get their loudness analyzed first.
    private func prioritizeLoudness() {
        guard let current else { return }
        let ids = [current.id] + (library.index.album(containing: current.id)?.trackIDs ?? []) + queue.upcoming.prefix(20).map(\.trackID)
        guard ids != prioritized else { return }
        prioritized = ids
        loudness?.prioritize(ids)
    }

    private func updateLyricIndex() {
        let index = lyrics?.index(at: position)
        if index != lyricIndex { lyricIndex = index }
    }
}
