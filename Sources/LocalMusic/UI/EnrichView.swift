import SwiftUI
import LocalMusicCore

/// 信息补全: songs missing a cover, lyrics or basic info, filled from the online sources on request. Only gaps are filled; the
/// files are never touched.
struct EnrichView: View {
    let model: AppModel
    let enrich: EnrichModel
    let index: LibraryIndex

    var body: some View {
        @Bindable var ui = model.ui
        let rows = ui.narrowed(index.songs, in: index).filter { ui.enrichFilter.includes($0, enrich.match($0)) }
        let counts = EnrichFilter.counts(index.songs, enrich.match)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("信息补全").font(.system(size: 26, weight: .bold))
                        Text("从在线来源（在设置里选择）补全缺失的封面、歌词、曲序、年份和流派。只填空缺，不改动文件里已有的信息，也不修改音频文件。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    actions(rows: rows)
                }
                Picker("", selection: $ui.enrichFilter) {
                    ForEach(EnrichFilter.allCases) { filter in
                        Text("\(filter.title) \(counts[filter] ?? 0)").tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if let notice = enrich.notice {
                    Label(notice, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            Divider()
            if rows.isEmpty {
                ContentUnavailableView("没有歌曲", systemImage: "checkmark.circle", description: Text("这一类里没有需要处理的歌曲"))
                    .frame(maxHeight: .infinity)
            } else {
                List(rows, selection: $ui.enrichSelection) { row in
                    EnrichRow(store: model.artwork, row: row, match: enrich.match(row),
                              applying: row.fingerprint.map(enrich.applying.contains) ?? false) { choose(row) }
                        .contextMenu {
                            Button("选择匹配…") { choose(row) }
                            Button("编辑信息…") { Task { await model.editInfo([row]) } }
                            Button("重新查找") { enrich.enrich([row]) }
                            if let status = enrich.match(row)?.status, status != .rejected {
                                Button(status.rejectTitle) { Task { await enrich.reject(row) } }
                            }
                        }
                }
                .id(ui.listID + [ui.enrichFilter])
            }
        }
    }

    private func choose(_ row: TrackRow) {
        Task { await model.chooseMatch(row) }
    }

    @ViewBuilder private func actions(rows: [TrackRow]) -> some View {
        if let progress = enrich.progress {
            HStack(spacing: 10) {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).frame(width: 140)
                Text("\(progress.done) / \(progress.total)").monospacedDigit().foregroundStyle(.secondary)
                Button("停止") { enrich.stop() }
            }
        } else {
            HStack(spacing: 10) {
                let selected = rows.filter { model.ui.enrichSelection.contains($0.id) }
                Button("补全所选（\(selected.count)）") {
                    enrich.enrich(selected)
                    model.ui.enrichSelection = []
                }
                    .disabled(selected.isEmpty)
                Button("全部补全") { Task { await enrich.enrichAll(index.songs) } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct EnrichRow: View {
    let store: ArtworkStore
    let row: TrackRow
    let match: MatchState?
    let applying: Bool
    let choose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            CoverView(store: store, row: row, size: 36, radius: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).lineLimit(1)
                Text([row.artistText, row.album ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                if !row.hasArtwork { Badge(text: "缺封面") }
                if !row.hasLyrics { Badge(text: "缺歌词") }
                if EnrichFilter.missingInfo(row) { Badge(text: "缺信息") }
            }
            status.frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var status: some View {
        if applying {
            ProgressView().controlSize(.small)
        } else {
            label
        }
    }

    @ViewBuilder private var label: some View {
        switch match?.status {
        case .auto?, .confirmed?: Label("已补全", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .pending?: Button("选择…", action: choose)
        case .none?: Label("未找到", systemImage: "minus.circle").foregroundStyle(.secondary)
        case .rejected?: Label("已忽略", systemImage: "xmark.circle").foregroundStyle(.secondary)
        case nil: EmptyView()
        }
    }
}

struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
    }
}

extension MatchStatus {
    /// What rejecting a song in this state does.
    var rejectTitle: String {
        switch self {
        case .pending: "都不是"
        case .auto, .confirmed: "清除补全并不再查找"
        case .none, .rejected: "不再查找"
        }
    }
}
