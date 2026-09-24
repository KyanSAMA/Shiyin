import AppKit
import SwiftUI
import LocalMusicCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let library = model.library {
                LibrarySettingsView(library: library, loudness: model.loudness)
            } else {
                ContentUnavailableView("无法打开曲库", systemImage: "exclamationmark.triangle", description: Text(model.startupError ?? ""))
            }
        }
        .frame(width: 560, height: 460)
    }
}

private struct LibrarySettingsView: View {
    let library: LibraryModel
    let loudness: LoudnessModel?

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
                    Text("把每首歌（或整张专辑）调到 −18 LUFS 的相近响度，峰值不削波。未分析完的歌先用曲库的中位增益。")
                        .foregroundStyle(.secondary)
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
