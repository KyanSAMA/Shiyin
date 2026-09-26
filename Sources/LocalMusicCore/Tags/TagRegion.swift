import CryptoKit
import Darwin
import Foundation

/// Size and modification time: what tells a file changed underneath a write.
public struct FileVersion: Sendable, Codable, Equatable {
    public let size: Int64
    public let mtime: Double

    public init(_ url: URL) throws {
        var url = url
        url.removeAllCachedResourceValues()   // a URL caches what it read, which would hide a change
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        (size, mtime) = (Int64(values.fileSize ?? 0), values.contentModificationDate?.timeIntervalSince1970 ?? 0)
    }
}

/// The only code that changes library files: replaces one byte range (the tag region) through a hidden temp file in the
/// same folder — a clone when the length is unchanged, else a copy around the new bytes — checks it, and renames it over
/// the original only if the original is still the version the edit was made from. Readers holding the old file (the
/// player) keep reading it undisturbed.
enum TagRegion {
    private static let chunk = 1 << 20

    /// Refuses files that can't be replaced safely: hard links (the other names would keep the old tags), locked files,
    /// read-only folders.
    static func checkWritable(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw TagWriteError.unsupported("无法读取文件") }
        guard info.st_nlink <= 1 else { throw TagWriteError.unsupported("文件有多个硬链接") }
        guard info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) == 0 else { throw TagWriteError.unsupported("文件已锁定") }
        guard access(url.path, W_OK) == 0 else { throw TagWriteError.unsupported("文件是只读的") }
        guard access(url.deletingLastPathComponent().path, W_OK) == 0 else { throw TagWriteError.unsupported("没有写入这个文件夹的权限") }
    }

    static let temporaryMarker = ".localmusic-tmp-"

    /// Hidden (the scanner skips it), unique (writes can't meet) and with the audio extension (readers go by it).
    static func temporary(for url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: ".\(url.deletingPathExtension().lastPathComponent)\(temporaryMarker)\(UUID().uuidString.prefix(8)).\(url.pathExtension)")
    }

    static func commit(_ url: URL, start: Int64, length: Int64, bytes: Data, expecting version: FileVersion,
                       verify: (URL) async throws -> Void) async throws -> FileVersion {
        let temp = temporary(for: url)
        defer { try? FileManager.default.removeItem(at: temp) }
        let created = try url.resourceValues(forKeys: [.creationDateKey]).creationDate
        if Int64(bytes.count) == length {
            try check(copyfile(url.path, temp.path, nil, copyfile_flags_t(COPYFILE_CLONE)))
            let out = try FileHandle(forWritingTo: temp)
            try out.seek(toOffset: UInt64(start))
            try out.write(contentsOf: bytes)
            try sync(out)
        } else {
            guard FileManager.default.createFile(atPath: temp.path, contents: nil) else { throw TagWriteError.unsupported("无法在文件夹里创建临时文件") }
            let out = try FileHandle(forWritingTo: temp), input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            try copy(input, to: out, count: start)
            try out.write(contentsOf: bytes)
            try input.seek(toOffset: UInt64(start + length))
            try copy(input, to: out, count: nil)
            try sync(out)
            // ACLs, extended attributes, mode and flags — not the times (COPYFILE_STAT would), so the change is seen.
            try check(copyfile(url.path, temp.path, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR)))
            var info = stat()
            try check(stat(url.path, &info))
            try check(chmod(temp.path, info.st_mode & 0o7777))
            try check(chflags(temp.path, info.st_flags))
        }
        try await verify(temp)
        guard try FileVersion(url) == version else { throw TagWriteError.changed }
        try check(rename(temp.path, url.path))
        if let created {
            var values = URLResourceValues()
            values.creationDate = created
            var target = url
            try? target.setResourceValues(values)
        }
        return try FileVersion(url)
    }

    /// SHA-256 of a byte range, streamed.
    static func sha256(_ url: URL, _ range: Range<Int64>) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(range.lowerBound))
        var hash = SHA256(), left = range.count
        while left > 0, let data = try input.read(upToCount: min(chunk, left)), !data.isEmpty {
            hash.update(data: data)
            left -= data.count
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func copy(_ input: FileHandle, to out: FileHandle, count: Int64?) throws {
        var left = count ?? .max
        while left > 0, let data = try input.read(upToCount: Int(min(Int64(chunk), left))), !data.isEmpty {
            try out.write(contentsOf: data)
            left -= Int64(data.count)
        }
    }

    /// Network volumes don't support F_FULLFSYNC: plain fsync then.
    private static func sync(_ handle: FileHandle) throws {
        if fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 { try check(fsync(handle.fileDescriptor)) }
        try handle.close()
    }

    private static func check(_ result: Int32) throws {
        guard result != -1 else { throw TagWriteError.unsupported(String(cString: strerror(errno))) }
    }
}
