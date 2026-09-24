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
    private(set) var lyrics: Lyrics?
    /// True between a track change and its lyrics arriving (so the page doesn't flash 暂无歌词).
    private(set) var lyricsLoading = false
    /// Changes only when playback crosses a line, so the lyric list doesn't re-render at 20 Hz.
    private(set) var lyricIndex: Int?
    /// Slider value while the user drags the scrubber.
    var scrubbing: Double?

    @ObservationIgnored let engine: PlaybackEngine
    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private let muted: Bool
    @ObservationIgnored private var rng = SystemRandomNumberGenerator()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var lyricsTrack: Int64?
    @ObservationIgnored var onChange: (() -> Void)?

    init(library: LibraryModel, muted: Bool) throws {
        self.library = library
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

    func setVolume(_ value: Float) {
        volume = min(max(value, 0), 1)
        engine.volume = muted ? 0 : volume
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
        library.index.tracks[entry.trackID].map { PlaybackItem(entryID: entry.id, trackID: $0.id, url: $0.url) }
    }

    /// Plays the current entry; an unplayable one is skipped, at most once per queue entry so an all-bad queue on
    /// repeat can't spin.
    private func startCurrent(attempt: Int = 0) {
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
            engine.stop()
            if attempt + 1 < queue.entries.count, queue.skipForward() != nil { return startCurrent(attempt: attempt + 1) }
        }
        sync()
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
        case .ended:
            break
        case .failed(let item, let message):
            lastError = message
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
        loadLyricsIfNeeded()
        updateLyricIndex()
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

    private func updateLyricIndex() {
        let index = lyrics?.index(at: position)
        if index != lyricIndex { lyricIndex = index }
    }
}
