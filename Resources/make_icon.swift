// make_icon.swift — render BallScroll's app icon (rounded-rect gradient +
// arrow.up.arrow.down glyph, matching the menu-bar symbol) at all iconset sizes.
import AppKit

func render(size: Int, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(size)
    // Rounded-rect background (Apple-style ~22.4% radius), blue→purple gradient.
    let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                          xRadius: s * 0.2237, yRadius: s * 0.2237)
    let grad = NSGradient(colors: [NSColor(srgbRed: 0.31, green: 0.42, blue: 0.98, alpha: 1),
                                   NSColor(srgbRed: 0.45, green: 0.24, blue: 0.86, alpha: 1)])!
    grad.draw(in: bg, angle: -90)

    // White SF Symbol arrow.up.arrow.down (the scroll gesture), ~52% of the face.
    if let base = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil) {
        let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.52, weight: .semibold)
        if let sym = base.withSymbolConfiguration(cfg) {
            let tinted = NSImage(size: sym.size)
            tinted.lockFocus()
            sym.draw(at: .zero, from: NSRect(origin: .zero, size: sym.size),
                     operation: .sourceOver, fraction: 1)
            NSColor.white.set()
            NSRect(origin: .zero, size: sym.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            let d = sym.size
            // Slightly optical center (up-arrow reads better a touch high).
            let origin = NSPoint(x: (s - d.width) / 2, y: (s - d.height) / 2 + s * 0.015)
            tinted.draw(at: origin, from: NSRect(origin: .zero, size: d),
                        operation: .sourceOver, fraction: 1)
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    if let png = rep.representation(using: .png, properties: [:]) {
        try! png.write(to: URL(fileURLWithPath: path))
    }
}

let dir = CommandLine.arguments[1]  // iconset directory
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),   ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),   ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),("icon_512x512@2x.png", 1024),
]
for (name, px) in sizes { render(size: px, to: "\(dir)/\(name)") }
print("iconset written to \(dir)")
