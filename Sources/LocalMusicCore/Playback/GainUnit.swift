import AudioToolbox
import AVFAudio
import Synchronization

/// In-process gain effect. A change armed for a render sample time lands exactly on that frame (the first frame of the
/// next track at a gapless join); any other change ramps over a few milliseconds so it doesn't click, or snaps while
/// nothing sounds. Built-in effects only apply scheduled parameters at render-cycle granularity, hence a unit of our own.
final class GainUnit: AUAudioUnit {
    struct Plan: Sendable {
        var gain: Float = 1
        /// Render sample time from which `next` applies.
        var switchAt = Float64.infinity
        var next: Float = 1
        /// Bumped to jump straight to the plan instead of ramping (the player was stopped, nothing to click).
        var snaps = 0
    }

    static let component = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0x6C6D_676E,
                                                     componentManufacturer: 0x4C6F_4D75, componentFlags: 0, componentFlagsMask: 0)
    /// Registers the component once; `AVAudioUnitEffect(audioComponentDescription:)` then instantiates it synchronously.
    static let registered: Void = AUAudioUnit.registerSubclass(GainUnit.self, as: component, name: "LocalMusic: Gain", version: 1)

    private let renderer = Renderer()
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [try AUAudioUnitBus(format: format)])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [try AUAudioUnitBus(format: format)])
        maximumFramesToRender = 4096
    }

    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }

    func set(_ db: Float, snap: Bool) {
        renderer.requested.withLock {
            $0.gain = Self.linear(db)
            $0.switchAt = .infinity
            if snap { $0.snaps += 1 }
        }
    }

    /// Keeps the current gain until render sample `time`, then `db`.
    func arm(at time: Float64, _ db: Float) {
        renderer.requested.withLock {
            $0.switchAt = time
            $0.next = Self.linear(db)
        }
    }

    /// Drops an armed switch: `db` from now on, or `next` if the render has already crossed the switch.
    func disarm(_ db: Float, next: Float?, snap: Bool) {
        let rendered = Float64(renderer.renderedUntil.load(ordering: .relaxed))
        renderer.requested.withLock { plan in
            plan.gain = Self.linear(next.map { rendered > plan.switchAt ? $0 : db } ?? db)
            plan.switchAt = .infinity
            if snap { plan.snaps += 1 }
        }
    }

    private static func linear(_ db: Float) -> Float { pow(10, db / 20) }

    override func allocateRenderResources() throws {
        let format = inputs[0].format
        guard format.channelCount == outputs[0].format.channelCount, format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFramesToRender) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        try super.allocateRenderResources()
        renderer.allocate(buffer, smoothing: 1 - exp(-1 / Float(0.005 * format.sampleRate)))
    }

    override func deallocateRenderResources() {
        renderer.deallocate()
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        { [renderer] flags, timestamp, frames, _, output, _, pullInput in
            guard let pullInput else { return kAudioUnitErr_NoConnection }
            guard let input = renderer.prepare(frames) else { return kAudioUnitErr_TooManyFramesToProcess }
            let status = pullInput(flags, timestamp, frames, 0, input.unsafeMutablePointer)
            guard status == noErr else { return status }
            // Never block the render thread: on contention keep last cycle's plan (changes are armed well ahead).
            if let requested = renderer.requested.withLockIfAvailable({ $0 }) { renderer.plan = requested }
            renderer.apply(input, UnsafeMutableAudioBufferListPointer(output), frames: Int(frames), at: timestamp.pointee.mSampleTime)
            return noErr
        }
    }

    /// `requested` is shared; everything else belongs to the render thread, except (de)allocation, which the host never
    /// overlaps with rendering.
    private final class Renderer: @unchecked Sendable {
        let requested = Mutex(Plan())
        /// Render sample time just past the last rendered frame.
        let renderedUntil = Atomic<Int64>(0)
        var plan = Plan()
        private var buffer: AVAudioPCMBuffer?
        private var capacity: AUAudioFrameCount = 0
        private var channels: [UnsafeMutablePointer<Float>] = []
        private var list: UnsafeMutableAudioBufferListPointer?
        private var applied: Float = 1
        private var snaps = 0
        private var smoothing: Float = 0

        func allocate(_ buffer: AVAudioPCMBuffer, smoothing: Float) {
            self.buffer = buffer
            capacity = buffer.frameCapacity
            channels = (0..<Int(buffer.format.channelCount)).map { buffer.floatChannelData![$0] }
            list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            self.smoothing = smoothing
        }

        func deallocate() {
            buffer = nil
            capacity = 0
            channels = []
            list = nil
        }

        /// The input list pointed back at our own memory: the upstream node may have swapped in its buffers last time.
        func prepare(_ frames: AUAudioFrameCount) -> UnsafeMutableAudioBufferListPointer? {
            guard let list, frames <= capacity else { return nil }
            for (c, data) in channels.enumerated() {
                list[c].mData = UnsafeMutableRawPointer(data)
                list[c].mDataByteSize = frames * 4
            }
            return list
        }

        func apply(_ input: UnsafeMutableAudioBufferListPointer, _ output: UnsafeMutableAudioBufferListPointer, frames: Int, at time: Float64) {
            if plan.snaps != snaps {
                snaps = plan.snaps
                applied = time >= plan.switchAt ? plan.next : plan.gain
            }
            let offset = plan.switchAt - time
            let crossing = offset >= 0 && offset < Float64(frames)
            let join = crossing ? Int(offset) : offset < 0 ? 0 : frames
            var end = applied
            for c in 0..<min(input.count, output.count) {
                if output[c].mData == nil { output[c].mData = input[c].mData }
                output[c].mDataByteSize = input[c].mDataByteSize
                let source = input[c].mData!.assumingMemoryBound(to: Float.self)
                let target = output[c].mData!.assumingMemoryBound(to: Float.self)
                var gain = applied
                for f in 0..<frames {
                    if crossing && f == join { gain = plan.next }
                    let goal = f < join ? plan.gain : plan.next
                    if gain != goal { gain = abs(goal - gain) < 1e-6 ? goal : gain + (goal - gain) * smoothing }
                    target[f] = source[f] * gain
                }
                end = gain
            }
            applied = end
            renderedUntil.store(Int64(time) + Int64(frames), ordering: .relaxed)
        }
    }
}
