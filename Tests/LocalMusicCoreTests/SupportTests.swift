import CoreGraphics
import Foundation
import Testing
@testable import LocalMusicCore

struct JSONQueryTests {
    private let state: [String: Any] = [
        "ui": ["sidebar": "songs", "firstRows": ["群青", "怪獣"]],
        "player": ["position": 3.02, "isPlaying": true, "title": "Part 2"],
        "snapshots": ["shell-dark": ["isLikelyBlank": false]],
    ]

    @Test func resolvesNestedPathsAndIndices() {
        #expect(JSONQuery.value(at: "ui.sidebar", in: state) as? String == "songs")
        #expect(JSONQuery.value(at: "ui.firstRows.1", in: state) as? String == "怪獣")
        #expect(JSONQuery.value(at: "snapshots.shell-dark.isLikelyBlank", in: state) as? Bool == false)
        #expect(JSONQuery.value(at: "ui.firstRows.9", in: state) == nil)
        #expect(JSONQuery.value(at: "player.title.x", in: state) == nil)
    }

    @Test func evaluatesComparators() throws {
        func check(_ step: [String: Any], _ path: String) throws -> Bool {
            try #require(Comparison(step)).matches(JSONQuery.value(at: path, in: state))
        }
        #expect(try check(["equals": "songs"], "ui.sidebar"))
        #expect(try check(["equals": true], "player.isPlaying"))
        #expect(try check(["equals": false], "snapshots.shell-dark.isLikelyBlank"))
        #expect(try !check(["equals": "albums"], "ui.sidebar"))
        #expect(try check(["approx": 3.0, "tol": 0.3], "player.position"))
        #expect(try !check(["approx": 2.0, "tol": 0.3], "player.position"))
        #expect(try check(["lt": 4], "player.position"))
        #expect(try check(["gt": 3], "player.position"))
        #expect(try !check(["gt": 1], "player.title"))
        #expect(try check(["contains": "怪獣"], "ui.firstRows"))
        #expect(try check(["contains": "art"], "player.title"))
        #expect(try check(["equals": NSNull()], "missing.path"))
        #expect(Comparison(["path": "x"]) == nil)
    }
}

struct ImageStatsTests {
    private func image(_ fill: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        let (w, h) = (64, 48)
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let (r, g, b) = fill(x, y)
                let i = (y * w + x) * 4
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    @Test func flagsUniformImageAsBlank() throws {
        let stats = try #require(ImageStats(image: image { _, _ in (30, 30, 30) }, stride: 1))
        #expect(stats.uniqueColors == 1)
        #expect(stats.isLikelyBlank)
    }

    @Test func acceptsDetailedImage() throws {
        let stats = try #require(ImageStats(image: image { x, y in (UInt8(x * 4), UInt8(y * 5), 128) }, stride: 1))
        #expect(stats.width == 64 && stats.height == 48)
        #expect(stats.uniqueColors > 100)
        #expect(!stats.isLikelyBlank)
    }
}
