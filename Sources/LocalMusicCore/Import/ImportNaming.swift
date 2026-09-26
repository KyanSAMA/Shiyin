import Foundation

/// How imported and downloaded files are named inside the target folder.
public enum ImportNaming: String, Codable, CaseIterable, Sendable {
    case title, artistTitle, titleArtist, albumTrack

    public var example: String {
        switch self {
        case .title: "标题"
        case .artistTitle: "艺人 - 标题"
        case .titleArtist: "标题 - 艺人"
        case .albumTrack: "专辑/01 标题"
        }
    }

    /// The names to try, in order: the scheme's, then with ` (专辑)`, then ` 2`, ` 3`, …; each a relative path.
    public func candidates(title: String, artists: [String], album: String?, trackNo: Int?, ext: String) -> [String] {
        let artist = artists.joined(separator: ", ")
        let base: (folder: String?, name: String) = switch self {
        case .title: (nil, title)
        case .artistTitle: (nil, artist.isEmpty ? title : "\(artist) - \(title)")
        case .titleArtist: (nil, artist.isEmpty ? title : "\(title) - \(artist)")
        case .albumTrack: (album.flatMap { $0.isEmpty ? nil : $0 } ?? "未知专辑", trackNo.map { String(format: "%02d ", $0) + title } ?? title)
        }
        let folder = base.folder.map { Self.component($0) + "/" } ?? ""
        let suffixes = [""] + (album.map { $0.isEmpty || self == .albumTrack ? [] : [" (\($0))"] } ?? []) + (2...99).map { " \($0)" }
        return suffixes.map { folder + Self.component(base.name, suffix: $0, ext: ext) }
    }

    /// A file or folder name: no path separators or colons, no leading dot or control characters, NFC, at most 255
    /// UTF-8 bytes — the name shortened first, so the suffix (a conflict's ` (专辑)` / ` 2`) and extension stay.
    static func component(_ name: String, suffix: String = "", ext: String? = nil) -> String {
        func clean(_ text: String) -> String {
            let text = text.precomposedStringWithCanonicalMapping.replacing("/", with: "／").replacing(":", with: "：")
            return String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        }
        var text = clean(name).trimmingCharacters(in: .whitespaces)
        while text.hasPrefix(".") { text.removeFirst() }
        if text.isEmpty { text = "未命名" }
        let tail = clean(suffix) + (ext.map { "." + $0 } ?? "")
        while !text.isEmpty, (text + tail).utf8.count > 255 { text.removeLast() }
        return text + tail
    }
}
