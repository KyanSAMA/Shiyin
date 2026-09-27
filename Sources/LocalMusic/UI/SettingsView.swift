import AppKit
import SwiftUI
import LocalMusicCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let library = model.library {
                TabView(selection: Binding(get: { model.ui.settingsTab }, set: { model.ui.settingsTab = $0 })) {
                    Tab("曲库", systemImage: "music.note.list", value: 0) {
                        LibrarySettingsView(library: library)
                    }
                    if let output = model.output {
                        Tab("播放", systemImage: "hifispeaker", value: 3) {
                            PlaybackSettingsView(output: output, loudness: model.loudness)
                        }
                    }
                    if let enrich = model.enrich {
                        Tab("在线资料", systemImage: "globe", value: 1) {
                            Form { OnlineSourcesSection(enrich: enrich) }.formStyle(.grouped)
                        }
                    }
                    if let importer = model.importer {
                        Tab("导入", systemImage: "square.and.arrow.down", value: 2) {
                            Form { ImportSettingsSection(importer: importer) }.formStyle(.grouped)
                        }
                    }
                }
            } else {
                ContentUnavailableView("无法打开曲库", systemImage: "exclamationmark.triangle", description: Text(model.startupError ?? ""))
            }
        }
        .frame(width: 560, height: 460)
    }
}

private struct LibrarySettingsView: View {
    let library: LibraryModel

    var body: some View {
        Form {
            folders("音乐文件夹", library.roots.include, excluded: false)
            folders("排除的文件夹", library.roots.exclude, excluded: true)
            Section {
                HStack {
                    Text(status).foregroundStyle(.secondary)
                    Spacer()
                    Button("重新扫描") { Task { await library.scan() } }
                        .disabled(library.scanning)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var status: String {
        if library.scanning { return "正在扫描…" }
        let count = "共 \(library.index.songs.count) 首"
        guard let scan = library.lastScan else { return count }
        let failures = scan.failures.isEmpty ? "" : " · \(scan.failures.count) 个文件无法读取"
        return count + failures
    }

    private func folders(_ title: String, _ paths: [String], excluded: Bool) -> some View {
        Section(title) {
            ForEach(paths, id: \.self) { path in
                HStack {
                    Label((path as NSString).abbreviatingWithTildeInPath, systemImage: excluded ? "folder.badge.minus" : "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("移除") { Task { await library.remove(path) } }
                        .buttonStyle(.borderless)
                }
            }
            Button(excluded ? "添加排除文件夹…" : "添加文件夹…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.prompt = "选择"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                Task { await library.add(url, excluded: excluded) }
            }
        }
    }
}

private struct PlaybackSettingsView: View {
    let output: OutputModel
    let loudness: LoudnessModel?

    var body: some View {
        Form {
            Section {
                Picker("输出设备", selection: Binding(get: { output.settings.deviceUID ?? "" }, set: { output.select($0.isEmpty ? nil : $0) })) {
                    Text("系统默认（\(output.defaultDevice?.name ?? "无")）").tag("")
                    ForEach(output.devices) { Text("\($0.name) · \($0.transport.title)").tag($0.id) }
                    if let missing = output.missing, let uid = output.settings.deviceUID { Text("\(missing)（未连接）").tag(uid) }
                }
            } header: {
                Text("输出")
            } footer: {
                Text([output.effective.map { "正在使用\($0.name)，\(kHz($0.nominalRate))。" },
                      "拔掉正在播放的设备时会暂停，不会改从扬声器外放。"].compactMap { $0 }.joined())
                    .foregroundStyle(.secondary)
            }
            if let loudness {
                Section {
                    NormalizationPicker(loudness: loudness, title: "模式").pickerStyle(.segmented)
                    let progress = loudness.progress
                    if progress.total > 0 {
                        LabeledContent("已分析", value: "\(progress.analyzed) / \(progress.total) 首")
                        if progress.failed > 0 { LabeledContent("无法分析", value: "\(progress.failed) 首") }
                        if progress.pending > 0 { ProgressView(value: Double(progress.total - progress.pending), total: Double(progress.total)) }
                    }
                } header: {
                    Text("响度均衡")
                } footer: {
                    Text("把每首歌（或整张专辑）调到 −18 LUFS 的相近响度，峰值不削波。未分析完的歌先用曲库的中位增益（只降不升）。")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

func kHz(_ rate: Double) -> String { String(format: "%g kHz", rate / 1000) }

/// Which sources 信息补全 asks, in which order; the order is also whose value shows when several have one.
private struct OnlineSourcesSection: View {
    let enrich: EnrichModel
    private static let storefronts = [("jp", "日本"), ("us", "美国"), ("gb", "英国"), ("cn", "中国大陆"), ("hk", "香港"), ("tw", "台湾")]

    var body: some View {
        let settings = enrich.settings, order = settings.ordered
        Section {
            ForEach(Array(order.enumerated()), id: \.element) { offset, source in
                HStack {
                    Toggle(isOn: Binding(get: { !settings.disabled.contains(source) }, set: { on in
                        update { if on { $0.disabled.remove(source) } else { $0.disabled.insert(source) } }
                    })) {
                        Text(source.title)
                        Text(source.detail)
                    }
                    Spacer()
                    Button("上移", systemImage: "chevron.up") { move(offset, by: -1) }
                        .disabled(offset == 0)
                    Button("下移", systemImage: "chevron.down") { move(offset, by: 1) }
                        .disabled(offset == order.count - 1)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            Picker("iTunes 商店地区", selection: Binding(get: { settings.storefront }, set: { value in update { $0.storefront = value } })) {
                ForEach(Self.storefronts, id: \.0) { Text($0.1).tag($0.0) }
            }
        } header: {
            Text("在线资料来源")
        } footer: {
            Text("信息补全按顺序查找已开启的来源，前面的来源认出歌曲后，只在还有空缺时才查后面的来源；几个来源都有值时显示排在前面的。只发送歌名、艺人和歌曲 id。")
                .foregroundStyle(.secondary)
        }
    }

    private func move(_ offset: Int, by step: Int) {
        update { $0.order = $0.ordered; $0.order.swapAt(offset, offset + step) }
    }

    private func update(_ change: (inout OnlineSettings) -> Void) {
        var settings = enrich.settings
        change(&settings)
        enrich.setSettings(settings)
    }
}

/// Where 网易云导入 reads from, and its defaults (each migration's sheet can change them, and remembers them).
private struct ImportSettingsSection: View {
    let importer: ImportModel

    var body: some View {
        let settings = importer.settings
        Section {
            LabeledContent("网易云下载文件夹") { folder(settings.neteaseFolder) { $0.neteaseFolder = $1 } }
            LabeledContent("导入到") {
                HStack {
                    Text(settings.target.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "第一个音乐文件夹")
                        .lineLimit(1).truncationMode(.middle)
                    Menu("更改") {
                        Button("第一个音乐文件夹") { update { $0.target = nil } }
                        Button("其他文件夹…") { if let url = chooseFolder(prompt: "导入到这里") { update { $0.target = url.path } } }
                    }
                    .fixedSize()
                }
            }
            Picker("文件命名", selection: Binding(get: { settings.naming }, set: { value in update { $0.naming = value } })) {
                ForEach(ImportNaming.allCases, id: \.self) { Text($0.example).tag($0) }
            }
            Toggle("从网易云补全信息并写入文件", isOn: Binding(get: { settings.fill }, set: { value in update { $0.fill = value } }))
            Toggle("迁移后把原文件移到废纸篓", isOn: Binding(get: { settings.trashOriginals }, set: { value in update { $0.trashOriginals = value } }))
        } header: {
            Text("网易云导入")
        } footer: {
            Text(".ncm 解密成原始的 FLAC / MP3，FLAC / MP3 直接复制；只在导入目录里新建文件，不覆盖已有文件。原文件移到废纸篓，可以找回。")
                .foregroundStyle(.secondary)
        }
    }

    private func folder(_ path: String, _ set: @escaping (inout ImportSettings, String) -> Void) -> some View {
        HStack {
            Text((path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
            Button("选择…") { if let url = chooseFolder(prompt: "选择") { update { set(&$0, url.path) } } }
        }
    }

    private func update(_ change: (inout ImportSettings) -> Void) {
        var settings = importer.settings
        change(&settings)
        importer.setSettings(settings)
    }
}

extension OnlineSource {
    var title: String {
        switch self {
        case .netease: "网易云音乐"
        case .qq: "QQ 音乐"
        case .itunes: "iTunes"
        case .lrclib: "LRCLIB"
        }
    }

    var detail: String {
        switch self {
        case .netease, .qq: "信息、歌词（含翻译）、封面"
        case .itunes: "年份、曲序、碟号、流派、封面"
        case .lrclib: "歌词"
        }
    }
}
