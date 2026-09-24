import SwiftUI
import LocalMusicCore

/// Sortable song table; double-click plays the displayed list from that row.
struct SongsTable: View {
    @Environment(AppModel.self) private var model
    let rows: [TrackRow]

    var body: some View {
        let ui = model.ui, artwork = model.artwork, player = model.player
        Table(rows, selection: Binding(get: { ui.songSelection }, set: { ui.songSelection = $0 }),
              sortOrder: Binding(get: { ui.songSort }, set: { ui.songSort = $0 })) {
            TableColumn("标题", value: \.title, comparator: .localizedStandard) { row in
                HStack(spacing: 8) {
                    CoverView(store: artwork, row: row, size: 28, radius: 3)
                    PlayingMark(player: player, track: row.id)
                    Text(row.title)
                }
            }
            .width(min: 160, ideal: 320)
            TableColumn("艺人", value: \.artistText, comparator: .localizedStandard) { Text($0.artistText) }
            TableColumn("专辑", value: \.albumTitle, comparator: .localizedStandard) { Text($0.albumTitle) }
            TableColumn("年份", value: \.yearSortKey) { Text($0.year.map(String.init) ?? "") }
                .width(44)
            TableColumn("时长", value: \.duration) { Text(clock($0.duration)).monospacedDigit() }
                .width(48)
            TableColumn("添加时间", value: \.addedAt) { Text($0.addedAt, format: .dateTime.year().month().day()) }
                .width(86)
        }
        .trackActions(rows)
    }
}

/// Speaker glyph on the playing row; only these tiny views observe the current track.
struct PlayingMark: View {
    let player: PlayerModel?
    let track: Int64

    var body: some View {
        if player?.current?.id == track {
            Image(systemName: "speaker.wave.2.fill").font(.system(size: 10)).foregroundStyle(.tint)
        }
    }
}

extension View {
    /// Double-click plays `rows` from the clicked one; the context menu queues the selection.
    func trackActions(_ rows: [TrackRow]) -> some View {
        modifier(TrackActions(rows: rows))
    }
}

private struct TrackActions: ViewModifier {
    @Environment(AppModel.self) private var model
    let rows: [TrackRow]

    func body(content: Content) -> some View {
        content.contextMenu(forSelectionType: TrackRow.ID.self) { ids in
            Button("播放下一首") { model.player?.playNext(ordered(ids)) }
            Button("添加到队列") { model.player?.addToQueue(ordered(ids)) }
        } primaryAction: { ids in
            guard let start = rows.firstIndex(where: { ids.contains($0.id) }) else { return }
            model.player?.play(rows.map(\.id), startAt: start)
        }
    }

    private func ordered(_ ids: Set<TrackRow.ID>) -> [Int64] {
        rows.map(\.id).filter(ids.contains)
    }
}

/// Header shared by album and person pages.
struct CollectionHeader<Artwork: View>: View {
    @Environment(AppModel.self) private var model
    let title: String
    let subtitle: String
    let detail: String
    let tracks: [Int64]
    @ViewBuilder let artwork: Artwork

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            artwork
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 26, weight: .bold)).lineLimit(2)
                Text(subtitle).font(.system(size: 17)).foregroundStyle(.tint).lineLimit(1)
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button { model.player?.play(tracks, startAt: 0, shuffle: false) } label: { Label("播放", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                    Button { model.player?.shufflePlay(tracks) } label: { Label("随机播放", systemImage: "shuffle") }
                }
                .controlSize(.large)
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
    }
}

func summary(count: Int, seconds: Double) -> String {
    let minutes = max(Int((seconds / 60).rounded()), 1)
    return "\(count) 首 · \(minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分钟" : "\(minutes) 分钟")"
}
