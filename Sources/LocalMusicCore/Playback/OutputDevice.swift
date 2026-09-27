import CoreAudio

public enum OutputTransport: String, Sendable, Codable {
    case builtIn, usb, thunderbolt, firewire, pci, bluetooth, airPlay, hdmi, displayPort, virtual, aggregate, unknown

    init(_ code: UInt32) {
        self = switch code {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeThunderbolt: .thunderbolt
        case kAudioDeviceTransportTypeFireWire: .firewire
        case kAudioDeviceTransportTypePCI: .pci
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeAirPlay: .airPlay
        case kAudioDeviceTransportTypeHDMI: .hdmi
        case kAudioDeviceTransportTypeDisplayPort: .displayPort
        case kAudioDeviceTransportTypeVirtual: .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: .aggregate
        default: .unknown
        }
    }

    /// A wired device whose clock can follow each song's rate; Bluetooth and AirPlay run at their codec's.
    public var canFollowRate: Bool { [.builtIn, .usb, .thunderbolt, .firewire, .pci].contains(self) }

    public var title: String {
        switch self {
        case .builtIn: "内置"
        case .usb: "USB"
        case .thunderbolt: "雷雳"
        case .firewire: "FireWire"
        case .pci: "PCI"
        case .bluetooth: "蓝牙"
        case .airPlay: "AirPlay"
        case .hdmi: "HDMI"
        case .displayPort: "DisplayPort"
        case .virtual: "虚拟"
        case .aggregate: "聚合"
        case .unknown: "其他"
        }
    }
}

public struct OutputDeviceInfo: Sendable, Equatable, Identifiable, Codable {
    /// The device's persistent UID.
    public let id: String
    public var name: String
    public var transport: OutputTransport
    /// Nominal rates the device offers.
    public var rates: [Double]
    public var nominalRate: Double

    public init(id: String, name: String, transport: OutputTransport, rates: [Double], nominalRate: Double) {
        (self.id, self.name, self.transport, self.rates, self.nominalRate) = (id, name, transport, rates, nominalRate)
    }
}

public enum OutputDeviceChange: Sendable, Equatable {
    case list, defaultDevice, rate(String)
}

/// The Mac's output devices, or stand-ins (tests, self-tests).
@MainActor public protocol OutputDevices: AnyObject {
    var devices: [OutputDeviceInfo] { get }
    var defaultUID: String? { get }
    var onChange: ((OutputDeviceChange) -> Void)? { get set }
    /// The device the engine binds to; nil leaves the engine on its current one (stand-ins).
    func bindingID(_ uid: String) -> AudioDeviceID?
    /// The rate the engine's graph runs at on this device; nil follows the hardware.
    func graphRate(_ uid: String) -> Double?
}

/// Where playback goes, remembered in the `setting` table.
public struct OutputSettings: Codable, Equatable, Sendable {
    public static let key = "output"

    /// nil: the system's default output.
    public var deviceUID: String?
    /// The chosen device's name, shown while it isn't connected.
    public var deviceName: String?
    public var followRate = false
    public var passthrough = false

    public init() {}
}
