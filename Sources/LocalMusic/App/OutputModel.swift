import Observation
import LocalMusicCore

/// Where playback goes: the chosen device (remembered by UID), else the system default. When the device playing goes
/// away (headphones unplugged), playback pauses instead of moving to the speakers; a chosen device coming back is
/// used again, still paused.
@Observable final class OutputModel {
    private(set) var devices: [OutputDeviceInfo] = []
    private(set) var defaultUID: String?
    private(set) var settings = OutputSettings()
    /// The device playing.
    private(set) var effective: OutputDeviceInfo?
    @ObservationIgnored let source: OutputDevices
    @ObservationIgnored private let player: PlayerModel
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// A stand-in's rate changed: its graph follows.
    @ObservationIgnored private var rateChanged = false

    init(source: OutputDevices, player: PlayerModel, store: LibraryStore) {
        (self.source, self.player, self.store) = (source, player, store)
        source.onChange = { [weak self] in self?.changed($0) }
        (devices, defaultUID) = (source.devices, source.defaultUID)
        loading = Task {
            if let saved = try? await store.setting(OutputSettings.key, as: OutputSettings.self) { settings = saved }
            apply()
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

    /// nil: the system default.
    func select(_ uid: String?) {
        let name = uid.flatMap { uid in devices.first { $0.id == uid }?.name }
        settings.deviceName = name ?? (uid == settings.deviceUID ? settings.deviceName : nil)
        settings.deviceUID = uid
        let settings = settings
        Task { try? await store.setSetting(OutputSettings.key, settings) }
        apply()
    }

    /// A device leaving posts several changes (the default moves, the list shrinks), in either order: act once they've
    /// settled, so playback pauses rather than moving to the new default.
    private func changed(_ change: OutputDeviceChange) {
        if case .rate(let uid) = change, uid == effective?.id, source.graphRate(uid) != nil { rateChanged = true }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            (devices, defaultUID) = (source.devices, source.defaultUID)
            if let effective {
                self.effective = devices.first { $0.id == effective.id }
                if self.effective == nil { player.pause() }
            }
            bind(force: rateChanged)
            rateChanged = false
        }
    }

    private func apply() { bind(force: false) }

    private func bind(force: Bool) {
        let chosen = settings.deviceUID.flatMap { uid in devices.first { $0.id == uid } }
        guard let target = chosen ?? defaultDevice, force || target.id != effective?.id else { return }
        if player.setOutput(device: source.bindingID(target.id), rate: source.graphRate(target.id)) { effective = target }
    }
}
