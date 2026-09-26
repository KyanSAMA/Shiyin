import AppKit
import Observation
import LocalMusicCore

/// The 资料对照 sheet for one song: its fields as the edit sheet has them, beside the results each enabled source finds
/// for the keywords. Whatever is picked here becomes a manual edit.
@Observable final class SourceCompare {
    enum Cover {
        case song(OnlineSong)
        case file(URL, NSImage?)
        /// Drops the manual cover.
        case removed
    }

    enum Lyrics {
        case song(OnlineSong)
        case text(String)
        /// Drops the manual lyrics.
        case removed
    }

    let row: TrackRow
    let editor: InfoEditor
    /// The enabled sources when the sheet opened, in order.
    let sources: [OnlineSource]
    var keywords: String
    var results: [OnlineSource: [OnlineSong]] = [:]
    var failures: [OnlineSource: String] = [:]
    /// The result shown per source, by index.
    var picked: [OnlineSource: Int] = [:]
    var searching: Bool
    /// Per result (`OnlineSong.key`), once loaded: its lyrics ("" when none), and a NetEase release year from the song's
    /// detail. Loads outlive the view that started them, so switching results doesn't cancel one halfway.
    var lyrics: [String: String] = [:]
    var years: [String: Int] = [:]
    @ObservationIgnored var details: [String: Task<Void, Never>] = [:]
    /// Something online was taken, which settles a song awaiting a choice.
    var tookOnline = false
    var cover: Cover?
    var lyricsChoice: Lyrics?
    /// Whose lyrics are shown in full.
    var previewing: OnlineSong?
    @ObservationIgnored var search: Task<Void, Never>?

    init(row: TrackRow, editor: InfoEditor, sources: [OnlineSource]) {
        (self.row, self.editor, self.sources) = (row, editor, sources)
        searching = !sources.isEmpty
        keywords = MatchQuery(title: row.title, artists: row.artists, album: row.album, duration: row.duration).keywords
    }

    func song(_ source: OnlineSource) -> OnlineSong? {
        let index = picked[source] ?? 0
        return results[source].flatMap { $0.indices.contains(index) ? $0[index] : nil }
    }

    /// What a result offers for a field.
    func value(_ field: EnrichField, of song: OnlineSong) -> String? {
        let text: String? = switch field {
        case .title: song.title
        case .artists: song.artists.joined(separator: " / ")
        case .album: song.album
        case .trackNo: song.trackNo.map(String.init)
        case .discNo: song.discNo.map(String.init)
        case .year: (song.year ?? years[song.key]).map(String.init)
        case .genre: song.genre
        case .composers: lyrics[song.key].flatMap { LRCParser.parse($0)?.credits.composers }?.joined(separator: " / ")
        case .albumArtist, .lyrics, .cover: nil
        }
        return text?.isEmpty == false ? text : nil
    }

    /// What the field shows once saved.
    func current(_ field: EnrichField) -> String {
        let typed = editor.texts[field, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? editor.shown(field) : typed
    }

    func take(_ value: String, for field: EnrichField) {
        editor.texts[field] = value
        tookOnline = true
    }

    /// Everything the result has that differs from what shows, plus its cover and lyrics (load its details first).
    func adopt(_ song: OnlineSong) {
        for field in editor.fields {
            if let value = value(field, of: song), value != current(field) { take(value, for: field) }
        }
        if song.coverURL != nil { cover = .song(song) }
        if lyrics[song.key]?.isEmpty == false { lyricsChoice = .song(song) }
        tookOnline = true
    }
}

extension OnlineSong {
    var key: String { source.rawValue + ":" + id }
}

extension AppModel {
    /// One song opens the 资料对照 sheet (searching right away); several, the batch edit sheet. Songs without a
    /// fingerprint (unreadable audio) can't carry edits.
    func editInfo(_ rows: [TrackRow]) async {
        let rows = rows.filter { $0.fingerprint != nil }
        guard let library, let first = rows.first?.fingerprint else { return }
        guard rows.count == 1, let enrich else {
            ui.infoEditor = InfoEditor(tracks: rows, edits: [:], unedited: [])
            return
        }
        let editor = InfoEditor(tracks: rows, edits: await library.userEdits(first), unedited: await library.uneditedRows([rows[0].id]))
        let compare = SourceCompare(row: rows[0], editor: editor, sources: enrich.settings.enabled)
        ui.compare = compare
        enrich.startSearch(compare)
    }
}

extension EnrichModel {
    /// Replaces a search still running.
    func startSearch(_ compare: SourceCompare) {
        compare.search?.cancel()
        compare.search = Task { await search(compare) }
    }

    /// Every source at once (each paced on its own); each shows its best match for the song first.
    func search(_ compare: SourceCompare) async {
        compare.searching = true
        compare.results = [:]
        compare.failures = [:]
        let query = MatchQuery(title: compare.row.title, artists: compare.row.artists, album: compare.row.album, duration: compare.row.duration)
        await withTaskGroup(of: (OnlineSource, [OnlineSong]?, String?).self) { group in
            for source in compare.sources {
                group.addTask { [service, keywords = compare.keywords, storefront = settings.storefront] in
                    do { return (source, try await service.search(source, keywords, storefront: storefront), nil) } catch {
                        return (source, nil, String(describing: error))
                    }
                }
            }
            for await (source, songs, failure) in group where !Task.isCancelled {
                compare.results[source] = songs ?? []
                compare.failures[source] = failure
                let best: OnlineSong? = switch Matcher.match(query, candidates: songs ?? []) {
                case .confident(let song, _): song
                case .uncertain(let songs): songs.first
                case .none: nil
                }
                compare.picked[source] = best.flatMap { best in songs?.firstIndex { $0.key == best.key } } ?? 0
            }
        }
        if !Task.isCancelled { compare.searching = false }
    }

    /// A result's lyrics, and a NetEase year search results lacked; one load per result, which every caller awaits.
    func loadDetails(_ song: OnlineSong, for compare: SourceCompare) async {
        let load = compare.details[song.key] ?? Task { [service] in
            if song.year == nil, song.source == .netease, let year = try? await service.neteaseYear(song) { compare.years[song.key] = year }
            compare.lyrics[song.key] = (try? await service.lyrics(song)) ?? ""
        }
        compare.details[song.key] = load
        await load.value
    }

    /// Text fields, cover and lyrics become manual edits; a song awaiting a choice counts as settled once something
    /// online was taken (and leaves the queue, so a lookup still waiting doesn't reopen it).
    func save(_ compare: SourceCompare) async {
        guard let fingerprint = compare.row.fingerprint else { return }
        var changes = compare.editor.changes
        let previousCover = await library.userEdits(fingerprint)[.cover]
        do {
            switch compare.cover {
            case .song(let song)?: if let name = try await service.saveCover(.song(song), fingerprint: fingerprint) { changes[.cover] = name }
            case .file(let url, _)?: if let name = try await service.saveCover(.file(url), fingerprint: fingerprint) { changes[.cover] = name }
            case .removed?: changes[.cover] = .some(nil)
            case nil: break
            }
        } catch {
            notice = "保存封面失败：\(error)"
        }
        do {
            switch compare.lyricsChoice {
            case .song(let song)?:
                var text = compare.lyrics[song.key].flatMap { $0.isEmpty ? nil : $0 }
                if text == nil { text = try await service.lyrics(song) }
                if let text { changes[.lyrics] = text }
            case .text(let text)?: changes[.lyrics] = text
            case .removed?: changes[.lyrics] = .some(nil)
            case nil: break
            }
        } catch {
            notice = "保存歌词失败：\(error)"
        }
        await library.setUserEdits([fingerprint], changes)
        // Whichever cover file the stored edit no longer names goes.
        if let replaced = changes[.cover] {
            let stored = await library.userEdits(fingerprint)[.cover]
            for name in [previousCover, replaced].compactMap({ $0 }) where name != stored {
                try? FileManager.default.removeItem(at: store.coversDirectory.appending(path: name))
            }
        }
        if compare.tookOnline, match(compare.row)?.status == .pending {
            dequeue(fingerprint)
            try? await store.setMatch(fingerprint, .confirmed)
            await reloadMatch(fingerprint)
        }
    }
}
