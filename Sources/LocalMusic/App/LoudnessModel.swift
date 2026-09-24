import Foundation
import Observation
import LocalMusicCore

@Observable final class LoudnessModel {
    private(set) var progress = LoudnessService.Progress()
    @ObservationIgnored private let service: LoudnessService

    init(service: LoudnessService) {
        self.service = service
        Task { [weak self] in
            for await progress in service.progress { self?.progress = progress }
        }
    }

    func refresh() {
        Task { await service.refresh() }
    }

    func prioritize(_ tracks: [Int64]) {
        Task { await service.prioritize(tracks) }
    }
}
