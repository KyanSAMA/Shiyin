import CoreGraphics
import CoreImage

/// Now Playing background: a tiny, heavily blurred, darkened copy of the cover, returned as a plain bitmap.
public enum Backdrop {
    private static let context = CIContext()

    public static func render(_ cover: CGImage, side: Int = 96) -> CGImage? {
        let scale = CGFloat(side) / CGFloat(max(cover.width, cover.height, 1))
        let small = CIImage(cgImage: cover).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let styled = small.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(side) / 8)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35, kCIInputBrightnessKey: -0.22])
            .cropped(to: small.extent)
        return context.createCGImage(styled, from: small.extent)
    }
}
