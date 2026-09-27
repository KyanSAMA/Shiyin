import Foundation
import Observation
import LocalMusicCore

/// Where playback goes: the chosen device (remembered by UID), else the system default. When the device playing goes
/// away (headphones unplugged), playback pauses instead of moving to the speakers; a chosen device coming back is
/// used again, still paused. With 采样率跟随歌曲 on a wired device, the device's clock follows each song's rate; the rate
/// it had before is put back when following stops, on quit, and at the next launch after a crash.
@Observable final class OutputModel {
    private(set) var devices: [OutputDeviceInfo] = []
    private(set) var defaultUID: String?
    private(set) var settings = OutputSettings()
    /// The device playing.
    private(set) var effective: OutputDeviceInfo?
    /// Per device (UID): the rate following last set, and the device's own before it.
    private(set) var restores: [String: RateRestore] = [:]
    private(set) var lastSwitch: (from: Double, to: Double, seconds: Double)?
    @ObservationIgnored let source: OutputDevices
    @ObservationIgnored private let player: PlayerModel
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// The device whose rate is being set.
    @ObservationIgnored private var inFlight: String?

    init(source: OutputDevices, player: PlayerModel, store: LibraryStore) {
        (self.source, self.player, self.store) = (source, player, store)
        source.onChange = { [weak self] in self?.changed($0) }
        (devices, defaultUID) = (source.devices, source.defaultUID)
        player.engine.switchRate = { [weak self] rate in try await self?.switchDevice(to: rate) }
        player.deviceVolume = { [weak self] in self?.effective?.volume }
        player.setDeviceVolume = { [weak self] in self?.setDeviceVolume($0) }
        loading = Task {
            if let saved = try? await store.setting(OutputSettings.key, as: OutputSettings.self) { settings = saved }
            let saved = (try? await store.setting(RateRestore.key, as: [RateRestore].self)) ?? []
            restores = Dictionary(saved.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
            if putBack(except: nil) { saveRestores() }   // left switched by a crash
            bind(force: false)
            player.setPassthrough(settings.passthrough)
        }
    }

    /// Settings loaded and applied (self-tests).
    func ready() async { await loading?.value }

    /// Device changes handled (self-tests).
    func settled() async { await pending?.value }

    /// The chosen device when it isn't connected.
    var missing: String? {
        guard let uid = settings.deviceUID, !devices.contains(where: { $0.id == uid }) else { return nil }
        return settings.deviceName ?? uid
    }

    var defaultDevice: OutputDeviceInfo? { devices.first { $0.id == defaultUID } }

    /// The device playing has a clock that can follow songs' rates (not Bluetooth or AirPlay).
    var canFollow: Bool { effective?.transport.canFollowRate == true }
    var following: Bool { settings.followRate && canFollow }
    var switchFailure: String? { following ? player.switchFailure : nil }

    /// nil: the system default.
    func select(_ uid: String?) {
        let name = uid.flatMap { uid in devices.first { $0.id == uid }?.name }
        settings.deviceName = name ?? (uid == settings.deviceUID ? settings.deviceName : nil)
        settings.deviceUID = uid
        saveSettings()
        bind(force: false)
    }

    func setFollowRate(_ on: Bool) {
        settings.followRate = on
        saveSettings()
        updateFollowing(effective)
        if !on, putBack(except: nil) {
            saveRestores()
            bind(force: true)   // carry on at the device's own rate
        }
    }

    /// 原样输出. Turning it on lowers the device's volume by the app's (which goes to 100 %), so it doesn't get louder.
    /// Turning it off raises the device back as far as it can, so the level heard stays the same either way.
    func setPassthrough(_ on: Bool) {
        if on != player.passthrough, let volume = effective?.volume, player.volume > 0 {
            setDeviceVolume(on ? volume * player.volume : min(volume / player.volume, 1))
        }
        settings.passthrough = on
        saveSettings()
        player.setPassthrough(on)
    }

    /// What happens to the playing song on its way out.
    var signalPath: SignalPath? {
        guard let track = player.current else { return nil }
        let codec = track.codec ?? track.format
        return SignalPath(format: ["pcm", "flac"].contains(codec) ? track.format : codec, lossy: ["mp3", "aac"].contains(codec),
                          fileRate: Double(track.sampleRate ?? 0), bitDepth: track.bitDepth, channels: player.fileChannels,
                          device: effective?.name ?? "输出设备", outputRate: player.outputRate, switching: player.switching,
                          gainDb: player.appliedGainDb, softwareVolume: player.passthrough ? 1 : player.volume, deviceVolume: player.passthrough)
    }

    /// Turning 原样输出 on would get louder with nothing to lower on the device: ask first.
    var passthroughNeedsWarning: Bool { effective?.volume == nil && player.volume < 0.5 }
    var confirmingPassthrough = false

    private func setDeviceVolume(_ volume: Float) {
        guard let uid = effective?.id, (try? source.setVolume(volume, uid: uid)) != nil else { return }
        effective?.volume = volume   // the device reports it shortly
    }

    /// Puts the devices' rates back before quitting.
    func restoreBeforeQuit() {
        guard putBack(except: nil) else { return }
        let store = store, records = Array(restores.values), done = DispatchSemaphore(value: 0)
        Task.detached {
            try? await store.setSetting(RateRestore.key, records)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    /// A device leaving posts several changes (the default moves, the list shrinks), in either order: act once they've
    /// settled, so playback pauses rather than moving to the new default.
    private func changed(_ change: OutputDeviceChange) {
        if case .volume(let uid) = change {   // at once: the volume slider follows it
            devices = source.devices
            if uid == effective?.id { effective = devices.first { $0.id == uid } }
            return
        }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            (devices, defaultUID) = (source.devices, source.defaultUID)
            if let effective {
                self.effective = devices.first { $0.id == effective.id }
                if self.effective == nil { player.pause() }
            }
            bind(force: false)
        }
    }

    /// Plays on the chosen device, else the default; devices left behind get their own rates back.
    private func bind(force: Bool) {
        let chosen = settings.deviceUID.flatMap { uid in devices.first { $0.id == uid } }
        if let target = chosen ?? defaultDevice, force || target.id != effective?.id {
            updateFollowing(target)   // before moving, so the engine asks for the new device's rates
            if player.setOutput(device: source.bindingID(target.id), rate: source.graphRate(target.id)) { effective = target }
            updateFollowing(effective)
        }
        if putBack(except: following ? effective?.id : nil) { saveRestores() }
    }

    private func updateFollowing(_ device: OutputDeviceInfo?) {
        guard settings.followRate, let device, device.transport.canFollowRate else { return player.engine.preferredRate = nil }
        let rates = device.rates
        player.engine.preferredRate = { RateChoice.target(fileRate: $0, available: rates) }
    }

    /// Called by the engine, stopped at a song of another rate: records what to restore (before touching the device, so
    /// a crash can undo it), sets the rate and waits up to 1.5 s for the device to report it.
    private func switchDevice(to rate: Double) async throws -> Double? {
        guard following, let device = effective else { throw OutputDeviceError.missing }
        let started = Date(), previous = restores[device.id]
        restores[device.id] = RateRestore(uid: device.id, originalRate: previous?.originalRate ?? device.nominalRate, setRate: rate)
        inFlight = device.id
        defer { inFlight = nil }
        try? await store.setSetting(RateRestore.key, Array(restores.values))
        do {
            // Turned off, or moved to another device, while the record was written.
            guard following, effective?.id == device.id else { throw CancellationError() }
            try source.setNominalRate(rate, uid: device.id)
        } catch {
            restores[device.id] = previous   // the device kept its rate
            saveRestores()
            throw error
        }
        while source.devices.first(where: { $0.id == device.id })?.nominalRate != rate {
            guard following, effective?.id == device.id else { throw CancellationError() }   // put back already
            guard Date().timeIntervalSince(started) < 1.5 else { throw OutputDeviceError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
        devices = source.devices
        guard following, effective?.id == device.id else {   // turned off, or moved on, while it switched
            if putBack(except: nil) { saveRestores() }
            throw CancellationError()
        }
        lastSwitch = (device.nominalRate, rate, Date().timeIntervalSince(started))
        effective = devices.first { $0.id == device.id }
        return source.graphRate(device.id)
    }

    /// Sets recorded devices (but `except`) back to their own rates, unless since changed by someone else; a record
    /// is kept while its device isn't connected. True if any record went.
    private func putBack(except uid: String?) -> Bool {
        var changed = false
        for record in restores.values where record.uid != uid {
            guard let device = source.devices.first(where: { $0.id == record.uid }) else { continue }
            // Mid-switch, the device's reported rate may still be the old one: put it back regardless.
            if inFlight == record.uid || device.nominalRate == record.setRate && device.nominalRate != record.originalRate {
                try? source.setNominalRate(record.originalRate, uid: record.uid)
            }
            restores[record.uid] = nil
            changed = true
        }
        return changed
    }

    private func saveSettings() {
        let settings = settings
        Task { try? await store.setSetting(OutputSettings.key, settings) }
    }

    private func saveRestores() {
        let records = Array(restores.values)
        Task { try? await store.setSetting(RateRestore.key, records) }
    }
}
