import Foundation
import Testing
@testable import LocalMusicCore

@MainActor
struct OutputDevicesTests {
    @Test func onlyWiredDevicesFollowTheSongsRate() {
        #expect([OutputTransport.builtIn, .usb, .thunderbolt].allSatisfy { $0.canFollowRate })
        #expect(![OutputTransport.bluetooth, .airPlay, .virtual, .aggregate, .hdmi].contains { $0.canFollowRate })
    }

    @Test func standInsPlugUnplugAndMoveTheDefault() {
        let fake = FakeOutputDevices()
        var changes: [OutputDeviceChange] = []
        fake.onChange = { changes.append($0) }
        fake.setDefault("fake-headphones")
        fake.unplug("fake-headphones")
        #expect(!fake.devices.contains { $0.id == "fake-headphones" } && fake.defaultUID == "fake-speakers")
        fake.plug("fake-headphones")
        #expect(fake.devices.contains { $0.id == "fake-headphones" })
        #expect(changes == [.defaultDevice, .list, .defaultDevice, .list])
        #expect(fake.bindingID("fake-speakers") == nil && fake.graphRate("fake-speakers") == 48000)
    }

    @Test func choosesTheSongsRateOrAnEvenMultiple() {
        let builtIn: [Double] = [44100, 48000, 88200, 96000]
        #expect(RateChoice.target(fileRate: 44100, available: builtIn) == 44100)
        #expect(RateChoice.target(fileRate: 192000, available: builtIn) == 96000)
        #expect(RateChoice.target(fileRate: 176400, available: builtIn) == 88200)
        #expect(RateChoice.target(fileRate: 22050, available: builtIn) == 88200)
        #expect(RateChoice.target(fileRate: 44100, available: [48000, 96000]) == nil)   // switching would still resample
    }

    @Test func settingsRoundTrip() throws {
        var settings = OutputSettings()
        (settings.deviceUID, settings.deviceName, settings.followRate) = ("fake-dac", "USB DAC", true)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(OutputSettings.self, from: data)
        #expect(decoded == settings)
    }
}
