import AVFAudio
import Foundation

public struct PlaybackItem: Sendable, Equatable {
    /// Queue entry identity, so a repeated track is still a distinct item.
    public let entryID: Int
    public let trackID: Int64
    public let url: URL
    public var gainDb: Float

    public init(entryID: Int, trackID: Int64, url: URL, gainDb: Float = 0) {
        self.entryID = entryID
        self.trackID = trackID
        self.url = url
        self.gainDb = gainDb
    }
}

public enum PlaybackError: Error {
    case unavailable
    case emptyFile
    case unsupportedChannelLayout(AVAudioChannelCount)
}

/// Gapless file player.
///
/// Graph: player ─(output rate, file channels)→ channelMixer ─(stereo)→ gain → mainMixer → output.
/// The player runs at the output rate and sample-rate converts each file itself, so files of any rate queue back to back
/// on one player timeline (gapless). Only a channel-count change needs a fresh player node, handed off once the previous
/// file has rendered. (A node whose rate differs from the output starts with a skewed timeline and stays silent for
/// about a second, which is why the player never runs at the file rate.)
@MainActor
public final class PlaybackEngine {
    public enum Mode: Sendable {
        case device
        /// Manual rendering for tests; drive it with `render(frames:)`.
        case offline(sampleRate: Double)
    }

    public enum Event: Sendable {
        /// Playback moved on to the item the caller supplied through `nextItem`.
        case advanced(PlaybackItem)
        case ended
        case failed(PlaybackItem, String)
    }

    public private(set) var current: PlaybackItem?
    public private(set) var isPlaying = false
    public private(set) var position: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var fileSampleRate: Double = 0
    public var outputSampleRate: Double { gainNode.outputFormat(forBus: 0).sampleRate }
    public var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }
    /// Post-gain, pre-volume output measurement while `metering` is on.
    public let meter = OutputMeter()
    public var metering = false {
        didSet {
            guard metering != oldValue else { return }
            gainNode.removeTap(onBus: 0)
            if metering { try? gainNode.installAudioTap(onBus: 0, bufferSize: 2048, format: nil, tapProvider: OutputMeter.tap(meter)) }
        }
    }

    /// Asked (side-effect free) for what follows the current item; queue logic stays with the caller.
    public var nextItem: (() -> PlaybackItem?)?
    public var onEvent: ((Event) -> Void)?

    private static let lookahead = 10.0

    private struct Segment {
        let id: Int
        var item: PlaybackItem
        let file: AVAudioFile
        let startFrame: AVAudioFramePosition
        let frames: AVAudioFrameCount
        let rate: Double
        /// Seconds on the player timeline where this segment starts.
        let playerStart: Double

        var duration: Double { Double(file.length) / rate }
        var playerEnd: Double { playerStart + Double(frames) / rate }
    }

    private let engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let channelMixer = AVAudioMixerNode()
    private let gainNode: AVAudioUnitEffect
    private let gain: GainUnit
    /// The next segment and render sample its gain switch is armed for.
    private var armed: (segment: Int, at: AVAudioFramePosition)?
    private let isOffline: Bool
    private var playerFormat: AVAudioFormat?
    private var outputRate = 48000.0
    private var segments: [Segment] = []
    private var currentSegment: Int?
    private var segmentCounter = 0
    /// Bumped whenever the player is stopped, so completions of abandoned segments are ignored.
    private var generation = 0
    private var lookaheadDone = false
    /// A next item needing a fresh player node, started once the current one has rendered.
    private var handoff: PlaybackItem?
    /// Everything queued has played; resuming restarts the current item.
    private var reachedEnd = false

    public init(mode: Mode = .device) throws {
        GainUnit.registered
        gainNode = AVAudioUnitEffect(audioComponentDescription: GainUnit.component)
        gain = gainNode.withAUAudioUnit { $0 as! GainUnit }
        [player, channelMixer, gainNode].forEach(engine.attach)
        if case .offline(let rate) = mode {
            isOffline = true
            try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!,
                                                 maximumFrameCount: 4096)
        } else {
            isOffline = false
            NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main,
                                                   using: Self.configurationChanged(self))
        }
        try connectOutput()
    }

    // MARK: Transport

    public func play(_ item: PlaybackItem, at time: Double = 0, autoplay: Bool = true) throws {
        // Reuse the open file when re-positioning the same item: Core Audio builds a FLAC seek index on the first seek
        // (≈0.5 s for a large 192 kHz file without a SEEKTABLE) and keeps it per file object.
        let file = try segments.first { $0.item.entryID == item.entryID }?.file ?? AVAudioFile(forReading: item.url)
        guard file.length > 0 else { throw PlaybackError.emptyFile }
        let newFormat = fits(file) ? nil : try playerFormat(for: file)
        generation += 1
        player.stop()
        segments = []
        handoff = nil
        reachedEnd = false
        if let format = newFormat {
            // A reconnected node keeps its old timeline; a fresh one starts clean.
            engine.detach(player)
            player = AVAudioPlayerNode()
            engine.attach(player)
            try engine.connectNode(player, to: channelMixer, format: format)
            playerFormat = format
        }
        let segment = schedule(item, file, from: time, playerStart: 0)
        enter(segment, snap: true)
        position = Double(segment.startFrame) / segment.rate
        if autoplay { try resume() } else { isPlaying = false }
    }

    public func resume() throws {
        guard let current else { return }
        if reachedEnd { return try play(current) }
        if !engine.isRunning { try engine.start() }
        try player.playAudio()
        isPlaying = true
    }

    public func pause() {
        guard isPlaying else { return }
        player.pause()
        if !isOffline { engine.pause() }   // release the audio hardware while paused
        isPlaying = false
        disarm()   // resuming shifts the player timeline against render time
    }

    public func stop() {
        generation += 1
        player.stop()
        if !isOffline { engine.pause() }
        segments = []
        handoff = nil
        current = nil
        currentSegment = nil
        isPlaying = false
        position = 0
        duration = 0
    }

    public func seek(to time: Double) throws {
        guard let current else { return }
        try play(current, at: time, autoplay: isPlaying)
    }

    /// Call after the caller's notion of "next" changed (queue edit, shuffle, repeat mode).
    public func nextChanged() {
        guard let current, let currentSegment else { return }
        let scheduled = segments.last.flatMap { $0.id == currentSegment ? nil : $0.item.entryID } ?? handoff?.entryID
        if let scheduled, nextItem?()?.entryID == scheduled { return }
        if segments.last?.id != currentSegment {
            // A stale next item is already queued in the player: rebuild from the current position.
            try? play(current, at: position, autoplay: isPlaying)
        }
        handoff = nil
        lookaheadDone = false
    }

    /// Re-evaluates the queued items' gains (mode changed, analyses arrived); a changed current one ramps to its level.
    public func updateGains(_ gainDb: (PlaybackItem) -> Float) {
        var changed = false
        func update(_ item: inout PlaybackItem) {
            let new = gainDb(item)
            if new != item.gainDb { (item.gainDb, changed) = (new, true) }
        }
        for i in segments.indices { update(&segments[i].item) }
        if current != nil { update(&current!) }
        if handoff != nil { update(&handoff!) }
        guard changed else { return }
        disarm()
        armGain()
    }

    /// Advances position and item boundaries; call periodically (the app runs it at 20 Hz while playing).
    public func tick() {
        guard let currentSegment, !segments.isEmpty else { return }
        // playerTime(forNodeTime:) raises an ObjC exception for a render time that isn't valid yet (fresh node).
        if let renderTime = player.lastRenderTime, renderTime.isSampleTimeValid,
           let playerTime = player.playerTime(forNodeTime: renderTime) {
            let rendered = Double(playerTime.sampleTime) / playerTime.sampleRate
            let now = rendered - (isOffline ? 0 : engine.outputNode.presentationLatency)
            let segment = segments.last { $0.playerStart <= now } ?? segments[0]
            let switched = segment.id != currentSegment
            if switched {
                segments.removeAll { $0.id < segment.id }
                enter(segment, snap: false)
            }
            position = min(Double(segment.startFrame) / segment.rate + max(now - segment.playerStart, 0), duration)
            if switched { onEvent?(.advanced(segment.item)) }
            // Don't wait for the asynchronous completion callback once the player has rendered everything queued.
            if let last = segments.last, rendered >= last.playerEnd {
                return finished(generation: generation, segment: last.id)
            }
            armGain()
        }
        lookAhead()
    }

    // MARK: Offline rendering

    public func render(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames)!
        _ = try engine.renderOffline(frames, to: buffer)
        return buffer
    }

    // MARK: Internals

    private func connectOutput() throws {
        let rate = isOffline ? engine.manualRenderingFormat.sampleRate : engine.outputNode.outputFormat(forBus: 0).sampleRate
        outputRate = rate > 0 ? rate : 48000
        playerFormat = nil   // the player must follow the new output rate
        let format = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
        try engine.connectNode(channelMixer, to: gainNode, format: format)
        try engine.connectNode(gainNode, to: engine.mainMixerNode, format: format)
    }

    private func fits(_ file: AVAudioFile) -> Bool {
        guard let playerFormat, playerFormat.channelCount == file.processingFormat.channelCount else { return false }
        return playerFormat.channelCount <= 2 || playerFormat.channelLayout?.layoutTag == file.processingFormat.channelLayout?.layoutTag
    }

    /// Output rate with the file's channels; beyond stereo the layout tells the mixer how to downmix.
    private func playerFormat(for file: AVAudioFile) throws -> AVAudioFormat {
        let source = file.processingFormat
        if source.channelCount <= 2 { return AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: source.channelCount)! }
        guard let layout = source.channelLayout else { throw PlaybackError.unsupportedChannelLayout(source.channelCount) }
        return AVAudioFormat(standardFormatWithSampleRate: outputRate, channelLayout: layout)
    }

    @discardableResult
    private func schedule(_ item: PlaybackItem, _ file: AVAudioFile, from time: Double, playerStart: Double) -> Segment {
        let rate = file.processingFormat.sampleRate
        let start = min(max(AVAudioFramePosition((time * rate).rounded()), 0), file.length - 1)
        segmentCounter += 1
        let segment = Segment(id: segmentCounter, item: item, file: file, startFrame: start,
                              frames: AVAudioFrameCount(file.length - start), rate: rate, playerStart: playerStart)
        segments.append(segment)
        player.scheduleSegment(file, startingFrame: start, frameCount: segment.frames, at: nil,
                               completionCallbackType: .dataRendered,
                               completionHandler: Self.completion(self, generation: generation, segment: segment.id))
        return segment
    }

    /// `snap` when the player was stopped; otherwise the gain was either switched on the joining frame already or, if
    /// that couldn't be armed in time, ramps now.
    private func enter(_ segment: Segment, snap: Bool) {
        currentSegment = segment.id
        current = segment.item
        duration = segment.duration
        fileSampleRate = segment.rate
        lookaheadDone = false
        gain.set(Self.level(segment), snap: snap)
        armed = nil
    }

    /// The item's gain, plus 3 dB for mono: the channel mixer spreads it over both speakers at −3 dB each, whereas its
    /// loudness is measured (and other players play it) as dual mono.
    private static func level(_ segment: Segment) -> Float {
        segment.item.gainDb + (segment.file.processingFormat.channelCount == 1 ? 3.0103 : 0)
    }

    /// Drops the armed switch, keeping whichever side of the join the render (ahead of what's heard) has reached.
    private func disarm() {
        guard let segment = segments.first(where: { $0.id == currentSegment }) else { return }
        gain.disarm(Self.level(segment), next: segments.last.flatMap { $0.id == segment.id ? nil : Self.level($0) }, snap: !isPlaying)
        armed = nil
    }

    /// Pins the next segment's gain to its first frame in render time. Re-checked every tick while the player renders, as
    /// pausing shifts the player timeline against render time; left alone once the render has passed the join.
    private func armGain() {
        guard isPlaying, let next = segments.last, next.id != currentSegment,
              let render = player.lastRenderTime, render.isSampleTimeValid,
              let played = player.playerTime(forNodeTime: render), Double(played.sampleTime) / played.sampleRate < next.playerStart,
              let at = player.nodeTime(forPlayerTime: AVAudioTime(sampleTime: AVAudioFramePosition((next.playerStart * outputRate).rounded()),
                                                                  atRate: outputRate)),
              at.isSampleTimeValid, armed?.segment != next.id || armed?.at != at.sampleTime else { return }
        armed = (next.id, at.sampleTime)
        gain.arm(at: Float64(at.sampleTime), Self.level(next))
    }

    private func lookAhead() {
        guard isPlaying, !lookaheadDone, let last = segments.last, last.id == currentSegment,
              duration - position < Self.lookahead else { return }
        lookaheadDone = true
        guard let next = nextItem?() else { return }
        // Repeat-one reuses the open file (and its seek index). Anything unusual — a new channel layout, an empty or
        // unreadable file — goes through the handoff, so a failure surfaces only when that item is actually due.
        if let file = next.entryID == last.item.entryID ? last.file : try? AVAudioFile(forReading: next.url),
           fits(file), file.length > 0 {
            schedule(next, file, from: 0, playerStart: last.playerEnd)
        } else {
            handoff = next
        }
    }

    /// The last queued segment finished rendering: hand off to a differently formatted next item, or end.
    private func finished(generation: Int, segment: Int) {
        guard generation == self.generation, !reachedEnd, segments.last?.id == segment else { return }
        let next = handoff ?? (lookaheadDone ? nil : nextItem?())
        handoff = nil
        guard let next else {
            isPlaying = false
            reachedEnd = true
            position = duration
            releaseHardware(after: isOffline ? 0 : engine.outputNode.presentationLatency + 0.2)
            onEvent?(.ended)
            return
        }
        do {
            try play(next)
            onEvent?(.advanced(next))
        } catch {
            isPlaying = false
            reachedEnd = true
            releaseHardware(after: 0)
            onEvent?(.failed(next, String(describing: error)))
        }
    }

    /// Pauses an idle engine so the Mac can sleep; after the end, only once the rendered tail has been heard.
    private func releaseHardware(after delay: Double) {
        guard !isOffline else { return }
        let generation = generation
        Task {
            try? await Task.sleep(for: .seconds(delay))
            if generation == self.generation, !isPlaying { engine.pause() }
        }
    }

    private func configurationChanged() {
        guard (try? connectOutput()) != nil, let current, !reachedEnd else { return }
        try? play(current, at: position, autoplay: isPlaying)
    }

    // Callback factories: nonisolated, so the closures are not MainActor-isolated and may run on AVFAudio's threads.

    nonisolated private static func completion(_ engine: PlaybackEngine, generation: Int, segment: Int)
        -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { [weak engine] _ in Task { @MainActor in engine?.finished(generation: generation, segment: segment) } }
    }

    nonisolated private static func configurationChanged(_ engine: PlaybackEngine) -> @Sendable (Notification) -> Void {
        { [weak engine] _ in Task { @MainActor in engine?.configurationChanged() } }
    }
}
