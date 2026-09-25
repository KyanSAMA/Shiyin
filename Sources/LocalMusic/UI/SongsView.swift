import AppKit
import SwiftUI
import LocalMusicCore

/// Album page header.
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

/// Person and playlist page header: title, summary, round play / shuffle buttons.
struct PageHeader: View {
    @Environment(AppModel.self) private var model
    let title: String
    let detail: String
    let tracks: [Int64]

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 26, weight: .bold)).lineLimit(1)
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            HStack(spacing: 10) {
                Button { model.player?.play(tracks, startAt: 0, shuffle: false) } label: { Label("播放", systemImage: "play.fill") }
                Button { model.player?.shufflePlay(tracks) } label: { Label("随机播放", systemImage: "shuffle") }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(tracks.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }
}

struct PlaylistView: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist
    let index: LibraryIndex

    var body: some View {
        let all = playlist.trackIDs.compactMap { index.tracks[$0] }
        let rows = model.ui.narrowed(all, in: index)
        VStack(spacing: 0) {
            PageHeader(title: playlist.name, detail: summary(count: all.count, seconds: all.reduce(0) { $0 + $1.duration }),
                       tracks: rows.map(\.id))
            if all.isEmpty {
                ContentUnavailableView("播放列表是空的", systemImage: "music.note.list",
                                       description: Text("在歌曲上右键选择「添加到播放列表」"))
                    .frame(maxHeight: .infinity)
            } else {
                Results(ui: model.ui, isEmpty: rows.isEmpty) { SongsTableView(model: model, rows: rows, playlist: playlist.id) }
            }
        }
    }
}

func revealInFinder(_ rows: [TrackRow]) {
    NSWorkspace.shared.activateFileViewerSelecting(rows.map(\.url))
}

func summary(count: Int, seconds: Double) -> String {
    guard count > 0 else { return "0 首" }
    let minutes = max(Int((seconds / 60).rounded()), 1)
    return "\(count) 首 · \(minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分钟" : "\(minutes) 分钟")"
}
