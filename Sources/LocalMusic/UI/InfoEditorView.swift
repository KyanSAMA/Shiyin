import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LocalMusicCore

/// 编辑信息: manual edits stay in the app's database; the files are never touched. One song also shows its online
/// sources' values to fill a field from, and its cover and lyrics.
struct InfoEditorView: View {
    let model: AppModel
    let editor: InfoEditor

    private var single: TrackRow? { editor.tracks.count == 1 ? editor.tracks[0] : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let row = single { header(row) } else {
                Text("编辑 \(editor.tracks.count) 首歌曲的信息").font(.headline).padding([.horizontal, .top], 20)
            }
            Form {
                Section {
                    ForEach(editor.fields, id: \.self, content: field)
                }
                if let row = single {
                    Section {
                        coverRow(row)
                        lyricsRow(row)
                    }
                }
            }
            .formStyle(.grouped)
            Text("留空则沿用文件标签或补全的信息；多位艺人用 / 分隔。只保存在本 App 里，不修改音频文件。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
            HStack {
                Button("还原为原始信息") { Task { await model.revertInfo(editor.tracks) } }
                    .disabled(single != nil && editor.edits.isEmpty)
                Spacer()
                Button("取消", role: .cancel) { model.ui.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { Task { await model.saveInfo(editor) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!editor.isValid)
            }
            .padding(20)
        }
        .frame(width: single == nil ? 440 : 500, height: single == nil ? nil : 540)
    }

    private func header(_ row: TrackRow) -> some View {
        HStack(spacing: 12) {
            CoverView(store: model.artwork, row: row, size: 56, radius: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text("编辑信息").font(.headline)
                Text([row.title, row.artistText, clock(row.duration)].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Text(editor.layers.isEmpty ? "没有在线补全的信息" : "补全来自 " + editor.layers.map(\.source.title).joined(separator: "、"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if model.enrich != nil { Button("选择匹配…") { Task { await model.chooseMatch(row) } } }
        }
        .padding([.horizontal, .top], 20)
    }

    private func field(_ field: EnrichField) -> some View {
        let text = Binding(get: { editor.texts[field] ?? "" }, set: { editor.texts[field] = $0 })
        let options = single == nil ? [] : editor.suggestions(field)
        return LabeledContent(field.label) {
            HStack(spacing: 4) {
                TextField(field.label, text: text, prompt: Text(editor.shown(field))).labelsHidden()
                if !options.isEmpty {
                    Menu {
                        ForEach(options, id: \.source) { option in Button("\(option.source.title)：\(option.value)") { text.wrappedValue = option.value } }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("在线来源的值")
                }
            }
        }
    }

    private func coverRow(_ row: TrackRow) -> some View {
        LabeledContent("封面") {
            HStack(spacing: 10) {
                Group {
                    switch editor.cover {
                    case .image(_, let image)?: Thumbnail(image: image)
                    case .removed?: Thumbnail(image: nil).overlay { Image(systemName: "xmark").foregroundStyle(.secondary) }
                    case .text?, nil: CoverView(store: model.artwork, row: row, size: 56, radius: 4)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first(where: { $0.isFileURL && UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }) else {
                        return false
                    }
                    editor.cover = .image(url, NSImage(contentsOf: url))
                    return true
                }
                Spacer(minLength: 0)
                let covers = editor.suggestions(.cover)
                if !covers.isEmpty {
                    Menu("在线来源") {
                        ForEach(covers, id: \.source) { option in
                            Button(option.source.title) { editor.cover = .image(URL(filePath: option.value), NSImage(contentsOfFile: option.value)) }
                        }
                    }
                    .fixedSize()
                }
                Button("选择图片…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image]
                    if panel.runModal() == .OK, let url = panel.url { editor.cover = .image(url, NSImage(contentsOf: url)) }
                }
                if editor.edits[.cover] != nil { Button("移除") { editor.cover = .removed } }
            }
        }
    }

    private func lyricsRow(_ row: TrackRow) -> some View {
        let state: String = switch editor.lyrics {
        case .text(let text)?: "新歌词（\(text.split(whereSeparator: \.isNewline).count) 行）"
        case .removed?: "移除手动设置的歌词"
        case .image?, nil: editor.edits[.lyrics] != nil ? "手动设置的歌词" : row.hasLyrics ? "有歌词" : "没有歌词"
        }
        return LabeledContent("歌词") {
            HStack(spacing: 10) {
                Text(state).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                let options = editor.suggestions(.lyrics)
                if !options.isEmpty {
                    Menu("在线来源") {
                        ForEach(options, id: \.source) { option in Button(option.source.title) { editor.lyrics = .text(option.value) } }
                    }
                    .fixedSize()
                }
                Button("导入 .lrc…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText, .plainText]
                    if panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) {
                        editor.lyrics = .text(text)
                    }
                }
                Button("粘贴") { if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty { editor.lyrics = .text(text) } }
                if editor.edits[.lyrics] != nil { Button("移除") { editor.lyrics = .removed } }
            }
        }
    }
}

struct Thumbnail: View {
    let image: NSImage?
    var size: CGFloat = 56

    var body: some View {
        RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            .overlay { if let image { Image(nsImage: image).resizable().scaledToFill() } }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
