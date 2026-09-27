// Renders the app icon (run by bundle.sh): swift Scripts/make-icon.swift <out.icns>
import AppKit

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ hex: UInt32) {
    color(hex).setFill()
    NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)).fill()
}

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
    // A record half out of its sleeve, on a cream ground.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    color(0xF5EFE6).setFill()
    shape.fill()
    // The sleeve is a little larger than the record, as a real LP's.
    circle(640, 512, 235, 0x16161A)
    NSColor(white: 1, alpha: 0.1).setStroke()
    for r in stride(from: 218.0, to: 99, by: -17.6) {
        let groove = NSBezierPath(ovalIn: NSRect(x: 640 - r, y: 512 - r, width: 2 * r, height: 2 * r))
        groove.lineWidth = 3
        groove.stroke()
    }
    circle(640, 512, 80, 0xFFC53D)
    circle(640, 512, 11, 0x16161A)
    NSGraphicsContext.saveGraphicsState()
    let sleeve = NSShadow()
    sleeve.shadowColor = .black.withAlphaComponent(0.18)
    sleeve.shadowOffset = NSSize(width: 10, height: 0)
    sleeve.shadowBlurRadius = 24
    sleeve.set()
    color(0xF0563A).setFill()
    NSBezierPath(roundedRect: NSRect(x: 140, y: 252, width: 520, height: 520), xRadius: 34, yRadius: 34).fill()
    NSGraphicsContext.restoreGraphicsState()
    circle(400, 512, 32, 0xF5EFE6)
    NSColor(white: 1, alpha: 0.22).setFill()
    NSBezierPath(roundedRect: NSRect(x: 178, y: 292, width: 130, height: 26), xRadius: 13, yRadius: 13).fill()
    NSGraphicsContext.restoreGraphicsState()
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
