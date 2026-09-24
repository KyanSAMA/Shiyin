// Renders the app icon (run by bundle.sh): swift Scripts/make-icon.swift <out.icns>
import AppKit

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
    // macOS icon grid: an 824-point rounded square centred on the 1024 canvas.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 24
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(srgbRed: 0.98, green: 0.45, blue: 0.36, alpha: 1), NSColor(srgbRed: 0.55, green: 0.22, blue: 0.78, alpha: 1),
                        NSColor(srgbRed: 0.16, green: 0.14, blue: 0.45, alpha: 1)])!.draw(in: shape, angle: -65)
    let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold).applying(.init(paletteColors: [.white]))
    if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let size = note.size
        note.draw(in: NSRect(x: 512 - size.width / 2 - 10, y: 512 - size.height / 2, width: size.width, height: size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(filePath: CommandLine.arguments[1])
let set = out.deletingPathExtension().appendingPathExtension("iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try render(points).write(to: set.appending(path: "icon_\(points)x\(points).png"))
    try render(points * 2).write(to: set.appending(path: "icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", set.path, "-o", out.path]
try iconutil.run()
iconutil.waitUntilExit()
try FileManager.default.removeItem(at: set)
exit(iconutil.terminationStatus)
