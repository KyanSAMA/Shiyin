import AVFAudio
import Synchronization

/// Measures rendered audio (engine tap or offline buffers): level, loudness, continuity and gaps. Thread-safe.
public final class OutputMeter: Sendable {
    public struct Reading: Sendable, Equatable {
        public var seconds = 0.0
        public var rmsDbfs = -120.0
        public var peakDbfs = -120.0
        /// Largest sample-to-sample jump; a glitch in a smooth test tone shows up here.
        public var maxStep = 0.0
        /// Longest run of digital silence between two sounding frames (leading/trailing silence ignored).
        public var longestGapMs = 0.0
        public var channelRmsDbfs: [Double] = []
        /// BS.1770 integrated loudness; nil for silence or less than one 400 ms block.
        public var integratedLufs: Double?
    }

    /// Seconds rather than frames, as the rate can change mid-measurement (following songs' rates).
    private struct State {
        var rate = 0.0
        var frames = 0
        var seconds = 0.0
        var sumSquares: [Double] = []
        var peak: Float = 0
        var maxStep: Float = 0
        var last: [Float] = []
        var sounded = false
        var zeroRun = 0.0
        var longestGap = 0.0
        var loudness: LoudnessAnalyzer?
    }

    private let state = Mutex(State())

    public init() {}

    public func reset() { state.withLock { $0 = State() } }

    public func process(_ buffer: AVAudioPCMBuffer) {
        process(AVReadOnlyAudioPCMBuffer(copying: buffer))
    }

    public func process(_ buffer: AVReadOnlyAudioPCMBuffer) {
        let channels = Int(buffer.format.channelCount), frames = buffer.frameLength
        var sounding = [Bool](repeating: false, count: frames)
        let samples = (0..<channels).map { c -> [Float] in
            guard case .float(let span) = buffer.channelData(c) else { return [] }
            return span.withUnsafeBufferPointer(Array.init)
        }
        state.withLock { s in
            if s.sumSquares.count != channels || s.rate != buffer.format.sampleRate {
                if s.sumSquares.count != channels { s.sumSquares = Array(repeating: 0, count: channels) }
                s.last = Array(repeating: .nan, count: channels)
                s.loudness = LoudnessAnalyzer(sampleRate: buffer.format.sampleRate, channels: channels)
            }
            s.loudness?.process(samples)
            s.rate = buffer.format.sampleRate
            for c in 0..<channels {
                guard case .float(let samples) = buffer.channelData(c) else { continue }
                var last = s.last[c], sum = 0.0
                for f in 0..<frames {
                    let x = samples[f]
                    sum += Double(x * x)
                    s.peak = max(s.peak, abs(x))
                    if !last.isNaN { s.maxStep = max(s.maxStep, abs(x - last)) }
                    last = x
                    if x != 0 { sounding[f] = true }
                }
                s.last[c] = last
                s.sumSquares[c] += sum
            }
            let period = 1 / buffer.format.sampleRate
            for f in 0..<frames {
                if sounding[f] {
                    s.longestGap = max(s.longestGap, s.zeroRun)
                    s.zeroRun = 0
                    s.sounded = true
                } else if s.sounded {
                    s.zeroRun += period
                }
            }
            s.frames += frames
            s.seconds += Double(frames) * period
        }
    }

    public var reading: Reading {
        state.withLock { s in
            func dbfs(_ power: Double) -> Double { power > 0 ? max(10 * log10(power), -120) : -120 }
            let frames = Double(max(s.frames, 1))
            let channelPower = s.sumSquares.map { $0 / frames }
            return Reading(seconds: s.seconds,
                           rmsDbfs: dbfs(channelPower.reduce(0, +) / Double(max(channelPower.count, 1))),
                           peakDbfs: dbfs(Double(s.peak * s.peak)), maxStep: Double(s.maxStep),
                           longestGapMs: s.longestGap * 1000,
                           channelRmsDbfs: channelPower.map(dbfs), integratedLufs: s.loudness?.result.integrated)
        }
    }

    static func tap(_ meter: OutputMeter) -> @Sendable (AVReadOnlyAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in meter.process(buffer) }
    }
}
