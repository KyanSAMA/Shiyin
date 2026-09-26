import SwiftUI
import LocalMusicCore

/// 写入文件 / 恢复原标签: what changes in each file, then the run's progress and outcome.
struct TagWriteView: View {
    let model: AppModel
    let plan: TagWritePlan

    var body: some View {
        let writing = plan.mode == .write
        let files = plan.files
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(writing ? "写入文件" : "恢复原标签").font(.headline)
                Text(writing ? "把 App 里显示的信息写进音频文件的标签。只改标签，不动音频数据；第一次写入前的原标签会备份，可随时「恢复原标签」。"
                             : "把文件的标签恢复成 App 第一次写入前的样子，写入时移出的手动修改也放回 App 里。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if writing {
                    HStack(spacing: 18) {
                        group("手动修改与替换", manual: true, isOn: Binding(get: { plan.includeManual }, set: { plan.includeManual = $0 }))
                        group("在线补全的空缺", manual: false, isOn: Binding(get: { plan.includeOnline }, set: { plan.includeOnline = $0 }))
                    }
                    .disabled(plan.started)
                }
            }
            .padding(20)
            Divider()
            List(plan.items) { item in
                ItemRow(item: item, changes: plan.changes(item), writing: writing)
            }
            Divider()
            footer(files.count).padding(20)
        }
        .frame(width: 660, height: 540)
        .interactiveDismissDisabled(plan.started && !plan.finished)
    }

    private func group(_ title: String, manual: Bool, isOn: Binding<Bool>) -> some View {
        let changed = plan.items.filter { $0.skip == nil && $0.changes.contains { $0.manual == manual } }
        let count = changed.reduce(0) { $0 + $1.changes.filter { $0.manual == manual }.count }
        return Toggle("\(title)（\(changed.count) 首，\(count) 项）", isOn: isOn).disabled(changed.isEmpty)
    }

    @ViewBuilder private func footer(_ count: Int) -> some View {
        HStack {
            if plan.finished {
                Text(plan.failures.isEmpty ? "已完成 \(plan.done) 首。" : "完成 \(plan.done - plan.failures.count) 首，\(plan.failures.count) 首失败（悬停查看原因）。")
                    .help(plan.failures.map { "\($0.title)：\($0.reason)" }.joined(separator: "\n"))
                Spacer()
                Button("完成") { model.ui.sheet = nil }.keyboardShortcut(.defaultAction)
            } else if plan.started {
                ProgressView(value: Double(plan.done), total: Double(max(count, 1))).frame(width: 200)
                Text("\(plan.mode == .write ? "正在写入" : "正在恢复") \(plan.done) / \(count)…").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("停止") { plan.run?.cancel() }
            } else {
                Spacer()
                Button("取消", role: .cancel) { model.ui.sheet = nil }.keyboardShortcut(.cancelAction)
                Button(plan.mode == .write ? "写入 \(count) 首" : "恢复 \(count) 首") { model.runTagPlan(plan) }
                    .buttonStyle(.borderedProminent)
                    .disabled(count == 0)
            }
        }
    }
}

private struct ItemRow: View {
    let item: TagWritePlan.Item
    let changes: [TagWritePlan.Change]
    let writing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(item.row.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let skip = item.skip { Text(skip).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            if writing {
                ForEach(changes) { change in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(change.field.label).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                        Text(change.old.isEmpty ? "（空）→ \(change.new)" : "\(change.old) → \(change.new)").lineLimit(2)
                        Spacer(minLength: 6)
                        Text(change.manual ? "手动" : "在线补全").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                }
                if let note = item.note { Label(note, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange) }
            }
        }
        .padding(.vertical, 3)
    }
}
