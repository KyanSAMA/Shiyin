import AppKit
import Observation
import LocalMusicCore

/// The 编辑信息 sheet's state. A filled field becomes a manual edit; an empty one keeps what the song shows (for a single
/// song it also removes that field's earlier edit).
@Observable final class InfoEditor {
    enum Choice {
        /// Lyrics text, or an image file for the cover.
        case text(String)
        case image(URL, NSImage?)
        /// Drops the manual one.
        case removed
    }

    let tracks: [TrackRow]
    var texts: [EnrichField: String]
    /// The single song's manual edits when the sheet opened, and the song as it would show without them.
    let edits: [EnrichField: String]
    private let unedited: [TrackRow]
    /// The single song's online layers in the user's order, to fill a field (cover, lyrics) from.
    let layers: [(source: OnlineSource, values: [EnrichField: String])]
    var cover: Choice?
    var lyrics: Choice?

    init(tracks: [TrackRow], edits: [EnrichField: String], unedited: [TrackRow], layers: [(source: OnlineSource, values: [EnrichField: String])] = []) {
        self.tracks = tracks
        self.edits = edits
        self.unedited = unedited
        self.layers = layers
        texts = Dictionary(uniqueKeysWithValues: edits.map { field, value in
            (field, field.isList ? EnrichField.decode(value).joined(separator: " / ") : value)
        })
    }

    /// Titles and track numbers only make sense one song at a time.
    var fields: [EnrichField] { tracks.count == 1 ? EnrichField.editable : EnrichField.editable.filter { $0 != .title && $0 != .trackNo } }

    /// What an empty field leaves showing: for one song its value without manual edits (what clearing reveals), for
    /// several what they show now, or 多个值.
    func shown(_ field: EnrichField) -> String {
        let values = Set((tracks.count == 1 ? unedited : tracks).map { $0.shown(field) })
        return values.count > 1 ? "多个值" : values.first ?? ""
    }

    /// Each source's value for a field, as typed (a cover as its file's path).
    func suggestions(_ field: EnrichField) -> [(source: OnlineSource, value: String)] {
        layers.compactMap { layer in layer.values[field].map { (layer.source, field.isList ? EnrichField.decode($0).joined(separator: " / ") : $0) } }
    }

    var isValid: Bool {
        fields.allSatisfy { field in value(field).map { !field.isNumber || Int($0) != nil } ?? true }
    }

    var changes: [EnrichField: String?] {
        var changes: [EnrichField: String?] = [:]
        for field in fields {
            if let value = value(field) {
                changes[field] = field.isList ? EnrichField.encode(value.components(separatedBy: "/").map(Self.trim).filter { !$0.isEmpty }) : value
            } else if edits[field] != nil {
                changes[field] = .some(nil)
            }
        }
        return changes
    }

    /// The typed value; nil when empty (a list of only separators is empty too). Only "/" separates names, as the
    /// hint says: "Earth, Wind & Fire" stays one artist.
    private func value(_ field: EnrichField) -> String? {
        let text = Self.trim(texts[field, default: ""])
        let empty = field.isList ? text.components(separatedBy: "/").allSatisfy { Self.trim($0).isEmpty } : text.isEmpty
        return empty ? nil : text
    }

    private static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension EnrichField {
    static let editable: [EnrichField] = [.title, .artists, .album, .albumArtist, .trackNo, .discNo, .year, .genre, .composers]

    var isNumber: Bool { self == .trackNo || self == .discNo || self == .year }

    var label: String {
        switch self {
        case .title: "标题"
        case .artists: "艺人"
        case .album: "专辑"
        case .albumArtist: "专辑艺人"
        case .trackNo: "曲序"
        case .discNo: "碟号"
        case .year: "年份"
        case .genre: "流派"
        case .composers: "作曲"
        case .lyrics: "歌词"
        case .cover: "封面"
        }
    }
}

extension TrackRow {
    func shown(_ field: EnrichField) -> String {
        switch field {
        case .title: title
        case .artists: artists.joined(separator: " / ")
        case .album: album ?? ""
        case .albumArtist: albumArtist ?? ""
        case .trackNo: trackNo.map(String.init) ?? ""
        case .discNo: discNo.map(String.init) ?? ""
        case .year: year.map(String.init) ?? ""
        case .genre: genre ?? ""
        case .composers: composers.joined(separator: " / ")
        case .lyrics, .cover: ""
        }
    }
}

extension AppModel {
    /// One song also gets its sources' values and its cover and lyrics; nothing is looked up online. Songs without a
    /// fingerprint (unreadable audio) can't carry edits.
    func editInfo(_ rows: [TrackRow]) async {
        let rows = rows.filter { $0.fingerprint != nil }
        guard let library, let first = rows.first?.fingerprint else { return }
        guard rows.count == 1 else {
            ui.sheet = .editor(InfoEditor(tracks: rows, edits: [:], unedited: []))
            return
        }
        let layers = await library.layers(first)
        let order = enrich?.settings.ordered ?? OnlineSource.allCases
        ui.sheet = .editor(InfoEditor(tracks: rows, edits: await library.userEdits(first), unedited: await library.rows([rows[0].id], without: [.user]),
                                      layers: order.compactMap { source in layers[source].map { (source, $0) } }))
    }

    /// A chosen cover is copied into the covers directory first.
    func saveInfo(_ editor: InfoEditor) async {
        ui.sheet = nil
        guard let library else { return }
        var changes = editor.changes
        if let fingerprint = editor.tracks.first?.fingerprint, editor.tracks.count == 1 {
            switch editor.cover {
            case .image(let url, _)?:
                do { changes[.cover] = try await enrich?.service.saveCover(url, fingerprint: fingerprint) } catch { enrich?.notice = "保存封面失败：\(error)" }
            case .removed?: changes[.cover] = .some(nil)
            case .text?, nil: break
            }
            switch editor.lyrics {
            case .text(let text)?: changes[.lyrics] = text
            case .removed?: changes[.lyrics] = .some(nil)
            case .image?, nil: break
            }
        }
        await library.setUserEdits(editor.tracks.compactMap(\.fingerprint), changes)
    }

    func revertInfo(_ rows: [TrackRow]) async {
        ui.sheet = nil
        await library?.revertUserEdits(rows.compactMap(\.fingerprint))
    }
}
