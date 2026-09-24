import Foundation

public enum TagError: Error, Equatable {
    case truncated
    case invalid(String)
    case unsupported(String)
}

/// Random-access bytes; tag parsers read only the ranges they need so embedded images are never loaded during scans.
protocol ByteSource: AnyObject {
    var size: Int64 { get }
    func read(at offset: Int64, count: Int) throws -> Data
}

final class FileSource: ByteSource {
    let size: Int64
    private(set) var bytesRead: Int64 = 0
    private let handle: FileHandle

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = Int64(try handle.seekToEnd())
    }

    deinit { try? handle.close() }

    func read(at offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset + Int64(count) <= size else { throw TagError.truncated }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw TagError.truncated }
        bytesRead += Int64(count)
        return data
    }
}

final class DataSource: ByteSource {
    private let bytes: Data
    var size: Int64 { Int64(bytes.count) }

    init(_ bytes: Data) { self.bytes = bytes }

    func read(at offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset + Int64(count) <= size else { throw TagError.truncated }
        let start = bytes.startIndex + Int(offset)
        return bytes.subdata(in: start..<start + count)
    }
}

/// Sequential cursor over an in-memory chunk.
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var position = 0

    init(_ data: Data) { bytes = [UInt8](data) }
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - position }

    mutating func skip(_ n: Int) throws {
        guard n >= 0, n <= remaining else { throw TagError.truncated }
        position += n
    }

    mutating func take(_ n: Int) throws -> [UInt8] {
        guard n >= 0, n <= remaining else { throw TagError.truncated }
        defer { position += n }
        return Array(bytes[position..<position + n])
    }

    mutating func u8() throws -> UInt8 { try take(1)[0] }

    mutating func uintBE(_ n: Int) throws -> Int {
        try take(n).reduce(0) { $0 << 8 | Int($1) }
    }

    mutating func uintLE(_ n: Int) throws -> Int {
        try take(n).reversed().reduce(0) { $0 << 8 | Int($1) }
    }

    /// Bytes up to (excluding) the next terminator; consumes the terminator. Two-byte terminators are aligned.
    mutating func terminated(width: Int) throws -> [UInt8] {
        var i = position
        while i + width <= bytes.count {
            if bytes[i..<i + width].allSatisfy({ $0 == 0 }) {
                defer { position = i + width }
                return Array(bytes[position..<i])
            }
            i += width
        }
        return try take(remaining)
    }

    mutating func rest() -> [UInt8] { (try? take(remaining)) ?? [] }
}

/// 28-bit ID3 "syncsafe" integer (7 significant bits per byte).
func syncsafe<C: Collection>(_ bytes: C) -> Int where C.Element == UInt8 {
    bytes.reduce(0) { $0 << 7 | Int($1 & 0x7F) }
}
