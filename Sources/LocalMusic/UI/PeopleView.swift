import SwiftUI
import LocalMusicCore

/// Artists / composers: a person list beside the selected person's albums (artists) or works (composers).
struct PeopleBrowser: View {
    @Environment(AppModel.self) private var model
    let groups: [PersonGroup]
    let role: PersonRole
    let index: LibraryIndex
    @FocusState private var listFocused: Bool

    var body: some View {
        let ui = model.ui
        let selected = ui.selectedPerson(role, in: groups)
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                // Picking a person keeps the keyboard here (a click alone may not), so ↑ / ↓ go on through the list.
                List(groups, selection: Binding(get: { selected?.id }, set: {
                    guard let id = $0 else { return }
                    ui.personSelection[role] = id
                    listFocused = true
                })) { group in
                    HStack(spacing: 10) {
                        CoverView(store: model.artwork, row: group.trackIDs.lazy.compactMap { index.tracks[$0] }.first(where: \.hasCover),
                                  size: 34, radius: 17)
                        Text(group.name).foregroundStyle(group.isUnknown ? .secondary : .primary).lineLimit(1)
                    }
                    .padding(.vertical, 2)
                }
                .focused($listFocused)
                // Rebuilt lists open at the top.
                .onAppear { if let id = selected?.id { proxy.scrollTo(id, anchor: .center) } }
            }
            .id(ui.listID + [role])
            .frame(width: 250)
            Divider()
            if let selected {
                PersonPane(group: selected, role: role, index: index)
            }
        }
        // Keep what's shown, so a fallback left by a search stays chosen once the search is cleared.
        .onChange(of: selected?.id, initial: true) { if let id = $1 { ui.personSelection[role] = id } }
    }
}

private struct PersonPane: View {
    @Environment(AppModel.self) private var model
    let group: PersonGroup
    let role: PersonRole
    let index: LibraryIndex

    var body: some View {
        let rows = group.trackIDs.compactMap { index.tracks[$0] }
        let seconds = rows.reduce(0) { $0 + $1.duration }
        if role == .artist {
            let ids = Set(group.trackIDs)
            let albums = index.albums.filter { $0.trackIDs.contains(where: ids.contains) }
            // Album by album, the way the grid reads.
            let tracks = albums.flatMap { $0.trackIDs.filter(ids.contains) }
            ScrollView {
                VStack(spacing: 0) {
                    PageHeader(title: group.name, detail: "\(albums.count) 张专辑 · " + summary(count: rows.count, seconds: seconds), tracks: tracks)
                    Divider().padding(.horizontal, 24).padding(.bottom, 20)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 22)], spacing: 26) {
                    ForEach(albums) { album in
                        NavigationLink(value: Route.album(album.id)) {
                            AlbumTile(store: model.artwork, album: album, cover: album.coverTrackID.flatMap { index.tracks[$0] })
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding([.horizontal, .bottom], 24)
            }
            .id(group.id)   // each person starts at the top
        } else {
            let sorted = rows.sorted(using: model.ui.songSort)
            VStack(spacing: 0) {
                PageHeader(title: group.name, detail: summary(count: rows.count, seconds: seconds), tracks: sorted.map(\.id))
                SongsTableView(model: model, rows: sorted)
            }
        }
    }
}
