// make_icon.swift — render BallScroll's app icon: the Logitech Marble Mouse
// (M510) silhouette — a smooth pebble body with the red trackball at top-center
// (recessed in its bearing well) and the two click buttons + scroll wheel below.
// All iconset sizes are written to the given .iconset directory.
import AppKit

/// Superellipse (n > 2 → squircle/pebble): flat-ish top & bottom, full-width
/// shoulders — the M510's pebble silhouette. Centered on (cx, cy), half-sizes hw/hh.
func pebblePath(cx: CGFloat, cy: CGFloat, hw: CGFloat, hh: CGFloat, n: Double = 3.2) -> NSBezierPath {
    let path = NSBezierPath()
    let steps = 240
    for i in 0...steps {
        let t = (Double(i) / Double(steps)) * 2.0 * .pi
        let cosT = cos(t), sinT = sin(t)
        let x = hw * pow(abs(cosT), 2.0 / n) * (cosT >= 0 ? 1 : -1)
        let y = hh * pow(abs(sinT), 2.0 / n) * (sinT >= 0 ? 1 : -1)
        let p = NSPoint(x: cx + x, y: cy + y)
        if i == 0 { path.move(to: p) } else { path.line(to: p) }
    }
    path.close()
    return path
}

func render(size: Int, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(size)
    // --- Full-face dark rounded square (macOS app-icon silhouette). ---
    let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                          xRadius: s * 0.2237, yRadius: s * 0.2237)
    let face = NSGradient(colors: [NSColor(srgbRed: 0.145, green: 0.157, blue: 0.188, alpha: 1),
                                   NSColor(srgbRed: 0.078, green: 0.090, blue: 0.114, alpha: 1)])!
    face.draw(in: bg, angle: -90)

    let c = NSPoint(x: s / 2, y: s / 2)

    // --- The Marble Mouse body: pebble, wider than tall (back flares out),
    // dome-lit from above. M325 silhouette: broad shoulders, tapered tail. ---
    let hw = s * 0.315, hh = s * 0.34
    let pebble = pebblePath(cx: c.x, cy: c.y - s * 0.005, hw: hw, hh: hh)
    let bodyGrad = NSGradient(colors: [NSColor(srgbRed: 0.34, green: 0.365, blue: 0.415, alpha: 1),   // top light
                                       NSColor(srgbRed: 0.205, green: 0.22, blue: 0.25, alpha: 1),   // mid
                                       NSColor(srgbRed: 0.12, green: 0.132, blue: 0.157, alpha: 1)]) // bottom
    bodyGrad?.draw(in: pebble, angle: -90)
    // subtle rim so the body reads against the dark face
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16).setStroke()
    pebble.lineWidth = max(1, s * 0.005)
    pebble.stroke()

    // --- Recessed well around the ball (the bearing contour). Ball sits at
    // top-center of the pebble, like the M510. ---
    let ballC = NSPoint(x: c.x, y: c.y + hh * 0.52)
    let ballR = s * 0.13
    let wellR = s * 0.168
    NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.4).setStroke()
    let well = NSBezierPath(ovalIn: CGRect(x: ballC.x - wellR, y: ballC.y - wellR,
                                           width: wellR * 2, height: wellR * 2))
    well.lineWidth = s * 0.024
    well.stroke()
    // faint light rim just inside the dark groove → machined recess look
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.1).setStroke()
    let rim = NSBezierPath(ovalIn: CGRect(x: ballC.x - wellR + s * 0.02, y: ballC.y - wellR + s * 0.02,
                                          width: (wellR - s * 0.02) * 2, height: (wellR - s * 0.02) * 2))
    rim.lineWidth = s * 0.01
    rim.stroke()

    // --- The red ball (3D, glossy). ---
    let ballRect = CGRect(x: ballC.x - ballR, y: ballC.y - ballR, width: ballR * 2, height: ballR * 2)
    let sphere = NSGradient(colors: [NSColor(srgbRed: 0.99, green: 0.47, blue: 0.42, alpha: 1),   // light
                                     NSColor(srgbRed: 0.93, green: 0.20, blue: 0.23, alpha: 1),   // mid
                                     NSColor(srgbRed: 0.58, green: 0.06, blue: 0.10, alpha: 1)]) // edge
    sphere?.draw(in: NSBezierPath(ovalIn: ballRect), relativeCenterPosition: NSPoint(x: -0.32, y: 0.4))
    let hlGrad = NSGradient(colors: [NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.8),
                                     NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)])!
    hlGrad.draw(in: NSBezierPath(ovalIn: CGRect(x: ballC.x - ballR * 0.48, y: ballC.y + ballR * 0.15,
                                                width: ballR * 0.62, height: ballR * 0.42)), angle: -65)

    // --- Two clearly-separate click buttons (M325 split LMB/RMB) with a small
    // scroll wheel in the center gap — kept large enough to read at 16 px. ---
    let btnW = s * 0.128, btnH = s * 0.075
    let off: CGFloat = s * 0.068   // inner edge of each button, from center
    let btnY = c.y - s * 0.152
    for side in [CGFloat(-1), 1] {
        let x = c.x + (side < 0 ? -(off + btnW) : off)
        let r = CGRect(x: x, y: btnY, width: btnW, height: btnH)
        let b = NSBezierPath(roundedRect: r, xRadius: s * 0.018, yRadius: s * 0.018)
        let btnGrad = NSGradient(colors: [NSColor(srgbRed: 0.46, green: 0.49, blue: 0.54, alpha: 1),
                                          NSColor(srgbRed: 0.31, green: 0.34, blue: 0.39, alpha: 1)])!
        btnGrad.draw(in: b, angle: -90)
    }

    // --- Scroll wheel: a vertical capsule sitting in the center gap, same height
    // as the buttons so it reads as a distinct control at every size. ---
    let wheelW = s * 0.046, wheelH = btnH
    let wheelRect = CGRect(x: c.x - wheelW / 2, y: btnY, width: wheelW, height: wheelH)
    let wheelGrad = NSGradient(colors: [NSColor(srgbRed: 0.52, green: 0.55, blue: 0.61, alpha: 1),
                                        NSColor(srgbRed: 0.35, green: 0.38, blue: 0.43, alpha: 1)])!
    wheelGrad.draw(in: NSBezierPath(roundedRect: wheelRect, xRadius: s * 0.013, yRadius: s * 0.013), angle: -90)
    // wheel grooves (horizontal lines) so it reads as a wheel, not a bar
    NSColor(srgbRed: 0.2, green: 0.215, blue: 0.245, alpha: 0.9).setStroke()
    for i in 1...3 {
        let gy = btnY + wheelH * (CGFloat(i) / 4.0)
        let line = NSBezierPath()
        line.move(to: NSPoint(x: wheelRect.minX + s * 0.006, y: gy))
        line.line(to: NSPoint(x: wheelRect.maxX - s * 0.006, y: gy))
        line.lineWidth = max(1, s * 0.006)
        line.stroke()
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
