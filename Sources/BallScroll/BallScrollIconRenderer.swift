//  BallScrollIconRenderer.swift — draws the Marble Mouse app icon (pebble body,
//  red ball in a recessed well + texture dots, two click buttons + grooved wheel).
//  Shared by the tray menu-bar icon (template: monochrome + alpha cutouts so it
//  tints correctly in light/dark bars AND stays detailed, not a solid box) and
//  the settings footer / decorative ball.

import AppKit

enum BallScrollIconRenderer {

    /// Superellipse (n > 2 → pebble): flat-ish top & bottom, full-width shoulders.
    static func pebblePath(cx: CGFloat, cy: CGFloat, hw: CGFloat, hh: CGFloat, n: Double = 3.2) -> NSBezierPath {
        let path = NSBezierPath()
        let steps = 120
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

    /// Fixed tiny texture speckles on the ball — a dense, even golden-angle
    /// field like the real Marble Mouse surface. Each entry: position in
    /// ball-RADIUS units (magnitude ≤ 0.96 so they stay on the lit face) plus
    /// its radius as a fraction of ballR (≈2–4% of the full diameter → "very
    /// small" dots that read as surface texture, not big blobs). Deterministic
    /// (no RNG) so the icon and settings ball always match.
    static let ballSpeckles: [(p: CGPoint, r: CGFloat)] = {
        let N = 128
        let golden = CGFloat(2.3999632297)          // π(3 − √5), golden angle
        let maxR: CGFloat = 0.94                     // keep speckles off the limb
        var out: [(CGPoint, CGFloat)] = []
        for i in 0..<N {
            let t = (CGFloat(i) + 0.5) / CGFloat(N)
            let rad = maxR * t.squareRoot()          // uniform-area disk fill
            let ang = CGFloat(i) * golden
            let p = CGPoint(x: rad * cos(ang), y: rad * sin(ang))
            // Per-speckle size jitter (deterministic) so it looks organic, not a
            // uniform dot grid. Base ~0.027 of ballR → ~5% diameter; jitter ±40%.
            let h = CGFloat(sin(Double(i) * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)
            let jitter = 0.6 + abs(h).truncatingRemainder(dividingBy: 1) * 0.8   // 0.6…1.4
            out.append((p, 0.027 * jitter))
        }
        return out
    }()

    /// Draw the Marble Mouse device into a context of size `s` (in points).
    ///
    /// template == false: full color — dark pebble, glossy red ball with texture
    /// dots, grey buttons + grooved wheel.
    /// template == true: monochrome for the menu bar. The body is a solid alpha
    /// silhouette and the ball socket, click buttons and wheel are CUT OUT (made
    /// transparent) so the menu-bar background shows through. That keeps it a
    /// recognizable, DETAILED trackball at 18pt instead of one merged blob/box —
    /// macOS then tints the silhouette for light/dark bars via isTemplate.
    static func drawDevice(in rep: NSBitmapImageRep, s: CGFloat, template: Bool) {
        let ctx = NSGraphicsContext.current

        // ---- Geometry (computed once, shared by both render modes) ----
        let c = NSPoint(x: s / 2, y: s / 2)
        let hw = s * 0.315, hh = s * 0.34
        let pebble = pebblePath(cx: c.x, cy: c.y - s * 0.005, hw: hw, hh: hh)
        let ballC = NSPoint(x: c.x, y: c.y + hh * 0.52)
        let wellR = s * 0.168
        let ballR = s * 0.13
        let ballRect = CGRect(x: ballC.x - ballR, y: ballC.y - ballR, width: ballR * 2, height: ballR * 2)
        let btnW = s * 0.132, btnH = s * 0.078
        let off: CGFloat = s * 0.066
        let btnY = c.y - s * 0.152
        let leftBtn  = CGRect(x: c.x - (off + btnW), y: btnY, width: btnW, height: btnH)
        let rightBtn = CGRect(x: c.x + off, y: btnY, width: btnW, height: btnH)
        let wheelW = s * 0.05
        let wheelRect = CGRect(x: c.x - wheelW / 2, y: btnY, width: wheelW, height: btnH)

        // ---- Body (solid silhouette in template; grey pebble in color) ----
        ctx?.compositingOperation = .sourceOver
        if template { NSColor.black.setFill() }
        else { NSColor(srgbRed: 0.27, green: 0.295, blue: 0.34, alpha: 1).setFill() }
        pebble.fill()

        if template {
            // Cut the details as transparent holes → menu-bar bg shows through,
            // so the icon reads as a trackball with a ball socket + buttons.
            ctx?.compositingOperation = .clear
            // Ball socket (leave a rim so it looks like an indented well).
            let socketR = ballR * 0.90
            NSBezierPath(ovalIn: CGRect(x: ballC.x - socketR, y: ballC.y - socketR,
                                        width: socketR * 2, height: socketR * 2)).fill()
            // Click-button + wheel slots.
            NSBezierPath(roundedRect: leftBtn.insetBy(dx: s * 0.012, dy: s * 0.014),
                         xRadius: s * 0.018, yRadius: s * 0.018).fill()
            NSBezierPath(roundedRect: rightBtn.insetBy(dx: s * 0.012, dy: s * 0.014),
                         xRadius: s * 0.018, yRadius: s * 0.018).fill()
            NSBezierPath(roundedRect: wheelRect.insetBy(dx: s * 0.008, dy: s * 0.014),
                         xRadius: s * 0.013, yRadius: s * 0.013).fill()
            ctx?.compositingOperation = .sourceOver
        } else {
            // Recessed well around the ball.
            NSColor.black.withAlphaComponent(0.4).setStroke()
            let well = NSBezierPath(ovalIn: CGRect(x: ballC.x - wellR, y: ballC.y - wellR,
                                                   width: wellR * 2, height: wellR * 2))
            well.lineWidth = max(1, s * 0.024)
            well.stroke()

            // Glossy red ball + highlight.
            let sphere = NSGradient(colors: [NSColor(srgbRed: 0.99, green: 0.47, blue: 0.42, alpha: 1),
                                             NSColor(srgbRed: 0.93, green: 0.20, blue: 0.23, alpha: 1),
                                             NSColor(srgbRed: 0.58, green: 0.06, blue: 0.10, alpha: 1)])!
            sphere.draw(in: NSBezierPath(ovalIn: ballRect), relativeCenterPosition: NSPoint(x: -0.32, y: 0.4))
            let hlGrad = NSGradient(colors: [NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.8),
                                             NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)])!
            hlGrad.draw(in: NSBezierPath(ovalIn: CGRect(x: ballC.x - ballR * 0.48, y: ballC.y + ballR * 0.15,
                                                        width: ballR * 0.62, height: ballR * 0.42)), angle: -65)

            // Tiny texture speckles on the ball surface (dense, even field — like
            // the real Marble Mouse). Per-speckle radius is stored so each dot is
            // genuinely small and varied, reading as surface texture.
            NSColor.black.withAlphaComponent(0.34).setFill()
            for sp in ballSpeckles {
                let dx = sp.p.x * ballR, dy = sp.p.y * ballR
                let dotR = max(0.5, sp.r * ballR)   // clamp so they never vanish
                NSBezierPath(ovalIn: CGRect(x: ballC.x + dx - dotR, y: ballC.y + dy - dotR,
                                            width: dotR * 2, height: dotR * 2)).fill()
            }

            // Grey click buttons + grooved wheel.
            for b in [leftBtn, rightBtn] {
                NSColor(srgbRed: 0.42, green: 0.45, blue: 0.5, alpha: 1).setFill()
                NSBezierPath(roundedRect: b, xRadius: s * 0.018, yRadius: s * 0.018).fill()
            }
            NSColor(srgbRed: 0.5, green: 0.53, blue: 0.58, alpha: 1).setFill()
            NSBezierPath(roundedRect: wheelRect, xRadius: s * 0.013, yRadius: s * 0.013).fill()
            NSColor(srgbRed: 0.2, green: 0.215, blue: 0.245, alpha: 0.9).setStroke()
            for i in 1...3 {
                let gy = btnY + btnH * (CGFloat(i) / 4.0)
                let line = NSBezierPath()
                line.move(to: NSPoint(x: wheelRect.minX + s * 0.006, y: gy))
                line.line(to: NSPoint(x: wheelRect.maxX - s * 0.006, y: gy))
                line.lineWidth = max(1, s * 0.006)
                line.stroke()
            }
        }
    }

    /// Small colored app icon (settings footer / About) — the full Marble Mouse.
    static func appIcon(sizePt: CGFloat, scale: CGFloat = 2) -> NSImage {
        let px = Int(sizePt * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return NSImage(size: NSSize(width: sizePt, height: sizePt))
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let S = CGFloat(px)
        // Dark rounded-square face, then the device.
        let bg = NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
                              xRadius: S * 0.2237, yRadius: S * 0.2237)
        let face = NSGradient(colors: [NSColor(srgbRed: 0.145, green: 0.157, blue: 0.188, alpha: 1),
                                       NSColor(srgbRed: 0.078, green: 0.090, blue: 0.114, alpha: 1)])!
        face.draw(in: bg, angle: -90)
        drawDevice(in: rep, s: S, template: false)
        NSGraphicsContext.restoreGraphicsState()

        let img = NSImage(size: NSSize(width: sizePt, height: sizePt))
        img.addRepresentation(rep)
        return img
    }

    /// Menu-bar (tray) icon: the Marble Mouse device as a monochrome template
    /// with transparent detail cutouts. `warning` adds an "!" badge when
    /// permissions/device are missing. isTemplate → macOS tints it per bar theme.
    static func menuBarIcon(warning: Bool) -> NSImage {
        let sizePt: CGFloat = 18, scale: CGFloat = 2
        let px = Int(sizePt * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let S = CGFloat(px)
        drawDevice(in: rep, s: S, template: true)
        if warning {
            // "!" badge top-right (drawn after cutouts, solid).
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            let dotRect = CGRect(x: S * 0.74, y: S * 0.82 + S * 0.14, width: S * 0.09, height: S * 0.09)
            NSBezierPath(ovalIn: dotRect).fill()
            let barW = S * 0.05, barH = S * 0.17
            let barRect = CGRect(x: S * 0.74 + S * 0.02, y: S * 0.82 - S * 0.10, width: barW, height: barH)
            NSBezierPath(roundedRect: barRect, xRadius: S * 0.025, yRadius: S * 0.025).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        let img = NSImage(size: NSSize(width: sizePt, height: sizePt))
        img.addRepresentation(rep)
        img.isTemplate = true
        img.accessibilityDescription = warning ? "BallScroll — attention needed" : "BallScroll"
        return img
    }
}
