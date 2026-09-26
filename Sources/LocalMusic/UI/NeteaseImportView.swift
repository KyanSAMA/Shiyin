import AppKit
import SwiftUI
import LocalMusicCore

/// 网易云导入: what's in the NetEase download folder, which of it the library already has, and the migration's progress.
struct NeteaseImportView: View {
    let model: AppModel
    let importer: ImportModel

    var body: some View {
        let sources = importer.sources, folder = importer.sourceFolder
        let fresh = sources.filter(importer.isFresh)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("网易云导入").font(.system(size: 26, weight: .bold))
                        Text("把网易云音乐下载的歌迁移到曲库：.ncm 解密成原始的 FLAC / MP3，本来就是 FLAC / MP3 的直接复制；可从网易云补全信息并写入新文件。不会覆盖已有文件。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    actions(sources: sources, fresh: fresh)
                }
                HStack(spacing: 8) {
                    Label((folder.path as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                        .lineLimit(1).truncationMode(.middle)
                    Button("在访达中打开") { NSWorkspace.shared.open(folder) }
                        .disabled(!FileManager.default.fileExists(atPath: folder.path))
                    Button("刷新") { Task { await importer.refresh() } }
                    Button("更改…") {
                        guard let url = chooseFolder(prompt: "选择") else { return }
                        var settings = importer.settings
                        settings.neteaseFolder = url.path
                        importer.setSettings(settings)
                    }
                    Spacer()
                    if importer.listing { ProgressView().controlSize(.small) }
                    Text("\(sources.count) 首 · 已在曲库 \(sources.count(where: importer.inLibrary)) 首").foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                .buttonStyle(.link)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            Divider()
            if sources.isEmpty && importer.processed.isEmpty {
                ContentUnavailableView("没有可导入的歌曲", systemImage: "square.and.arrow.down",
                                       description: Text(FileManager.default.fileExists(atPath: folder.path)
                                                         ? "这个文件夹里没有 .ncm、FLAC 或 MP3 文件" : "找不到这个文件夹，可点「更改…」选择网易云音乐的下载目录"))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { importer.selection }, set: { importer.selection = $0 })) {
                    if !sources.isEmpty {
                        Section("网易云下载文件夹") {
                            ForEach(sources) { ImportRow(source: $0, inLibrary: importer.inLibrary($0), state: importer.states[$0.id]) }
                        }
                    }
                    if !importer.processed.isEmpty {
                        Section("本次已处理") {
                            ForEach(importer.processed.reversed()) { ImportRow(source: $0.source, inLibrary: false, state: $0.state).selectionDisabled() }
                        }
                    }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    let picked = sources.filter { ids.contains($0.id) }
                    if !picked.isEmpty {
                        Button("迁移…") { plan(picked) }
                        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting(picked.map(\.url)) }
                    }
                }
            }
        }
        .task { importer.activate() }
    }

    @ViewBuilder private func actions(sources: [ImportSource], fresh: [ImportSource]) -> some View {
        if importer.running {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在迁移，还剩 \(importer.remaining) 首").monospacedDigit().foregroundStyle(.secondary)
                Button("停止") { importer.stop() }
            }
        } else {
            HStack(spacing: 10) {
                let selected = sources.filter { importer.selection.contains($0.id) }
                Button("迁移所选（\(selected.count)）…") { plan(selected) }.disabled(selected.isEmpty)
                Button("全部迁移（\(fresh.count)）…") { plan(fresh) }.buttonStyle(.borderedProminent).disabled(fresh.isEmpty)
            }
        }
    }

    private func plan(_ sources: [ImportSource]) {
        model.ui.sheet = .importPlan(importer.plan(sources))
    }
}

private struct ImportRow: View {
    let source: ImportSource
    let inLibrary: Bool
    let state: ImportState?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: source.isNCM ? "lock.doc" : "music.note")
                .font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title).lineLimit(1)
                Text([source.artists.joined(separator: " / "), source.album].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Badge(text: (source.isNCM ? "NCM · " : "") + source.format.uppercased())
            status.frame(width: 110, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .help(source.url.path)
    }

    @ViewBuilder private var status: some View {
        switch state {
        case .queued?: Text("等待中").foregroundStyle(.secondary)
        case .working?: ProgressView().controlSize(.small)
        case .done(let url, let note)?:
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                Label("已导入", systemImage: note == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(note == nil ? .green : .orange)
            }
            .buttonStyle(.borderless)
            .help([note, "已导入到 \(url.path)，点按在访达中显示"].compactMap { $0 }.joined(separator: "\n"))
        case .failed(let reason)?: Label("失败", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(reason)
        case nil:
            if inLibrary { Label("已在曲库", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
        }
    }
}

/// 迁移: where the files go, how they're named, whether to fill and write their info and trash the originals.
struct ImportPlanView: View {
    let model: AppModel
    let importer: ImportModel
    let plan: ImportPlan

    var body: some View {
        let target = plan.target ?? importer.firstFolder
        let roots = model.library?.roots.include ?? []
        let outside = target.map { url in !roots.contains { url.path == $0 || url.path.hasPrefix($0 + "/") } } ?? false
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    LabeledContent("导入到") {
                        HStack {
                            Text(target.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "还没有音乐文件夹")
                                .lineLimit(1).truncationMode(.middle)
                            Menu("更改") {
                                Button("第一个音乐文件夹") { plan.target = nil }.disabled(importer.firstFolder == nil)
                                Button("其他文件夹…") { if let url = chooseFolder(prompt: "导入到这里") { plan.target = url } }
                            }
                            .fixedSize()
                        }
                    }
                    if outside, let target {
                        HStack {
                            Label("这个文件夹不在音乐文件夹里，导入的歌不会出现在曲库", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("添加到音乐文件夹") { Task { await model.library?.add(target, excluded: false) } }
                        }
                        .font(.system(size: 12))
                    }
                    Picker("文件命名", selection: Binding(get: { plan.naming }, set: { plan.naming = $0 })) {
                        ForEach(ImportNaming.allCases, id: \.self) { Text($0.example).tag($0) }
                    }
                    Toggle("从网易云补全信息并写入文件", isOn: Binding(get: { plan.fill }, set: { plan.fill = $0 }))
                    Toggle("迁移后把原文件（及同名 .lrc）移到废纸篓", isOn: Binding(get: { plan.trashOriginals }, set: { plan.trashOriginals = $0 }))
                } header: {
                    Text("迁移 \(plan.sources.count) 首")
                } footer: {
                    Text("重名时依次加「 (专辑名)」「 2」「 3」…，不会覆盖已有文件。补全会发送歌曲的网易云 id 或歌名。")
                        .foregroundStyle(.secondary)
                }
                Section("预览") {
                    ForEach(plan.sources.prefix(100)) { source in
                        HStack(spacing: 6) {
                            Text(source.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Text(plan.naming.candidates(title: source.title, artists: source.artists, album: source.album,
                                                        trackNo: source.trackNo, ext: source.format)[0])
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .font(.system(size: 12))
                    }
                    if plan.sources.count > 100 { Text("还有 \(plan.sources.count - 100) 首…").foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("取消", role: .cancel) { model.ui.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("开始迁移") {
                    importer.start(plan)
                    model.ui.sheet = nil
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(target == nil || plan.sources.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 600, height: 520)
    }
}

func chooseFolder(prompt: String) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = prompt
    return panel.runModal() == .OK ? panel.url : nil
}
