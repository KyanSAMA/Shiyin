import Foundation
import Observation
import LocalMusicCore

/// 选择歌词: one song's lyrics from any source with lyrics — 选择匹配's results and LRCLIB's, or a search of its own
/// (from 编辑信息). Choosing hands the text to whoever opened it.
@Observable final class LyricsChooser {
    let query: MatchQuery
    var keywords: String
    fileprivate(set) var options: [OnlineSong]
    /// The option shown; nil keeps what the song has.
    var selection: String?
    /// Per option, once loaded ("" when it has none).
    fileprivate(set) var texts: [String: String]
    fileprivate(set) var searching = false
    /// The last search's failure, when no source answered.
    fileprivate(set) var failure: String?
    @ObservationIgnored fileprivate var loads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var search: Task<Void, Never>?
    /// The chosen song and its lyrics; nil keeps what the song has.
    @ObservationIgnored let chosen: ((song: OnlineSong, text: String)?) -> Void

    init(query: MatchQuery, options: [OnlineSong], texts: [String: String], chosen: @escaping ((song: OnlineSong, text: String)?) -> Void) {
        (self.query, self.chosen) = (query, chosen)
        keywords = query.keywords
        let options = options.filter { $0.source != .itunes }
        self.options = options
        self.texts = texts.merging(options.compactMap { song in song.lyrics.map { (song.key, $0) } }) { $1 }
    }

    var selected: OnlineSong? { options.first { $0.key == selection } }

    /// Hands over the selected lyrics (or keeping the song's own).
    func use() {
        chosen(selected.flatMap { song in texts[song.key].flatMap { $0.isEmpty ? nil : (song, $0) } })
    }
}

extension EnrichModel {
    /// The enabled sources with lyrics.
    var lyricsSources: [OnlineSource] { settings.enabled.filter { $0 != .itunes } }

    /// Replaces the options with the enabled lyric sources' results for the keywords (LRCLIB's come with their lyrics);
    /// keeps them when every source failed.
    func searchLyrics(_ chooser: LyricsChooser) {
        let sources = lyricsSources
        guard !sources.isEmpty else { return }
        chooser.search?.cancel()
        chooser.searching = true
        chooser.search = Task {
            var found: [OnlineSource: [OnlineSong]] = [:], failures: [String] = []
            await withTaskGroup(of: (OnlineSource, Result<[OnlineSong], Error>).self) { group in
                for source in sources {
                    group.addTask { [service, keywords = chooser.keywords, storefront = settings.storefront] in
                        let result: Result<[OnlineSong], Error>
                        do { result = .success(try await service.search(source, keywords, storefront: storefront)) } catch { result = .failure(error) }
                        return (source, result)
                    }
                }
                for await (source, result) in group {
                    switch result {
                    case .success(let songs): found[source] = songs
                    case .failure(let error): failures.append("\(source.title)：\(error)")
                    }
                }
            }
            guard !Task.isCancelled else { return }
            chooser.searching = false
            chooser.failure = found.isEmpty ? failures.joined(separator: "\n") : nil
            guard !found.isEmpty else { return }
            // Ties go by the user's source order, whichever answered first.
            chooser.options = Matcher.ranked(chooser.query, candidates: sources.flatMap { found[$0] ?? [] })
            for song in chooser.options { if let lyrics = song.lyrics { chooser.texts[song.key] = lyrics } }
        }
    }

    /// One load per option, which every caller awaits.
    func loadLyrics(_ song: OnlineSong, for chooser: LyricsChooser) async {
        guard chooser.texts[song.key] == nil else { return }
        let load = chooser.loads[song.key] ?? Task { [service] in
            chooser.texts[song.key] = (try? await service.lyrics(song)) ?? ""
        }
        chooser.loads[song.key] = load
        await load.value
    }
}

extension EnrichModel {
    /// From 选择匹配: its results and LRCLIB's (and lyrics chosen before); a search of its own when it showed stored
    /// candidates or is still searching. The list stops re-ranking, so the selection (and the choice) stays.
    func chooseLyrics(for picker: MatchPicker) {
        let earlier = picker.chosenLyrics
        let options = (earlier.map { [$0.song] } ?? []) + (picker.results + picker.lyricsResults).filter { $0.key != earlier?.song.key }
        let chooser = LyricsChooser(query: picker.query, options: options, texts: picker.lyrics.merging(earlier.map { [$0.song.key: $0.text] } ?? [:]) { $1 }) {
            [weak picker] in picker?.chosenLyrics = $0
        }
        chooser.keywords = picker.keywords
        chooser.selection = earlier?.song.key
        picker.touched = true
        picker.lyricsChooser = chooser
        if picker.status.isEmpty || picker.searching { searchLyrics(chooser) }
    }
}

extension AppModel {
    /// From 编辑信息: a search of every source with lyrics.
    func chooseLyrics(for editor: InfoEditor) {
        guard let enrich, let row = editor.tracks.first else { return }
        let query = MatchQuery(title: row.title, artists: row.artists, album: row.album, duration: row.duration)
        let chooser = LyricsChooser(query: query, options: [], texts: [:]) { [weak editor] in
            if let text = $0?.text { editor?.lyrics = .text(text) }
        }
        editor.lyricsChooser = chooser
        enrich.searchLyrics(chooser)
    }
}
