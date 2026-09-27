import CoreAudio
import Dispatch

/// The Mac's output devices through Core Audio, kept current by property listeners.
@MainActor public final class HALOutputDevices: OutputDevices {
    public private(set) var devices: [OutputDeviceInfo] = []
    public private(set) var defaultUID: String?
    public var onChange: ((OutputDeviceChange) -> Void)?
    private var objects: [String: AudioDeviceID] = [:]
    /// Per-device listeners, replaced when the device list changes (the system object's stay for the app's life).
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []

    public init() {
        _ = listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, .list)
        _ = listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, .defaultDevice)
        reload()
    }

    public func bindingID(_ uid: String) -> AudioDeviceID? { objects[uid] }
    public func graphRate(_ uid: String) -> Double? { nil }

    private func reload() {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        listeners = []
        var found: [OutputDeviceInfo] = [], ids: [String: AudioDeviceID] = [:]
        for id in Self.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, of: AudioDeviceID.self) {
            guard let info = Self.info(id) else { continue }
            found.append(info)
            ids[info.id] = id
            if let listener = listen(id, kAudioDevicePropertyNominalSampleRate, .rate(info.id)) { listeners.append(listener) }
        }
        (devices, objects) = (found, ids)
        readDefault()
    }

    private func readDefault() {
        let current = Self.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, of: AudioDeviceID.self).first
        defaultUID = current.flatMap { id in objects.first { $0.value == id }?.key }
    }

    private func changed(_ change: OutputDeviceChange) {
        switch change {
        case .list: reload()
        case .defaultDevice: readDefault()
        case .rate(let uid):
            guard let index = devices.firstIndex(where: { $0.id == uid }), let id = objects[uid] else { return }
            devices[index].nominalRate = Self.array(id, kAudioDevicePropertyNominalSampleRate, of: Float64.self).first ?? devices[index].nominalRate
        }
        onChange?(change)
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        _ change: OutputDeviceChange) -> (AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block = Self.listener(self, change)
        return AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr ? (object, address, block) : nil
    }

    nonisolated private static func listener(_ devices: HALOutputDevices, _ change: OutputDeviceChange) -> AudioObjectPropertyListenerBlock {
        { [weak devices] _, _ in Task { @MainActor in devices?.changed(change) } }
    }

    /// A visible device with output streams.
    private static func info(_ id: AudioDeviceID) -> OutputDeviceInfo? {
        guard !array(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput, of: AudioStreamID.self).isEmpty,
              array(id, kAudioDevicePropertyIsHidden, of: UInt32.self).first != 1,
              let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let ranges = array(id, kAudioDevicePropertyAvailableNominalSampleRates, of: AudioValueRange.self)
        let rates = standardRates.filter { rate in ranges.contains { $0.mMinimum <= rate && rate <= $0.mMaximum } }
        return OutputDeviceInfo(id: uid, name: string(id, kAudioObjectPropertyName) ?? uid,
                                transport: OutputTransport(array(id, kAudioDevicePropertyTransportType, of: UInt32.self).first ?? 0),
                                rates: rates, nominalRate: array(id, kAudioDevicePropertyNominalSampleRate, of: Float64.self).first ?? 0)
    }

    private static let standardRates: [Double] = [22050, 32000, 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000]

    private static func array<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of type: T.Type) -> [T] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return [] }
        return (0..<Int(size) / MemoryLayout<T>.stride).map { buffer.load(fromByteOffset: $0 * MemoryLayout<T>.stride, as: T.self) }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
