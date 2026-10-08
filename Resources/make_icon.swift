// make_icon.swift — render BallScroll's app icon: a trackball. A dark rounded-
// square device body with a red 3D ball (the "red ball") and a recessed groove
// ring around it (the trackball's bearing contour). Written to all iconset sizes.
import AppKit

func render(size: Int, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(size)
    // --- Device body: dark rounded square (the trackball housing). ---
    let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                          xRadius: s * 0.2237, yRadius: s * 0.2237)
    let body = NSGradient(colors: [NSColor(srgbRed: 0.176, green: 0.192, blue: 0.235, alpha: 1),
                                   NSColor(srgbRed: 0.106, green: 0.122, blue: 0.157, alpha: 1)])!
    body.draw(in: bg, angle: -90)

    // --- Recessed groove ring (the trackball bearing contour). ---
    let c = NSPoint(x: s / 2, y: s / 2)
    let grooveR = s * 0.315
    let groove = NSBezierPath(ovalIn: CGRect(x: c.x - grooveR, y: c.y - grooveR,
                                             width: grooveR * 2, height: grooveR * 2))
    NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.35).setStroke()
    groove.lineWidth = s * 0.028
    groove.stroke()
    // faint light rim just inside the dark groove → reads as a machined recess
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08).setStroke()
    let rim = NSBezierPath(ovalIn: CGRect(x: c.x - grooveR + s*0.02, y: c.y - grooveR + s*0.02,
                                          width: (grooveR - s*0.02) * 2, height: (grooveR - s*0.02) * 2))
    rim.lineWidth = s * 0.012
    rim.stroke()

    // --- The red ball (3D shaded sphere). ---
    let ballR = s * 0.215
    let ballRect = CGRect(x: c.x - ballR, y: c.y - ballR, width: ballR * 2, height: ballR * 2)
    NSGraphicsContext.current?.compositingOperation = .sourceOver
    let sphere = NSGradient(colors: [NSColor(srgbRed: 0.98, green: 0.42, blue: 0.36, alpha: 1),   // light
                                     NSColor(srgbRed: 0.90, green: 0.18, blue: 0.20, alpha: 1),   // mid
                                     NSColor(srgbRed: 0.62, green: 0.07, blue: 0.11, alpha: 1)]) // dark edge
    sphere?.draw(in: NSBezierPath(ovalIn: ballRect), relativeCenterPosition: NSPoint(x: -0.35, y: 0.4))
    // specular highlight (top-left) for the glossy look
    let hlW = ballR * 0.62, hlH = ballR * 0.44
    let hlRect = CGRect(x: c.x - ballR*0.5, y: c.y + ballR*0.18, width: hlW, height: hlH)
    let hl = NSBezierPath(ovalIn: hlRect)
    let hlGrad = NSGradient(colors: [NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85),
                                     NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)])!
    hlGrad.draw(in: hl, angle: -65)

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
