import AppKit
import LocalMusicCore

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
            try await settle()
        case "activate":
            NSApp.activate()
            try window().makeKeyAndOrderFront(nil)
            try await settle()
        case "snapshot":
            try await snapshot(try step.required("name"))
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
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
            ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
    }

    private func window() throws -> NSWindow {
        guard let window = mainWindow else { throw SelfTestFailure(description: "main window not found") }
        return window
    }

    /// Prefers a window-server capture (faithful, incl. Liquid Glass sidebar; needs the terminal's Screen Recording
    /// grant). Falls back to an in-process `cacheDisplay` render, which omits system materials.
    private func snapshot(_ name: String) async throws {
        let window = try window()
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

    private func screencapture(_ window: NSWindow, to url: URL) async throws -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l\(window.windowNumber)", url.path]
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in done.resume() }
            do { try process.run() } catch { done.resume(throwing: error) }
        }
        return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path)
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
        let main: Any = mainWindow.map {
            ["number": $0.windowNumber, "visible": $0.isVisible, "alpha": $0.alphaValue,
             "width": $0.frame.width, "height": $0.frame.height] as Step
        } ?? NSNull()
        return [
            "app": ["dataDir": model.paths.data.path, "startupError": model.startupError as Any? ?? NSNull(),
                    "storeOpen": model.store != nil, "isActive": NSApp.isActive],
            "ui": ["sidebar": model.ui.sidebar.rawValue],
            "windows": ["main": main],
            "snapshots": snapshots,
            "perf": ["maxMainThreadStallMs": perf.maxMs, "stallsOver50ms": perf.over50ms],
        ]
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
