import CoreGraphics
import Foundation
import ImageIO

/// Cheap "did we capture something real" signal for self-test snapshots.
public struct ImageStats: Sendable {
    public let width: Int
    public let height: Int
    public let uniqueColors: Int
    public let lumaStdDev: Double

    public var isLikelyBlank: Bool { lumaStdDev < 2 || uniqueColors < 16 }

    public init?(image: CGImage, stride: Int = 4) {
        let width = image.width, height = image.height
        self.width = width
        self.height = height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var colors = Set<UInt32>()
        var count = 0.0, sum = 0.0, sumSquares = 0.0
        for y in Swift.stride(from: 0, to: height, by: stride) {
            for x in Swift.stride(from: 0, to: width, by: stride) {
                let i = y * bytesPerRow + x * 4
                let r = pixels[i], g = pixels[i + 1], b = pixels[i + 2]
                colors.insert(UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b))
                let luma = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
                count += 1
                sum += luma
                sumSquares += luma * luma
            }
        }
        uniqueColors = colors.count
        let mean = sum / max(count, 1)
        lumaStdDev = (max(sumSquares / max(count, 1) - mean * mean, 0)).squareRoot()
    }

    public init?(contentsOf url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        self.init(image: image)
    }

    public var json: [String: Any] {
        ["width": width, "height": height, "uniqueColors": uniqueColors,
         "lumaStdDev": (lumaStdDev * 100).rounded() / 100, "isLikelyBlank": isLikelyBlank]
    }
}
