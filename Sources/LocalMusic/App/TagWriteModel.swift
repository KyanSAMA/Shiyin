import Foundation
import Observation
import LocalMusicCore

/// 写入文件 / 恢复原标签 for chosen songs: what would change in each file, then the run, one file after another.
@Observable final class TagWritePlan {
    enum Mode { case write, restore }

    struct Change: Identifiable {
        let field: EnrichField
        let old: String
        let new: String
        /// A manual edit (or a replaced value) rather than an online source's gap fill.
        let manual: Bool
        var id: EnrichField { field }
    }

    struct Item: Identifiable {
        let row: TrackRow
        var changes: [Change] = []
        /// Why nothing will be written.
        var skip: String?
        var note: String?
        var id: Int64 { row.id }
    }

    let mode: Mode
    let items: [Item]
    var includeManual = true
    var includeOnline = true
    /// Set when the run starts: the choices are fixed and the sheet stays until it ends.
    private(set) var started = false
    private(set) var done = 0
    private(set) var failures: [(title: String, reason: String)] = []
    private(set) var finished = false
    @ObservationIgnored var run: Task<Void, Never>?

    init(mode: Mode, items: [Item]) { (self.mode, self.items) = (mode, items) }

    func changes(_ item: Item) -> [Change] {
        item.skip != nil ? [] : item.changes.filter { $0.manual ? includeManual : includeOnline }
    }

    var files: [Item] { items.filter { mode == .restore ? $0.skip == nil : !changes($0).isEmpty } }

    fileprivate func start() { started = true }

    fileprivate func progressed(failure: (String, String)?) {
        done += 1
        if let failure { failures.append(failure) }
    }

    fileprivate func finish() { finished = true }
}

extension AppModel {
    /// What writing would change: the shown values where they differ from the file's own (values only guessed from
    /// the file name or lyrics credits aren't written), lyrics and a cover the file lacks or that were set by hand
    /// (unless the file already has them). Rows are read fresh.
    func planTagWrite(_ rows: [TrackRow]) async {
        guard let library else { return }
        let ids = rows.filter { $0.fingerprint != nil }.map(\.id)
        let shown = await library.rows(ids, without: []), own = await library.rows(ids, without: [.user] + EnrichSource.allOnline)
        let files = Dictionary(uniqueKeysWithValues: own.map { ($0.id, $0) })
        var items: [TagWritePlan.Item] = []
        for row in shown {
            var item = TagWritePlan.Item(row: row)
            guard ["flac", "mp3"].contains(row.url.pathExtension.lowercased()) else {
                item.skip = "暂不支持写入 \(row.url.pathExtension.uppercased()) 文件"
                items.append(item)
                continue
            }
            guard let file = files[row.id], let fingerprint = row.fingerprint else { continue }
            let edits = await library.userEdits(fingerprint)
            for field in [EnrichField.title, .artists, .album, .albumArtist, .trackNo, .discNo, .year, .genre, .composers]
            where !row.inferred.contains(field) {
                let value = row.shown(field), fileValue = file.inferred.contains(field) ? "" : file.shown(field)
                if !value.isEmpty, value != fileValue { item.changes.append(.init(field: field, old: fileValue, new: value, manual: edits[field] != nil)) }
            }
            if let lyrics = await library.enrichedLyrics(fingerprint), lyrics.manual || !row.hasFileLyrics,
               await library.embeddedLyrics(row.id) != lyrics.text.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) {
                let lines = lyrics.text.split(whereSeparator: \.isNewline).count
                item.changes.append(.init(field: .lyrics, old: row.hasFileLyrics ? "有歌词" : "", new: "\(lines) 行", manual: lyrics.manual))
                if lyrics.manual, FileManager.default.fileExists(atPath: row.url.deletingPathExtension().appendingPathExtension("lrc").path) {
                    item.note = "有同名 .lrc：写进文件的歌词不会显示，App 里仍用手动设置的"
                }
            }
            if let cover = row.coverFile, row.userCover || !row.hasCover && !ArtworkCache.hasFolderImage(near: row),
               await embeddedCover(row) != (try? Data(contentsOf: URL(filePath: cover))) {
                item.changes.append(.init(field: .cover, old: row.hasCover ? "有封面" : "", new: row.userCover ? "手动设置的封面" : "补全的封面",
                                          manual: row.userCover))
            }
            if item.changes.isEmpty { item.skip = "文件里的信息已经和显示的一致" }
            items.append(item)
        }
        ui.sheet = .write(TagWritePlan(mode: .write, items: items))
    }

    private func embeddedCover(_ row: TrackRow) async -> Data? {
        guard row.hasCover, let offset = row.coverOffset, let length = row.coverLength else { return nil }
        return try? await TagReader.coverData(row.url, CoverRef(offset: offset, length: length, mime: nil, pictureType: 3))
    }

    func planTagRestore(_ rows: [TrackRow]) {
        let items = rows.map { row in
            var item = TagWritePlan.Item(row: row)
            if library?.backedUp.contains(row.path) != true { item.skip = "没有写入过，不需要恢复" }
            return item
        }
        ui.sheet = .write(TagWritePlan(mode: .restore, items: items))
    }

    /// One file after another, with the choices as they were at the start; stopping lets the current file finish.
    /// Self-tests may only touch their own copies.
    func runTagPlan(_ plan: TagWritePlan) {
        guard let library, !plan.started else { return }
        plan.start()
        // The self-test's own folder (its data dir's parent), shared by a relaunch.
        let allowed = options.isSelfTest ? options.dataDir?.deletingLastPathComponent().resolvingSymlinksInPath().path : nil
        let work = plan.files.map { ($0, plan.changes($0)) }
        plan.run = Task {
            for (item, changes) in work where !Task.isCancelled {
                let failure: String?
                if let allowed, !item.row.url.resolvingSymlinksInPath().path.hasPrefix(allowed + "/") {
                    failure = "自测只能写入自测目录里的副本"
                } else {
                    failure = plan.mode == .write ? await write(item, changes, library: library) : await restore(item, library: library)
                }
                plan.progressed(failure: failure.map { (item.row.title, $0) })
            }
            await library.scan()
            await library.refresh()
            plan.finish()
        }
    }

    private func write(_ item: TagWritePlan.Item, _ changes: [TagWritePlan.Change], library: LibraryModel) async -> String? {
        guard let fingerprint = item.row.fingerprint, let row = await library.rows([item.row.id], without: []).first else { return "歌曲已不在曲库里" }
        let edits = await library.userEdits(fingerprint)
        var edit = TagEdit()
        for change in changes {
            switch change.field {
            case .title: edit.title = row.title
            case .artists: edit.artists = row.artists
            case .album: edit.album = row.album
            case .albumArtist: edit.albumArtist = row.albumArtist
            case .trackNo: edit.trackNo = row.trackNo
            case .discNo: edit.discNo = row.discNo
            case .year: edit.year = row.year
            case .genre: edit.genre = row.genre
            case .composers: edit.composers = row.composers
            case .lyrics: edit.lyrics = await library.enrichedLyrics(fingerprint)?.text
            case .cover:
                do { edit.cover = try row.coverFile.map { try TagEdit.Cover(Data(contentsOf: URL(filePath: $0))) } } catch { return String(describing: error) }
            }
        }
        let prepared: TagWriter.Prepared, begun: (id: Int64, existed: Bool), version: FileVersion
        do {
            // Reads and hashes the whole audio: off the main actor.
            let url = row.url
            prepared = try await Task.detached { [edit] in try TagWriter.prepare(edit, for: url) }.value
            begun = try await library.store.beginTagWrite(path: row.path, original: prepared.original)
        } catch {
            return "文件未改动：\(error)"
        }
        do {
            version = try await Task.detached { try await TagWriter.commit(prepared) }.value
        } catch {
            try? await library.store.abandonTagWrite(id: begun.id, existed: begun.existed)
            return "文件未改动：\(error)"
        }
        // Written. Manual edits now in the file leave the manual layer (kept for restoring) if they're still what was
        // written — unless another copy of the recording still shows them, or a sidecar .lrc would hide the lyrics.
        do {
            let shared = library.index.songs.contains { $0.fingerprint == fingerprint && $0.id != row.id }
            let current = await library.userEdits(fingerprint)
            let moved = shared ? [:] : edits.filter { field, value in
                current[field] == value && changes.contains { $0.field == field && $0.manual } && !(field == .lyrics && item.note != nil)
            }
            try await library.store.finishTagWrite(id: begun.id, written: version, moved: moved)
            try await library.store.restampLoudness(trackID: row.id, from: prepared.original.version, to: version)
            if !moved.isEmpty { try await library.store.setEnrichment([fingerprint], moved.mapValues { _ -> String? in nil }, source: .user) }
            return nil
        } catch {
            return "已写入，但记录时出错（仍可恢复原标签）：\(error)"
        }
    }

    /// Moved edits come back where the user hasn't set something newer; a moved cover that doesn't loses its file.
    private func restore(_ item: TagWritePlan.Item, library: LibraryModel) async -> String? {
        let url = item.row.url
        do {
            guard let backup = try await library.store.tagBackup(path: item.row.path) else { return "没有备份" }
            let before = try FileVersion(url)
            try await library.store.beginTagRestore(id: backup.id)
            let version: FileVersion
            do {
                let original = backup.original
                version = try await Task.detached { try await TagWriter.restore(url, to: original) }.value
            } catch {
                try? await library.store.abandonTagWrite(id: backup.id, existed: true)
                return "文件未改动：\(error)"
            }
            if let fingerprint = item.row.fingerprint, !backup.moved.isEmpty {
                let current = await library.userEdits(fingerprint)
                let back = backup.moved.filter { current[$0.key] == nil }
                if let cover = backup.moved[.cover], back[.cover] == nil {
                    try? FileManager.default.removeItem(at: library.store.coversDirectory.appending(path: cover))
                }
                try await library.store.setEnrichment([fingerprint], back.mapValues(Optional.some), source: .user)
            }
            try await library.store.removeTagBackup(id: backup.id)
            try await library.store.restampLoudness(trackID: item.row.id, from: before, to: version)
            return nil
        } catch {
            return String(describing: error)
        }
    }
}
