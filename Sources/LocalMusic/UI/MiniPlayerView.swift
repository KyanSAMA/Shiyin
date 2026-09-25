import AppKit
import SwiftUI
import LocalMusicCore

extension NSPanel {
    /// Floats over other apps (full-screen ones too) on every Space, and never activates the app when clicked.
    static func miniPlayer(_ model: AppModel, player: PlayerModel) -> NSPanel {
        let size = NSSize(width: 360, height: 112)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("mini")
        panel.title = "迷你播放器"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(button)?.isHidden = true }
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setFrame(NSRect(origin: .zero, size: size), display: false)   // the content fills the titlebar area too
        // As the window's content view, a hosting view resizes the window to fit, titlebar inset included.
        let host = NSHostingView(rootView: MiniPlayerView(model: model, player: player))
        host.frame = panel.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        panel.contentView!.addSubview(host)
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - size.width - 20, y: screen.maxY - 20))
        }
        return panel
    }
}

struct MiniPlayerView: View {
    let model: AppModel
    let player: PlayerModel

    var body: some View {
        HStack(spacing: 12) {
            CoverView(store: model.artwork, row: player.current, size: 84, radius: 6)
                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.current?.title ?? "未在播放").font(.system(size: 13, weight: .semibold))
                Text(player.current?.artistText ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                MiniLyric(player: player)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    button("上一首", "backward.fill", size: 13) { player.previous() }
                    button(player.isPlaying ? "暂停" : "播放", player.isPlaying ? "pause.fill" : "play.fill", size: 18) {
                        player.togglePlayPause()
                    }
                    button("下一首", "forward.fill", size: 13) { player.next() }
                    Spacer(minLength: 0)
                    if let library = model.library, let current = player.current { LikeButton(library: library, track: current.id) }
                    button("显示主窗口", "macwindow", size: 12) { model.showMainWindow() }
                    button("关闭迷你播放器", "xmark", size: 11) { model.setMiniPlayer(false) }
                }
                MiniProgress(player: player).padding(.top, 4)
            }
            .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents()   // the panel never activates the app: take the first click / drag as is
        .background { BackdropView(store: model.artwork, row: player.current).overlay(.black.opacity(0.2)) }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    private func button(_ title: String, _ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).font(.system(size: size)) }
            .buttonStyle(IconButtonStyle(side: 28))
            .help(title)
    }
}

/// The current synced lyric line, else the album.
private struct MiniLyric: View {
    let player: PlayerModel

    var body: some View {
        let line: String? = if case .synced(let lines)? = player.lyrics, let index = player.lyricIndex { lines[index].text } else { nil }
        Text(line.flatMap { $0.isEmpty ? nil : $0 } ?? player.current?.album ?? "")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}

/// Reads `position` (20 Hz), so kept to this leaf.
private struct MiniProgress: View {
    let player: PlayerModel

    var body: some View {
        let fraction = player.duration > 0 ? min(max(player.position / player.duration, 0), 1) : 0
        Capsule()
            .fill(.white.opacity(0.2))
            .overlay(alignment: .leading) {
                GeometryReader { Capsule().fill(.white.opacity(0.8)).frame(width: $0.size.width * fraction) }
            }
            .frame(height: 3)
    }
}
