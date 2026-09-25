import SwiftUI
import LocalMusicCore

/// Full-window page over the library (player bar stays below): cover and titles left, scrolling lyrics right,
/// on a blurred copy of the cover.
struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    let player: PlayerModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 56) {
                VStack(spacing: 22) {
                    CoverView(store: model.artwork, row: player.current, size: 320, radius: 14)
                        .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
                    VStack(spacing: 6) {
                        Text(player.current?.title ?? "未在播放").font(.system(size: 22, weight: .bold))
                        Text(player.current?.artistText ?? "").font(.system(size: 15)).foregroundStyle(.secondary)
                        Text(player.current?.album ?? "").font(.system(size: 13)).foregroundStyle(.tertiary)
                        if let library = model.library, let current = player.current { LikeButton(library: library, track: current.id).font(.system(size: 14)) }
                    }
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                LyricsView(player: player, ui: model.ui)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 40)
            Button { model.ui.nowPlayingShown = false } label: {
                Label("收起", systemImage: "chevron.down").labelStyle(.iconOnly).font(.system(size: 16, weight: .semibold))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(.top, 36)
            .padding(.leading, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { BackdropView(store: model.artwork, row: player.current) }
        .clipped()
        .environment(\.colorScheme, .dark)
    }
}

struct BackdropView: View {
    let store: ArtworkStore
    let row: TrackRow?

    var body: some View {
        let box = row.map(store.backdrop)
        ZStack {
            Color.black
            // Until the new track's backdrop is ready, keep the last one instead of flashing black.
            if let image = box?.image ?? store.lastBackdrop.image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            }
            Color.black.opacity(0.25)
        }
        .ignoresSafeArea()
        .task(id: box.map(ObjectIdentifier.init)) {
            if let box, let row { await store.loadBackdrop(box, row) }
        }
    }
}

private struct LyricsView: View {
    let player: PlayerModel
    let ui: UIState

    var body: some View {
        switch player.lyrics {
        case .synced(let lines)?:
            SyncedLyrics(lines: lines, player: player, ui: ui)
        case .unsynced(let lines)?:
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(lines.indices, id: \.self) { Text(lines[$0]).font(.system(size: 17)) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 40)
            }
        case nil:
            Text(player.current == nil || player.lyricsLoading ? "" : "暂无歌词")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SyncedLyrics: View {
    let lines: [LyricLine]
    let player: PlayerModel
    let ui: UIState

    var body: some View {
        @Bindable var ui = ui
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 20) {
                    // Lines sharing a timestamp (a split credit group) light up together.
                    let currentTime = player.lyricIndex.map { lines[$0].time }
                    ForEach(lines.indices, id: \.self) { i in
                        LyricLineView(line: lines[i], current: lines[i].time == currentTime)
                            .contentShape(Rectangle())
                            .onTapGesture { player.seekToLyric(i) }
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, geometry.size.height / 2)
            }
            .scrollPosition($ui.lyricsPosition, anchor: .center)
            .onChange(of: player.lyricIndex, initial: true) { _, index in
                guard let index else { return ui.lyricsPosition.scrollTo(edge: .top) }
                withAnimation(.easeInOut(duration: 0.4)) { ui.lyricsPosition.scrollTo(id: index, anchor: .center) }
            }
        }
    }
}

private struct LyricLineView: View {
    let line: LyricLine
    let current: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(line.text)
                .font(.system(size: line.isCredit ? 13 : current ? 24 : 18, weight: current ? .bold : .medium))
            if let translation = line.translation {
                Text(translation).font(.system(size: current ? 16 : 14))
            }
        }
        .foregroundStyle(.white)
        .opacity(current ? 1 : line.isCredit ? 0.3 : 0.45)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.25), value: current)
    }
}
