import AppKit
import SwiftUI
import LocalMusicCore

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

func revealInFinder(_ rows: [TrackRow]) {
    NSWorkspace.shared.activateFileViewerSelecting(rows.map(\.url))
}

func summary(count: Int, seconds: Double) -> String {
    let minutes = max(Int((seconds / 60).rounded()), 1)
    return "\(count) 首 · \(minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分钟" : "\(minutes) 分钟")"
}
