import SwiftUI
import LocalMusicCore

struct PlayerBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            if let player = model.player {
                NowPlayingSummary(player: player, artwork: model.artwork, ui: model.ui, library: model.library)
                    .frame(width: 300, alignment: .leading)
                Spacer(minLength: 0)
                VStack(spacing: 2) {
                    TransportControls(player: player)
                    ProgressRow(player: player)
                }
                .frame(maxWidth: 520)
                Spacer(minLength: 0)
                PageToggles(model: model, current: player.current?.id)
                if let output = model.output, player.current != nil { SignalPathButton(output: output, player: player, ui: model.ui) }
                if let loudness = model.loudness { NormalizationMenu(loudness: loudness, passthrough: player.passthrough) }
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
    let artwork: ArtworkStore
    let ui: UIState
    let library: LibraryModel?

    var body: some View {
        HStack(spacing: 10) {
            Button { ui.nowPlayingShown.toggle() } label: {
                CoverView(store: artwork, row: player.current, size: 48, radius: 6)
            }
            .buttonStyle(.plain)
            .disabled(player.current == nil)
            .help("播放页")
            VStack(alignment: .leading, spacing: 2) {
                Text(player.current?.title ?? "未在播放")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(player.current == nil ? .secondary : .primary)
                if let notice = player.skipNotice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                } else {
                    Text(player.current?.artistText ?? "")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            // Beside the title and artist; always there (disabled without a track).
            if let library { LikeButton(library: library, track: player.current?.id, side: 34).font(.system(size: 19, weight: .semibold)) }
        }
    }
}

/// Sized by the surrounding `.font`, like the buttons beside it.
struct LikeButton: View {
    let library: LibraryModel
    let track: Int64?
    var side: CGFloat = 30

    var body: some View {
        let liked = track.map { library.liked[$0] != nil } ?? false
        Button { track.map { library.setLiked([$0], !liked) } } label: {
            Label(liked ? "取消喜欢" : "喜欢", systemImage: liked ? "heart.fill" : "heart")
        }
        .buttonStyle(IconButtonStyle(side: side))
        .foregroundStyle(liked ? AnyShapeStyle(.pink) : AnyShapeStyle(.secondary))
        .help(liked ? "取消喜欢" : "喜欢")
        .disabled(track == nil)
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
    let current: Int64?

    var body: some View {
        let ui = model.ui
        HStack(spacing: 2) {
            Button { ui.nowPlayingShown.toggle() } label: { Label("歌词", systemImage: "quote.bubble") }
                .foregroundStyle(ui.nowPlayingShown ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .disabled(current == nil)
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

/// The output rate; opens what happens to the audio on its way out. Tinted when nothing does.
private struct SignalPathButton: View {
    let output: OutputModel
    let player: PlayerModel
    let ui: UIState

    var body: some View {
        let untouched = output.signalPath?.untouched == true
        Button { ui.signalPathShown.toggle() } label: {
            Text(String(format: "%gk", player.outputRate / 1000))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 6)
                .frame(height: 20)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.tertiary))
        }
        .buttonStyle(.plain)
        .foregroundStyle(untouched ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .help("信号路径")
        .popover(isPresented: Binding(get: { ui.signalPathShown }, set: { ui.signalPathShown = $0 }), arrowEdge: .top) {
            SignalPathView(path: output.signalPath)
        }
        .onDisappear { ui.signalPathShown = false }   // nothing playing: don't pop up again with the next song
    }
}

struct SignalPathView: View {
    let path: SignalPath?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("信号路径").font(.headline)
            if let lines = path?.lines {
                ForEach(Array(lines.dropLast().enumerated()), id: \.offset) { Text($0.element) }
                Divider()
                Text(lines.last ?? "").fontWeight(.semibold).foregroundStyle(path?.untouched == true ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                Text("之后的系统与设备处理（如扬声器音效、蓝牙编码）不在拾音控制范围内。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }
}

private struct NormalizationMenu: View {
    let loudness: LoudnessModel
    let passthrough: Bool

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
        .foregroundStyle(loudness.mode == .off || passthrough ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        .disabled(passthrough)
        .help(passthrough ? "原样输出开启时不做响度均衡（设置已保留）" : "响度均衡：\(loudness.mode.title)")
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
            if let volume = player.shownVolume {
                Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Slider(value: Binding(get: { Double(volume) }, set: { player.setVolume(Float($0)) }), in: 0...1)
                    .controlSize(.mini)
                    .help(player.passthrough ? "原样输出：调的是设备的音量" : "音量")
            } else {
                Text("在设备上调音量")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("原样输出时拾音不调音量，这个设备也没有可调的音量：请用设备或耳放上的旋钮。")
            }
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
