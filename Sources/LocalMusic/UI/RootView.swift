import SwiftUI
import LocalMusicCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
            } detail: {
                DetailView()
            }
            Divider()
            PlayerBarView()
        }
        .frame(minWidth: 900, minHeight: 560)
        .task {
            model.ui.openSettings = openSettings
            await model.startLibrary()
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ui = model.ui
        List(selection: Binding(get: { ui.sidebar }, set: { if let item = $0 { ui.sidebar = item } })) {
            Section("资料库") {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.title, systemImage: item.symbol).tag(item)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210)
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let item = model.ui.sidebar
        if let library = model.library, !library.index.songs.isEmpty {
            switch item {
            case .songs: SongsTableView(songs: library.index.songs)
            case .albums, .artists, .composers:
                ContentUnavailableView(item.title, systemImage: item.symbol, description: Text("浏览视图开发中"))
            }
        } else if let library = model.library, library.scanning || !library.started {
            ProgressView("正在扫描曲库…")
        } else {
            ContentUnavailableView {
                Label("没有音乐", systemImage: "music.note.list")
            } description: {
                Text(model.startupError ?? "在设置中添加音乐文件夹")
            } actions: {
                SettingsLink { Text("打开设置") }
            }
        }
    }
}

struct SongsTableView: View {
    let songs: [TrackRow]

    var body: some View {
        Table(songs) {
            TableColumn("标题", value: \.title)
            TableColumn("艺人") { Text($0.artistText) }
            TableColumn("专辑") { Text($0.album ?? "") }
            TableColumn("时长") { Text(Duration.seconds($0.duration).formatted(.time(pattern: .minuteSecond))).monospacedDigit() }
                .width(56)
        }
    }
}

struct PlayerBarView: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 44, height: 44)
                .overlay { Image(systemName: "music.note").foregroundStyle(.secondary) }
            Text("未在播放")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(.bar)
    }
}
