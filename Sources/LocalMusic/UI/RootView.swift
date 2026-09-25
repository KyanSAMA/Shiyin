import SwiftUI
import LocalMusicCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @FocusState private var searchFocused: Bool

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
                .searchFocused($searchFocused)
                .onChange(of: ui.searchFocusRequests) {
                    // Next turn: a window just reopened isn't ready yet, and focus it lost on closing may still read true.
                    searchFocused = false
                    Task { searchFocused = true }
                }
                .onChange(of: ui.nowPlayingShown) { if $1 { searchFocused = false } }
                .toolbar(ui.nowPlayingShown ? .hidden : .visible, for: .windowToolbar)
                // Here rather than on the list pages: adding and removing a toolbar item on every push / pop costs ~100 ms.
                .toolbar {
                    if let index = model.library?.index, !index.songs.isEmpty {
                        FilterMenu(ui: ui, facets: index.facets)
                    }
                }
                .disabled(ui.nowPlayingShown)   // keep focus, type-select and VoiceOver out of the covered library
                if ui.nowPlayingShown, let player = model.player {
                    NowPlayingView(player: player)
                        .ignoresSafeArea(edges: .top)
                        .transition(.move(edge: .bottom))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: ui.nowPlayingShown)
            .inspector(isPresented: $ui.queueShown) {
                // A hidden inspector keeps its content: a live queue list would lay out every entry of a new queue.
                if ui.queueShown, let player = model.player {
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
            model.ui.openWindow = openWindow
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
        let ui = model.ui
        if let library = model.library, !library.index.songs.isEmpty {
            let index = library.index
            VStack(spacing: 0) {
                if !ui.filter.isEmpty {
                    FilterBar(ui: ui)
                    Divider()
                }
                switch ui.sidebar {
                case .songs:
                    let rows = ui.songs(in: index)
                    Results(ui: ui, isEmpty: rows.isEmpty) { SongsTableView(model: model, rows: rows) }
                case .albums:
                    let albums = ui.albums(in: index)
                    Results(ui: ui, isEmpty: albums.isEmpty) { AlbumsGrid(albums: albums, index: index) }
                case .artists, .composers:
                    let role: PersonRole = ui.sidebar == .artists ? .artist : .composer, groups = ui.people(role, in: index)
                    Results(ui: ui, isEmpty: groups.isEmpty) { PeopleBrowser(groups: groups, role: role, index: index) }
                }
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

/// Stands in for a list the search or filter left empty.
private struct Results<Content: View>: View {
    let ui: UIState
    let isEmpty: Bool
    @ViewBuilder let content: Content

    var body: some View {
        if isEmpty {
            ContentUnavailableView {
                Label("没有结果", systemImage: "magnifyingglass")
            } description: {
                let search = ui.search.trimmingCharacters(in: .whitespaces)
                Text(search.isEmpty ? "没有符合筛选条件的内容" : "没有与“\(search)”匹配的内容")
            } actions: {
                if !ui.filter.isEmpty { Button("清除筛选") { ui.filter = TrackFilter() } }
            }
            .frame(maxHeight: .infinity)
        } else {
            content
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
        }
    }
}
