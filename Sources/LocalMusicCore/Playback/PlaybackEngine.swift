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
        /// Restarted after the output changed (another device, sample rate); the position jumped to what was heard.
        case restarted
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

    /// Following each song's rate: the output rate for a file's (nil: stay). Setting it again retries after a failure.
    public var preferredRate: ((Double) -> Double?)? { didSet { switchFailure = nil } }
    /// Moves the output device to a rate, returning the rate to run the graph at (nil: the device's), or throws.
    public var switchRate: ((Double) async throws -> Double?)?
    /// Why the last switch failed; following stays off until `preferredRate` is set again.
    public private(set) var switchFailure: String?
    public var isSwitching: Bool { switching != nil }
    /// Rendering (tests: not while a switch has the engine stopped).
    var isRunning: Bool { engine.isRunning }

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
    /// Render and player sample times at the last tick, and the output latency then: what has been heard can still be
    /// placed once the engine has stopped.
    private var anchor: (render: AVAudioFramePosition, player: AVAudioFramePosition, latency: Double)?
    private var outputDevice: AudioDeviceID = 0
    /// The graph's rate when it doesn't follow the device's (stand-in devices); the output unit converts.
    private var graphRate: Double?
    private var configurationTask: Task<Void, Never>?
    /// A rate switch under way, and what plays once the device is free (nil: stopped meanwhile); an output change asked
    /// for meanwhile waits for it too.
    private var switching: Task<Void, Never>?
    private var pendingSwitch: (item: PlaybackItem, file: AVAudioFile, time: Double)?
    private var pendingOutput: (device: AudioDeviceID?, rate: Double?)?
    /// Bumped when what the switch is for changes (another item, another device), so a rate may be tried again.
    private var switchRequest = 0

    public init(mode: Mode = .device) throws {
        GainUnit.registered
        gainNode = AVAudioUnitEffect(audioComponentDescription: GainUnit.component)
        gain = gainNode.withAUAudioUnit { $0 as! GainUnit }
        [player, channelMixer, gainNode].forEach(engine.attach)
        if case .offline(let rate) = mode {
            isOffline = true
            try engine.enableManualRenderingMode(.offline, format: Self.stereo(rate), maximumFrameCount: 4096)
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
        let open = segments.first { $0.item.entryID == item.entryID }?.file
            ?? pendingSwitch.flatMap { $0.item.entryID == item.entryID ? $0.file : nil }
        let file = try open ?? AVAudioFile(forReading: item.url)
        guard file.length > 0 else { throw PlaybackError.emptyFile }
        if switching != nil { return hold(item, file, at: time, playing: autoplay) }
        if autoplay, wantedRate(file) != nil { return beginSwitch(item, file, at: time, drain: false) }
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
        anchor = nil
        let segment = schedule(item, file, from: time, playerStart: 0)
        enter(segment, snap: true)
        position = Double(segment.startFrame) / segment.rate
        if autoplay { try resume() } else { isPlaying = false }
    }

    public func resume() throws {
        guard let current else { return }
        if switching != nil { return isPlaying = true }
        if reachedEnd { return try play(current) }
        if let segment = segments.first(where: { $0.id == currentSegment }), wantedRate(segment.file) != nil {
            return beginSwitch(current, segment.file, at: position, drain: false)
        }
        anchor = nil
        if !engine.isRunning { try engine.start() }
        try player.playAudio()
        isPlaying = true
    }

    public func pause() {
        if switching != nil { return isPlaying = false }   // the switch ends paused
        tick()   // the position as heard, where a restart while paused picks up
        guard isPlaying else { return }
        player.pause()
        if !isOffline { engine.pause() }   // release the audio hardware while paused
        isPlaying = false
        disarm()   // resuming shifts the player timeline against render time
    }

    public func stop() {
        generation += 1
        pendingSwitch = nil
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
        if pendingSwitch != nil { update(&pendingSwitch!.item) }
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
            let latency = isOffline ? 0 : engine.outputNode.presentationLatency
            if isPlaying { anchor = (renderTime.sampleTime, playerTime.sampleTime, latency) }
            let now = rendered - latency
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

    /// Plays on `device` (nil: stays on the current one) with the graph at `rate` (nil: the device's; offline, the
    /// rendering rate), carrying on from what was heard. On failure it stays wherever the output unit is, paused.
    public func setOutput(device: AudioDeviceID?, rate: Double?) throws {
        if switching != nil {
            switchRequest += 1
            return pendingOutput = (device, rate)
        }
        generation += 1
        let point = reachedEnd ? nil : heard().map { ($0.segment.item, $0.time) }, wasPlaying = isPlaying
        engine.stop()
        do {
            if isOffline {
                if let rate { try renderOffline(at: rate) }
            } else {
                if let device { try engine.outputNode.withAUAudioUnit { try $0.setDeviceID(device) } }
                graphRate = rate
            }
            try connectOutput()
        } catch {
            try? connectOutput()
            carryOn(from: point, autoplay: false)
            throw error
        }
        carryOn(from: point, autoplay: wasPlaying)
    }

    // MARK: Offline rendering

    public func render(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames)!
        _ = try engine.renderOffline(frames, to: buffer)
        return buffer
    }

    // MARK: Internals

    private func connectOutput() throws {
        let (rate, device) = liveOutput
        outputRate = rate > 0 ? rate : 48000
        outputDevice = device
        playerFormat = nil   // the player must follow the new output rate
        let format = Self.stereo(outputRate)
        try engine.connectNode(channelMixer, to: gainNode, format: format)
        try engine.connectNode(gainNode, to: engine.mainMixerNode, format: format)
        // Explicit, so a new device's rate is converted once, in the output unit.
        try engine.connectNode(engine.mainMixerNode, to: engine.outputNode, format: format)
        if metering {
            gainNode.removeTap(onBus: 0)
            try? gainNode.installAudioTap(onBus: 0, bufferSize: 2048, format: nil, tapProvider: OutputMeter.tap(meter))
        }
    }

    private static func stereo(_ rate: Double) -> AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)! }

    /// The graph's rate and the output device as they are now (the device is 0 offline).
    private var liveOutput: (rate: Double, device: AudioDeviceID) {
        isOffline ? (engine.manualRenderingFormat.sampleRate, 0)
            : (graphRate ?? engine.outputNode.outputFormat(forBus: 0).sampleRate, engine.outputNode.withAUAudioUnit { $0.deviceID })
    }

    /// The output rate to switch to before playing this file, when following songs' rates.
    private func wantedRate(_ file: AVAudioFile) -> Double? {
        guard switchRate != nil, switchFailure == nil, let rate = preferredRate?(file.processingFormat.sampleRate),
              rate != outputRate else { return nil }
        return rate
    }

    private func fits(_ file: AVAudioFile) -> Bool {
        guard wantedRate(file) == nil, let playerFormat, playerFormat.channelCount == file.processingFormat.channelCount else { return false }
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
        if let file = try? AVAudioFile(forReading: next.url), file.length > 0, wantedRate(file) != nil {
            beginSwitch(next, file, at: 0, drain: true)
            return onEvent?(.advanced(next)) ?? ()
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

    /// Stops, moves the device to the item's rate, then plays it (paused if paused meanwhile); after a track that ended
    /// (`drain`), only once its rendered tail has been heard. A device switch, once begun, runs to its end: playing,
    /// seeking or stopping meanwhile only changes what follows, and the item then due is checked again (and switched
    /// for). A failed switch plays at the output's rate and stops following until asked again.
    private func beginSwitch(_ item: PlaybackItem, _ file: AVAudioFile, at time: Double, drain: Bool) {
        generation += 1
        player.stop()
        (segments, handoff, currentSegment, anchor, armed, reachedEnd) = ([], nil, nil, nil, nil, false)
        hold(item, file, at: time, playing: true)
        switching = Task {
            if drain, !isOffline { try? await Task.sleep(for: .seconds(engine.outputNode.presentationLatency + 0.25)) }
            engine.stop()
            // A rate tried again for the same request failed (or didn't take).
            var tried: Set<Double> = [], request = switchRequest
            while true {
                if let output = pendingOutput {
                    pendingOutput = nil
                    if isOffline {
                        if let rate = output.rate { try? renderOffline(at: rate) }
                    } else {
                        do {
                            if let device = output.device { try engine.outputNode.withAUAudioUnit { try $0.setDeviceID(device) } }
                            graphRate = output.rate
                        } catch {}   // the device went: stay where the output is
                    }
                }
                try? connectOutput()
                if request != switchRequest { (tried, request) = ([], switchRequest) }
                guard let pending = pendingSwitch, let rate = wantedRate(pending.file) else { break }
                do {
                    guard tried.insert(rate).inserted, let switchRate else { throw OutputDeviceError.timedOut }
                    let graph = try await switchRate(rate)
                    if graph == nil, !isOffline { try await hardwareRate(rate) }
                    if isOffline { try renderOffline(at: rate) } else { graphRate = graph }
                } catch is CancellationError {
                    // Superseded (following turned off, another device): what's asked now decides.
                } catch {
                    switchFailure = "无法切换到 \(String(format: "%g", rate / 1000)) kHz"
                }
            }
            switching = nil
            guard let pending = pendingSwitch else { return }
            // The file opened already: a failure here is the output's, so pause rather than skip through the queue.
            if (try? play(pending.item, at: pending.time, autoplay: isPlaying)) == nil { isPlaying = false }
            if switching == nil { pendingSwitch = nil }
            onEvent?(.restarted)
        }
    }

    /// What plays once the device switch is done.
    private func hold(_ item: PlaybackItem, _ file: AVAudioFile, at time: Double, playing: Bool) {
        if pendingSwitch?.item.entryID != item.entryID { switchRequest += 1 }
        pendingSwitch = (item, file, time)
        let rate = file.processingFormat.sampleRate
        (current, position, duration, fileSampleRate, isPlaying) = (item, time, Double(file.length) / rate, rate, playing)
    }

    /// Waits (up to 1.5 s) for the output unit to report the device's new rate.
    private func hardwareRate(_ rate: Double) async throws {
        for _ in 0..<75 {
            if engine.outputNode.outputFormat(forBus: 0).sampleRate == rate { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw OutputDeviceError.timedOut
    }

    private func renderOffline(at rate: Double) throws {
        guard rate != engine.manualRenderingFormat.sampleRate else { return }
        engine.stop()
        engine.disableManualRenderingMode()
        try engine.enableManualRenderingMode(.offline, format: Self.stereo(rate), maximumFrameCount: 4096)
    }

    /// The segment and time in its file last heard: what the gain unit rendered, placed on the player timeline through
    /// the last tick's anchor, less what the output hadn't played yet. Without an anchor (paused, just started), the
    /// ticked position.
    private func heard() -> (segment: Segment, time: Double)? {
        guard let first = segments.first(where: { $0.id == currentSegment }) else { return nil }
        guard isPlaying, let anchor else { return (first, position) }
        let now = Double(anchor.player + gain.renderedUntil - anchor.render) / outputRate - anchor.latency
        let segment = segments.last { $0.playerStart <= now } ?? first
        let time = Double(segment.startFrame) / segment.rate + max(now - segment.playerStart, 0)
        return (segment, min(time, segment.duration))
    }

    /// The output changed under the engine, which stopped: reconnect at the output's rate and carry on from what was
    /// heard, paused if the device playing went away (unplugged headphones shouldn't switch to the speakers). A burst
    /// of notifications is handled once; completions of the stopped player are ignored meanwhile (the tick still ends
    /// the queue if nothing restarts).
    private func configurationChanged() {
        guard switching == nil else { return }   // our own switch; it reconnects when done
        generation += 1
        configurationTask?.cancel()
        configurationTask = Task {
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            restart(deviceGone: outputDevice != 0 && !HAL.isAlive(outputDevice))
        }
    }

    private func restart(deviceGone: Bool) {
        // Nothing changed for the running graph: leave it (and its gapless player) alone.
        if !deviceGone, engine.isRunning, liveOutput == (outputRate, outputDevice) { return }
        let point = reachedEnd ? nil : heard().map { ($0.segment.item, $0.time) }
        guard (try? connectOutput()) != nil else { return }
        carryOn(from: point, autoplay: isPlaying && !deviceGone)
    }

    private func carryOn(from point: (item: PlaybackItem, time: Double)?, autoplay: Bool) {
        guard let (item, time) = point else { return }
        let previous = current?.entryID
        // A failure here is the output's, not the file's: stop rather than skip through the queue.
        if (try? play(item, at: time, autoplay: autoplay)) == nil { isPlaying = false }
        if current?.entryID != previous, let current { onEvent?(.advanced(current)) }
        onEvent?(.restarted)
    }

    /// As when the output changes under a playing engine (tests, self-tests).
    public func simulateConfigurationChange(deviceGone: Bool = false) {
        generation += 1
        engine.stop()
        restart(deviceGone: deviceGone)
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
