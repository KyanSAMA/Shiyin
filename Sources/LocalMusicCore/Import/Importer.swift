import Darwin
import Foundation

public struct ImportSettings: Codable, Equatable, Sendable {
    public static let key = "import"

    /// Where NetEase Cloud Music keeps its downloads.
    public var neteaseFolder: String
    /// Where new files go; nil means the first music folder.
    public var target: String?
    public var naming = ImportNaming.title
    /// Move migrated NetEase files (and their .lrc) to the Trash.
    public var trashOriginals = true
    /// Complete the info from NetEase and write it into the new files.
    public var fill = true

    public init(neteaseFolder: String) { self.neteaseFolder = neteaseFolder }

    public static var `default`: ImportSettings {
        ImportSettings(neteaseFolder: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Music/网易云音乐").path)
    }
}

/// Puts new files into a folder without ever touching an existing one: each is built as a hidden staging file there
/// (the scanner skips it), tagged through `TagWriter` (verified), then renamed to the first free name.
public enum Importer {
    static let stagingMarker = ".localmusic-import-"

    public static func staging(in folder: URL, ext: String) -> URL {
        folder.appending(path: "\(stagingMarker)\(UUID().uuidString.prefix(8)).\(ext)")
    }

    /// Staging files a crash left behind (and a tag write's temp file beside one); only while no import is running.
    public static func sweepStaging(in folder: URL) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasPrefix(stagingMarker) || name.hasPrefix("." + stagingMarker) {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }

    /// A copy of the file `source` names (a link is followed; the copy is a clone on APFS), writable and unlocked
    /// whatever the source's mode, as the staging file.
    public static func stage(copyOf source: URL, to staged: URL) throws {
        let source = source.resolvingSymlinksInPath()
        var info = stat()
        guard lstat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw TagWriteError.unsupported("不是普通文件") }
        guard copyfile(source.path, staged.path, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0, chflags(staged.path, 0) == 0,
              chmod(staged.path, 0o644) == 0 else {
            throw TagWriteError.unsupported(String(cString: strerror(errno)))
        }
    }

    /// Tags for audio from an .ncm, whose own tags are junk: its metadata (title, artists, album, the 163 key), then from
    /// NetEase's detail the track, disc and year, lyrics (NetEase's with translation, else the sidecar's) with their
    /// credited composers, and the cover.
    public static func ncmEdit(_ meta: NCMFile.Meta?, song: OnlineSong?, lyrics: String?, cover: Data?) -> TagEdit {
        var edit = TagEdit()
        edit.replaceAll = true
        // Trimmed as the tag reader does, so the values read back as written.
        edit.title = (meta?.title.trimmed.nonEmpty ?? song?.title.trimmed.nonEmpty)
        edit.artists = meta.flatMap { $0.artists.isEmpty ? nil : $0.artists } ?? song?.artists
        edit.album = meta?.album.trimmed.nonEmpty ?? song?.album.trimmed.nonEmpty
        edit.ncmKey = meta?.key163
        (edit.trackNo, edit.discNo, edit.year) = (song?.trackNo, song?.discNo, song?.year)
        if let lyrics = lyrics?.nonEmpty {
            edit.lyrics = lyrics
            edit.composers = LRCParser.parse(lyrics)?.credits.composers.nonEmpty
        }
        edit.cover = cover.flatMap { try? TagEdit.Cover($0) }
        return edit
    }

    /// Writes `edit` into the staged file, then renames it to the first of `candidates` (relative to `folder`) that
    /// doesn't exist, creating folders as needed. Returns where it went.
    public static func place(_ staged: URL, edit: TagEdit, in folder: URL, candidates: [String]) async throws -> URL {
        if !edit.isEmpty { _ = try await TagWriter.commit(try TagWriter.prepare(edit, for: staged)) }
        var created: [URL] = []
        defer {   // folders made for a file that didn't land there
            for folder in created.reversed() where (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        for relative in candidates {
            let target = folder.appending(path: relative), parent = target.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parent.path) {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                created.append(parent)
            }
            if renamex_np(staged.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                created.removeAll { target.path.hasPrefix($0.path + "/") }
                return target
            }
            guard errno == EEXIST else { throw TagWriteError.unsupported(String(cString: strerror(errno))) }
        }
        throw TagWriteError.unsupported("没有可用的文件名")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) }
}

private extension Array {
    var nonEmpty: Self? { isEmpty ? nil : self }
}
