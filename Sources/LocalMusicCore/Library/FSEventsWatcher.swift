import CoreServices
import Foundation

public struct FileEvent: Sendable, Equatable {
    public let path: String
    public let flags: UInt32

    public init(path: String, flags: UInt32) {
        self.path = path
        self.flags = flags
    }
}

extension LibraryRoots {
    /// Whether an FSEvents record can change the library. Call on `resolved` roots.
    public func isRelevant(_ event: FileEvent) -> Bool {
        let rescanAll = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
        if event.flags & rescanAll != 0 { return true }
        guard !isExcluded(event.path) else { return false }
        if event.flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 { return true }
        let ext = URL(filePath: event.path).pathExtension.lowercased()
        return ext == "lrc" || TagReader.audioExtensions.contains(ext)
    }
}

/// Recursive FSEvents stream over the library roots. Only a trigger: the scanner re-diffs the whole tree, so
/// coalescing, renames and NFD/NFC differences don't matter.
public final class FSEventsWatcher: Sendable {
    public let events: AsyncStream<[FileEvent]>
    private let continuation: AsyncStream<[FileEvent]>.Continuation
    private nonisolated(unsafe) let stream: FSEventStreamRef?

    /// Owned by the stream through the context retain/release callbacks, so an in-flight callback never touches
    /// a watcher that is being deallocated.
    private final class Sink: Sendable {
        let continuation: AsyncStream<[FileEvent]>.Continuation
        init(_ continuation: AsyncStream<[FileEvent]>.Continuation) { self.continuation = continuation }
    }

    public init(paths: [String], latency: TimeInterval = 1.0) {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
        guard !paths.isEmpty else {
            stream = nil
            return
        }
        let sink = Sink(continuation)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: { info in UnsafeRawPointer(Unmanaged<Sink>.fromOpaque(info!).retain().toOpaque()) },
            release: { info in Unmanaged<Sink>.fromOpaque(info!).release() },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info, let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            let events = (0..<min(count, changed.count)).map { FileEvent(path: changed[$0], flags: flags[$0]) }
            Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue().continuation.yield(events)
        }
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes
        stream = withExtendedLifetime(sink) {
            FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, FSEventStreamCreateFlags(flags))
        }
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "LocalMusic.FSEvents"))
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        continuation.finish()
    }
}
