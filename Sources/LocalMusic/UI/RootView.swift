import SwiftUI
import LocalMusicCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var ui = model.ui
        VStack(spacing: 0) {
            ZStack {
                NavigationSplitView {
                    SidebarView()
                } detail: {
                    NavigationStack(path: $ui.path) {
                        DetailView()
                            .navigationDestination(for: Route.self) { RouteView(route: $0) }
                    }
                }
                .searchable(text: $ui.search, placement: .toolbar, prompt: "搜索")
                .toolbar(ui.nowPlayingShown ? .hidden : .visible, for: .windowToolbar)
                .disabled(ui.nowPlayingShown)   // keep focus, type-select and VoiceOver out of the covered library
                if ui.nowPlayingShown, let player = model.player {
                    NowPlayingView(player: player)
                        .ignoresSafeArea(edges: .top)
                        .transition(.move(edge: .bottom))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: ui.nowPlayingShown)
            .inspector(isPresented: $ui.queueShown) {
                if let player = model.player {
                    QueueView(player: player).inspectorColumnWidth(min: 240, ideal: 300, max: 420)
                }
            }
            Divider()
            PlayerBarView()
        }
        .frame(minWidth: 900, minHeight: 560)
        .transaction { if !ui.animationsEnabled { $0.disablesAnimations = true; $0.animation = nil } }
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
        List(selection: Binding(get: { ui.sidebar }, set: { item in
            guard let item else { return }
            ui.sidebar = item
            ui.path = []
        })) {
            Section("资料库") {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.title, systemImage: item.symbol)
                        .tag(item)
                        // Re-clicking the selected item doesn't reach the selection setter; still pop to its root.
                        .simultaneousGesture(TapGesture().onEnded { if ui.sidebar == item { ui.path = [] } })
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
            let index = library.index, search = model.ui.search
            switch item {
            // `.id(search)`: rebuilding is far cheaper than SwiftUI diffing hundreds of reinserted rows (2.5 s to clear a
            // search over 322 songs).
            case .songs: SongsTable(rows: model.ui.songs(in: index)).id(search)
            case .albums: AlbumsGrid(albums: index.albums(matching: search), index: index)
            case .artists: PeopleList(groups: index.people(.artist, matching: search), role: .artist).id(search)
            case .composers: PeopleList(groups: index.people(.composer, matching: search), role: .composer).id(search)
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

struct RouteView: View {
    @Environment(AppModel.self) private var model
    let route: Route

    var body: some View {
        let index = model.library?.index
        switch route {
        case .album(let id):
            if let index, let album = index.album(id) {
                AlbumDetailView(album: album, index: index)
            } else {
                ContentUnavailableView("专辑已不在曲库中", systemImage: "square.stack")
            }
        case .person(let role, let id):
            if let index, let group = index.person(role, id) {
                PersonDetailView(group: group, role: role, index: index)
            } else {
                ContentUnavailableView("已不在曲库中", systemImage: "person")
            }
        }
    }
}
