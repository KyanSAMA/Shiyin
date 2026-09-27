import CoreAudio
import Foundation

/// Stand-in output devices for tests and self-tests, which must never touch the Mac's real ones: the engine stays on
/// its device and runs its graph at the stand-in's rate.
@MainActor public final class FakeOutputDevices: OutputDevices {
    public private(set) var devices: [OutputDeviceInfo]
    public private(set) var defaultUID: String?
    public var onChange: ((OutputDeviceChange) -> Void)?
    /// Unplugged devices, kept to plug back in.
    private var unplugged: [OutputDeviceInfo] = []
    /// The next rate change fails, as a device that won't switch.
    public var failNextSwitch = false
    /// Where the devices' rates persist, so a relaunch sees what the last run left.
    private let stateURL: URL?

    public static let presets = [
        OutputDeviceInfo(id: "fake-speakers", name: "MacBook Pro扬声器", transport: .builtIn, rates: [44100, 48000, 88200, 96000],
                         nominalRate: 48000, volume: 0.5),
        OutputDeviceInfo(id: "fake-headphones", name: "外置耳机", transport: .builtIn, rates: [44100, 48000, 88200, 96000],
                         nominalRate: 48000, volume: 0.5),
        OutputDeviceInfo(id: "fake-airpods", name: "AirPods", transport: .bluetooth, rates: [48000], nominalRate: 48000, volume: 0.5),
        OutputDeviceInfo(id: "fake-dac", name: "USB DAC", transport: .usb,
                         rates: [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000], nominalRate: 48000),
    ]

    public init(devices: [OutputDeviceInfo] = presets, state stateURL: URL? = nil) {
        self.stateURL = stateURL
        self.devices = stateURL.flatMap { try? JSONDecoder().decode([OutputDeviceInfo].self, from: Data(contentsOf: $0)) } ?? devices
        defaultUID = self.devices.first?.id
    }

    public func bindingID(_ uid: String) -> AudioDeviceID? { nil }
    public func graphRate(_ uid: String) -> Double? { devices.first { $0.id == uid }?.nominalRate }

    public func setNominalRate(_ rate: Double, uid: String) throws {
        guard let index = devices.firstIndex(where: { $0.id == uid }) else { throw OutputDeviceError.missing }
        if failNextSwitch {
            failNextSwitch = false
            throw OutputDeviceError.status(kAudioHardwareUnsupportedOperationError)
        }
        devices[index].nominalRate = rate
        if let stateURL { try? JSONEncoder().encode(devices).write(to: stateURL) }
        onChange?(.rate(uid))
    }

    public func setVolume(_ volume: Float, uid: String) throws {
        guard let index = devices.firstIndex(where: { $0.id == uid }), devices[index].volume != nil else { throw OutputDeviceError.missing }
        devices[index].volume = min(max(volume, 0), 1)
        if let stateURL { try? JSONEncoder().encode(devices).write(to: stateURL) }
        onChange?(.volume(uid))
    }

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
