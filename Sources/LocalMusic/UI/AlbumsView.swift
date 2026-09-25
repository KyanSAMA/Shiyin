import SwiftUI
import LocalMusicCore

struct AlbumsGrid: View {
    @Environment(AppModel.self) private var model
    let albums: [AlbumGroup]
    let index: LibraryIndex

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 22)], spacing: 26) {
                ForEach(albums) { album in
                    NavigationLink(value: Route.album(album.id)) {
                        AlbumTile(store: model.artwork, album: album, cover: album.coverTrackID.flatMap { index.tracks[$0] })
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("播放下一首") { model.player?.playNext(album.trackIDs) }
                        Button("添加到队列") { model.player?.addToQueue(album.trackIDs) }
                        AddToPlaylistMenu(model: model, tracks: album.trackIDs)
                    }
                }
            }
            .padding(24)
        }
    }
}

struct AlbumTile: View {
    let store: ArtworkStore
    let album: AlbumGroup
    let cover: TrackRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CoverView(store: store, row: cover, radius: 8)
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                .padding(.bottom, 4)
            Text(album.title).font(.system(size: 12, weight: .medium))
            Text(album.artist).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .contentShape(Rectangle())
    }
}

struct AlbumDetailView: View {
    @Environment(AppModel.self) private var model
    let album: AlbumGroup
    let index: LibraryIndex

    var body: some View {
        let tracks = album.trackIDs.compactMap { index.tracks[$0] }
        let details: [String?] = [album.year.map(String.init), tracks.lazy.compactMap(\.genre).first,
                                  summary(count: tracks.count, seconds: tracks.reduce(0) { $0 + $1.duration })]
        VStack(spacing: 0) {
            CollectionHeader(title: album.title, subtitle: album.artist, detail: details.compactMap { $0 }.joined(separator: " · "),
                             tracks: album.trackIDs) {
                CoverView(store: model.artwork, row: album.coverTrackID.flatMap { index.tracks[$0] }, size: 200, radius: 10)
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
            }
            SongsTableView(model: model, rows: tracks, album: album)
        }
        .navigationTitle(album.title)
    }
}
