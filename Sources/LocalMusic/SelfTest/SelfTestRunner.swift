import AppKit
import LocalMusicCore
import MediaPlayer

struct SelfTestFailure: Error, CustomStringConvertible {
    let description: String
}

typealias Step = [String: Any]

private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func number(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
    func required(_ key: String) throws -> String {
        guard let value = string(key) else { throw SelfTestFailure(description: "missing \"\(key)\"") }
        return value
    }
}

/// Runs a JSON script of UI/player actions, writing PNG snapshots, state dumps and `report.json` to `--out`.
final class SelfTestRunner {
    private let model: AppModel
    private let scriptURL: URL
    private let out: URL
    private let stalls = StallMonitor()
    private let watchdog = Watchdog()
    private let started = Date()
    private var snapshots: [String: Any] = [:]
    private var measures: [String: Any] = [:]
    private var inspected: [String: Any] = [:]
    private var fileTags: [String: Any] = [:]
    private var fileCounter = 0

    init(model: AppModel) {
        self.model = model
        scriptURL = model.options.selfTestScript!
        out = model.options.outDir!
    }

    private var reportURL: URL { out.appending(path: "report.json") }

    func run() async -> Int32 {
        stalls.start()
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            guard let script = try JSONSerialization.jsonObject(with: Data(contentsOf: scriptURL)) as? Step else {
                throw SelfTestFailure(description: "script root must be an object")
            }
            guard let steps = script["steps"] as? [Step], !steps.isEmpty else {
                throw SelfTestFailure(description: "\"steps\" must be a non-empty array of objects")
            }
            watchdog.arm(after: script.number("timeout") ?? 120, onTimeout: Self.timeoutHandler(report: reportURL))
            model.ui.animationsEnabled = false
            try await prepareWindow(script)
            for (i, step) in steps.enumerated() {
                let action = step.string("do") ?? "?"
                watchdog.mark("step \(i) \(action)")
                do {
                    try await perform(action, step)
                } catch {
                    throw SelfTestFailure(description: "step \(i) \(action): \(error)")
                }
            }
            finish(status: "pass", error: nil)
            return 0
        } catch {
            finish(status: "fail", error: String(describing: error))
            return 1
        }
    }

    // MARK: Actions

    private func perform(_ action: String, _ step: Step) async throws {
        switch action {
        case "wait":
            try await Task.sleep(for: .seconds(step.number("seconds") ?? 0.5))
        case "settle":
            try await settle()
        case "window":
            try window().setContentSize(NSSize(width: step.number("width") ?? 1280, height: step.number("height") ?? 800))
            try await settle()
        case "appearance":
            NSApp.appearance = NSAppearance(named: try step.required("value") == "dark" ? .darkAqua : .aqua)
            try await settle()
        case "sidebar":
            let value = try step.required("value")
            if value == "playlist" {
                model.ui.sidebar = .playlist(try playlist(step.required("name")).id)
            } else {
                guard let item = SidebarItem(name: value) else { throw SelfTestFailure(description: "unknown sidebar \(value)") }
                model.ui.sidebar = item
            }
            model.ui.path = []
            try await settle()
        case "hideSidebar":
            model.ui.hiddenSidebar = Set(try (step["values"] as? [String] ?? []).map {
                guard let item = SidebarItem(name: $0) else { throw SelfTestFailure(description: "unknown sidebar \($0)") }
                return item
            })
            try await settle()
        case "search":
            model.ui.search = step.string("value") ?? ""
            try await settle()
        case "filter":
            if let unknown = step.keys.first(where: { !["do", "albumArtists", "years", "genres", "formats", "hiRes", "hasLyrics"].contains($0) }) {
                throw SelfTestFailure(description: "unknown filter key \(unknown)")
            }
            func typed<T>(_ key: String) throws -> T? {
                guard let raw = step[key] else { return nil }
                guard let value = raw as? T else { throw SelfTestFailure(description: "bad \(key): \(raw)") }
                return value
            }
            var filter = TrackFilter()
            filter.albumArtists = Set(try typed("albumArtists") ?? [String]())
            filter.years = Set(try typed("years") ?? [Int]())
            filter.genres = Set(try typed("genres") ?? [String]())
            filter.formats = Set(try typed("formats") ?? [String]())
            filter.hiRes = try typed("hiRes")
            filter.hasLyrics = try typed("hasLyrics")
            model.ui.filter = filter
            try await settle()
        case "sort":
            model.ui.songSort = [try comparator(step.required("column"), ascending: step["ascending"] as? Bool ?? true)]
            try await settle()
        case "openAlbum":
            let title = try step.required("title")
            guard let album = try library().index.albums.first(where: { $0.title == title }) else {
                throw SelfTestFailure(description: "no album \(title)")
            }
            model.ui.path = [.album(album.id)]
            try await settle()
        case "openPerson":
            let name = try step.required("name"), role: PersonRole = step.string("role") == "composer" ? .composer : .artist
            guard let group = try library().index.people(role).first(where: { $0.name == name }) else {
                throw SelfTestFailure(description: "no \(role) \(name)")
            }
            model.ui.sidebar = role == .artist ? .artists : .composers
            model.ui.path = []
            model.ui.personSelection[role] = group.id
            try await settle()
        case "back":
            _ = model.ui.path.popLast()
            try await settle()
        case "scrollList":
            try await scrollList(steps: Int(step.number("steps") ?? 30), interval: step.number("interval") ?? 0.06)
        case "perfReset":
            stalls.reset()
        case "activate":
            NSApp.activate()
            try window().makeKeyAndOrderFront(nil)
            try await settle()
        case "snapshot":
            try await snapshot(try step.required("name"), window: try window(step.string("window") ?? "main"))
        case "startLibrary":
            let include = (step["include"] as? [String])?.map(resolve), exclude = (step["exclude"] as? [String])?.map(resolve)
            try await library().start(roots: include.map { LibraryRoots(include: $0, exclude: exclude ?? []) })
        case "rescan":
            try await library().scan()
        case "fs":
            try fileOperation(step)
        case "setImport":
            // `folder` (NetEase), `target` (a path, or "first"), `naming`, `fill`, `trash`; what's not given stays.
            let importer = try importModel()
            await importer.ready()
            var settings = importer.settings
            if let folder = step.string("folder") { settings.neteaseFolder = resolve(folder) }
            if let target = step.string("target") { settings.target = target == "first" ? nil : resolve(target) }
            if let naming = step.string("naming").flatMap(ImportNaming.init) { settings.naming = naming }
            if let fill = step["fill"] as? Bool { settings.fill = fill }
            if let trash = step["trash"] as? Bool { settings.trashOriginals = trash }
            await importer.setSettings(settings).value
            await importer.refresh()
            try await settle()
        case "makeNCM":
            // An .ncm at `to` (inside --out) around the audio file `from`, with `musicId` / `title` / `artists` / `album`,
            // an optional `cover` image file and sidecar `lrc` text.
            let from = URL(filePath: resolve(try step.required("from"))), to = URL(filePath: resolve(try step.required("to"))).standardizedFileURL
            guard canonicalPath(to.path).hasPrefix(canonicalPath(out.path) + "/") else {
                throw SelfTestFailure(description: "makeNCM path \(to.path) is outside --out")
            }
            var meta: Step = ["musicName": try step.required("title"), "album": step.string("album") ?? "", "format": from.pathExtension.lowercased(),
                              "artist": (step["artists"] as? [String] ?? []).map { [$0, 0] as [Any] }]
            if let id = step.number("musicId") { meta["musicId"] = Int64(id) }
            let json = String(decoding: try JSONSerialization.data(withJSONObject: meta), as: UTF8.self)
            let cover = try step.string("cover").map { try Data(contentsOf: URL(filePath: resolve($0))) }
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try NCMFile.encode(audio: Data(contentsOf: from), meta: "music:" + json, cover: cover).write(to: to)
            if let lrc = step.string("lrc") { try lrc.write(to: to.deletingPathExtension().appendingPathExtension("lrc"), atomically: true, encoding: .utf8) }
        case "importNetease":
            // Plans 迁移 for `titles` (else everything not in the library), with `target` / `naming` / `fill` / `trash` over
            // the defaults; unless `keepOpen`, starts it and waits for the queue.
            let importer = try importModel()
            await importer.ready()
            let titles = step["titles"] as? [String]
            let sources = importer.sources.filter { titles?.contains($0.title) ?? importer.isFresh($0) }
            let plan = importer.plan(sources)
            if let target = step.string("target") { plan.target = target == "first" ? nil : URL(filePath: resolve(target)) }
            if let naming = step.string("naming").flatMap(ImportNaming.init) { plan.naming = naming }
            if let fill = step["fill"] as? Bool { plan.fill = fill }
            if let trash = step["trash"] as? Bool { plan.trashOriginals = trash }
            model.ui.sheet = .importPlan(plan)
            try await settle()
            if step["keepOpen"] as? Bool != true {
                model.ui.sheet = nil
                importer.start(plan)
                await importer.finish()
                try await settle()
            }
        case "sirenAlbum":
            // Loads the catalogue and opens the album `name`.
            guard let siren = model.siren else { throw SelfTestFailure(description: "no siren") }
            await siren.load()
            let name = try step.required("name")
            guard let album = siren.albums.first(where: { $0.name == name }) else { throw SelfTestFailure(description: "no album \(name)") }
            siren.select(album.id)
            if siren.detail == nil { await siren.loadDetail(album.id) }
            try await settle()
        case "downloadSiren":
            // Plans 下载 for the open album's `titles` (else the songs not in the library), with `target` / `naming` over the
            // defaults; unless `keepOpen`, starts it and waits for the queue.
            guard let siren = model.siren, let detail = siren.detail else { throw SelfTestFailure(description: "no open album") }
            let titles = step["titles"] as? [String]
            let plan = siren.plan(detail.songs.filter { titles?.contains($0.name) ?? siren.owned($0).isEmpty }, in: detail)
            if let target = step.string("target") { plan.target = target == "first" ? nil : URL(filePath: resolve(target)) }
            if let naming = step.string("naming").flatMap(ImportNaming.init) { plan.naming = naming }
            model.ui.sheet = .sirenPlan(plan)
            try await settle()
            if step["keepOpen"] as? Bool != true {
                model.ui.sheet = nil
                siren.start(plan)
                await siren.finish()
                try await settle()
            }
        case "promptPlaylist":
            if let name = step.string("rename") { model.promptRenamePlaylist(try playlist(name)) } else { model.promptNewPlaylist(try trackIDs(step)) }
            try await settle()
        case "commitPlaylistPrompt":
            guard let prompt = model.ui.playlistPrompt else { throw SelfTestFailure(description: "no playlist prompt") }
            model.ui.playlistName = step.string("name") ?? model.ui.playlistName
            model.ui.playlistPrompt = nil
            model.commitPlaylistPrompt(prompt)
            try await settle()
        case "addToPlaylist":
            try library().addToPlaylist(try playlist(step.required("name")).id, try trackIDs(step))
            try await settle()
        case "removeFromPlaylist":
            try library().removeFromPlaylist(try playlist(step.required("name")).id, Set(try trackIDs(step)))
            try await settle()
        case "movePlaylistTracks":
            try library().movePlaylistTracks(try playlist(step.required("name")).id, Set(try trackIDs(step)), to: Int(step.number("to") ?? 0))
            try await settle()
        case "deletePlaylist":
            model.deletePlaylist(try playlist(step.required("name")).id)
            try await settle()
        case "editInfo":
            // Through the sheet: open it, fill `fields` (EnrichField names) and, for one song, `suggest` a source's value
            // for a field (or cover / lyrics); then save unless `keepOpen`.
            let index = try library().index
            await model.editInfo(try trackIDs(step).compactMap { index.tracks[$0] })
            guard let editor = model.ui.sheet?.editor else { throw SelfTestFailure(description: "no editor") }
            for (key, value) in step["fields"] as? [String: String] ?? [:] {
                guard let field = EnrichField(rawValue: key) else { throw SelfTestFailure(description: "unknown field \(key)") }
                editor.texts[field] = value
            }
            for (key, source) in step["suggest"] as? [String: String] ?? [:] {
                guard let field = EnrichField(rawValue: key), let value = editor.suggestions(field).first(where: { $0.source.rawValue == source })?.value else {
                    throw SelfTestFailure(description: "no \(source) value for \(key)")
                }
                switch field {
                case .cover: editor.cover = .image(URL(filePath: value), NSImage(contentsOfFile: value))
                case .lyrics: editor.lyrics = .text(value)
                default: editor.texts[field] = value
                }
            }
            if step["keepOpen"] as? Bool != true { await model.saveInfo(editor) }
            try await settle()
        case "chooseMatch":
            // Opens 选择匹配 and waits for a search it starts.
            await model.chooseMatch(try song(step.required("title")))
            await model.ui.sheet?.picker?.search?.value
            try await settle()
        case "searchMatch":
            let picker = try openPicker()
            picker.keywords = try step.required("keywords")
            model.enrich?.startSearch(picker)
            await picker.search?.value
            try await settle()
        case "selectMatch":
            // Selects the result with `key` and ticks `replace`, without adopting.
            let picker = try openPicker()
            picker.selection = try step.required("key")
            if let names = step["replace"] as? [String] { picker.replace = Set(names.compactMap(EnrichField.init(rawValue:))) }
            try await settle()
        case "adoptMatch":
            // The result at `index` or with `key`, as 采用 with `replace` (EnrichField names) ticked; waits until it's applied.
            let picker = try openPicker()
            let song = step.string("key").flatMap { key in picker.results.first { $0.key == key } }
                ?? step.number("index").flatMap { picker.results.indices.contains(Int($0)) ? picker.results[Int($0)] : nil }
            guard let song, let enrich = model.enrich else { throw SelfTestFailure(description: "no such result") }
            picker.selection = song.key
            picker.replace = Set((step["replace"] as? [String] ?? []).compactMap(EnrichField.init(rawValue:)))
            model.ui.sheet = nil
            await enrich.choose(song, for: picker)
            try await settle()
        case "chooseLyrics":
            // 选择歌词 from the open 选择匹配 or 编辑信息 sheet: waits for its search, selects `key` (or `keep`), then uses it
            // unless `keepOpen`.
            guard let enrich = model.enrich else { throw SelfTestFailure(description: "no enrichment") }
            let picker = model.ui.sheet?.picker, editor = model.ui.sheet?.editor
            if let picker, picker.lyricsChooser == nil { enrich.chooseLyrics(for: picker) }
            if let editor, editor.lyricsChooser == nil { model.chooseLyrics(for: editor) }
            guard let chooser = picker?.lyricsChooser ?? editor?.lyricsChooser else { throw SelfTestFailure(description: "no lyrics chooser") }
            await chooser.search?.value
            if step["keep"] as? Bool == true {
                chooser.selection = nil
            } else {
                let key = try step.required("key")
                guard let song = chooser.options.first(where: { $0.key == key }) else { throw SelfTestFailure(description: "no option \(key)") }
                chooser.selection = key
                await enrich.loadLyrics(song, for: chooser)
            }
            if step["keepOpen"] as? Bool != true {
                chooser.use()
                picker?.lyricsChooser = nil
                editor?.lyricsChooser = nil
            }
            try await settle()
        case "writeTags", "restoreTags":
            // Plans 写入文件 / 恢复原标签 for `titles` (unless a plan is open) and, unless `keepOpen`, runs it to the end;
            // `manual` / `online` pick the groups.
            let index = try library().index
            if model.ui.sheet?.plan == nil {
                let rows = try trackIDs(step).compactMap { index.tracks[$0] }
                if step.string("do") == "writeTags" { await model.planTagWrite(rows) } else { model.planTagRestore(rows) }
            }
            guard let plan = model.ui.sheet?.plan else { throw SelfTestFailure(description: "no write plan") }
            if let manual = step["manual"] as? Bool { plan.includeManual = manual }
            if let online = step["online"] as? Bool { plan.includeOnline = online }
            if step["keepOpen"] as? Bool != true {
                model.runTagPlan(plan)
                await plan.run?.value
            }
            try await settle()
        case "readFile":
            // A file's own tags and SHA-256, straight from disk (`title`, or `path`), into `fileTags.<as>`.
            let url = try step.string("path").map { URL(filePath: resolve($0)) } ?? song(step.required("title")).url
            let raw = try await TagReader.read(url)
            var tags: Step = ["sha": TagReader.sha256(try Data(contentsOf: url)), "hasCover": raw.cover != nil]
            for (key, values) in raw.tags.fields { tags[key] = values.count == 1 ? values[0] : values }
            fileTags[try step.string("as") ?? step.required("title")] = tags
        case "saveEditInfo":
            guard let editor = model.ui.sheet?.editor else { throw SelfTestFailure(description: "no edit sheet") }
            await model.saveInfo(editor)
            try await settle()
        case "closeEditInfo":
            model.ui.sheet = nil
            try await settle()
        case "revertInfo":
            let index = try library().index
            await model.revertInfo(try trackIDs(step).compactMap { index.tracks[$0] })
            try await settle()
        case "enrich":
            // `titles`, else everything still missing something (全部补全); waits for the queue.
            guard let enrich = model.enrich else { throw SelfTestFailure(description: "no enrichment") }
            let index = try library().index
            if step["titles"] != nil { enrich.enrich(try trackIDs(step).compactMap { index.tracks[$0] }) } else { await enrich.enrichAll(model.ui.narrowed(index.songs, in: index)) }
            await enrich.finish()
            try await settle()
        case "rejectMatch":
            let row = try song(step.required("title"))
            guard let enrich = model.enrich else { throw SelfTestFailure(description: "no enrichment") }
            model.ui.sheet = nil
            await enrich.reject(row)
            try await settle()
        case "setSources":
            // `order` / `disabled` (source names), `storefront`; what's not given stays.
            guard let enrich = model.enrich else { throw SelfTestFailure(description: "no enrichment") }
            var settings = enrich.settings
            func sources(_ key: String) -> [OnlineSource]? { (step[key] as? [String])?.compactMap(OnlineSource.init) }
            if let order = sources("order") { settings.order = order }
            if let disabled = sources("disabled") { settings.disabled = Set(disabled) }
            if let storefront = step.string("storefront") { settings.storefront = storefront }
            await enrich.setSettings(settings).value
            try await settle()
        case "enrichFilter":
            guard let filter = EnrichFilter(rawValue: try step.required("value")) else { throw SelfTestFailure(description: "unknown filter") }
            model.ui.enrichFilter = filter
            try await settle()
        case "inspect":
            // The song as shown, merged from tags, enrichment and edits.
            let title = try step.required("title")
            guard let row = try library().index.songs.first(where: { $0.title == title }) else { throw SelfTestFailure(description: "no song \(title)") }
            inspected[title] = ["album": row.album as Any? ?? NSNull(), "artists": row.artists, "composers": row.composers,
                                "trackNo": row.trackNo as Any? ?? NSNull(), "year": row.year as Any? ?? NSNull(), "genre": row.genre as Any? ?? NSNull(),
                                "hasLyrics": row.hasLyrics, "hasArtwork": row.hasArtwork, "coverFile": row.coverFile != nil, "userCover": row.userCover,
                                "match": model.enrich?.match(row)?.status.rawValue ?? NSNull()] as Step
        case "like":
            let library = try library()
            let ids = try step.string("title").map { title in library.index.songs.filter { $0.title == title }.map(\.id) }
                ?? [try player().current?.id].compactMap { $0 }
            guard !ids.isEmpty else { throw SelfTestFailure(description: "nothing to like") }
            library.setLiked(ids, step["value"] as? Bool ?? true)
            try await settle()
        case "play":
            try play(step)
        case "setOutputDevice":
            // `uid`, or "default" for the system default.
            guard let output = model.output else { throw SelfTestFailure(description: "no output") }
            await output.ready()
            let uid = try step.required("uid")
            output.select(uid == "default" ? nil : uid)
            try await settle()
        case "fakeOutput":
            // Plugs, unplugs or makes default a stand-in device (`op`: plug / unplug / setDefault, `uid`).
            guard let fake = model.output?.source as? FakeOutputDevices else { throw SelfTestFailure(description: "no stand-in devices") }
            let uid = try step.required("uid")
            switch try step.required("op") {
            case "plug": fake.plug(uid)
            case "unplug": fake.unplug(uid)
            case "setDefault": fake.setDefault(uid)
            case let op: throw SelfTestFailure(description: "unknown fakeOutput op \(op)")
            }
            await model.output?.settled()
            try await settle()
        case "simulateDeviceChange":
            try player().engine.simulateConfigurationChange(deviceGone: step["deviceGone"] as? Bool ?? false)
            try await settle()
        case "togglePlayPause":
            try player().togglePlayPause()
        case "pause":
            try player().pause()
        case "resume":
            try player().resume()
        case "next":
            try player().next()
        case "previous":
            try player().previous()
        case "seek":
            try player().seek(to: step.number("seconds") ?? 0)
        case "setShuffle":
            try player().setShuffle(step["value"] as? Bool ?? true)
        case "setRepeat":
            guard let mode = RepeatMode(rawValue: try step.required("value")) else { throw SelfTestFailure(description: "bad repeat mode") }
            try player().setRepeat(mode)
        case "measure":
            let engine = try player().engine
            engine.meter.reset()
            engine.metering = true
            try await Task.sleep(for: .seconds(step.number("seconds") ?? 2))
            engine.metering = false
            let r = engine.meter.reading
            measures[try step.required("name")] = ["seconds": r.seconds, "rmsDbfs": r.rmsDbfs, "peakDbfs": r.peakDbfs,
                                                   "maxStep": r.maxStep, "longestGapMs": r.longestGapMs,
                                                   "integratedLufs": r.integratedLufs as Any? ?? NSNull()]
        case "setNormalization":
            guard let mode = NormalizationMode(rawValue: try step.required("value")), let loudness = model.loudness else {
                throw SelfTestFailure(description: "bad normalization mode or no loudness model")
            }
            loudness.setMode(mode)
        case "showNowPlaying":
            model.ui.nowPlayingShown = step["value"] as? Bool ?? true
            try await settle()
        case "miniPlayer":
            model.setMiniPlayer(step["value"] as? Bool ?? true)
            try await settle()
        case "focusSearch":
            model.ui.focusSearch()
            try await settle()
        case "pressKey":
            // The route of the active app (AppKit skips key equivalents for the inactive self-test app): key monitor,
            // the window's key equivalents, the menu's, then the window.
            let event = try keyEvent(step), window = try window()
            if let unhandled = model.handleKey(event), !window.performKeyEquivalent(with: unhandled),
               NSApp.mainMenu?.performKeyEquivalent(with: unhandled) != true {
                window.sendEvent(unhandled)
            }
            try await settle()
        case "clearFocus":
            try window().makeFirstResponder(nil)
            try await settle()
        case "focusList":
            // The SwiftUI list right of the sidebar (e.g. the people list) takes the keyboard.
            let window = try window()
            guard let list = tables(window.contentView).filter({ !($0.delegate is SongsTableView.Coordinator) })
                .max(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }) else {
                throw SelfTestFailure(description: "no list")
            }
            window.makeFirstResponder(list)
            try await settle()
        case "setVolume":
            try player().setVolume(Float(step.number("value") ?? 1))
        case "quit":
            // The real quit path (saving playback on the way out); the report is written first, as the app exits there.
            finish(status: "pass", error: nil)
            NSApp.terminate(nil)
            try await Task.sleep(for: .seconds(30))
        case "closeMainWindow":
            try window().performClose(nil)
            try await settle()
        case "openMainWindow":
            model.ui.openWindow?(id: "main")
            try await settle()
        case "showQueue":
            model.ui.queueShown = step["value"] as? Bool ?? true
            try await settle()
        case "seekToLyric":
            try player().seekToLyric(Int(step.number("index") ?? 0))
        case "playNext":
            let title = try step.required("title")
            guard let song = try library().index.songs.first(where: { $0.title == title }) else { throw SelfTestFailure(description: "no song \(title)") }
            try player().playNext([song.id])
        case "enableNowPlaying":
            model.enableNowPlaying()
        case "openSettings":
            model.ui.settingsTab = Int(step.number("tab") ?? 0)
            model.ui.openSettings?()
            let deadline = Date().addingTimeInterval(5)
            while (try? window("settings")) == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            try await settle()
        case "state":
            try write(state(), to: nextFile(try step.required("name"), "state.json"))
        case "assert":
            try check(step)
        case "waitUntil":
            try await waitUntil(step)
        default:
            throw SelfTestFailure(description: "unknown action")
        }
    }

    private func tables(_ view: NSView?) -> [NSTableView] {
        guard let view else { return [] }
        return (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
    }

    private func keyEvent(_ step: Step) throws -> NSEvent {
        let keys: [String: (characters: String, code: UInt16)] = [
            "space": (" ", 49), "return": ("\r", 36), "f": ("f", 3), "l": ("l", 37), "m": ("m", 46), "left": ("\u{F702}", 123), "right": ("\u{F703}", 124), "down": ("\u{F701}", 125), "up": ("\u{F700}", 126),
        ]
        let name = try step.required("key")
        guard let key = keys[name] else { throw SelfTestFailure(description: "unknown key \(name)") }
        var flags: NSEvent.ModifierFlags = key.code >= 123 ? [.function, .numericPad] : []
        for modifier in step["modifiers"] as? [String] ?? [] {
            guard let flag = ["command": NSEvent.ModifierFlags.command, "shift": .shift, "option": .option][modifier] else {
                throw SelfTestFailure(description: "unknown modifier \(modifier)")
            }
            flags.insert(flag)
        }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: try window().windowNumber, context: nil, characters: key.characters,
                                           charactersIgnoringModifiers: key.characters, isARepeat: step["repeat"] as? Bool ?? false, keyCode: key.code)
        else { throw SelfTestFailure(description: "cannot make key event") }
        return event
    }

    private func comparator(_ column: String, ascending: Bool) throws -> KeyPathComparator<TrackRow> {
        guard let comparator = SongColumn(rawValue: column)?.comparator(ascending ? .forward : .reverse) else {
            throw SelfTestFailure(description: "unknown column \(column)")
        }
        return comparator
    }

    private func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    /// Scrolls the tallest scroll view in the main window from top to bottom, like a user flicking through;
    /// `steps: 0` only jumps back to the top.
    private func scrollList(steps: Int, interval: Double) async throws {
        guard let root = try window().contentView,
              let scroll = scrollViews(root).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        else { throw SelfTestFailure(description: "no scroll view") }
        for i in 0...steps {
            let maxY = max((scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height, 0)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: steps == 0 ? 0 : maxY * Double(i) / Double(steps)))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .seconds(interval))
        }
    }

    private func scrollOffsets() -> [Step] {
        (mainWindow?.contentView).map(scrollViews)?.map {
            ["width": $0.frame.width, "height": $0.frame.height, "contentHeight": $0.documentView?.frame.height ?? 0,
             "y": $0.contentView.bounds.origin.y] as Step
        } ?? []
    }

    private func playlist(_ name: String) throws -> Playlist {
        guard let playlist = try library().playlists.first(where: { $0.name == name }) else { throw SelfTestFailure(description: "no playlist \(name)") }
        return playlist
    }

    /// Ids of the songs titled in `titles`, in that order.
    private func trackIDs(_ step: Step) throws -> [Int64] {
        let songs = try library().index.songs
        return try (step["titles"] as? [String] ?? []).map { title in
            guard let song = songs.first(where: { $0.title == title }) else { throw SelfTestFailure(description: "no song \(title)") }
            return song.id
        }
    }

    private func song(_ title: String) throws -> TrackRow {
        guard let row = try library().index.songs.first(where: { $0.title == title }) else { throw SelfTestFailure(description: "no song \(title)") }
        return row
    }

    private func openPicker() throws -> MatchPicker {
        guard let picker = model.ui.sheet?.picker else { throw SelfTestFailure(description: "no 选择匹配 sheet") }
        return picker
    }

    private func pickerState(_ picker: MatchPicker) -> Step {
        ["keywords": picker.keywords, "searching": picker.searching, "stored": picker.status.isEmpty,
         "results": picker.results.map(\.key), "selected": picker.selection ?? NSNull(), "replace": picker.replace.map(\.rawValue).sorted(),
         "lyrics": picker.chosenLyrics?.song.key ?? NSNull(), "lyricsResults": picker.lyricsResults.map(\.key),
         "status": Dictionary(uniqueKeysWithValues: picker.status.map { source, status in
             (source.rawValue, { () -> Any in
                 switch status {
                 case .searching: "searching"
                 case .found(let count): count
                 case .failed(let error): "failed: \(error)"
                 }
             }())
         })]
    }

    private func editorState(_ editor: InfoEditor) -> Step {
        func describe(_ choice: InfoEditor.Choice?) -> Any {
            switch choice {
            case .text(let text)?: text
            case .image(let url, _)?: url.lastPathComponent
            case .removed?: "removed"
            case nil: NSNull()
            }
        }
        return ["texts": Dictionary(uniqueKeysWithValues: editor.texts.map { ($0.key.rawValue, $0.value) }),
                "sources": editor.layers.map(\.source.rawValue), "cover": describe(editor.cover), "lyrics": describe(editor.lyrics),
                "edited": editor.edits.keys.map(\.rawValue).sorted()]
    }

    private func enrichState(_ enrich: EnrichModel) -> Step {
        let songs = model.library?.index.songs ?? []
        func titles(_ status: MatchStatus) -> [String] { songs.filter { enrich.match($0)?.status == status }.map(\.title).sorted() }
        // As the page shows them: narrowed by the search and filter.
        let counts = model.library.map { EnrichFilter.counts(model.ui.narrowed(songs, in: $0.index), enrich.match, backedUp: $0.backedUp) } ?? [:]
        return ["running": enrich.progress != nil, "notice": enrich.notice ?? NSNull(),
                "counts": Dictionary(uniqueKeysWithValues: EnrichFilter.allCases.map { ($0.rawValue, counts[$0] ?? 0) }),
                "auto": titles(.auto), "confirmed": titles(.confirmed), "pending": titles(.pending), "none": titles(.none), "rejected": titles(.rejected),
                "requests": Dictionary(OnlineFixtures.requests.map { (String($0.prefix { $0 != "/" }).replacing(".", with: "_"), 1) }, uniquingKeysWith: +),
                "sources": enrich.settings.enabled.map(\.rawValue)]
    }

    /// The person the artists / composers page shows.
    private func personState() -> Any {
        let ui = model.ui
        guard let index = model.library?.index, ui.path.isEmpty, ui.sidebar == .artists || ui.sidebar == .composers else { return NSNull() }
        let role: PersonRole = ui.sidebar == .artists ? .artist : .composer
        guard let group = ui.selectedPerson(role, in: ui.people(role, in: index)) else { return NSNull() }
        let ids = Set(group.trackIDs)
        return ["name": group.name, "trackCount": group.trackIDs.count,
                "albumCount": index.albums.count { $0.trackIDs.contains(where: ids.contains) }] as Step
    }

    /// Titles or names the current page shows, in display order.
    private func visibleTitles() -> [String] {
        guard let index = model.library?.index else { return [] }
        let ui = model.ui
        switch ui.path.last {
        case .album(let id)?:
            return index.album(id)?.trackIDs.compactMap { index.tracks[$0]?.title } ?? []
        case nil:
            switch ui.sidebar {
            case .songs: return ui.songs(in: index).map(\.title)
            case .albums: return ui.albums(in: index).map(\.title)
            case .recent: return ui.recentAlbums(in: index).map(\.title)
            case .liked: return ui.likedSongs(in: index, liked: model.library?.liked ?? [:]).map(\.title)
            case .enrich:
                return ui.narrowed(index.songs, in: index).filter { ui.enrichFilter.includes($0, model.enrich?.match($0), backedUp: model.library?.backedUp ?? []) }.map(\.title)
            case .neteaseImport: return model.importer?.sources.map(\.title) ?? []
            case .siren: return model.siren?.detail?.songs.map(\.name) ?? []
            case .playlist(let id):
                return ui.narrowed(model.library?.playlist(id)?.trackIDs.compactMap { index.tracks[$0] } ?? [], in: index).map(\.title)
            case .artists: return ui.people(.artist, in: index).map(\.name)
            case .composers: return ui.people(.composer, in: index).map(\.name)
            }
        }
    }

    private func player() throws -> PlayerModel {
        guard let player = model.player else { throw SelfTestFailure(description: "player unavailable: \(model.startupError ?? "")") }
        return player
    }

    /// Plays the first song matching `title` / `format` / `minSampleRate`, queued with its album (default) or all songs.
    private func play(_ step: Step) throws {
        let index = try library().index
        guard let song = index.songs.first(where: { row in
            (step.string("title").map { row.title == $0 } ?? true)
                && (step.string("format").map { row.format == $0 } ?? true)
                && (step.number("minSampleRate").map { Double(row.sampleRate ?? 0) >= $0 } ?? true)
        }) else { throw SelfTestFailure(description: "no song matches \(step)") }
        let queue = step.string("context") == "songs" ? index.songs.map(\.id)
            : index.albums.first { $0.trackIDs.contains(song.id) }?.trackIDs ?? [song.id]
        try player().play(queue, startAt: queue.firstIndex(of: song.id) ?? 0)
    }

    private func importModel() throws -> ImportModel {
        guard let importer = model.importer else { throw SelfTestFailure(description: "no importer") }
        return importer
    }

    private func importState(_ importer: ImportModel) -> Step {
        func describe(_ source: ImportSource, _ state: ImportState?) -> String {
            switch state {
            case .queued?: "queued"
            case .working?: "working"
            case .done(let url, let note)?: "done: " + url.path.replacingOccurrences(of: out.path + "/", with: "") + (note.map { " (\($0))" } ?? "")
            case .failed(let reason)?: "failed: " + reason
            case nil: importer.inLibrary(source) ? "inLibrary" : ""
            }
        }
        var plan: Any = NSNull()
        if case .importPlan(let open)? = model.ui.sheet {
            plan = ["count": open.sources.count, "target": open.target?.path ?? "first", "naming": open.naming.rawValue,
                    "fill": open.fill, "trash": open.trashOriginals] as Step
        }
        var sources: Step = [:]
        for source in importer.sources {
            sources[source.title] = ["file": source.url.lastPathComponent, "format": source.format, "ncm": source.isNCM, "state": describe(source, importer.states[source.id])] as Step
        }
        let bin = (model.options.dataDir ?? out).deletingLastPathComponent().appending(path: "Trash")
        let trashed = (try? FileManager.default.contentsOfDirectory(atPath: bin.path).sorted()) ?? []
        return ["folder": importer.settings.neteaseFolder, "running": importer.running, "plan": plan, "sources": sources,
                "count": importer.sources.count, "trashed": trashed,
                "processed": Dictionary(importer.processed.map { ($0.source.title, describe($0.source, $0.state)) }, uniquingKeysWith: { _, b in b })]
    }

    private func sirenState(_ siren: SirenModel) -> Step {
        var albums: Step = [:], songs: Step = [:]
        for album in siren.albums {
            let count = siren.ownedCount(album)
            albums[album.name] = "\(count.owned)/\(count.total)"
        }
        for song in siren.detail?.songs ?? [] {
            let owned = siren.owned(song)
            let state: String = switch siren.states[song.id] {
            case .queued?: "queued"
            case .downloading?: "downloading"
            case .done(let url)?: "done: " + url.path.replacingOccurrences(of: out.path + "/", with: "")
            case .failed(let reason)?: "failed: " + reason
            case nil: ""
            }
            songs[song.name] = ["owned": owned.map(\.format).sorted(), "state": state] as Step
        }
        var plan: Any = NSNull()
        if case .sirenPlan(let open)? = model.ui.sheet {
            plan = ["count": open.songs.count, "target": open.target?.path ?? "first", "naming": open.naming.rawValue] as Step
        }
        return ["albums": albums, "album": siren.detail?.album.name ?? NSNull(), "songs": songs, "running": siren.running,
                "failure": siren.failure ?? NSNull(), "plan": plan]
    }

    private func library() throws -> LibraryModel {
        guard let library = model.library else { throw SelfTestFailure(description: "library unavailable: \(model.startupError ?? "")") }
        return library
    }

    /// `@out` / `@fixtures` placeholders in script paths.
    private func resolve(_ path: String) -> String {
        path.replacingOccurrences(of: "@out", with: out.path)
            .replacingOccurrences(of: "@fixtures", with: model.options.fixturesDir?.path ?? "@fixtures")
    }

    /// Copies (anything readable) or removes, but only ever writes strictly inside `--out`; canonical paths resolve
    /// symlinks, so neither `..` nor a symlinked component can escape.
    private func fileOperation(_ step: Step) throws {
        let op = try step.required("op")
        let target = URL(filePath: resolve(try step.required(op == "remove" ? "path" : "to"))).standardizedFileURL
        let sources = op == "move" ? [target, URL(filePath: resolve(try step.required("from"))).standardizedFileURL] : [target]
        for url in sources where !canonicalPath(url.path).hasPrefix(canonicalPath(out.path) + "/") {
            throw SelfTestFailure(description: "fs path \(url.path) is outside --out")
        }
        let fm = FileManager.default
        switch op {
        case "copy":
            try? fm.removeItem(at: target)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: URL(filePath: resolve(try step.required("from"))), to: target)
        case "remove":
            try fm.removeItem(at: target)
        case "move":
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: URL(filePath: resolve(try step.required("from"))), to: target)
        default:
            throw SelfTestFailure(description: "unknown fs op \(op)")
        }
    }

    private func prepareWindow(_ script: Step) async throws {
        let deadline = Date().addingTimeInterval(5)
        while mainWindow == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try await perform("window", script["window"] as? Step ?? [:])
    }

    private func settle() async throws {
        mainWindow?.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
    }

    private func check(_ step: Step) throws {
        let path = try step.required("path")
        var step = step
        // `equalsPath`: equal to another state value.
        if let other = step.string("equalsPath") { step["equals"] = JSONQuery.value(at: other, in: state()) ?? NSNull() }
        guard let comparison = Comparison(step) else { throw SelfTestFailure(description: "missing comparator") }
        let actual = JSONQuery.value(at: path, in: state())
        guard comparison.matches(actual) else {
            throw SelfTestFailure(description: "assert \(path) failed: actual=\(actual ?? "nil"), step=\(step)")
        }
    }

    private func waitUntil(_ step: Step) async throws {
        let path = try step.required("path")
        guard let comparison = Comparison(step) else { throw SelfTestFailure(description: "missing comparator") }
        let deadline = Date().addingTimeInterval(step.number("timeout") ?? 10)
        while !comparison.matches(JSONQuery.value(at: path, in: state())) {
            guard Date() < deadline else {
                throw SelfTestFailure(description: "timed out waiting for \(path); last=\(JSONQuery.value(at: path, in: state()) ?? "nil")")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: Capture

    private var mainWindow: NSWindow? {
        NSApp.windows.first(where: \.isLibraryWindow)
            ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
    }

    private func window(_ name: String = "main") throws -> NSWindow {
        // "sheet": the innermost one (a sheet can present its own).
        let window = name == "main" ? mainWindow : name == "sheet" ? mainWindow?.attachedSheet.map { sequence(first: $0) { $0.attachedSheet }.reduce($0) { $1 } }
            : NSApp.windows.first {
            $0 !== mainWindow && $0.isVisible && ($0.identifier?.rawValue.localizedCaseInsensitiveContains(name) == true || name == "settings" && $0.title.contains("设置"))
        }
        guard let window else { throw SelfTestFailure(description: "\(name) window not found") }
        return window
    }

    /// Prefers a window-server capture (faithful, incl. Liquid Glass sidebar; needs the terminal's Screen Recording
    /// grant). Falls back to an in-process `cacheDisplay` render, which omits system materials.
    private func snapshot(_ name: String, window: NSWindow) async throws {
        let url = nextFile(name, "png")
        let method: String
        if try await screencapture(window, to: url) {
            method = "screen"
        } else {
            try render(window, to: url)
            method = "render"
        }
        guard let stats = await Task.detached(operation: { ImageStats(contentsOf: url) }).value else {
            throw SelfTestFailure(description: "cannot read snapshot \(url.lastPathComponent)")
        }
        snapshots[name] = stats.json.merging(["file": url.lastPathComponent, "method": method]) { $1 }
    }

    /// Retries briefly: right after launch the window server may not know the window yet.
    private func screencapture(_ window: NSWindow, to url: URL) async throws -> Bool {
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(300)) }
            let process = Process()
            process.executableURL = URL(filePath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l\(window.windowNumber)", url.path]
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in done.resume() }
                do { try process.run() } catch { done.resume(throwing: error) }
            }
            if process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) { return true }
        }
        return false
    }

    private func render(_ window: NSWindow, to url: URL) throws {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { throw SelfTestFailure(description: "cannot render window") }
        view.layoutSubtreeIfNeeded()
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw SelfTestFailure(description: "cannot encode render")
        }
        try png.write(to: url)
    }

    // MARK: State & report

    private func state() -> Step {
        let perf = stalls.current
        let visible = visibleTitles()
        let main: Any = mainWindow.map {
            ["number": $0.windowNumber, "visible": $0.isVisible, "alpha": $0.alphaValue,
             "width": $0.frame.width, "height": $0.frame.height] as Step
        } ?? NSNull()
        return [
            "app": ["dataDir": model.paths.data.path, "startupError": model.startupError as Any? ?? NSNull(),
                    "storeOpen": model.library != nil, "isActive": NSApp.isActive],
            "ui": ["sidebar": model.ui.sidebar.name, "search": model.ui.search, "depth": model.ui.path.count,
                   "filterChips": model.ui.filter.chips.map { [$0.dimension, $0.value].compactMap { $0 }.joined(separator: " ") },
                   "searchFocused": mainWindow?.firstResponder is NSText, "nowPlaying": model.ui.nowPlayingShown,
                   "sort": model.ui.songSort.first.map { "\(SongColumn($0)?.rawValue ?? "?")\($0.order == .forward ? "+" : "-")" } ?? "",
                   "selectionCount": model.ui.songSelection.count, "person": personState(),
                   "playlistPrompt": model.ui.playlistPrompt?.title ?? NSNull(),
                   "playlist": { if case .playlist(let id) = model.ui.sidebar { model.library?.playlist(id)?.name } else { nil } }() ?? NSNull(),
                   "visibleCount": visible.count, "firstRows": Array(visible.prefix(5))] as Step,
            "windows": ["main": main, "mini": miniState(), "scrolls": scrollOffsets()],
            "library": model.library.map(libraryState) ?? NSNull(),
            "player": model.player.map(playerState) ?? NSNull(),
            "output": model.output.map(outputState) ?? NSNull(),
            "lyrics": model.player.map(lyricsState) ?? NSNull(),
            "loudness": model.loudness.map { ["analyzed": $0.progress.analyzed, "failed": $0.progress.failed, "total": $0.progress.total,
                                                "pending": $0.progress.pending, "mode": $0.mode.rawValue] as Step } ?? NSNull(),
            "measure": measures,
            "inspected": inspected,
            "enrich": model.enrich.map(enrichState) ?? NSNull(),
            "picker": model.ui.sheet?.picker.map(pickerState) ?? NSNull(),
            "editor": model.ui.sheet?.editor.map(editorState) ?? NSNull(),
            "fileTags": fileTags,
            "import": model.importer.map(importState) ?? NSNull(),
            "siren": model.siren.map(sirenState) ?? NSNull(),
            "tagPlan": model.ui.sheet?.plan.map { plan in
                ["items": Dictionary(plan.items.map { ($0.row.title, ["changes": plan.changes($0).map(\.field.rawValue), "skip": $0.skip ?? NSNull()] as Step) },
                                     uniquingKeysWith: { first, _ in first }),
                 "done": plan.done, "finished": plan.finished, "failures": plan.failures.map { "\($0.title)：\($0.reason)" }] as Step
            } ?? NSNull(),
            "lyricsChooser": (model.ui.sheet?.picker?.lyricsChooser ?? model.ui.sheet?.editor?.lyricsChooser).map { chooser in
                ["keywords": chooser.keywords, "options": chooser.options.map(\.key), "selection": chooser.selection ?? NSNull(),
                 "searching": chooser.searching] as Step
            } ?? NSNull(),
            "nowPlayingInfo": nowPlayingState(),
            "snapshots": snapshots,
            "perf": ["maxMainThreadStallMs": perf.maxMs, "stallsOver50ms": perf.over50ms],
        ]
    }

    private func miniState() -> Any {
        guard let panel = NSApp.windows.first(where: { $0.identifier?.rawValue == "mini" }) as? NSPanel else { return NSNull() }
        return ["number": panel.windowNumber, "visible": panel.isVisible, "floating": panel.level == .floating,
                "allSpaces": panel.collectionBehavior.contains(.canJoinAllSpaces), "nonactivating": panel.styleMask.contains(.nonactivatingPanel),
                "hidesOnDeactivate": panel.hidesOnDeactivate, "width": panel.frame.width, "height": panel.frame.height] as Step
    }

    private func libraryState(_ library: LibraryModel) -> Step {
        let index = library.index
        return [
            "started": library.started, "scanning": library.scanning, "lastError": library.lastError as Any? ?? NSNull(),
            "trackCount": index.songs.count, "albumCount": index.albums.count,
            "artistCount": index.artists.count, "composerCount": index.composers.count,
            "firstSongs": index.songs.prefix(5).map(\.title),
            "liked": library.liked.keys.compactMap { index.tracks[$0]?.title }.sorted(),
            "backedUp": library.backedUp.map { URL(filePath: $0).lastPathComponent }.sorted(),
            "playlists": library.playlists.map { ["name": $0.name, "titles": $0.trackIDs.compactMap { index.tracks[$0]?.title }] as Step },
            "roots": ["include": library.roots.include, "exclude": library.roots.exclude],
            "lastScan": library.lastScan.map {
                ["total": $0.total, "parsed": $0.parsed, "added": $0.added, "updated": $0.updated, "removed": $0.removed,
                 "failureCount": $0.failures.count, "ms": $0.milliseconds] as Step
            } ?? NSNull(),
        ]
    }

    private func outputState(_ output: OutputModel) -> Step {
        ["devices": output.devices.map { ["uid": $0.id, "name": $0.name, "transport": $0.transport.rawValue, "rate": $0.nominalRate] as Step },
         "selected": output.settings.deviceUID ?? NSNull(), "effective": output.effective?.id ?? NSNull(),
         "defaultUID": output.defaultUID ?? NSNull(), "missing": output.missing ?? NSNull()]
    }

    private func playerState(_ player: PlayerModel) -> Step {
        let engine = player.engine
        return [
            "title": player.current?.title as Any? ?? NSNull(), "trackId": player.current?.id as Any? ?? NSNull(),
            "isPlaying": player.isPlaying, "position": player.position, "duration": player.duration,
            "fileSampleRate": engine.fileSampleRate, "outputSampleRate": engine.outputSampleRate,
            "gainDb": engine.current?.gainDb as Any? ?? NSNull(),
            "volume": player.volume, "engineVolume": engine.volume, "lastError": player.lastError as Any? ?? NSNull(),
            "skipNotice": player.skipNotice as Any? ?? NSNull(),
            "queue": ["count": player.queue.entries.count, "index": player.queue.index as Any? ?? NSNull(),
                      "upcomingTitles": player.queue.upcoming.prefix(5).compactMap { model.library?.index.tracks[$0.trackID]?.title },
                      "trackIds": player.queue.entries.map(\.trackID), "shuffled": player.queue.shuffled,
                      "repeat": player.queue.repeatMode.rawValue] as Step,
        ]
    }

    private func lyricsState(_ player: PlayerModel) -> Step {
        let lines: [LyricLine] = switch player.lyrics {
        case .synced(let lines)?: lines
        case .unsynced(let texts)?: texts.map { LyricLine(time: 0, text: $0) }
        case nil: []
        }
        let current = player.lyricIndex.map { lines[$0] }
        let position = model.ui.lyricsPosition
        return ["lineCount": lines.count, "index": player.lyricIndex as Any? ?? NSNull(), "loading": player.lyricsLoading,
                "scrollTarget": position.viewID(type: Int.self).map { "line \($0)" } ?? (position.edge == .top ? "top" : "none"),
                "synced": { if case .synced = player.lyrics { true } else { false } }(),
                "currentText": current?.text as Any? ?? NSNull(), "currentTranslation": current?.translation as Any? ?? NSNull(),
                "consecutiveDuplicates": zip(lines, lines.dropFirst()).filter { $0.text == $1.text && !$0.text.isEmpty }.count]
    }

    private func nowPlayingState() -> Any {
        guard let info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return NSNull() }
        return [
            "title": info[MPMediaItemPropertyTitle] as? String ?? "",
            "elapsed": info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? -1,
            "rate": info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? -1,
        ] as Step
    }

    private func finish(status: String, error: String?) {
        stalls.stop()
        var report = state()
        report["status"] = status
        report["error"] = error ?? NSNull()
        report["durationSec"] = Date().timeIntervalSince(started)
        try? write(report, to: reportURL)
    }

    private func nextFile(_ name: String, _ suffix: String) -> URL {
        fileCounter += 1
        return out.appending(path: String(format: "%02d-%@.%@", fileCounter, name, suffix))
    }

    private func write(_ object: Any, to url: URL) throws {
        // JSONSerialization raises an uncatchable exception on NaN or non-JSON types.
        guard JSONSerialization.isValidJSONObject(object) else { throw SelfTestFailure(description: "state is not valid JSON") }
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }

    nonisolated private static func timeoutHandler(report: URL) -> @Sendable (String) -> Void {
        { progress in
            let data = try? JSONSerialization.data(withJSONObject: ["status": "timeout", "error": progress])
            try? data?.write(to: report)
            _exit(2)
        }
    }
}
