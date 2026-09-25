import SwiftUI
import LocalMusicCore

/// Artists / composers: a person list beside the selected person's albums (artists) or works (composers).
struct PeopleBrowser: View {
    @Environment(AppModel.self) private var model
    let groups: [PersonGroup]
    let role: PersonRole
    let index: LibraryIndex

    var body: some View {
        let ui = model.ui
        let selected = ui.selectedPerson(role, in: groups)
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(groups, selection: Binding(get: { selected?.id }, set: { if let id = $0 { ui.personSelection[role] = id } })) { group in
                    HStack(spacing: 10) {
                        CoverView(store: model.artwork, row: group.trackIDs.lazy.compactMap { index.tracks[$0] }.first(where: \.hasCover),
                                  size: 34, radius: 17)
                        Text(group.name).foregroundStyle(group.isUnknown ? .secondary : .primary).lineLimit(1)
                    }
                    .padding(.vertical, 2)
                }
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
                header(detail: "\(albums.count) 张专辑 · " + summary(count: rows.count, seconds: seconds), tracks: tracks)
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
                header(detail: summary(count: rows.count, seconds: seconds), tracks: sorted.map(\.id))
                SongsTableView(model: model, rows: sorted)
            }
        }
    }

    private func header(detail: String, tracks: [Int64]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name).font(.system(size: 26, weight: .bold)).lineLimit(1)
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                HStack(spacing: 10) {
                    Button { model.player?.play(tracks, startAt: 0, shuffle: false) } label: { Label("播放", systemImage: "play.fill") }
                    Button { model.player?.shufflePlay(tracks) } label: { Label("随机播放", systemImage: "shuffle") }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            if role == .artist { Divider().padding(.horizontal, 24).padding(.bottom, 20) }
        }
    }
}
