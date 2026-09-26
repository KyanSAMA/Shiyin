import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LocalMusicCore

/// 资料对照: one song's fields beside each enabled source's result. Clicking a value (or 全部采用) takes it into the
/// 当前 column; saving stores that column as manual edits.
struct SourceCompareView: View {
    let model: AppModel
    let enrich: EnrichModel
    let compare: SourceCompare
    private static let column: CGFloat = 170, current: CGFloat = 210, label: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            Divider()
            ScrollView {
                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Color.clear.frame(width: Self.label, height: 1)
                        Text("当前").font(.headline).frame(width: Self.current, alignment: .leading)
                        ForEach(compare.sources, id: \.self) { SourceHeader(enrich: enrich, compare: compare, source: $0, width: Self.column) }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(compare.editor.fields, id: \.self) { field in
                        GridRow(alignment: .firstTextBaseline) {
                            label(field.label)
                            TextField(field.label, text: Binding(get: { compare.editor.texts[field] ?? "" }, set: { compare.editor.texts[field] = $0 }),
                                      prompt: Text(compare.editor.shown(field)))
                                .labelsHidden()
                                .frame(width: Self.current)
                            ForEach(compare.sources, id: \.self) { valueCell(field, $0) }
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        label("封面")
                        currentCover
                        ForEach(compare.sources, id: \.self) { coverCell($0) }
                    }
                    GridRow {
                        label("歌词")
                        currentLyrics
                        ForEach(compare.sources, id: \.self) { lyricsCell($0) }
                    }
                }
                .padding(20)
            }
            Divider()
            footer.padding(20)
        }
        .frame(width: max(Self.label + Self.current + CGFloat(compare.sources.count) * (Self.column + 12) + 64, 820), height: 740)
        .onDisappear {
            compare.search?.cancel()
            enrich.clearThumbnails()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("资料对照").font(.headline)
            Text(["「\(compare.row.title)」", compare.row.artistText, clock(compare.row.duration)].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                TextField("搜索关键词", text: Binding(get: { compare.keywords }, set: { compare.keywords = $0 }))
                    .onSubmit(search)
                Button("搜索", action: search).disabled(compare.searching || compare.sources.isEmpty)
                if compare.searching { ProgressView().controlSize(.small) }
            }
            if compare.sources.isEmpty {
                Text("没有启用的在线资料来源，可以在设置里开启；也可以直接在「当前」一栏手动修改。").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("还原为原始信息") { Task { await model.revertInfo([compare.row]) } }
                .disabled(compare.editor.edits.isEmpty)
            if let status = enrich.match(compare.row)?.status, status != .rejected {
                Button("清除补全并不再查找") {
                    model.ui.compare = nil
                    Task { await enrich.reject(compare.row) }
                }
            }
            Spacer()
            Text("点击来源里的值即可采用；保存为手动修改，不改动音频文件。").font(.caption).foregroundStyle(.secondary)
            Button("取消", role: .cancel) { model.ui.compare = nil }
                .keyboardShortcut(.cancelAction)
            // No Return shortcut: Return in the keyword field searches.
            Button("保存") {
                model.ui.compare = nil
                Task { await enrich.save(compare) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!compare.editor.isValid)
        }
    }

    private func search() {
        if !compare.sources.isEmpty { enrich.startSearch(compare) }
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(width: Self.label, alignment: .trailing)
    }

    private func valueCell(_ field: EnrichField, _ source: OnlineSource) -> some View {
        let value = compare.song(source).flatMap { compare.value(field, of: $0) }
        return Button { if let value { compare.take(value, for: field) } } label: {
            Text(value ?? "—")
                .lineLimit(2)
                .foregroundStyle(value == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .frame(width: Self.column - 12, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(value != nil && value == compare.current(field) ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(value == nil)
    }

    private var currentCover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                switch compare.cover {
                case .song(let song)?: Thumbnail(image: song.coverURL.flatMap { enrich.thumbnails[$0] })
                case .file(_, let image)?: Thumbnail(image: image)
                case .removed?: Thumbnail(image: nil).overlay { Image(systemName: "xmark").foregroundStyle(.secondary) }
                case nil: CoverView(store: model.artwork, row: compare.row, size: 72)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: { $0.isFileURL && UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }) else {
                    return false
                }
                compare.cover = .file(url, NSImage(contentsOf: url))
                return true
            }
            HStack {
                Button("选择图片…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image]
                    if panel.runModal() == .OK, let url = panel.url { compare.cover = .file(url, NSImage(contentsOf: url)) }
                }
                if compare.editor.edits[.cover] != nil { Button("移除") { compare.cover = .removed } }
            }
            .controlSize(.small)
        }
        .frame(width: Self.current, alignment: .leading)
    }

    private func coverCell(_ source: OnlineSource) -> some View {
        let song = compare.song(source)
        let chosen = if case .song(let picked)? = compare.cover { picked.key == song?.key } else { false }
        return Button {
            guard let song else { return }
            compare.cover = .song(song)
            compare.tookOnline = true
        } label: {
            Thumbnail(image: song?.coverURL.flatMap { enrich.thumbnails[$0] })
                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: chosen ? 2 : 0) }
        }
        .buttonStyle(.plain)
        .disabled(song?.coverURL == nil)
        .frame(width: Self.column, alignment: .leading)
        .task(id: song?.key) { if let song { await enrich.loadThumbnail(song) } }
    }

    private var currentLyrics: some View {
        let text: String = switch compare.lyricsChoice {
        case .song(let song)?: "采用\(song.source.title)的歌词"
        case .text(let text)?: "导入的歌词（\(text.split(whereSeparator: \.isNewline).count) 行）"
        case .removed?: "移除手动设置的歌词"
        case nil: compare.row.hasLyrics ? "有歌词" : "没有歌词"
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text(text).lineLimit(2)
            HStack {
                Button("导入 .lrc…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText, .plainText]
                    if panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) {
                        compare.lyricsChoice = .text(text)
                    }
                }
                Button("粘贴") { if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty { compare.lyricsChoice = .text(text) } }
                if compare.editor.edits[.lyrics] != nil { Button("移除") { compare.lyricsChoice = .removed } }
            }
            .controlSize(.small)
        }
        .frame(width: Self.current, alignment: .leading)
    }

    private func lyricsCell(_ source: OnlineSource) -> some View {
        let song = compare.song(source)
        let text = song.flatMap { compare.lyrics[$0.key] }
        let chosen = if case .song(let picked)? = compare.lyricsChoice { picked.key == song?.key } else { false }
        return VStack(alignment: .leading, spacing: 4) {
            if let song, let text, let lyrics = LRCParser.parse(text) {
                Button {
                    compare.lyricsChoice = .song(song)
                    compare.tookOnline = true
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary(lyrics)).font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(firstLines(lyrics)).lineLimit(2)
                    }
                    .frame(width: Self.column - 12, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(chosen ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                Button("查看全文") { compare.previewing = song }
                    .controlSize(.small)
                    .popover(isPresented: Binding(get: { compare.previewing?.key == song.key }, set: { if !$0 { compare.previewing = nil } })) {
                        ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                            .frame(width: 380, height: 440)
                    }
            } else {
                Text(song == nil ? "—" : text == nil ? "载入中…" : "没有歌词").foregroundStyle(.tertiary)
            }
        }
        .frame(width: Self.column, alignment: .leading)
    }

    private func summary(_ lyrics: Lyrics) -> String {
        switch lyrics {
        case .synced(let lines):
            "\(lines.filter { !$0.isCredit && !$0.text.isEmpty }.count) 行" + (lines.contains { $0.translation != nil } ? " · 含翻译" : "")
        case .unsynced(let lines): "\(lines.count) 行 · 无时间轴"
        }
    }

    private func firstLines(_ lyrics: Lyrics) -> String {
        switch lyrics {
        case .synced(let lines): lines.filter { !$0.isCredit && !$0.text.isEmpty }.prefix(2).map(\.text).joined(separator: "\n")
        case .unsynced(let lines): lines.prefix(2).joined(separator: "\n")
        }
    }
}

/// A source's column head: its name, which result is shown (switchable), and 全部采用.
private struct SourceHeader: View {
    let enrich: EnrichModel
    let compare: SourceCompare
    let source: OnlineSource
    let width: CGFloat

    var body: some View {
        let results = compare.results[source] ?? []
        let song = compare.song(source)
        VStack(alignment: .leading, spacing: 4) {
            Text(source.title).font(.headline)
            if let song {
                Menu {
                    ForEach(Array(results.enumerated()), id: \.offset) { offset, result in
                        Button(describe(result)) { compare.picked[source] = offset }
                    }
                } label: {
                    Text("第 \((compare.picked[source] ?? 0) + 1) / \(results.count) 个结果")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                let delta = song.duration - compare.row.duration
                Text(song.duration > 0 ? "时长 \(clock(song.duration))（\(delta >= 0 ? "+" : "−")\(Int(abs(delta).rounded())) 秒）" : "时长未知")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(song.duration > 0 && abs(delta) > Matcher.durationTolerance ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                Button("全部采用") {
                    Task {
                        await enrich.loadDetails(song, for: compare)
                        compare.adopt(song)
                    }
                }
                .controlSize(.small)
            } else if compare.searching {
                ProgressView().controlSize(.small)
            } else {
                Text(compare.failures[source] != nil ? "请求失败" : "没有结果").foregroundStyle(.secondary)
                    .help(compare.failures[source] ?? "")
            }
        }
        .frame(width: width, alignment: .leading)
        .task(id: song?.key) { if let song { await enrich.loadDetails(song, for: compare) } }
    }

    private func describe(_ song: OnlineSong) -> String {
        ([song.title, song.artists.joined(separator: " / "), song.album] + [clock(song.duration)]).filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct Thumbnail: View {
    let image: NSImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            .overlay { if let image { Image(nsImage: image).resizable().scaledToFill() } }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
