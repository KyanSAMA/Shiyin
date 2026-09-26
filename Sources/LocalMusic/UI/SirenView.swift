import AppKit
import SwiftUI
import LocalMusicCore

/// 塞壬唱片: the label's albums (searchable with the toolbar field), an album's songs with what the library already has,
/// and downloads into the library.
struct SirenView: View {
    let model: AppModel
    let siren: SirenModel

    var body: some View {
        Group {
            if !siren.albums.isEmpty {
                HStack(spacing: 0) {
                    albumList.frame(width: 300)
                    Divider()
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let failure = siren.failure, !siren.loading {
                ContentUnavailableView {
                    Label("无法读取塞壬唱片", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(failure)
                } actions: {
                    Button("重试") { Task { await siren.load() } }
                }
            } else {
                ProgressView("正在读取塞壬唱片…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await siren.load() }
    }

    private var albumList: some View {
        List(selection: Binding(get: { siren.albumID }, set: { if let id = $0 { siren.select(id) } })) {
            ForEach(siren.albums(matching: model.ui.search)) { SirenAlbumRow(siren: siren, album: $0).tag($0.id) }
        }
        .id(model.ui.search)
    }

    @ViewBuilder private var detail: some View {
        if let detail = siren.detail {
            let owned = detail.songs.filter { !siren.owned($0).isEmpty }
            let missing = detail.songs.filter { siren.owned($0).isEmpty && !siren.isPending($0) && !isDone($0) }
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 18) {
                    Cover(image: siren.covers[detail.album.id], side: 140, radius: 8)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(detail.album.name).font(.system(size: 24, weight: .bold)).lineLimit(2)
                        Text("\(Siren.albumArtist) · \(detail.songs.count) 首 · 已有 \(owned.count) 首")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        if !detail.intro.isEmpty {
                            Text(detail.intro).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                        }
                        Spacer(minLength: 8)
                        actions(detail, missing: missing)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 140)
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                Divider()
                List(selection: Binding(get: { siren.selection }, set: { siren.selection = $0 })) {
                    ForEach(Array(detail.songs.enumerated()), id: \.element.id) { offset, song in
                        SirenSongRow(siren: siren, number: offset + 1, song: song)
                    }
                }
                .id(detail.album.id)
                .contextMenu(forSelectionType: String.self) { ids in
                    let picked = detail.songs.filter { ids.contains($0.id) }
                    if !picked.isEmpty { Button("下载…") { plan(picked, detail) } }
                    let files = picked.flatMap { siren.owned($0).map(\.url) }
                    if !files.isEmpty { Button("在访达中显示已有的") { NSWorkspace.shared.activateFileViewerSelecting(files) } }
                }
            }
        } else if let failure = siren.detailFailure, let id = siren.albumID {
            ContentUnavailableView {
                Label("无法读取专辑", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            } actions: {
                Button("重试") { Task { await siren.loadDetail(id) } }
            }
        } else {
            ProgressView()
        }
    }

    @ViewBuilder private func actions(_ detail: Siren.AlbumDetail, missing: [Siren.Song]) -> some View {
        HStack(spacing: 10) {
            let selected = detail.songs.filter { siren.selection.contains($0.id) }
            Button("下载所选（\(selected.count)）…") { plan(selected, detail) }.disabled(selected.isEmpty)
            Button("下载未有的（\(missing.count)）…") { plan(missing, detail) }.buttonStyle(.borderedProminent).disabled(missing.isEmpty)
            if siren.running {
                ProgressView().controlSize(.small)
                Text("还剩 \(siren.remaining) 首").monospacedDigit().foregroundStyle(.secondary)
                Button("停止") { siren.stop() }
            }
        }
    }

    private func isDone(_ song: Siren.Song) -> Bool {
        if case .done? = siren.states[song.id] { true } else { false }
    }

    private func plan(_ songs: [Siren.Song], _ detail: Siren.AlbumDetail) {
        model.ui.sheet = .sirenPlan(siren.plan(songs, in: detail))
    }
}

private struct SirenAlbumRow: View {
    let siren: SirenModel
    let album: Siren.Album

    var body: some View {
        let count = siren.ownedCount(album)
        HStack(spacing: 10) {
            Cover(image: siren.covers[album.id], side: 40, radius: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name).lineLimit(2)
                Text(count.owned == 0 ? "\(count.total) 首" : "已有 \(count.owned) / \(count.total)")
                    .font(.system(size: 11))
                    .foregroundStyle(count.owned > 0 && count.owned == count.total ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.vertical, 2)
        .onAppear { siren.showCover(album) }
    }
}

private struct SirenSongRow: View {
    let siren: SirenModel
    let number: Int
    let song: Siren.Song

    var body: some View {
        let owned = siren.owned(song)
        HStack(spacing: 10) {
            Text("\(number)").monospacedDigit().foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.name).lineLimit(1)
                Text(song.artists.joined(separator: " / ")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if !owned.isEmpty {
                let lossless = owned.contains { $0.format != "mp3" }
                Label(lossless ? "已有" : "已有 MP3", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(lossless ? .green : .secondary)
                    .help(owned.map(\.path).joined(separator: "\n") + (lossless ? "" : "\n官网音源多为 WAV，可再下载为 FLAC"))
            }
            status.frame(width: 110, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var status: some View {
        switch siren.states[song.id] {
        case .queued?: Text("等待中").foregroundStyle(.secondary)
        case .downloading(let share)?:
            if let share { ProgressView(value: share).frame(width: 90) } else { ProgressView().controlSize(.small) }
        case .done(let url)?:
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                Label("已下载", systemImage: "arrow.down.circle.fill").foregroundStyle(.green)
            }
            .buttonStyle(.borderless)
            .help("已下载到 \(url.path)，点按在访达中显示")
        case .failed(let reason)?: Label("失败", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(reason)
        case nil: EmptyView()
        }
    }
}

private struct Cover: View {
    let image: NSImage?
    let side: CGFloat
    let radius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(.quaternary)
            .overlay {
                if let image { Image(nsImage: image).resizable().scaledToFill() } else { Image(systemName: "opticaldisc").foregroundStyle(.secondary) }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .frame(width: side, height: side)
    }
}

/// 下载: where the songs go and how they're named.
struct SirenPlanView: View {
    let model: AppModel
    let siren: SirenModel
    let importer: ImportModel
    let plan: SirenPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    ImportTargetRows(model: model, importer: importer, target: Binding(get: { plan.target }, set: { plan.target = $0 }))
                    Picker("文件命名", selection: Binding(get: { plan.naming }, set: { plan.naming = $0 })) {
                        ForEach(ImportNaming.allCases, id: \.self) { Text($0.example).tag($0) }
                    }
                } header: {
                    Text("从「\(plan.detail.album.name)」下载 \(plan.songs.count) 首")
                } footer: {
                    Text("WAV 无损转成 FLAC，MP3 保持原样；写入歌名、艺人、专辑、专辑艺人「\(Siren.albumArtist)」、曲序、封面和官网歌词。重名时依次加「 (专辑名)」「 2」…，不会覆盖已有文件。")
                        .foregroundStyle(.secondary)
                }
                Section("预览") {
                    ForEach(plan.songs) { song in
                        let trackNo = plan.detail.songs.firstIndex { $0.id == song.id }.map { $0 + 1 }
                        HStack(spacing: 6) {
                            Text(song.name).lineLimit(1)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Text(plan.naming.candidates(title: song.name, artists: song.artists, album: plan.detail.album.name,
                                                        trackNo: trackNo, ext: "flac")[0])
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .font(.system(size: 12))
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("取消", role: .cancel) { model.ui.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("开始下载") {
                    siren.start(plan)
                    model.ui.sheet = nil
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled((plan.target ?? importer.firstFolder) == nil || plan.songs.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 600, height: 520)
    }
}
