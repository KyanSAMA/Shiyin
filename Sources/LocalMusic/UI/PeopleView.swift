import SwiftUI
import LocalMusicCore

struct PeopleList: View {
    let groups: [PersonGroup]
    let role: PersonRole

    var body: some View {
        List(groups) { group in
            NavigationLink(value: Route.person(role, group.id)) {
                HStack {
                    Text(group.name).foregroundStyle(group.isUnknown ? .secondary : .primary)
                    Spacer()
                    Text("\(group.trackIDs.count) 首").foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }
}

struct PersonDetailView: View {
    @Environment(AppModel.self) private var model
    let group: PersonGroup
    let role: PersonRole
    let index: LibraryIndex

    var body: some View {
        let rows = group.trackIDs.compactMap { index.tracks[$0] }.sorted(using: model.ui.songSort)
        let ids = Set(group.trackIDs)
        let albums = role == .artist ? index.albums.filter { $0.trackIDs.contains(where: ids.contains) } : []
        VStack(spacing: 0) {
            CollectionHeader(title: group.name, subtitle: role == .artist ? "艺人" : "作曲",
                             detail: summary(count: rows.count, seconds: rows.reduce(0) { $0 + $1.duration }),
                             tracks: rows.map(\.id)) {
                CoverView(store: model.artwork, row: rows.first(where: \.hasCover), size: 140, radius: 70)
            }
            if !albums.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 18) {
                        ForEach(albums) { album in
                            NavigationLink(value: Route.album(album.id)) {
                                AlbumTile(store: model.artwork, album: album, cover: album.coverTrackID.flatMap { index.tracks[$0] })
                                    .frame(width: 130)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .frame(height: 180)
            }
            SongsTableView(model: model, rows: rows)
        }
        .navigationTitle(group.name)
    }
}
