import CoreAudio

/// Stand-in output devices for tests and self-tests, which must never touch the Mac's real ones: the engine stays on
/// its device and runs its graph at the stand-in's rate.
@MainActor public final class FakeOutputDevices: OutputDevices {
    public private(set) var devices: [OutputDeviceInfo]
    public private(set) var defaultUID: String?
    public var onChange: ((OutputDeviceChange) -> Void)?
    /// Unplugged devices, kept to plug back in.
    private var unplugged: [OutputDeviceInfo] = []

    public static let presets = [
        OutputDeviceInfo(id: "fake-speakers", name: "MacBook Pro扬声器", transport: .builtIn, rates: [44100, 48000, 88200, 96000], nominalRate: 48000),
        OutputDeviceInfo(id: "fake-headphones", name: "外置耳机", transport: .builtIn, rates: [44100, 48000, 88200, 96000], nominalRate: 48000),
        OutputDeviceInfo(id: "fake-airpods", name: "AirPods", transport: .bluetooth, rates: [48000], nominalRate: 48000),
        OutputDeviceInfo(id: "fake-dac", name: "USB DAC", transport: .usb,
                         rates: [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000], nominalRate: 48000),
    ]

    public init(devices: [OutputDeviceInfo] = presets) {
        self.devices = devices
        defaultUID = devices.first?.id
    }

    public func bindingID(_ uid: String) -> AudioDeviceID? { nil }
    public func graphRate(_ uid: String) -> Double? { devices.first { $0.id == uid }?.nominalRate }

    public func unplug(_ uid: String) {
        guard let index = devices.firstIndex(where: { $0.id == uid }) else { return }
        unplugged.append(devices.remove(at: index))
        onChange?(.list)
        if defaultUID == uid { setDefault(devices.first?.id) }
    }

    public func plug(_ uid: String) {
        guard let index = unplugged.firstIndex(where: { $0.id == uid }) else { return }
        devices.append(unplugged.remove(at: index))
        onChange?(.list)
    }

    public func setDefault(_ uid: String?) {
        defaultUID = uid
        onChange?(.defaultDevice)
    }
}
