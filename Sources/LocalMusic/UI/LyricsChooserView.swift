import SwiftUI
import LocalMusicCore

/// 选择歌词: the options on the left (source, song, what kind of lyrics), the selected one's text on the right.
struct LyricsChooserView: View {
    let enrich: EnrichModel
    let chooser: LyricsChooser
    let close: () -> Void
    private static let keep = "keep"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("选择歌词").font(.headline)
                HStack {
                    TextField("搜索关键词", text: Binding(get: { chooser.keywords }, set: { chooser.keywords = $0 }))
                        .onSubmit(search)
                    Button("搜索", action: search)
                    if chooser.searching { ProgressView().controlSize(.small) }
                }
                if chooser.failure != nil {
                    Text("在线资料来源请求失败，请稍后再搜").font(.system(size: 11)).foregroundStyle(.orange).help(chooser.failure ?? "")
                }
            }
            .padding(20)
            Divider()
            HStack(spacing: 0) {
                List(selection: Binding(get: { chooser.selection ?? Self.keep }, set: { chooser.selection = $0 == Self.keep ? nil : $0 })) {
                    Text("保留现有的歌词").tag(Self.keep)
                    ForEach(chooser.options, id: \.key) { song in
                        LyricsOption(song: song, text: chooser.texts[song.key], duration: chooser.query.duration).tag(song.key)
                    }
                }
                .frame(width: 340)
                Divider()
                preview.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                Button(chooser.selected == nil ? "保留现有的" : "使用这份歌词") {
                    chooser.use()
                    close()
                }
                .buttonStyle(.borderedProminent)
                .disabled(chooser.selected.map { chooser.texts[$0.key]?.isEmpty ?? true } ?? false)
            }
            .padding(20)
        }
        .frame(width: 760, height: 520)
        .onDisappear { chooser.search?.cancel() }
    }

    @ViewBuilder private var preview: some View {
        if let song = chooser.selected {
            let text = chooser.texts[song.key]
            ScrollView {
                Text(text.map { $0.isEmpty ? "这首没有歌词" : $0 } ?? "载入中…")
                    .foregroundStyle(text?.isEmpty == false ? .primary : .secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .task(id: song.key) {
                // Only once the selection settles: loads hold the sources' request slots.
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { await enrich.loadLyrics(song, for: chooser) }
            }
        } else {
            Text("不改动这首歌现有的歌词。").foregroundStyle(.secondary).padding(16)
        }
    }

    private func search() { enrich.searchLyrics(chooser) }
}

private struct LyricsOption: View {
    let song: OnlineSong
    let text: String?
    let duration: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(song.title).lineLimit(1)
                Spacer(minLength: 6)
                DurationDelta(song: song, duration: duration)
            }
            HStack(spacing: 5) {
                Badge(text: song.source.title)
                Text([song.artists.joined(separator: " / "), kind].filter { !$0.isEmpty }.joined(separator: " · ")).lineLimit(1)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var kind: String {
        guard let text else { return "" }
        guard let lyrics = LRCParser.parse(text) else { return "没有歌词" }
        return switch lyrics {
        case .synced(let lines): "同步 \(lines.filter { !$0.isCredit && !$0.text.isEmpty }.count) 行" + (lines.contains { $0.translation != nil } ? "，含翻译" : "")
        case .unsynced(let lines): "纯文本 \(lines.count) 行"
        }
    }
}
