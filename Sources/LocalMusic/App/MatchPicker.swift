import AppKit
import Observation
import LocalMusicCore

/// The 选择匹配 sheet for one song: which online song it is, from the stored candidates or a search of the enabled
/// sources. The pick becomes the song's match, filling gaps; what `replace` names becomes manual edits over the file.
@Observable final class MatchPicker {
    enum SourceStatus: Equatable {
        case searching, found(Int), failed(String)
    }

    let row: TrackRow
    /// The song without online layers: what a pick fills and what it leaves alone.
    let baseline: TrackRow
    /// The sources it can search (LRCLIB can't tell songs apart), in order.
    let sources: [OnlineSource]
    var keywords: String
    fileprivate(set) var results: [OnlineSong]
    /// The selected result's key; choosing another clears `replace`.
    var selection: String? {
        didSet { if selection != oldValue { replace = [] } }
    }
    /// What the pick replaces in the file (as manual edits) rather than only filling gaps.
    var replace: Set<EnrichField> = []
    /// The last search's per source; empty while showing the stored candidates.
    fileprivate(set) var status: [OnlineSource: SourceStatus] = [:]
    /// Once the user has picked a row, results arriving later go to the end instead of re-ranking under the cursor.
    var touched = false
    /// Per result (`OnlineSong.key`), once loaded: its lyrics ("" when none), and a NetEase year search results lack.
    /// Loads outlive the view that started them, so moving the selection doesn't cancel one halfway.
    fileprivate(set) var lyrics: [String: String] = [:]
    fileprivate(set) var years: [String: Int] = [:]
    @ObservationIgnored fileprivate var details: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var search: Task<Void, Never>?
    @ObservationIgnored private var found: [OnlineSource: [OnlineSong]] = [:]

    init(row: TrackRow, baseline: TrackRow, sources: [OnlineSource], candidates: [OnlineSong]) {
        (self.row, self.baseline, self.sources, results) = (row, baseline, sources.filter { $0 != .lrclib }, candidates)
        keywords = MatchQuery(title: row.title, artists: row.artists, album: row.album, duration: row.duration).keywords
        selection = candidates.first?.key
    }

    var query: MatchQuery { MatchQuery(title: row.title, artists: row.artists, album: row.album, duration: row.duration) }
    var searching: Bool { status.values.contains(.searching) }
    var selected: OnlineSong? { results.first { $0.key == selection } }

    fileprivate func begin() {
        results = []
        found = [:]
        selection = nil
        touched = false
        status = Dictionary(uniqueKeysWithValues: sources.map { ($0, .searching) })
    }

    fileprivate func arrive(_ source: OnlineSource, _ songs: [OnlineSong]?, failure: String?) {
        status[source] = failure.map(SourceStatus.failed) ?? .found(songs?.count ?? 0)
        found[source] = songs ?? []
        if touched {
            results += songs ?? []
        } else {
            // Ties go by the user's source order, whichever answered first.
            results = Matcher.ranked(query, candidates: sources.flatMap { found[$0] ?? [] })
            selection = results.first?.key
        }
    }

    /// What a result gives for a field, as the editor spells it.
    func value(_ field: EnrichField, of song: OnlineSong) -> String? {
        let text: String? = switch field {
        case .title: song.title
        case .artists: song.artists.joined(separator: " / ")
        case .album: song.album
        case .trackNo: song.trackNo.map(String.init)
        case .discNo: song.discNo.map(String.init)
        case .year: (song.year ?? years[song.key]).map(String.init)
        case .genre: song.genre
        default: nil
        }
        return text?.isEmpty == false ? text : nil
    }
}

extension OnlineSong {
    var key: String { source.rawValue + ":" + id }
}

extension AppModel {
    /// Lists the stored candidates, or searches when there are none.
    func chooseMatch(_ row: TrackRow) async {
        guard let enrich, let library, let fingerprint = row.fingerprint,
              let baseline = await library.rows([row.id], without: EnrichSource.allOnline).first else { return }
        let picker = MatchPicker(row: row, baseline: baseline, sources: enrich.settings.enabled,
                                 candidates: enrich.matches[fingerprint]?.candidates ?? [])
        ui.sheet = .picker(picker)
        if picker.results.isEmpty { enrich.startSearch(picker) }
    }
}

extension EnrichModel {
    /// Replaces a search still running.
    func startSearch(_ picker: MatchPicker) {
        guard !picker.sources.isEmpty else { return }
        picker.search?.cancel()
        picker.begin()
        picker.search = Task { await search(picker) }
    }

    /// Every source at once (each paced on its own), ranked as they arrive.
    private func search(_ picker: MatchPicker) async {
        await withTaskGroup(of: (OnlineSource, [OnlineSong]?, String?).self) { group in
            for source in picker.sources {
                group.addTask { [service, keywords = picker.keywords, storefront = settings.storefront] in
                    // Not `return (source, try await …)`: optimized builds lost `source` across the suspension (it came back
                    // as .netease), so its results went to the wrong source and the others stayed 搜索中.
                    do {
                        let songs = try await service.search(source, keywords, storefront: storefront)
                        return (source, songs, nil)
                    } catch {
                        return (source, nil, String(describing: error))
                    }
                }
            }
            for await (source, songs, failure) in group where !Task.isCancelled {
                picker.arrive(source, songs, failure: failure)
            }
        }
    }

    /// A result's lyrics, and a NetEase year search results lacked; one load per result, which every caller awaits.
    func loadDetails(_ song: OnlineSong, for picker: MatchPicker) async {
        let load = picker.details[song.key] ?? Task { [service] in
            if song.year == nil, song.source == .netease, let year = try? await service.neteaseYear(song) { picker.years[song.key] = year }
            picker.lyrics[song.key] = (try? await service.lyrics(song)) ?? ""
        }
        picker.details[song.key] = load
        await load.value
    }

    /// The pick replaces every online layer and asks the other sources after it; the list stays for picking again.
    func choose(_ song: OnlineSong, for picker: MatchPicker) async {
        guard let job = job(picker.row, songID: nil) else { return }
        dequeue(job.fingerprint)
        applying.insert(job.fingerprint)
        let replace = picker.selection == song.key ? picker.replace : []
        // Lyrics already loaded for the preview aren't fetched again.
        let overrides = PickOverrides(fields: replace, lyrics: replace.contains(.lyrics) ? picker.lyrics[song.key].flatMap { $0.isEmpty ? nil : $0 } : nil)
        do { _ = try await service.apply(song, to: job, candidates: picker.results, overrides: overrides) } catch { notice = "补全失败：\(error)" }
        await reloadMatch(job.fingerprint)
        await library.refresh()
        applying.remove(job.fingerprint)
    }
}
