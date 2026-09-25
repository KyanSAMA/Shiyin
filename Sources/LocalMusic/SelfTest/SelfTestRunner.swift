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
            guard let item = SidebarItem(rawValue: value) else { throw SelfTestFailure(description: "unknown sidebar \(value)") }
            model.ui.sidebar = item
            model.ui.path = []
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
        case "like":
            let library = try library()
            let ids = try step.string("title").map { title in library.index.songs.filter { $0.title == title }.map(\.id) }
                ?? [try player().current?.id].compactMap { $0 }
            guard !ids.isEmpty else { throw SelfTestFailure(description: "nothing to like") }
            library.setLiked(ids, step["value"] as? Bool ?? true)
            try await settle()
        case "play":
            try play(step)
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
        let window = name == "main" ? mainWindow : NSApp.windows.first {
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
            "ui": ["sidebar": model.ui.sidebar.rawValue, "search": model.ui.search, "depth": model.ui.path.count,
                   "filterChips": model.ui.filter.chips.map { [$0.dimension, $0.value].compactMap { $0 }.joined(separator: " ") },
                   "searchFocused": mainWindow?.firstResponder is NSText, "nowPlaying": model.ui.nowPlayingShown,
                   "sort": model.ui.songSort.first.map { "\(SongColumn($0)?.rawValue ?? "?")\($0.order == .forward ? "+" : "-")" } ?? "",
                   "selectionCount": model.ui.songSelection.count, "person": personState(),
                   "visibleCount": visible.count, "firstRows": Array(visible.prefix(5))] as Step,
            "windows": ["main": main, "mini": miniState(), "scrolls": scrollOffsets()],
            "library": model.library.map(libraryState) ?? NSNull(),
            "player": model.player.map(playerState) ?? NSNull(),
            "lyrics": model.player.map(lyricsState) ?? NSNull(),
            "loudness": model.loudness.map { ["analyzed": $0.progress.analyzed, "failed": $0.progress.failed, "total": $0.progress.total,
                                                "pending": $0.progress.pending, "mode": $0.mode.rawValue] as Step } ?? NSNull(),
            "measure": measures,
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
            "roots": ["include": library.roots.include, "exclude": library.roots.exclude],
            "lastScan": library.lastScan.map {
                ["total": $0.total, "parsed": $0.parsed, "added": $0.added, "updated": $0.updated, "removed": $0.removed,
                 "failureCount": $0.failures.count, "ms": $0.milliseconds] as Step
            } ?? NSNull(),
        ]
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
