import SwiftUI
import LocalMusicCore

/// 选择匹配: the NetEase songs a lookup couldn't decide between. Covers load from NetEase (through the enrichment client,
/// so self-tests get recorded ones) only while this is open.
struct CandidatePicker: View {
    let model: AppModel
    let enrich: EnrichModel
    let row: TrackRow
    let candidates: [NeteaseSong]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("选择匹配").font(.headline)
                Text("「\(row.title)」\(row.artistText.isEmpty ? "" : " · \(row.artistText)") · \(clock(row.duration))")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(20)
            List(Array(candidates.enumerated()), id: \.offset) { offset, song in
                HStack(spacing: 10) {
                    Rectangle().fill(.quaternary)
                        .overlay { if let image = song.coverURL.flatMap({ enrich.thumbnails[$0] }) { Image(nsImage: image).resizable().scaledToFill() } }
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .task { if let url = song.coverURL { await enrich.loadThumbnail(url) } }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title).lineLimit(1)
                        Text(([song.artists.joined(separator: " / "), song.album] + [song.year.map(String.init)].compactMap { $0 })
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    let delta = song.duration - row.duration
                    Text("\(clock(song.duration))（\(delta >= 0 ? "+" : "−")\(Int(abs(delta).rounded())) 秒）")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(abs(delta) <= Matcher.durationTolerance ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    Button("采用") { choose(song) }
                        .accessibilityIdentifier("candidate-\(offset)")
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 240)
            HStack {
                Button("都不是") {
                    model.ui.candidatesFor = nil
                    Task { await enrich.reject(row) }
                }
                Spacer()
                Button("取消", role: .cancel) { model.ui.candidatesFor = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
        }
        .frame(width: 560)
        .onDisappear { enrich.clearThumbnails() }
    }

    private func choose(_ song: NeteaseSong) {
        model.ui.candidatesFor = nil
        Task { await enrich.choose(song, for: row) }
    }
}
