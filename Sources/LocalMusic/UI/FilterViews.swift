import SwiftUI
import LocalMusicCore

/// Toolbar menu: one submenu per dimension.
struct FilterMenu: View {
    let ui: UIState
    let facets: LibraryIndex.Facets

    var body: some View {
        Menu {
            values("专辑艺人", facets.albumArtists, \.albumArtists) { $0 }
            values("年份", facets.years, \.years) { String($0) }
            values("流派", facets.genres, \.genres) { $0 }
            values("格式", facets.formats, \.formats) { $0 }
            tristate("Hi-Res", \.hiRes, yes: "仅 Hi-Res", no: "非 Hi-Res")
            tristate("歌词", \.hasLyrics, yes: "有歌词", no: "无歌词")
            Divider()
            Button("清除筛选") { ui.filter = TrackFilter() }
                .disabled(ui.filter.isEmpty)
        } label: {
            Label("筛选", systemImage: ui.filter.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .help("筛选")
    }

    private func values<Value: Hashable>(_ title: String, _ options: [Value], _ key: WritableKeyPath<TrackFilter, Set<Value>>,
                                         label: @escaping (Value) -> String) -> some View {
        Menu(title) {
            ForEach(options, id: \.self) { value in
                Toggle(label(value), isOn: Binding(get: { ui.filter[keyPath: key].contains(value) }, set: { on in
                    if on { ui.filter[keyPath: key].insert(value) } else { ui.filter[keyPath: key].remove(value) }
                }))
            }
        }
        .disabled(options.isEmpty)
    }

    private func tristate(_ title: String, _ key: WritableKeyPath<TrackFilter, Bool?>, yes: String, no: String) -> some View {
        Picker(title, selection: Binding(get: { ui.filter[keyPath: key] }, set: { ui.filter[keyPath: key] = $0 })) {
            Text("不限").tag(Bool?.none)
            Text(yes).tag(Bool?.some(true))
            Text(no).tag(Bool?.some(false))
        }
    }
}

/// The active filter as removable chips.
struct FilterBar: View {
    let ui: UIState

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ui.filter.chips) { chip in
                        Button { ui.filter = chip.remaining } label: {
                            HStack(spacing: 4) {
                                if let dimension = chip.dimension { Text(dimension).foregroundStyle(.secondary) }
                                Text(chip.value)
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("移除筛选 \(chip.value)")
                    }
                }
                .padding(.horizontal, 16)
            }
            Button("清除") { ui.filter = TrackFilter() }
                .buttonStyle(.link)
                .padding(.trailing, 16)
        }
        .font(.system(size: 12))
        .padding(.vertical, 8)
    }
}

struct FilterChip: Identifiable {
    let dimension: String?
    let value: String
    let remaining: TrackFilter
    var id: String { (dimension ?? "") + "\u{1}" + value }
}

extension TrackFilter {
    var chips: [FilterChip] {
        var chips: [FilterChip] = []
        func add(_ dimension: String?, _ value: String, _ remove: (inout TrackFilter) -> Void) {
            var remaining = self
            remove(&remaining)
            chips.append(FilterChip(dimension: dimension, value: value, remaining: remaining))
        }
        for artist in albumArtists.localizedSorted() { add("专辑艺人", artist) { $0.albumArtists.remove(artist) } }
        for year in years.sorted(by: >) { add("年份", String(year)) { $0.years.remove(year) } }
        for genre in genres.localizedSorted() { add("流派", genre) { $0.genres.remove(genre) } }
        for format in formats.sorted() { add(nil, format) { $0.formats.remove(format) } }
        if let hiRes { add(nil, hiRes ? "Hi-Res" : "非 Hi-Res") { $0.hiRes = nil } }
        if let hasLyrics { add(nil, hasLyrics ? "有歌词" : "无歌词") { $0.hasLyrics = nil } }
        return chips
    }
}
