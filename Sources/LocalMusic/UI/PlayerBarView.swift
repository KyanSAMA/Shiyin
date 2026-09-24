import SwiftUI
import LocalMusicCore

struct PlayerBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            if let player = model.player {
                NowPlayingSummary(player: player)
                    .frame(width: 260, alignment: .leading)
                Spacer(minLength: 0)
                VStack(spacing: 2) {
                    TransportControls(player: player)
                    ProgressRow(player: player)
                }
                .frame(maxWidth: 520)
                Spacer(minLength: 0)
                VolumeControl(player: player)
                    .frame(width: 150)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 76)
        .background(.bar)
    }
}

private struct NowPlayingSummary: View {
    let player: PlayerModel

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 48, height: 48)
                .overlay { Image(systemName: "music.note").foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 2) {
                Text(player.current?.title ?? "未在播放")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(player.current == nil ? .secondary : .primary)
                Text(player.current?.artistText ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
    }
}

private struct TransportControls: View {
    let player: PlayerModel

    var body: some View {
        HStack(spacing: 22) {
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
        .buttonStyle(.plain)
    }

    private func button(_ title: String, _ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly).font(.system(size: size))
        }
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }

    private func toggle(_ title: String, _ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        button(title, symbol, size: 13, action: action)
            .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
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
