import Foundation

/// Folds a separate translation LRC into the original: under each of an original line's timestamps, its translation
/// follows with that very timestamp text, which `LRCParser` reads as the line's translation. Timestamps match to the
/// centisecond, whatever their spelling ([00:03.45] / [00:03.450] / [00:03:45]).
public enum LyricsMerge {
    public static func merge(_ original: String, translation: String?) -> String {
        guard let translation else { return original }
        var translated: [Int: String] = [:]
        for line in translation.split(whereSeparator: \.isNewline) {
            let (stamps, rest) = split(line)
            let text = rest.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            for stamp in stamps { translated[stamp.centiseconds] = text }
        }
        return original.split(whereSeparator: \.isNewline).map { line -> String in
            let (stamps, text) = split(line)
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return String(line) }
            return ([String(line)] + stamps.compactMap { stamp in translated[stamp.centiseconds].map { stamp.tag + $0 } })
                .joined(separator: "\n")
        }.joined(separator: "\n")
    }

    private nonisolated(unsafe) static let stamp = /^\s*(\[(\d+):(\d+)(?:[.:](\d+))?\])/

    /// Leading timestamps (value, and the tag as written), and the text after them.
    private static func split(_ line: Substring) -> ([(centiseconds: Int, tag: String)], Substring) {
        var rest = line, stamps: [(Int, String)] = []
        while let match = rest.firstMatch(of: stamp) {
            let fraction = match.4.map { Int(String($0.prefix(2)).padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0 } ?? 0
            stamps.append(((Int(match.2)! * 60 + Int(match.3)!) * 100 + fraction, String(match.1)))
            rest = rest[match.range.upperBound...]
        }
        return (stamps, rest)
    }
}
