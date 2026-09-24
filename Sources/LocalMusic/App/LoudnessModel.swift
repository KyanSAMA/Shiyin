import Foundation
import Observation
import LocalMusicCore

@Observable final class LoudnessModel {
    private(set) var progress = LoudnessService.Progress()
    private(set) var mode = NormalizationMode.track
    @ObservationIgnored private var gains = GainTable()
    @ObservationIgnored private let service: LoudnessService
    @ObservationIgnored private let store: LibraryStore
    /// The mode or the gains changed, so the playing items' gains need re-evaluating.
    @ObservationIgnored var onGainsChange: (() -> Void)?
    private static let modeKey = "normalization"

    init(store: LibraryStore) {
        self.store = store
        service = LoudnessService(store: store)
        Task { [weak self, service] in
            for await update in service.updates {
                guard let self else { return }
                progress = update.progress
                if update.gains != gains {
                    gains = update.gains
                    onGainsChange?()
                }
            }
        }
        Task { [weak self] in
            guard let raw = try? await store.setting(Self.modeKey, as: String.self), let mode = NormalizationMode(rawValue: raw) else { return }
            self?.apply(mode)
        }
    }

    func setMode(_ mode: NormalizationMode) {
        guard mode != self.mode else { return }
        apply(mode)
        Task { [store] in try? await store.setSetting(Self.modeKey, mode.rawValue) }
    }

    private func apply(_ mode: NormalizationMode) {
        self.mode = mode
        onGainsChange?()
    }

    func gainDb(for track: Int64) -> Float {
        Float(gains.gainDb(track, mode))
    }

    /// Titled albums get an album gain; untitled tracks grouped per artist don't form one.
    func refresh(_ index: LibraryIndex) {
        let albums = index.albums.filter { !$0.isUntitled }.map(\.trackIDs)
        Task { await service.refresh(albums: albums) }
    }

    func prioritize(_ tracks: [Int64]) {
        Task { await service.prioritize(tracks) }
    }
}
