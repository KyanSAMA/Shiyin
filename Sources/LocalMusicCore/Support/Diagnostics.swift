import Foundation
import Synchronization

/// Measures main-queue latency from a background thread.
public final class StallMonitor: Sendable {
    public struct Stats: Sendable {
        public var maxMs = 0.0
        public var over50ms = 0
    }

    private let stats = Mutex(Stats())
    private let running = Atomic(false)

    public init() {}

    public func start(interval: TimeInterval = 0.01) {
        guard !running.exchange(true, ordering: .relaxed) else { return }
        Thread.detachNewThread { [self] in
            while running.load(ordering: .relaxed) {
                let start = DispatchTime.now().uptimeNanoseconds
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { done.signal() }
                done.wait()
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                stats.withLock {
                    $0.maxMs = max($0.maxMs, ms)
                    if ms > 50 { $0.over50ms += 1 }
                }
                Thread.sleep(forTimeInterval: interval)
            }
        }
    }

    public func stop() { running.store(false, ordering: .relaxed) }
    public func reset() { stats.withLock { $0 = Stats() } }
    public var current: Stats { stats.withLock { $0 } }
}

/// Fires once after a deadline unless the process exits first; `mark` records progress for the timeout report.
public final class Watchdog: Sendable {
    private let progress = Mutex("")

    public init() {}

    public func mark(_ note: String) { progress.withLock { $0 = note } }

    public func arm(after seconds: TimeInterval, onTimeout: @escaping @Sendable (String) -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
            onTimeout(progress.withLock { $0 })
        }
    }
}
