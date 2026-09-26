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
        .alert(ui.playlistPrompt?.title ?? "",
               isPresented: Binding(get: { ui.playlistPrompt != nil }, set: { if !$0 { ui.playlistPrompt = nil } }),
               presenting: ui.playlistPrompt) { prompt in
            TextField("名称", text: $ui.playlistName)
            Button("取消", role: .cancel) {}
            Button(prompt.action) { model.commitPlaylistPrompt(prompt) }.keyboardShortcut(.defaultAction)
        }
        .sheet(isPresented: Binding(get: { ui.infoEditor != nil }, set: { if !$0 { ui.infoEditor = nil } })) {
            if let editor = ui.infoEditor { InfoEditorView(model: model, editor: editor) }
        }
        .sheet(isPresented: Binding(get: { ui.compare != nil }, set: { if !$0 { ui.compare = nil } })) {
            if let compare = ui.compare, let enrich = model.enrich { SourceCompareView(model: model, enrich: enrich, compare: compare) }
        }
        .confirmationDialog(ui.deletingPlaylist.flatMap { model.library?.playlist($0) }.map { "删除播放列表「\($0.name)」？" } ?? "",
                            isPresented: Binding(get: { ui.deletingPlaylist != nil }, set: { if !$0 { ui.deletingPlaylist = nil } }),
                            titleVisibility: .visible, presenting: ui.deletingPlaylist) { id in
            Button("删除", role: .destructive) { model.deletePlaylist(id) }
        } message: { _ in
            Text("歌曲文件不会被删除。")
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
            ForEach([("资料库", SidebarItem.library), ("精选", SidebarItem.presets), ("工具", SidebarItem.tools)], id: \.0) { title, items in
                Section(title) {
                    ForEach(items) { row(item: $0, title: $0.title) }
                }
            }
            if let playlists = model.library?.playlists, !playlists.isEmpty {
                Section("播放列表") {
                    ForEach(playlists) { playlist in
                        row(item: .playlist(playlist.id), title: playlist.name)
                            .background(ui.dropTarget == .playlist(playlist.id) ? Color.accentColor.opacity(0.25) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .songDrop(.playlist(playlist.id), ui: ui) { model.library?.addToPlaylist(playlist.id, $0) }
                            .contextMenu {
                                Button("重命名…") { model.promptRenamePlaylist(playlist) }
                                Button("删除播放列表…") { ui.deletingPlaylist = playlist.id }
                            }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { model.promptNewPlaylist() } label: {
                Label("新建播放列表", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(ui.dropTarget == .newPlaylist ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .songDrop(.newPlaylist, ui: ui) { model.promptNewPlaylist($0) }   // songs dropped here start a new playlist
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210)
    }

    private func row(item: SidebarItem, title: String) -> some View {
        let ui = model.ui
        return Label(title, systemImage: item.symbol)
            .tag(item)
            // Re-clicking the selected item doesn't reach the selection setter; still pop to its root.
            .simultaneousGesture(TapGesture().onEnded { if ui.sidebar == item { ui.path = [] } })
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
                case .albums, .recent:
                    let albums = ui.sidebar == .albums ? ui.albums(in: index) : ui.recentAlbums(in: index)
                    Results(ui: ui, isEmpty: albums.isEmpty) { AlbumsGrid(albums: albums, index: index).id(ui.sidebar) }
                case .liked:
                    if library.liked.isEmpty {
                        ContentUnavailableView("还没有喜欢的歌曲", systemImage: "heart",
                                               description: Text("点播放条上的心形，或在歌曲上右键选择「喜欢」"))
                            .frame(maxHeight: .infinity)
                    } else {
                        let rows = ui.likedSongs(in: index, liked: library.liked)
                        Results(ui: ui, isEmpty: rows.isEmpty) { SongsTableView(model: model, rows: rows) }
                    }
                case .artists, .composers:
                    let role: PersonRole = ui.sidebar == .artists ? .artist : .composer, groups = ui.people(role, in: index)
                    Results(ui: ui, isEmpty: groups.isEmpty) { PeopleBrowser(groups: groups, role: role, index: index) }
                case .enrich:
                    if let enrich = model.enrich { EnrichView(model: model, enrich: enrich, index: index) }
                case .playlist(let id):
                    if let playlist = library.playlist(id) {
                        PlaylistView(playlist: playlist, index: index)
                    } else {
                        ContentUnavailableView("播放列表已删除", systemImage: "music.note.list").frame(maxHeight: .infinity)
                    }
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
struct Results<Content: View>: View {
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

private extension View {
    /// Takes songs dragged from a song table. Ids come from the drag pasteboard, in row order: the strings SwiftUI hands
    /// over arrive in load order, and text from other apps carries no track ids.
    func songDrop(_ target: DropTarget, ui: UIState, perform: @escaping ([Int64]) -> Void) -> some View {
        dropDestination(for: String.self) { _, _ in
            let ids = NSPasteboard(name: .drag).pasteboardItems?.compactMap { $0.string(forType: .trackID).flatMap { Int64($0) } } ?? []
            if !ids.isEmpty { perform(ids) }
            return !ids.isEmpty
        } isTargeted: { targeted in
            if targeted, NSPasteboard(name: .drag).types?.contains(.trackID) == true {
                ui.dropTarget = target
            } else if ui.dropTarget == target {
                ui.dropTarget = nil
            }
        }
    }
}
