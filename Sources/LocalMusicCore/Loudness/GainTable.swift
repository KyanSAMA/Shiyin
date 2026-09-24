import Foundation

public enum NormalizationMode: String, Sendable, CaseIterable {
    case off, track, album
}

/// ReplayGain 2.0 style gains toward −18 LUFS, per track and per fully analyzed album.
public struct GainTable: Sendable, Equatable {
    static let reference = -18.0
    var tracks: [Int64: Double] = [:]
    /// Only tracks whose whole album has been analyzed.
    var albums: [Int64: Double] = [:]
    /// Median track gain, the likeliest level for a track not analyzed yet; never a boost, its peak being unknown.
    private(set) var fallback = 0.0

    public init() {}

    init(tracks: [Int64: Double]) {
        self.tracks = tracks
        let sorted = tracks.values.sorted()
        if !sorted.isEmpty { fallback = min((sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2, 0) }
    }

    /// Album mode uses the track gain until the whole album is analyzed.
    public func gainDb(_ track: Int64, _ mode: NormalizationMode) -> Double {
        switch mode {
        case .off: 0
        case .track: tracks[track] ?? fallback
        case .album: albums[track] ?? tracks[track] ?? fallback
        }
    }

    /// −18 − I, lowered so the sample peak stays 0.5 dB under full scale, within [−24, +12] dB; silence stays at 0.
    static func gain(integrated: Double?, peak: Double) -> Double {
        guard let integrated else { return 0 }
        let headroom = peak > 0 ? -20 * log10(peak) - 0.5 : .infinity
        return min(max(min(reference - integrated, headroom), -24), 12)
    }
}
