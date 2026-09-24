import AVFAudio
import Foundation

public struct LoudnessResult: Sendable, Equatable {
    /// Integrated loudness (LUFS); nil when the programme is silent or shorter than one 400 ms block.
    public var integrated: Double?
    /// Linear sample peak across channels.
    public var samplePeak: Double
    /// Mean-square energy of every 400 ms block (75 % overlap), kept so album loudness can be gated over the union.
    public var blockEnergies: [Float]
    public var seconds: Double
}

/// ITU-R BS.1770-4 / EBU R128 integrated loudness, fed incrementally.
public struct LoudnessAnalyzer {
    public static let version = 1

    private var filters: [KWeighting]
    private let weights: [Double]
    private let hopLength: Int
    private var hopFill = 0
    private var hopEnergy = 0.0
    private var hops: [Double] = []   // the last 3 completed hops
    private var energies: [Float] = []
    private var peak: Float = 0
    private var frames = 0
    private let sampleRate: Double

    /// A mono programme counts twice (it plays on both speakers), as ffmpeg's `ebur128=dualmono=true`. With channel
    /// `labels` (from the file's layout) LFE is excluded and surrounds weigh 1.41; without, every channel weighs 1.
    public init(sampleRate: Double, channels: Int, labels: [AudioChannelLabel]? = nil) {
        self.sampleRate = sampleRate
        filters = Array(repeating: KWeighting(sampleRate: sampleRate), count: channels)
        weights = channels == 1 ? [2] : (0..<channels).map { c in labels.map { c < $0.count ? Self.weight($0[c]) : 1 } ?? 1 }
        hopLength = Int((sampleRate * 0.1).rounded())
    }

    private static func weight(_ label: AudioChannelLabel) -> Double {
        switch label {
        case kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2: 0
        case kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround, kAudioChannelLabel_LeftSurroundDirect,
             kAudioChannelLabel_RightSurroundDirect, kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight: 1.41
        default: 1
        }
    }

    /// `channels[c][f]`, non-interleaved.
    public mutating func process(_ channels: [UnsafeBufferPointer<Float>]) {
        guard let count = channels.first?.count else { return }
        var weighted = [Double](repeating: 0, count: count)
        for (c, samples) in channels.enumerated() where weights[c] > 0 {
            let weight = weights[c]
            filters[c].run(samples) { f, y in weighted[f] += weight * y * y }
        }
        for samples in channels {
            for x in samples { peak = max(peak, abs(x)) }
        }
        for energy in weighted {
            hopEnergy += energy
            hopFill += 1
            if hopFill == hopLength { completeHop() }
        }
        frames += count
    }

    private mutating func completeHop() {
        if hops.count == 3 {
            energies.append(Float((hops.reduce(0, +) + hopEnergy) / Double(4 * hopLength)))
            hops.removeFirst()
        }
        hops.append(hopEnergy)
        hopEnergy = 0
        hopFill = 0
    }

    public var result: LoudnessResult {
        LoudnessResult(integrated: Self.integrated(energies), samplePeak: Double(peak), blockEnergies: energies,
                       seconds: Double(frames) / sampleRate)
    }

    /// Two-stage gating: absolute −70 LUFS, then relative −10 LU below the absolute-gated mean.
    public static func integrated(_ energies: [Float]) -> Double? {
        let absolute = energies.filter { loudness(Double($0)) > -70 }
        guard !absolute.isEmpty else { return nil }
        let threshold = loudness(mean(absolute)) - 10
        let gated = absolute.filter { loudness(Double($0)) > threshold }
        return gated.isEmpty ? nil : loudness(mean(gated))
    }

    private static func loudness(_ energy: Double) -> Double { -0.691 + 10 * log10(energy) }
    private static func mean(_ values: [Float]) -> Double { values.reduce(0) { $0 + Double($1) } / Double(values.count) }

    /// Reads until the decoder runs dry rather than trusting `length`: a truncated or damaged file (or a FLAC whose
    /// STREAMINFO has no sample count) still yields whatever decodes, as ffmpeg does.
    public static func analyze(_ url: URL) throws -> LoudnessResult {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        var analyzer = LoudnessAnalyzer(sampleRate: format.sampleRate, channels: Int(format.channelCount), labels: labels(format))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65536) else { throw TagError.invalid("buffer") }
        while true {
            do {
                try file.read(into: buffer)
            } catch let error as NSError where error.domain == NSOSStatusErrorDomain && error.code == Int(eofErr) {
                break
            }
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            analyzer.process((0..<Int(format.channelCount)).map { UnsafeBufferPointer(start: data[$0], count: Int(buffer.frameLength)) })
        }
        return analyzer.result
    }

    /// Channel labels in file order (AVAudioFile keeps e.g. AAC 5.1 as C L R Ls Rs LFE); nil for mono/stereo or no layout.
    static func labels(_ format: AVAudioFormat) -> [AudioChannelLabel]? {
        guard format.channelCount > 2, let layout = format.channelLayout?.layout else { return nil }
        var tag = layout.pointee.mChannelLayoutTag
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions {
            return withUnsafePointer(to: layout.pointee.mChannelDescriptions) { first in
                UnsafeBufferPointer(start: first, count: Int(layout.pointee.mNumberChannelDescriptions)).map(\.mChannelLabel)
            }
        }
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag, 4, &tag, &size) == noErr else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { raw.deallocate() }
        guard AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag, 4, &tag, &size, raw) == noErr else { return nil }
        let expanded = raw.assumingMemoryBound(to: AudioChannelLayout.self)
        return withUnsafePointer(to: &expanded.pointee.mChannelDescriptions) { first in
            UnsafeBufferPointer(start: first, count: Int(expanded.pointee.mNumberChannelDescriptions)).map(\.mChannelLabel)
        }
    }
}

/// K-weighting pre-filter (high shelf + high pass), coefficients derived for any sample rate as in libebur128.
struct KWeighting {
    private let b: (Double, Double, Double, Double, Double, Double)   // stage1 b0 b1 b2, stage2 b0 b1 b2
    private let a: (Double, Double, Double, Double)                   // stage1 a1 a2, stage2 a1 a2
    private var z = (0.0, 0.0, 0.0, 0.0)                               // transposed direct form II state

    init(sampleRate fs: Double) {
        let shelf = (f0: 1681.974450955533, gain: 3.999843853973347, q: 0.7071752369554196)
        var k = tan(.pi * shelf.f0 / fs)
        let vh = pow(10, shelf.gain / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / shelf.q + k * k
        let s1b = ((vh + vb * k / shelf.q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / shelf.q + k * k) / a0)
        let s1a = (2 * (k * k - 1) / a0, (1 - k / shelf.q + k * k) / a0)
        let highPass = (f0: 38.13547087602444, q: 0.5003270373238773)
        k = tan(.pi * highPass.f0 / fs)
        a0 = 1 + k / highPass.q + k * k
        b = (s1b.0, s1b.1, s1b.2, 1, -2, 1)
        a = (s1a.0, s1a.1, 2 * (k * k - 1) / a0, (1 - k / highPass.q + k * k) / a0)
    }

    var coefficients: [Double] { [b.0, b.1, b.2, a.0, a.1, b.3, b.4, b.5, a.2, a.3] }

    mutating func run(_ samples: UnsafeBufferPointer<Float>, _ output: (Int, Double) -> Void) {
        var (z0, z1, z2, z3) = z
        for (i, sample) in samples.enumerated() {
            let x = Double(sample)
            let y1 = b.0 * x + z0
            z0 = b.1 * x - a.0 * y1 + z1
            z1 = b.2 * x - a.1 * y1
            let y2 = b.3 * y1 + z2
            z2 = b.4 * y1 - a.2 * y2 + z3
            z3 = b.5 * y1 - a.3 * y2
            output(i, y2)
        }
        z = (z0, z1, z2, z3)
    }
}
