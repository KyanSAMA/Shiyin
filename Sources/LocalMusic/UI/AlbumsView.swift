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
            AlbumTracksTable(album: album, tracks: tracks)
        }
        .navigationTitle(album.title)
    }
}

private struct AlbumTracksTable: View {
    @Environment(AppModel.self) private var model
    let album: AlbumGroup
    let tracks: [TrackRow]

    var body: some View {
        let ui = model.ui, player = model.player
        let multiDisc = Set(tracks.map(LibraryIndex.disc)).count > 1
        Table(tracks, selection: Binding(get: { ui.songSelection }, set: { ui.songSelection = $0 })) {
            TableColumn("#") { row in
                Text(row.trackNo.map { multiDisc ? "\(LibraryIndex.disc(of: row))-\($0)" : "\($0)" } ?? "")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(36)
            TableColumn("标题") { row in
                HStack(spacing: 6) {
                    PlayingMark(player: player, track: row.id)
                    Text(row.title)
                }
            }
            .width(min: 200, ideal: 420)
            TableColumn("艺人") { row in
                Text(row.artistText == album.artist ? "" : row.artistText).foregroundStyle(.secondary)
            }
            TableColumn("时长") { Text(clock($0.duration)).monospacedDigit() }
                .width(48)
        }
        .trackActions(tracks)
    }
}
