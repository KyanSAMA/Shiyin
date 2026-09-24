import Foundation

public struct LyricLine: Sendable, Equatable {
    public var time: Double
    public var text: String
    public var translation: String?
    public var isCredit = false

    public init(time: Double, text: String, translation: String? = nil, isCredit: Bool = false) {
        self.time = time
        self.text = text
        self.translation = translation
        self.isCredit = isCredit
    }
}

public struct LyricCredits: Sendable, Equatable {
    public var composers: [String] = []
    public var lyricists: [String] = []
    public var arrangers: [String] = []
}

public enum Lyrics: Sendable, Equatable {
    case synced([LyricLine])
    case unsynced([String])

    /// Index of the line being sung at `time`; `lead` shows a line slightly before its timestamp.
    public func index(at time: Double, lead: Double = 0.15) -> Int? {
        guard case .synced(let lines) = self else { return nil }
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].time <= time + lead { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }

    public var credits: LyricCredits {
        guard case .synced(let lines) = self else { return LyricCredits() }
        var credits = LyricCredits()
        for line in lines where line.isCredit {
            guard let (key, value) = LRCParser.credit(line.text) else { continue }
            let names = PersonSplitter.split([value])
            switch LRCParser.creditRoles[key.lowercased()] {
            case .composer: credits.composers += names
            case .lyricist: credits.lyricists += names
            case .arranger: credits.arrangers += names
            default: break
            }
        }
        return credits
    }
}

public enum LRCParser {
    private nonisolated(unsafe) static let timeTag = /\[([0-9]{1,3}):([0-9]{1,2})(?:[.:]([0-9]{1,3}))?\]/
    private nonisolated(unsafe) static let metaTag = /\[([A-Za-z#]+):([^\]]*)\]/
    private nonisolated(unsafe) static let wordTime = /<[0-9]{1,3}:[0-9]{1,2}(?:[.:][0-9]{1,3})?>/
    private nonisolated(unsafe) static let creditLine = /([^:：，。！？,!?]{1,12}?)\s*[:：]\s*(.+)/
    private static let creditWindow = 15

    static let creditRoles: [String: PersonRole] = [
        "作曲": .composer, "曲": .composer, "作曲者": .composer, "composer": .composer, "composed by": .composer,
        "music": .composer, "music by": .composer,
        "作词": .lyricist, "作詞": .lyricist, "词": .lyricist, "詞": .lyricist, "作词者": .lyricist, "作詞者": .lyricist,
        "lyricist": .lyricist, "lyrics": .lyricist, "lyrics by": .lyricist,
        "编曲": .arranger, "編曲": .arranger, "arranger": .arranger, "arrangement": .arranger, "arranged by": .arranger,
    ]

    public static func parse(_ raw: String) -> Lyrics? {
        var entries: [(ms: Int, order: Int, text: String)] = []
        var unsynced: [String] = []
        var offsetMs = 0.0
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = rawLine.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
            if let meta = rest.trimmingCharacters(in: .whitespaces).wholeMatch(of: metaTag) {
                if meta.1.lowercased() == "offset" { offsetMs = Double(meta.2.trimmingCharacters(in: .whitespaces)) ?? 0 }
                continue
            }
            var stamps: [Int] = []
            while let tag = rest.prefixMatch(of: timeTag) {
                stamps.append(milliseconds(tag.1, tag.2, tag.3))
                rest = rest[tag.range.upperBound...].drop(while: \.isWhitespace)
            }
            let content = rest.replacing(wordTime, with: "").trimmingCharacters(in: .whitespaces)
            if stamps.isEmpty {
                if !content.isEmpty { unsynced.append(content) }
            } else {
                for ms in stamps { entries.append((ms, entries.count, content)) }
            }
        }
        guard !entries.isEmpty else { return unsynced.isEmpty ? nil : .unsynced(unsynced) }

        entries.sort { ($0.ms, $0.order) < ($1.ms, $1.order) }
        var lines: [LyricLine] = []
        var i = 0
        while i < entries.count {
            let ms = entries[i].ms
            var texts: [String] = []
            while i < entries.count, entries[i].ms == ms {
                if !texts.contains(entries[i].text) { texts.append(entries[i].text) }
                i += 1
            }
            if texts.count > 1 { texts.removeAll(where: \.isEmpty) }
            let time = max(0, (Double(ms) - offsetMs) / 1000)
            if texts.count > 1, texts.allSatisfy(isCreditLike) {
                lines += texts.map { LyricLine(time: time, text: $0) }
            } else {
                lines.append(LyricLine(time: time, text: texts[0],
                                       translation: texts.count > 1 ? texts.dropFirst().joined(separator: " / ") : nil))
            }
        }
        markCredits(&lines)
        return .synced(lines)
    }

    /// `作曲 : Ayase` → ("作曲", "Ayase").
    static func credit(_ text: String) -> (String, String)? {
        guard let match = text.wholeMatch(of: creditLine) else { return nil }
        return (match.1.trimmingCharacters(in: .whitespaces), match.2.trimmingCharacters(in: .whitespaces))
    }

    /// Known role keys, or any key of 2+ characters (制作人, 混音…); single-character keys like 男/女 are dialogue.
    private static func isCreditLike(_ text: String) -> Bool {
        guard let (key, _) = credit(text) else { return false }
        return creditRoles[key.lowercased()] != nil || key.count >= 2
    }

    /// The credit block sits near the top and starts with a known role key; lines before it (e.g. "Title - Artist")
    /// are skipped, and the first non-credit line after it ends the block.
    private static func markCredits(_ lines: inout [LyricLine]) {
        var inBlock = false
        for i in lines.indices.prefix(creditWindow) where !lines[i].text.isEmpty {
            let key = credit(lines[i].text)?.0
            if let key, creditRoles[key.lowercased()] != nil || (inBlock && key.count >= 2) {
                lines[i].isCredit = true
                inBlock = true
            } else if inBlock {
                return
            }
        }
    }

    private static func milliseconds(_ minutes: Substring, _ seconds: Substring, _ fraction: Substring?) -> Int {
        let whole = (Int(minutes) ?? 0) * 60_000 + (Int(seconds) ?? 0) * 1000
        guard let fraction, let value = Int(fraction) else { return whole }
        return whole + [0, 100, 10, 1][fraction.count] * value
    }
}
