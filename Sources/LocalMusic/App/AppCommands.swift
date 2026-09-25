import SwiftUI
import LocalMusicCore

/// 控制 menu plus additions to 编辑 and 显示. Space (play / pause) is `AppModel.handleKey`.
/// Items with shortcuts stay enabled and check state in their actions: menus only re-read model state when opened, and
/// a disabled item still swallows its shortcut.
struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        SidebarCommands()
        CommandGroup(after: .textEditing) {
            Button("搜索") { model.searchFromMenu() }
                .keyboardShortcut("f")
        }
        CommandGroup(after: .sidebar) {
            let ui = model.ui
            Toggle("播放页", isOn: Binding(get: { ui.nowPlayingShown }, set: { ui.nowPlayingShown = $0 && model.player?.current != nil }))
                .keyboardShortcut("l")
            Toggle("播放队列", isOn: Binding(get: { ui.queueShown }, set: { ui.queueShown = $0 }))
                .keyboardShortcut("u", modifiers: [.command, .option])
            Toggle("迷你播放器", isOn: Binding(get: { model.miniPlayerShown }, set: { model.setMiniPlayer($0) }))
                .keyboardShortcut("m", modifiers: [.command, .option])
                .disabled(model.player == nil)
            Divider()
        }
        CommandMenu("控制") {
            if let player = model.player {
                Button(player.isPlaying ? "暂停" : "播放") { player.togglePlayPause() }
                    .disabled(player.queue.current == nil)
                Button("下一首") { player.next() }
                    .keyboardShortcut(.rightArrow)
                Button("上一首") { player.previous() }
                    .keyboardShortcut(.leftArrow)
                Divider()
                Button("增大音量") { player.setVolume(player.volume + 0.1) }
                    .keyboardShortcut(.upArrow)
                Button("减小音量") { player.setVolume(player.volume - 0.1) }
                    .keyboardShortcut(.downArrow)
                Divider()
                if let library = model.library {
                    Toggle("喜欢", isOn: Binding(get: { player.current.map { library.liked[$0.id] != nil } ?? false },
                                               set: { on in player.current.map { library.setLiked([$0.id], on) } }))
                        .disabled(player.current == nil)
                    Divider()
                }
                Toggle("随机播放", isOn: Binding(get: { player.queue.shuffled }, set: { player.setShuffle($0) }))
                Picker("循环", selection: Binding(get: { player.queue.repeatMode }, set: { player.setRepeat($0) })) {
                    Text("关").tag(RepeatMode.off)
                    Text("列表循环").tag(RepeatMode.all)
                    Text("单曲循环").tag(RepeatMode.one)
                }
            }
            if let loudness = model.loudness { NormalizationPicker(loudness: loudness) }
        }
    }
}
