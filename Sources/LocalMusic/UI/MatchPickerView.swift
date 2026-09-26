import SwiftUI
import LocalMusicCore

/// 选择匹配: the online songs the lookup couldn't decide between (or a search's), best first; the selected one's data
/// beside the list. 采用 (also double-click or Return in the list) makes it the song's match.
struct MatchPickerView: View {
    let model: AppModel
    let enrich: EnrichModel
    let picker: MatchPicker
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            Divider()
            HStack(spacing: 0) {
                list.frame(width: 400)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            footer.padding(20)
        }
        .frame(width: 780, height: 540)
        .onAppear { listFocused = true }
        // The list only exists with results: focus it once they arrive.
        .onChange(of: picker.results.isEmpty) { _, empty in if !empty { listFocused = true } }
        .onDisappear {
            picker.search?.cancel()
            enrich.clearThumbnails()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选择匹配").font(.headline)
            Text(["「\(picker.row.title)」", picker.row.artistText, clock(picker.row.duration)].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                TextField("搜索关键词", text: Binding(get: { picker.keywords }, set: { picker.keywords = $0 }))
                    .onSubmit(search)
                Button("搜索", action: search).disabled(picker.sources.isEmpty)
            }
            statusLine.font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var statusLine: some View {
        if picker.sources.isEmpty {
            HStack {
                Text(enrich.settings.enabled.isEmpty ? "没有启用的在线资料来源" : "LRCLIB 只提供歌词，认不出歌曲，请再开启一个来源")
                Button("打开设置") {
                    model.ui.sheet = nil
                    model.ui.settingsTab = 1
                    model.ui.openSettings?()
                }
                .controlSize(.small)
            }
        } else if picker.status.isEmpty {
            Text(picker.results.isEmpty ? "还没有候选，可以搜索" : "上次查找找到的 \(picker.results.count) 个候选")
        } else {
            SourceStatusLine(picker: picker)
        }
    }

    @ViewBuilder private var list: some View {
        if picker.results.isEmpty {
            ContentUnavailableView {
                Text(picker.searching ? "正在搜索…" : "没有找到")
            } description: {
                Text(picker.searching ? "" : "换个关键词再试，或者手动编辑信息")
            }
        } else {
            List(picker.results, id: \.key, selection: Binding(get: { picker.selection }, set: {
                picker.selection = $0
                picker.touched = true
            })) { song in
                CandidateRow(enrich: enrich, song: song, duration: picker.row.duration)
            }
            .contextMenu(forSelectionType: String.self) { keys in
                if let key = keys.first, let song = picker.results.first(where: { $0.key == key }) { Button("采用") { choose(song) } }
            } primaryAction: { keys in
                if let key = keys.first, let song = picker.results.first(where: { $0.key == key }) { choose(song) }
            }
            .focused($listFocused)
        }
    }

    @ViewBuilder private var detail: some View {
        if let song = picker.selected {
            MatchDetail(enrich: enrich, picker: picker, song: song).task(id: song.key) {
                // Only once the selection settles: loads can't be cancelled and hold the sources' request slots.
                try? await Task.sleep(for: .milliseconds(400))
                if !Task.isCancelled { await enrich.loadDetails(song, for: picker) }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let status = enrich.match(picker.row)?.status, status != .rejected {
                Button(status.rejectTitle) {
                    model.ui.sheet = nil
                    Task { await enrich.reject(picker.row) }
                }
            }
            Button("手动编辑…") { Task { await model.editInfo([picker.row]) } }
            Spacer()
            Button("取消", role: .cancel) { model.ui.sheet = nil }
                .keyboardShortcut(.cancelAction)
            Button("采用") { picker.selected.map(choose) }
                .buttonStyle(.borderedProminent)
                .disabled(picker.selected == nil)
        }
    }

    private func search() { enrich.startSearch(picker) }

    private func choose(_ song: OnlineSong) {
        model.ui.sheet = nil
        Task { await enrich.choose(song, for: picker) }
    }
}

/// Each source's progress; failures explain themselves on hover.
private struct SourceStatusLine: View {
    let picker: MatchPicker

    var body: some View {
        let parts = picker.sources.map { source -> Text in
            switch picker.status[source] {
            case .searching?: Text("\(source.title) 搜索中…")
            case .found(let count)?: Text("\(source.title) \(count)")
            case .failed?: Text("\(source.title) 请求失败").foregroundStyle(Color.orange)
            case nil: Text("")
            }
        }
        let failures = picker.sources.compactMap { source in
            if case .failed(let error)? = picker.status[source] { "\(source.title)：\(error)" } else { nil }
        }
        parts.dropFirst().reduce(parts.first ?? Text("")) { Text("\($0)    \($1)") }
            .help(failures.joined(separator: "\n"))
    }
}

private struct CandidateRow: View {
    let enrich: EnrichModel
    let song: OnlineSong
    let duration: Double

    var body: some View {
        HStack(spacing: 10) {
            Thumbnail(image: enrich.thumbnail(song, pixels: 100), size: 40)
                .task { await enrich.loadThumbnail(song, pixels: 100) }
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).lineLimit(1)
                HStack(spacing: 5) {
                    Badge(text: song.source.title)
                    Text(([song.artists.joined(separator: " / "), song.album] + [song.year.map(String.init)].compactMap { $0 })
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                        .lineLimit(1)
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            DurationDelta(song: song, duration: duration)
        }
        .padding(.vertical, 2)
    }
}

/// The selected result: what it fills, what the song keeps.
private struct MatchDetail: View {
    let enrich: EnrichModel
    let picker: MatchPicker
    let song: OnlineSong
    private static let fields: [EnrichField] = [.title, .artists, .album, .trackNo, .discNo, .year, .genre]

    var body: some View {
        let base = picker.baseline
        let lyrics = picker.lyrics[song.key].flatMap(LRCParser.parse)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Thumbnail(image: enrich.thumbnail(song, pixels: 300), size: 110)
                        .task(id: song.key) { await enrich.loadThumbnail(song, pixels: 300) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(song.title).font(.headline).lineLimit(2)
                        Text(song.source.title).foregroundStyle(.secondary)
                        DurationDelta(song: song, duration: picker.row.duration)
                    }
                }
                // A value only from the file name is replaced.
                let rows = Self.fields.compactMap { field in
                    picker.value(field, of: song).map { (field: field, value: $0, current: base.shown(field), inferred: base.inferred.contains(field)) }
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                    ForEach(rows, id: \.field) { row in
                        GridRow {
                            mark(row.inferred || row.current.isEmpty ? .fills : row.current == row.value ? .same : .kept)
                            Text(row.field.label).foregroundStyle(.secondary)
                            Text(row.current.isEmpty || row.current == row.value ? row.value
                                 : row.inferred ? "\(row.value)（替换文件名里的 \(row.current)）" : "\(row.value)（保留现有的 \(row.current)）")
                                .lineLimit(2)
                        }
                    }
                    if song.coverURL != nil {
                        GridRow {
                            mark(base.hasArtwork || ArtworkCache.hasFolderImage(near: base) ? .kept : .fills)
                            Text("封面").foregroundStyle(.secondary)
                            Text(base.hasArtwork || ArtworkCache.hasFolderImage(near: base) ? "保留现有的封面" : "补上")
                        }
                    }
                    GridRow {
                        mark(base.hasLyrics ? .kept : lyrics == nil ? .none : .fills)
                        Text("歌词").foregroundStyle(.secondary)
                        Text(base.hasLyrics ? "保留现有的歌词" : picker.lyrics[song.key] == nil ? "载入中…" : lyrics.map(summary) ?? "没有歌词，采用后再从其他来源找")
                    }
                }
                Text(picker.row.fingerprint.flatMap { enrich.matches[$0] }.map { $0.status == .auto || $0.status == .confirmed } == true
                     ? "采用后替换现有的补全，并用这首的资料再查其他来源。只补空缺，不改动文件里已有的信息。"
                     : "采用后还会用这首的资料再查其他来源。只补空缺，不改动文件里已有的信息。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private enum Mark { case fills, same, kept, none }

    private func mark(_ mark: Mark) -> some View {
        let (symbol, color): (String, Color) = switch mark {
        case .fills: ("plus.circle.fill", .green)
        case .same: ("equal.circle", .secondary)
        case .kept: ("minus.circle", .secondary)
        case .none: ("circle.dashed", .secondary)
        }
        return Image(systemName: symbol).foregroundStyle(color)
    }

    private func summary(_ lyrics: Lyrics) -> String {
        switch lyrics {
        case .synced(let lines):
            "补上 \(lines.filter { !$0.isCredit && !$0.text.isEmpty }.count) 行" + (lines.contains { $0.translation != nil } ? "，含翻译" : "")
        case .unsynced(let lines): "补上 \(lines.count) 行（无时间轴）"
        }
    }
}

private struct DurationDelta: View {
    let song: OnlineSong
    let duration: Double

    var body: some View {
        let delta = song.duration - duration
        Text(song.duration > 0 ? "\(clock(song.duration))（\(delta >= 0 ? "+" : "−")\(Int(abs(delta).rounded())) 秒）" : "时长未知")
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(song.duration > 0 && abs(delta) > Matcher.durationTolerance ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
    }
}
