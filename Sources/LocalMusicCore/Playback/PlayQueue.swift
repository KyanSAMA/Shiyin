import Foundation

public enum RepeatMode: String, Sendable, CaseIterable {
    case off, all, one
}

/// One occurrence of a track in the queue; the same track may be queued more than once.
public struct QueueEntry: Sendable, Hashable, Identifiable {
    public let id: Int
    public let trackID: Int64
}

public struct PlayQueue: Sendable {
    /// Play order (shuffled when `shuffled`).
    public private(set) var entries: [QueueEntry] = []
    public private(set) var index: Int?
    public private(set) var shuffled = false
    public var repeatMode: RepeatMode = .off
    /// List order, restored when shuffle is turned off.
    private var original: [QueueEntry] = []
    private var lastID = 0

    public init() {}

    public var current: QueueEntry? { index.map { entries[$0] } }
    public var upcoming: ArraySlice<QueueEntry> { entries[((index ?? -1) + 1)...] }

    /// `shuffle: nil` keeps the current mode.
    public mutating func replace(with tracks: [Int64], start: Int, shuffle: Bool? = nil, using rng: inout some RandomNumberGenerator) {
        original = makeEntries(tracks)
        entries = original
        index = entries.isEmpty ? nil : min(max(start, 0), entries.count - 1)
        let on = shuffle ?? shuffled
        shuffled = false
        if on { setShuffle(true, using: &rng) }
    }

    /// The entry automatic advance would move to (repeat-one repeats, repeat-all wraps).
    public func peekNext() -> QueueEntry? {
        guard let index else { return nil }
        if repeatMode == .one { return entries[index] }
        if index + 1 < entries.count { return entries[index + 1] }
        return repeatMode == .all ? entries.first : nil
    }

    /// Commits the move `peekNext` announced, once playback has actually crossed into it.
    @discardableResult
    public mutating func advance() -> QueueEntry? {
        guard let next = peekNext() else { return nil }
        index = entries.firstIndex(of: next)
        return next
    }

    /// Makes the entry with this id current (e.g. the one the engine is actually playing).
    @discardableResult
    public mutating func select(_ entryID: Int) -> Bool {
        guard let found = entries.firstIndex(where: { $0.id == entryID }) else { return false }
        index = found
        return true
    }

    /// Manual skip: leaves a repeated track, wraps unless repeat is off.
    @discardableResult
    public mutating func skipForward() -> QueueEntry? {
        guard let index else { return nil }
        if index + 1 < entries.count { self.index = index + 1 } else if repeatMode != .off { self.index = 0 } else { return nil }
        return current
    }

    @discardableResult
    public mutating func skipBackward() -> QueueEntry? {
        guard let index else { return nil }
        if index > 0 { self.index = index - 1 } else if repeatMode != .off { self.index = entries.count - 1 } else { return nil }
        return current
    }

    /// Shuffling keeps the current entry playing and first; unshuffling restores list order around it.
    public mutating func setShuffle(_ on: Bool, using rng: inout some RandomNumberGenerator) {
        guard on != shuffled else { return }
        shuffled = on
        let current = self.current
        if on {
            entries = (current.map { [$0] } ?? []) + original.filter { $0 != current }.shuffled(using: &rng)
            index = entries.isEmpty ? nil : 0
        } else {
            entries = original
            index = current.flatMap { entries.firstIndex(of: $0) } ?? (entries.isEmpty ? nil : 0)
        }
    }

    public mutating func insertNext(_ tracks: [Int64]) {
        let added = makeEntries(tracks)
        entries.insert(contentsOf: added, at: (index ?? -1) + 1)
        original.insert(contentsOf: added, at: current.flatMap { original.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        if index == nil, !entries.isEmpty { index = 0 }
    }

    public mutating func append(_ tracks: [Int64]) {
        let added = makeEntries(tracks)
        entries += added
        original += added
        if index == nil, !added.isEmpty { index = entries.count - added.count }
    }

    /// Removes entries; returns true when the current entry was among them (the caller restarts or stops playback;
    /// the entry that followed it becomes current).
    @discardableResult
    public mutating func remove(_ ids: Set<Int>) -> Bool {
        let current = self.current
        let survivorsBefore = entries.prefix(index ?? 0).filter { !ids.contains($0.id) }.count
        entries.removeAll { ids.contains($0.id) }
        original.removeAll { ids.contains($0.id) }
        guard let current, ids.contains(current.id) else {
            index = current.flatMap { entries.firstIndex(of: $0) }
            return false
        }
        index = survivorsBefore < entries.count ? survivorsBefore : nil
        return true
    }

    /// Reorders upcoming entries (offsets relative to `upcoming`).
    public mutating func moveUpcoming(from source: IndexSet, to destination: Int) {
        let base = (index ?? -1) + 1
        var upcoming = Array(entries[base...])
        let moving = source.sorted().map { upcoming[$0] }
        let insertAt = destination - source.filter { $0 < destination }.count
        upcoming.removeAll { moving.contains($0) }
        upcoming.insert(contentsOf: moving, at: min(max(insertAt, 0), upcoming.count))
        entries.replaceSubrange(base..., with: upcoming)
        if !shuffled { original = entries }
    }

    public mutating func clearUpcoming() {
        let keep = Set(entries.prefix((index ?? -1) + 1).map(\.id))
        entries.removeAll { !keep.contains($0.id) }
        original.removeAll { !keep.contains($0.id) }
    }

    private mutating func makeEntries(_ tracks: [Int64]) -> [QueueEntry] {
        defer { lastID += tracks.count }
        return tracks.enumerated().map { QueueEntry(id: lastID + $0.offset + 1, trackID: $0.element) }
    }
}
