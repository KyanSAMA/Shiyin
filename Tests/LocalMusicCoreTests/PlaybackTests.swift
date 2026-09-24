import AVFAudio
import Foundation
import Testing
@testable import LocalMusicCore

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct PlayQueueTests {
    private var rng = SplitMix64(state: 42)

    private func queue(_ tracks: [Int64], start: Int = 0, repeat mode: RepeatMode = .off) -> PlayQueue {
        var q = PlayQueue()
        var rng = SplitMix64(state: 1)
        q.replace(with: tracks, start: start, using: &rng)
        q.repeatMode = mode
        return q
    }

    @Test func advancesAndSkipsPerRepeatMode() {
        var off = queue([1, 2, 3], start: 2)
        #expect(off.peekNext() == nil)
        let offAdvance = off.advance(), offSkip = off.skipForward(), offBack = off.skipBackward()
        #expect(offAdvance == nil && offSkip == nil && offBack?.trackID == 2)

        var all = queue([1, 2, 3], start: 2, repeat: .all)
        #expect(all.peekNext()?.trackID == 1)
        let allAdvance = all.advance()
        #expect(allAdvance?.trackID == 1 && all.index == 0)
        let allBack = all.skipBackward()
        #expect(allBack?.trackID == 3)

        var one = queue([1, 2, 3], start: 1, repeat: .one)
        #expect(one.peekNext()?.trackID == 2)
        let oneAdvance = one.advance()
        #expect(oneAdvance?.trackID == 2 && one.index == 1)
        let oneSkip = one.skipForward()
        #expect(oneSkip?.trackID == 3)
    }

    @Test mutating func shuffleKeepsCurrentFirstAndRestoresOrder() {
        var q = queue(Array(1...20), start: 5)
        let current = q.current
        q.setShuffle(true, using: &rng)
        #expect(q.current == current && q.index == 0)
        #expect(Set(q.entries.map(\.trackID)) == Set(1...20) && q.entries.map(\.trackID) != Array(1...20))
        q.setShuffle(false, using: &rng)
        #expect(q.entries.map(\.trackID) == Array(1...20) && q.current == current)
    }

    @Test mutating func replaceWhileShuffledStartsWithTheChosenTrack() {
        var q = queue([1, 2, 3])
        q.setShuffle(true, using: &rng)
        q.replace(with: Array(10...30), start: 4, using: &rng)
        #expect(q.shuffled && q.current?.trackID == 14 && q.index == 0)
    }

    @Test func editsTheQueue() {
        var q = queue([1, 2, 3], start: 0)
        q.insertNext([9])
        q.append([7])
        #expect(q.entries.map(\.trackID) == [1, 9, 2, 3, 7])
        q.moveUpcoming([q.entries[4].id], before: q.entries[1].id)
        #expect(q.upcoming.map(\.trackID) == [7, 9, 2, 3])
        q.moveUpcoming([q.entries[1].id, -5], before: nil)
        #expect(q.upcoming.map(\.trackID) == [9, 2, 3, 7])
        q.moveUpcoming([q.entries[4].id], before: q.entries[1].id)
        let removedCurrent = q.remove([q.entries[2].id])
        #expect(!removedCurrent && q.entries.map(\.trackID) == [1, 7, 2, 3] && q.current?.trackID == 1)
        let removedCurrentNow = q.remove([q.entries[0].id])
        #expect(removedCurrentNow && q.current?.trackID == 7)
        q.clearUpcoming()
        #expect(q.entries.map(\.trackID) == [7])
        var empty = PlayQueue()
        empty.clearUpcoming()
        #expect(empty.entries.isEmpty)
    }

    @Test mutating func keepsOrderAndCurrentWhenEditingAnIdleQueue() {
        var q = PlayQueue()
        q.insertNext([9])
        q.insertNext([8])
        q.setShuffle(true, using: &rng)
        q.setShuffle(false, using: &rng)
        #expect(q.entries.map(\.trackID) == [9, 8] && q.current?.trackID == 9)

        var ended = queue([1], start: 0)
        _ = ended.remove([ended.entries[0].id])
        ended.append([7, 6])
        #expect(ended.current?.trackID == 7)
        #expect(ended.select(ended.entries[1].id) && ended.current?.trackID == 6 && !ended.select(-1))
    }

    @Test func distinguishesRepeatedTracks() {
        var q = queue([5, 5])
        #expect(q.entries[0].id != q.entries[1].id)
        let next = q.advance()
        #expect(next?.id == q.entries[1].id)
    }
}

/// Writes float CAF files whose samples come from `sample(globalFrame, channel)`.
private enum ToneFile {
    static func write(_ url: URL, rate: Double, channels: Int = 2, frames: Range<Int>, sample: (Int) -> Float) throws {
        let format = channels == 6
            ? AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)!)
            : AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames.count))!
        buffer.frameLength = AVAudioFrameCount(frames.count)
        for c in 0..<channels {
            for (i, frame) in frames.enumerated() { buffer.floatChannelData![c][i] = sample(frame) }
        }
        try file.write(from: buffer)
    }

    /// 375 Hz at 48 kHz has an exact 128-sample period, so whole-second files loop without a seam.
    static func sine(_ frame: Int, rate: Double = 48000) -> Float { 0.5 * sin(2 * .pi * 375 * Float(Double(frame) / rate)) }
}

@MainActor
private final class OfflineRig {
    let dir = FileManager.default.temporaryDirectory.appending(path: "lm-play-\(UUID().uuidString)")
    let engine: PlaybackEngine
    let meter = OutputMeter()
    var events: [PlaybackEngine.Event] = []
    var upcoming: [PlaybackItem] = []
    private var entry = 0

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        engine = try PlaybackEngine(mode: .offline(sampleRate: 48000))
        engine.nextItem = { [unowned self] in upcoming.first }
        engine.onEvent = { [unowned self] event in
            events.append(event)
            if case .advanced = event { upcoming.removeFirst() }
        }
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func item(_ name: String, rate: Double = 48000, channels: Int = 2, frames: Range<Int>, sample: (Int) -> Float) throws -> PlaybackItem {
        let url = dir.appending(path: "\(name).caf")
        try ToneFile.write(url, rate: rate, channels: channels, frames: frames, sample: sample)
        entry += 1
        return PlaybackItem(entryID: entry, trackID: Int64(entry), url: url)
    }

    /// Renders in small chunks, ticking and yielding so completion callbacks reach the main actor between chunks.
    func render(seconds: Double, chunk: AVAudioFrameCount = 256) async throws {
        var remaining = Int(seconds * 48000)
        while remaining > 0 {
            meter.process(try engine.render(frames: chunk))
            engine.tick()
            remaining -= Int(chunk)
            await Task.yield()
        }
    }

    var advanced: Int { events.filter { if case .advanced = $0 { true } else { false } }.count }
    var ended: Bool { events.contains { if case .ended = $0 { true } else { false } } }
}

@MainActor
struct PlaybackEngineTests {
    @Test func joinsSameFormatFilesWithoutAGap() async throws {
        let rig = try OfflineRig()
        let split = 264_601, total = 576_000   // 12 s = 4500 whole periods, split mid-buffer
        let first = try rig.item("a", frames: 0..<split) { ToneFile.sine($0) }
        rig.upcoming = [try rig.item("b", frames: split..<total) { ToneFile.sine($0) }]
        try rig.engine.play(first)
        try await rig.render(seconds: 12.3)

        let reading = rig.meter.reading
        #expect(reading.maxStep < 0.03)          // a dropped or repeated sample would jump ~0.05
        #expect(reading.longestGapMs < 1)
        #expect(rig.advanced == 1 && rig.ended)
        #expect(abs(reading.rmsDbfs - -9.03) < 0.2)
    }

    @Test func joinsDifferentSampleRatesWithoutAGap() async throws {
        let rig = try OfflineRig()
        let first = try rig.item("a", rate: 44100, frames: 0..<88200) { ToneFile.sine($0, rate: 44100) }
        let second = try rig.item("b", rate: 96000, frames: 0..<192_000) { ToneFile.sine($0, rate: 96000) }
        rig.upcoming = [second]
        try rig.engine.play(first)
        try await rig.render(seconds: 3)

        #expect(rig.advanced == 1 && rig.engine.current == second && rig.engine.fileSampleRate == 96000)
        #expect(rig.meter.reading.longestGapMs < 1 && rig.meter.reading.maxStep < 0.05)
        #expect(abs(rig.engine.position - 1.0) < 0.02)
    }

    @Test func handsOffWhenTheChannelCountChanges() async throws {
        let rig = try OfflineRig()
        let stereo = try rig.item("stereo", frames: 0..<48000) { ToneFile.sine($0) }
        let mono = try rig.item("mono", channels: 1, frames: 0..<48000) { ToneFile.sine($0) }
        rig.upcoming = [mono]
        try rig.engine.play(stereo)
        try await rig.render(seconds: 1.5)
        #expect(rig.advanced == 1 && rig.engine.current == mono)
        #expect(rig.meter.reading.longestGapMs < 50)
        #expect(abs(rig.engine.position - 0.5) < 0.05)
    }

    @Test func seeksSampleAccurately() async throws {
        let rig = try OfflineRig()
        let frames = 240_000   // the sample value encodes its own position
        let ramp = try rig.item("ramp", frames: 0..<frames) { Float($0) / Float(frames) }
        try rig.engine.play(ramp, at: 2.5)
        let buffer = try rig.engine.render(frames: 4096)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        let first = try #require(samples.first { $0 != 0 })
        #expect(abs(Double(first) * Double(frames) / 48000 - 2.5) < 0.002)
        #expect(rig.engine.position == 2.5)
    }

    @Test func loopsRepeatOneSeamlessly() async throws {
        let rig = try OfflineRig()
        let loop = try rig.item("loop", frames: 0..<48000) { ToneFile.sine($0) }
        rig.engine.nextItem = { loop }
        rig.engine.onEvent = { rig.events.append($0) }
        try rig.engine.play(loop)
        try await rig.render(seconds: 3.5)
        #expect(rig.meter.reading.maxStep < 0.03 && rig.meter.reading.longestGapMs < 1)
        #expect(rig.advanced == 3 && !rig.ended)
    }

    @Test func reportsPositionAndIgnoresCallbacksAfterStop() async throws {
        let rig = try OfflineRig()
        let tone = try rig.item("tone", frames: 0..<24000) { ToneFile.sine($0) }
        try rig.engine.play(tone)
        try await rig.render(seconds: 0.25)
        #expect(abs(rig.engine.position - 0.25) < 0.02 && rig.engine.isPlaying)
        rig.engine.stop()
        try await rig.render(seconds: 1)
        #expect(rig.events.isEmpty && rig.engine.current == nil)
    }

    @Test func playsMonoOnBothChannels() async throws {
        let rig = try OfflineRig()
        let mono = try rig.item("mono", channels: 1, frames: 0..<48000) { ToneFile.sine($0) }
        try rig.engine.play(mono)
        try await rig.render(seconds: 0.5)
        let channels = rig.meter.reading.channelRmsDbfs
        #expect(channels.count == 2 && channels.allSatisfy { $0 > -20 } && abs(channels[0] - channels[1]) < 0.1)
    }

    @Test func downmixesSurroundFiles() async throws {
        let rig = try OfflineRig()
        let surround = try rig.item("surround", channels: 6, frames: 0..<48000) { ToneFile.sine($0) }
        try rig.engine.play(surround)
        try await rig.render(seconds: 0.5)
        #expect(rig.meter.reading.channelRmsDbfs.allSatisfy { $0 > -30 })
    }

    @Test func reportsTheNewTrackPositionWithTheAdvance() async throws {
        let rig = try OfflineRig()
        let first = try rig.item("a", frames: 0..<48000) { ToneFile.sine($0) }
        rig.upcoming = [try rig.item("b", frames: 0..<48000) { ToneFile.sine($0) }]
        var positionAtAdvance = -1.0
        rig.engine.onEvent = { event in
            if case .advanced = event { positionAtAdvance = rig.engine.position }
            rig.events.append(event)
        }
        try rig.engine.play(first)
        try await rig.render(seconds: 1.5)
        #expect(positionAtAdvance >= 0 && positionAtAdvance < 0.1)
    }

    @Test func failsOnAMissingNextItemOnceAndStopsCleanly() async throws {
        let rig = try OfflineRig()
        let tone = try rig.item("tone", frames: 0..<24000) { ToneFile.sine($0) }
        rig.upcoming = [PlaybackItem(entryID: 99, trackID: 99, url: rig.dir.appending(path: "gone.caf"))]
        try rig.engine.play(tone)
        try await rig.render(seconds: 1.5)
        let failures = rig.events.filter { if case .failed(let item, _) = $0 { item.entryID == 99 } else { false } }
        #expect(failures.count == 1 && !rig.ended && !rig.engine.isPlaying)
        try await rig.render(seconds: 0.5)
        #expect(rig.events.count == 1)
    }

    @Test func endsOnce() async throws {
        let rig = try OfflineRig()
        try rig.engine.play(try rig.item("tone", frames: 0..<12000) { ToneFile.sine($0) })
        try await rig.render(seconds: 1)
        #expect(rig.events.count == 1 && rig.ended)
        try rig.engine.resume()
        try await rig.render(seconds: 0.5)
        #expect(rig.events.count == 2 && abs(rig.engine.position - 0.25) < 0.01)
    }

    @Test func pausesAndResumesInPlace() async throws {
        let rig = try OfflineRig()
        let tone = try rig.item("tone", frames: 0..<96000) { ToneFile.sine($0) }
        try rig.engine.play(tone)
        try await rig.render(seconds: 0.5)
        rig.engine.pause()
        let paused = rig.engine.position
        try await rig.render(seconds: 0.5)
        #expect(rig.engine.position == paused && !rig.engine.isPlaying)
        try rig.engine.resume()
        try await rig.render(seconds: 0.25)
        #expect(abs(rig.engine.position - (paused + 0.25)) < 0.02)
    }
}
