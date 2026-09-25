import SwiftUI
import LocalMusicCore

/// 编辑信息: manual edits stay in the app's database; the files are never touched.
struct InfoEditorView: View {
    let model: AppModel
    let editor: InfoEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(editor.tracks.count == 1 ? "编辑信息" : "编辑 \(editor.tracks.count) 首歌曲的信息")
                .font(.headline)
                .padding([.horizontal, .top], 20)
            Form {
                ForEach(editor.fields, id: \.self) { field in
                    TextField(field.label, text: Binding(get: { editor.texts[field] ?? "" }, set: { editor.texts[field] = $0 }),
                              prompt: Text(editor.shown(field)))
                }
            }
            .formStyle(.grouped)
            Text("留空则沿用文件标签或补全的信息；多位艺人用 / 分隔。只保存在本 App 里，不修改音频文件。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
            HStack {
                Button("还原为原始信息") { Task { await model.revertInfo(editor.tracks) } }
                    .disabled(editor.tracks.count == 1 && editor.edits.isEmpty)
                Spacer()
                Button("取消", role: .cancel) { model.ui.infoEditor = nil }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { Task { await model.saveInfo(editor) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!editor.isValid)
            }
            .padding(20)
        }
        .frame(width: 440)
    }
}
