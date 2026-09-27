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

    @Test func describesTheSignalPath() {
        var path = SignalPath(format: "flac", lossy: false, fileRate: 96000, bitDepth: 24, channels: 2, device: "外置耳机", outputRate: 96000,
                              switching: false, gainDb: 0, softwareVolume: 1, deviceVolume: true)
        #expect(path.untouched && path.lines.last == "拾音没有改动音频数据（直通）")
        #expect(path.lines.contains("文件：FLAC · 96 kHz · 24 bit · 立体声") && path.lines.contains("采样率一致，未重采样"))
        path.outputRate = 48000
        #expect(!path.untouched && path.lines.contains("重采样 96 → 48 kHz"))
        (path.outputRate, path.gainDb, path.deviceVolume, path.softwareVolume) = (96000, -3.2, false, 0.7)
        #expect(path.lines.contains("响度均衡 -3.2 dB") && path.lines.contains("软件音量 70%") && !path.untouched)
        (path.gainDb, path.softwareVolume, path.channels) = (0, 1, 1)
        #expect(!path.untouched && path.lines.contains("单声道复制到左右声道"))
    }

    @Test func settingsRoundTrip() throws {
        var settings = OutputSettings()
        (settings.deviceUID, settings.deviceName, settings.followRate) = ("fake-dac", "USB DAC", true)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(OutputSettings.self, from: data)
        #expect(decoded == settings)
    }
}
