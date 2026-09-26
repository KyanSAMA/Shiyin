import AppKit
import Observation
import LocalMusicCore

/// A file in the NetEase download folder: an .ncm (read from its header) or a FLAC / MP3 (from its tags).
struct ImportSource: Identifiable, Sendable {
    let url: URL
    let isNCM: Bool
    let format: String
    let title: String
    let artists: [String]
    let album: String
    let trackNo: Int?
    /// What tells the library already has it: the NetEase id (an .ncm, or a file's 163 key), the audio (a FLAC / MP3).
    let musicId: Int64?
    let fingerprint: String?
    /// When listed; a changed file is read again.
    let size: Int
    let modified: Date
    var id: String { url.path }
}

enum ImportState: Equatable {
    case queued, working
    /// Where it went, and what didn't go as asked (the original not trashed).
    case done(URL, note: String?)
    case failed(String)
}

/// One migration's outcome, for 本次已处理.
struct ImportRecord: Identifiable {
    let id = UUID()
    let source: ImportSource
    let state: ImportState
}

/// 迁移: the chosen files, where they go and how they're named. Choices become the next defaults.
@Observable final class ImportPlan {
    let sources: [ImportSource]
    /// nil: the first music folder.
    var target: URL?
    var naming: ImportNaming
    var fill: Bool
    var trashOriginals: Bool

    init(sources: [ImportSource], settings: ImportSettings) {
        self.sources = sources
        (target, naming, fill, trashOriginals) = (settings.target.map { URL(filePath: $0) }, settings.naming, settings.fill, settings.trashOriginals)
    }
}

/// 网易云导入: lists the NetEase download folder, and migrates chosen files one after another — decrypted (or copied),
/// completed from NetEase when asked, tagged, placed under a new name in the target folder, the originals trashed when
/// asked. Nothing existing is overwritten.
@Observable final class ImportModel {
    private(set) var settings = ImportSettings.default
    private(set) var sources: [ImportSource] = []
    private(set) var listing = false
    private(set) var states: [String: ImportState] = [:]
    private(set) var running = false
    private(set) var processed: [ImportRecord] = []
    var selection: Set<String> = []
    /// What the library has, for 已在曲库.
    private(set) var libraryIDs: Set<Int64> = []
    private(set) var libraryFingerprints: Set<String> = []
    @ObservationIgnored private var queue: [(ImportSource, ImportPlan)] = []
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var run: Task<Void, Never>?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var cache: [String: ImportSource] = [:]
    @ObservationIgnored private var watcher: (folder: String, events: FSEventsWatcher, task: Task<Void, Never>)?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private let enrich: EnrichModel?
    @ObservationIgnored private let options: LaunchOptions

    init(library: LibraryModel, enrich: EnrichModel?, options: LaunchOptions) {
        (self.library, self.enrich, self.options) = (library, enrich, options)
        loading = Task {
            if let saved = try? await library.store.setting(ImportSettings.key, as: ImportSettings.self) { settings = saved }
        }
    }

    /// Settings loaded (self-tests).
    func ready() async { await loading?.value }

    /// The queue run to its end (self-tests).
    func finish() async { await run?.value }

    /// The page opened: list the folder and keep watching it.
    func activate() {
        guard !active else { return }
        active = true
        Task {
            await ready()
            await refresh()
        }
    }

    var sourceFolder: URL { URL(filePath: settings.neteaseFolder) }
    var firstFolder: URL? { library.roots.include.first.map { URL(filePath: $0) } }

    func inLibrary(_ source: ImportSource) -> Bool {
        source.musicId.map(libraryIDs.contains) ?? false || source.fingerprint.map(libraryFingerprints.contains) ?? false
    }

    /// Not in the library and not migrated (or failed) this session: what 全部迁移 takes.
    func isFresh(_ source: ImportSource) -> Bool {
        guard !inLibrary(source) else { return false }
        switch states[source.id] {
        case nil, .failed?: return true
        default: return false
        }
    }

    func isPending(_ source: ImportSource) -> Bool {
        switch states[source.id] {
        case .queued?, .working?: true
        default: false
        }
    }

    /// Files queued or being migrated.
    var remaining: Int { states.values.count { if case .queued = $0 { true } else { $0 == .working } } }

    @discardableResult func setSettings(_ settings: ImportSettings) -> Task<Void, Never> {
        let moved = settings.neteaseFolder != self.settings.neteaseFolder
        self.settings = settings
        return Task {
            try? await library.store.setSetting(ImportSettings.key, settings)
            if moved, active { await refresh() }
        }
    }

    /// The library's NetEase ids and audio fingerprints (after each reload).
    func libraryChanged() async {
        let keys = (try? await library.store.neteaseKeys()) ?? [:]
        libraryIDs = Set(keys.values)
        libraryFingerprints = Set(library.index.songs.compactMap(\.fingerprint))
    }

    /// Reads the folder (not `meta/`, not hidden files; unchanged files from the last listing), and watches it. A
    /// listing overtaken by a newer one, or for a folder no longer set, is dropped.
    func refresh() async {
        active = true
        let folder = sourceFolder
        if let root = selfTestRoot, !within(folder.path, root) { return }
        generation += 1
        let mine = generation
        listing = true
        defer { if mine == generation { listing = false } }
        await libraryChanged()
        let cache = cache
        let listed = await Task.detached { await Self.list(folder, cache: cache) }.value
        guard mine == generation, folder == sourceFolder else { return }
        sources = listed
        self.cache = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        watch()
    }

    private nonisolated static func list(_ folder: URL, cache: [String: ImportSource]) async -> [ImportSource] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let depth = folder.pathComponents.count
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])?
            .compactMap { $0 as? URL }.filter { !$0.pathComponents.dropFirst(depth).dropLast().contains("meta") } ?? []
        var sources: [ImportSource] = []
        for url in files.sorted(by: { $0.path < $1.path }) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let size = values.fileSize, let modified = values.contentModificationDate else { continue }
            if let known = cache[url.path], known.size == size, known.modified == modified {
                sources.append(known)
                continue
            }
            switch url.pathExtension.lowercased() {
            case "ncm":
                guard let file = try? NCMFile(url), let format = try? file.audioFormat() else { continue }
                let meta = file.meta
                sources.append(ImportSource(url: url, isNCM: true, format: format, title: meta?.title ?? url.deletingPathExtension().lastPathComponent,
                                            artists: meta?.artists ?? [], album: meta?.album ?? "", trackNo: nil,
                                            musicId: meta?.musicId, fingerprint: nil, size: size, modified: modified))
            case let format where ["flac", "mp3"].contains(format):
                guard let raw = try? await TagReader.read(url) else { continue }
                let meta = TrackMetadata(tags: raw.tags, fileURL: url)
                sources.append(ImportSource(url: url, isNCM: false, format: format, title: meta.title, artists: meta.names(.artist),
                                            album: meta.album ?? "", trackNo: meta.trackNo, musicId: meta.ncmKey.flatMap(NCMKey.songID),
                                            fingerprint: raw.fingerprint, size: size, modified: modified))
            default: continue
            }
        }
        return sources
    }

    /// Refreshes a moment after the folder changes (a download or a migration touches it many times).
    private func watch() {
        let folder = settings.neteaseFolder
        guard watcher?.folder != folder else { return }
        watcher?.task.cancel()
        let events = FSEventsWatcher(paths: [folder])
        watcher = (folder, events, Task { [weak self] in
            for await _ in events.events {
                self?.debounce?.cancel()
                self?.debounce = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(700))
                    if !Task.isCancelled { await self?.refresh() }
                }
            }
        })
    }

    func plan(_ sources: [ImportSource]) -> ImportPlan { ImportPlan(sources: sources, settings: settings) }

    /// Queues the plan's files (remembering its choices; ones already migrated this session are skipped); runs the
    /// queue if idle.
    func start(_ plan: ImportPlan) {
        var next = settings
        (next.target, next.naming, next.fill, next.trashOriginals) = (plan.target?.path, plan.naming, plan.fill, plan.trashOriginals)
        setSettings(next)
        for source in plan.sources {
            switch states[source.id] {
            case .queued?, .working?, .done?: continue
            default: break
            }
            states[source.id] = .queued
            queue.append((source, plan))
        }
        guard !running else { return }
        running = true
        run = Task {
            var swept: Set<URL> = []
            while !queue.isEmpty {
                let (source, plan) = queue.removeFirst()
                states[source.id] = .working
                if let target = plan.target ?? firstFolder, allowed(source, target), swept.insert(target).inserted {
                    await Task.detached { Importer.sweepStaging(in: target) }.value
                }
                let state = await migrate(source, plan)
                states[source.id] = state
                processed.append(ImportRecord(source: source, state: state))
            }
            running = false
            if library.started { await library.scan() }
            await refresh()
        }
    }

    func stop() {
        for (source, _) in queue { states[source.id] = nil }
        queue.removeAll()
    }

    private func migrate(_ source: ImportSource, _ plan: ImportPlan) async -> ImportState {
        guard let target = plan.target ?? firstFolder else { return .failed("没有导入目录：请先在设置里添加音乐文件夹") }
        guard allowed(source, target) else { return .failed("自测只能在自测目录里导入") }
        let staged = Importer.staging(in: target, ext: source.format)
        defer { try? FileManager.default.removeItem(at: staged) }
        let placed: URL
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let edit: TagEdit
            if source.isNCM {
                // Read again: the file may have changed since it was listed.
                let ncm = try await Task.detached {
                    let ncm = try NCMFile(source.url)
                    try ncm.decrypt(to: staged)
                    return ncm
                }.value
                edit = await ncmEdit(ncm, fill: plan.fill)
            } else {
                try await Task.detached { try Importer.stage(copyOf: source.url, to: staged) }.value
                edit = plan.fill ? await fillEdit(source) : TagEdit()
            }
            let names = plan.naming.candidates(title: edit.title ?? source.title, artists: edit.artists ?? source.artists,
                                               album: edit.album ?? source.album, trackNo: edit.trackNo ?? source.trackNo, ext: source.format)
            placed = try await Importer.place(staged, edit: edit, in: target, candidates: names)
        } catch {
            return .failed((error as? TagWriteError)?.description ?? error.localizedDescription)
        }
        guard plan.trashOriginals else { return .done(placed, note: nil) }
        // A FLAC / MP3 inside a music folder is a library track: trashing it would drop its likes and playlists.
        if !source.isNCM, library.roots.include.contains(where: { within(source.url.path, canonicalPath($0)) }) {
            return .done(placed, note: "原文件在音乐文件夹里，没有移到废纸篓")
        }
        do {
            try await trash(original: source.url)
            return .done(placed, note: nil)
        } catch {
            return .done(placed, note: "原文件没能移到废纸篓：\(error.localizedDescription)")
        }
    }

    /// The .ncm's own metadata, then NetEase's detail, lyrics and cover when asked (else the sidecar .lrc); a failed
    /// request just leaves those out.
    private func ncmEdit(_ ncm: NCMFile, fill: Bool) async -> TagEdit {
        var song: OnlineSong?, lyrics: String?, cover = ncm.cover
        if fill, let id = ncm.meta?.musicId, let service = enrich?.service {
            song = (try? await service.neteaseSong(id)) ?? nil
            if let song {
                lyrics = (try? await service.lyrics(song)) ?? nil
                if cover == nil { cover = (try? await service.cover(song)) ?? nil }
            }
        }
        let sidecar = ncm.url.deletingPathExtension().appendingPathExtension("lrc")
        if lyrics == nil, let text = try? String(contentsOf: sidecar, encoding: .utf8) { lyrics = NCMFile.lyrics(fromSidecar: text) }
        return Importer.ncmEdit(ncm.meta, song: song, lyrics: lyrics, cover: cover)
    }

    /// A FLAC / MP3 keeps its tags; NetEase fills what it lacks (by its 163 key, else a confident search match).
    private func fillEdit(_ source: ImportSource) async -> TagEdit {
        guard let service = enrich?.service, let raw = try? await TagReader.read(source.url) else { return TagEdit() }
        let meta = TrackMetadata(tags: raw.tags, fileURL: source.url)
        var song: OnlineSong?
        if let id = source.musicId { song = (try? await service.neteaseSong(id)) ?? nil }
        if song == nil {
            let query = MatchQuery(title: meta.title, artists: meta.names(.artist), album: meta.album, duration: raw.properties.duration)
            let found = (try? await service.search(.netease, query.keywords, storefront: "")) ?? []
            if case .confident(let match, _) = Matcher.match(query, candidates: found) { song = match }
        }
        guard let song else { return TagEdit() }
        var edit = TagEdit()
        if meta.album == nil, !song.album.isEmpty { edit.album = song.album }
        if meta.trackNo == nil { edit.trackNo = song.trackNo }
        if meta.discNo == nil { edit.discNo = song.discNo }
        if meta.year == nil { edit.year = song.year }
        if meta.lyrics == nil, let lyrics = (try? await service.lyrics(song)) ?? nil {
            edit.lyrics = lyrics
            if meta.names(.composer).isEmpty { edit.composers = LRCParser.parse(lyrics)?.credits.composers }
        }
        if raw.cover == nil, let data = (try? await service.cover(song)) ?? nil { edit.cover = try? TagEdit.Cover(data) }
        return edit
    }

    /// The original, and its .lrc unless another file of that name (an .ncm beside a FLAC) still needs it. Self-tests
    /// keep their "trash" in their own folder.
    private func trash(original url: URL) async throws {
        let stem = url.deletingPathExtension()
        let others = ["ncm", "flac", "mp3"].map { stem.appendingPathExtension($0) }.filter { $0 != url }
        let bin = selfTestRoot.map { URL(filePath: $0).appending(path: "Trash") }
        try await Task.detached {
            let fm = FileManager.default
            var files = [url]
            if !others.contains(where: { fm.fileExists(atPath: $0.path) }) { files.append(stem.appendingPathExtension("lrc")) }
            for file in files where fm.fileExists(atPath: file.path) {
                guard let bin else {
                    try fm.trashItem(at: file, resultingItemURL: nil)
                    continue
                }
                try fm.createDirectory(at: bin, withIntermediateDirectories: true)
                let name = (1...99).lazy.map { $0 == 1 ? file.lastPathComponent : "\($0) " + file.lastPathComponent }
                    .first { !fm.fileExists(atPath: bin.appending(path: $0).path) } ?? UUID().uuidString
                try fm.moveItem(at: file, to: bin.appending(path: name))
            }
        }.value
    }

    /// Self-tests import only within their own folder.
    private func allowed(_ source: ImportSource, _ target: URL) -> Bool {
        guard let root = selfTestRoot else { return true }
        return within(source.url.path, root) && within(target.path, root)
    }

    /// The self-test's own folder (its data dir's parent).
    private var selfTestRoot: String? {
        options.isSelfTest ? options.dataDir.map { canonicalPath($0.deletingLastPathComponent().path) } : nil
    }

    private func within(_ path: String, _ root: String) -> Bool {
        let path = canonicalPath(path)
        return path == root || path.hasPrefix(root + "/")
    }
}
