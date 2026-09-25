import SwiftUI
import LocalMusicCore

struct PlayerBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            if let player = model.player {
                NowPlayingSummary(player: player, library: model.library, artwork: model.artwork, ui: model.ui)
                    .frame(width: 260, alignment: .leading)
                Spacer(minLength: 0)
                VStack(spacing: 2) {
                    TransportControls(player: player)
                    ProgressRow(player: player)
                }
                .frame(maxWidth: 520)
                Spacer(minLength: 0)
                PageToggles(model: model, hasTrack: player.current != nil)
                if let loudness = model.loudness { NormalizationMenu(loudness: loudness) }
                VolumeControl(player: player)
                    .frame(width: 130)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 76)
        .background(.bar)
    }
}

private struct NowPlayingSummary: View {
    let player: PlayerModel
    let library: LibraryModel?
    let artwork: ArtworkStore
    let ui: UIState

    var body: some View {
        HStack(spacing: 10) {
            Button { ui.nowPlayingShown.toggle() } label: {
                CoverView(store: artwork, row: player.current, size: 48, radius: 6)
            }
            .buttonStyle(.plain)
            .disabled(player.current == nil)
            .help("播放页")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 2) {
                    Text(player.current?.title ?? "未在播放")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(player.current == nil ? .secondary : .primary)
                    if let library, let current = player.current { LikeButton(library: library, track: current.id, size: 11, side: 20) }
                }
                if let notice = player.skipNotice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                } else {
                    Text(player.current?.artistText ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
    }
}

struct LikeButton: View {
    let library: LibraryModel
    let track: Int64
    var size: CGFloat = 14
    var side: CGFloat = 30

    var body: some View {
        let liked = library.liked[track] != nil
        Button { library.setLiked([track], !liked) } label: {
            Label(liked ? "取消喜欢" : "喜欢", systemImage: liked ? "heart.fill" : "heart").font(.system(size: size))
        }
        .buttonStyle(IconButtonStyle(side: side))
        .foregroundStyle(liked ? AnyShapeStyle(.pink) : AnyShapeStyle(.secondary))
        .help(liked ? "取消喜欢" : "喜欢")
    }
}

private struct TransportControls: View {
    let player: PlayerModel

    var body: some View {
        HStack(spacing: 12) {
            toggle("随机播放", "shuffle", on: player.queue.shuffled) { player.setShuffle(!player.queue.shuffled) }
            button("上一首", "backward.fill", size: 15) { player.previous() }
            button(player.isPlaying ? "暂停" : "播放", player.isPlaying ? "pause.fill" : "play.fill", size: 24) {
                player.togglePlayPause()
            }
            button("下一首", "forward.fill", size: 15) { player.next() }
            toggle("循环", player.queue.repeatMode == .one ? "repeat.1" : "repeat", on: player.queue.repeatMode != .off) {
                player.setRepeat(player.queue.repeatMode.next)
            }
        }
        .buttonStyle(IconButtonStyle(side: 34))
    }

    private func button(_ title: String, _ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).font(.system(size: size)) }
            .help(title)
    }

    private func toggle(_ title: String, _ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        button(title, symbol, size: 13, action: action)
            .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
    }
}

private struct PageToggles: View {
    let model: AppModel
    let hasTrack: Bool

    var body: some View {
        let ui = model.ui
        HStack(spacing: 2) {
            Button { ui.nowPlayingShown.toggle() } label: { Label("歌词", systemImage: "quote.bubble") }
                .foregroundStyle(ui.nowPlayingShown ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .disabled(!hasTrack)
            Button { ui.queueShown.toggle() } label: { Label("播放队列", systemImage: "list.bullet") }
                .foregroundStyle(ui.queueShown ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Button { model.setMiniPlayer(!model.miniPlayerShown) } label: { Label("迷你播放器", systemImage: "pip.enter") }
                .foregroundStyle(model.miniPlayerShown ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .help("迷你播放器（⌥⌘M）")
        }
        .buttonStyle(IconButtonStyle(side: 30))
        .font(.system(size: 14))
    }
}

/// Icon buttons whose whole square takes clicks (a plain button only takes them on the glyph), dimmed while pressed.
struct IconButtonStyle: ButtonStyle {
    let side: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .opacity(!isEnabled ? 0.3 : configuration.isPressed ? 0.4 : 1)
    }
}

/// The only bar view that reads `position` (20 Hz while playing).
private struct ProgressRow: View {
    let player: PlayerModel

    var body: some View {
        let shown = player.scrubbing ?? player.position
        HStack(spacing: 8) {
            Text(clock(shown)).frame(width: 40, alignment: .trailing)
            Slider(value: Binding(get: { shown }, set: { player.scrubbing = $0 }), in: 0...max(player.duration, 0.1)) { editing in
                guard !editing, let target = player.scrubbing else { return }
                player.seek(to: target)
                player.scrubbing = nil
            }
            .controlSize(.mini)
            .disabled(player.current == nil)
            Text(clock(player.duration)).frame(width: 40, alignment: .leading)
        }
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

private struct NormalizationMenu: View {
    let loudness: LoudnessModel

    var body: some View {
        Menu {
            NormalizationPicker(loudness: loudness).pickerStyle(.inline)
        } label: {
            Label("响度均衡", systemImage: "waveform")
        }
        .menuStyle(.button)
        .buttonStyle(IconButtonStyle(side: 30))
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(loudness.mode == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        .help("响度均衡：\(loudness.mode.title)")
    }
}

struct NormalizationPicker: View {
    let loudness: LoudnessModel
    var title = "响度均衡"

    var body: some View {
        Picker(title, selection: Binding(get: { loudness.mode }, set: { loudness.setMode($0) })) {
            ForEach(NormalizationMode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
    }
}

extension NormalizationMode {
    var title: String {
        switch self {
        case .off: "关"
        case .track: "单曲"
        case .album: "专辑"
        }
    }
}

private struct VolumeControl: View {
    let player: PlayerModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Slider(value: Binding(get: { Double(player.volume) }, set: { player.setVolume(Float($0)) }), in: 0...1)
                .controlSize(.mini)
        }
    }
}

func clock(_ seconds: Double) -> String {
    Duration.seconds(seconds.isFinite ? max(seconds, 0) : 0).formatted(.time(pattern: .minuteSecond))
}

extension RepeatMode {
    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}
