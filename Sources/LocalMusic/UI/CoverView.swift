import SwiftUI
import LocalMusicCore

@Observable final class ArtworkBox {
    var image: CGImage?
    @ObservationIgnored var requested = false
}

/// Per-(track, size) observable boxes, so only the cover that finishes loading re-renders. Least recently requested
/// boxes are dropped past a byte budget (a view that needs one again gets a fresh box, served from the cache actor).
final class ArtworkStore {
    private let cache: ArtworkCache
    private var boxes: [String: (box: ArtworkBox, used: UInt64)] = [:]
    private var backdrops: [Int64: ArtworkBox] = [:]
    /// The most recently rendered backdrop, shown while the next one renders.
    let lastBackdrop = ArtworkBox()
    private var clock: UInt64 = 0
    private var bytes = 0
    private static let budget = 120 << 20, maxBoxes = 4000

    init(cache: ArtworkCache) {
        self.cache = cache
    }

    func box(_ row: TrackRow, pixels: Int) -> ArtworkBox {
        let key = "\(row.id)-\(Int(row.fileMtime))-\(pixels)"
        clock += 1
        if let entry = boxes[key] {
            boxes[key]?.used = clock
            return entry.box
        }
        let box = ArtworkBox()
        boxes[key] = (box, clock)
        return box
    }

    func load(_ box: ArtworkBox, _ row: TrackRow, pixels: Int) async {
        guard !box.requested else { return }
        box.requested = true
        guard let image = await cache.image(for: row, pixels: pixels) else {
            if Task.isCancelled { box.requested = false }   // scrolled away: retry when it comes back
            return
        }
        box.image = image
        bytes += Self.cost(image)
        while bytes > Self.budget || boxes.count > Self.maxBoxes, let oldest = boxes.min(by: { $0.value.used < $1.value.used }) {
            bytes -= oldest.value.box.image.map(Self.cost) ?? 0
            boxes[oldest.key] = nil
        }
    }

    private static func cost(_ image: CGImage) -> Int { image.bytesPerRow * image.height }

    func image(for row: TrackRow, pixels: Int) async -> CGImage? {
        await cache.image(for: row, pixels: pixels)
    }

    /// Blurred Now Playing background for a track (a few recent ones kept).
    func backdrop(_ row: TrackRow) -> ArtworkBox {
        if let box = backdrops[row.id] { return box }
        if backdrops.count >= 4 { backdrops.removeAll() }
        let box = ArtworkBox()
        backdrops[row.id] = box
        return box
    }

    func loadBackdrop(_ box: ArtworkBox, _ row: TrackRow) async {
        guard !box.requested else { return }
        box.requested = true
        guard let cover = await cache.image(for: row, pixels: 480) else {
            if Task.isCancelled { box.requested = false }
            return
        }
        box.image = await Task.detached { Backdrop.render(cover) }.value
        if box.image != nil { lastBackdrop.image = box.image }
    }
}

/// Square cover; `size == nil` fills the available width. Takes the store explicitly: it is used inside Table cells,
/// where environment lookups are not reliable while rows are rebuilt (sorting crashed with a missing AppModel).
struct CoverView: View {
    let store: ArtworkStore
    let row: TrackRow?
    var size: CGFloat?
    var radius: CGFloat = 4

    var body: some View {
        let pixels = Self.pixels(for: size ?? 240)
        let box = row.map { store.box($0, pixels: pixels) }
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image = box?.image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note").font(.system(size: (size ?? 120) * 0.3)).foregroundStyle(.tertiary)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .task(id: box.map(ObjectIdentifier.init)) {
                if let box, let row { await store.load(box, row, pixels: pixels) }
            }
    }

    /// Retina pixel buckets, so each point size decodes roughly 2× — not one oversized shared size.
    static func pixels(for points: CGFloat) -> Int {
        [64, 160, 320, 480].first { CGFloat($0) >= points * 2 } ?? 1024
    }
}
