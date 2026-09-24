import SwiftUI
import LocalMusicCore

struct QueueView: View {
    @Environment(AppModel.self) private var model
    let player: PlayerModel

    var body: some View {
        let tracks = model.library?.index.tracks ?? [:]
        // Edits map rendered rows to entry ids, so a queue that advanced mid-drag can't misplace or trap.
        let upcoming = Array(player.queue.upcoming)
        List {
            if let current = player.queue.current {
                Section("正在播放") { QueueRow(store: model.artwork, row: tracks[current.trackID] ?? player.current) }
            }
            Section {
                ForEach(upcoming) { entry in
                    QueueRow(store: model.artwork, row: tracks[entry.trackID])
                        .contextMenu { Button("从队列中移除") { player.remove([entry.id]) } }
                }
                .onMove { source, destination in
                    player.moveUpcoming(source.map { upcoming[$0].id }, before: destination < upcoming.count ? upcoming[destination].id : nil)
                }
                .onDelete { player.remove(Set($0.map { upcoming[$0].id })) }
            } header: {
                HStack {
                    Text("接下来")
                    Spacer()
                    Button("清空") { player.clearUpcoming() }
                        .buttonStyle(.borderless)
                        .disabled(upcoming.isEmpty)
                }
            }
        }
    }
}

private struct QueueRow: View {
    let store: ArtworkStore
    let row: TrackRow?

    var body: some View {
        HStack(spacing: 8) {
            CoverView(store: store, row: row, size: 32, radius: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(row?.title ?? "（已移出曲库）").font(.system(size: 12))
                Text(row?.artistText ?? "").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
    }
}
