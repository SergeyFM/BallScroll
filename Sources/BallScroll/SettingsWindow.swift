//  SettingsWindow.swift — single-window settings (NFR-1, AM parity).
//  No tabs: scroll-button config on top, all other settings below it.
//
//  UI details per user feedback:
//   * window uses a fixed .aqua appearance so toggles/sliders keep their colors
//     when the window loses focus (no "everything goes grey" on app switch);
//   * every option has a small "?" help bubble (NSPopover — always visible,
//     shown on hover/click of the icon) explaining what it does;
//   * "Scroll deadzone" range is 0–100 px;
//   * the window sizes exactly to its content (no empty space at the bottom);
//   * the decorative red ball carries texture speckles like a real Marble Mouse.

import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let onClosed: () -> Void

    init(prefs: PreferencesModel, onClosed: @escaping () -> Void) {
        self.onClosed = onClosed

        let root = SettingsView(prefs: prefs)
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hosting)
        window.title = "BallScroll"
        // .resizable omitted → fixed-width single page, no tabs. Height follows
        // the content exactly (NSHostingController keeps preferredContentSize in
        // sync) → no dead space below the last row.
        window.styleMask = [.titled, .closable, .miniaturizable]
        // Fixed appearance: controls keep full color even when the window is not
        // key / another app is active (no greyed-out unfocused look).
        window.appearance = NSAppearance(named: .aqua)

        super.init(window: window)
        // Make ourselves the delegate so windowWillClose fires when the user
        // closes the window (otherwise onClosed never runs and the activation
        // policy stays .regular / Dock icon lingers).
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { onClosed() }
}

// MARK: - Help. We use SwiftUI's native `.help("…")` tooltips on each option —
// hovering the row shows a bubble just above it (no separate "?" icon). This is
// the standard macOS affordance and needs no @State / NSViewRepresentable, so it
// compiles cleanly under standalone `xcrun swiftc`.

// MARK: - Single settings page

struct SettingsView: View {
    @ObservedObject var prefs: PreferencesModel

    // Log-scaled inertia DECAY TIME: slider position 0…1 ↔ decay 25…1000 ms.
    // The lever means "how long after release it takes to brake smoothly to a stop".
    // Log scale = fine precision at the low end (25…~160 ms occupies the left ~48%
    // of travel in sub-millisecond steps) — that's where "barely any inertia" lives;
    // coarser toward 1000 ms (a long roll-out).
    private let INERTIA_DECAY_MIN: Double = 25     // ms — imperceptible
    private let INERTIA_DECAY_MAX: Double = 1000   // ms — long roll-out

    var inertiaDecayBinding: Binding<Double> {
        Binding(
            get: {
                let s = min(max(prefs.inertiaDecayMs, INERTIA_DECAY_MIN), INERTIA_DECAY_MAX)
                return log(s / INERTIA_DECAY_MIN) / log(INERTIA_DECAY_MAX / INERTIA_DECAY_MIN)
            },
            set: { p in
                let s = INERTIA_DECAY_MIN * pow(INERTIA_DECAY_MAX / INERTIA_DECAY_MIN, min(max(p, 0), 1))
                prefs.inertiaDecayMs = s   // persist() fires via onChange(of: inertiaDecayMs) below
            }
        )
    }

    // Decorative ball geometry (matches BallScrollIconRenderer proportions).
    private let ballSize: CGFloat = 74

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            scrollSection
            Divider()
            behaviorSection
            Divider()
            generalSection
        }
        .padding(16)
        .frame(width: 540, alignment: .top)
        .onChange(of: prefs.invertDirection) { _, _ in prefs.persist() }
        .onChange(of: prefs.horizontalScrolling) { _, _ in prefs.persist() }
        .onChange(of: prefs.speedMultiplier) { _, _ in prefs.persist() }
        .onChange(of: prefs.emulateInertia) { _, _ in prefs.persist() }
        .onChange(of: prefs.deadzonePx) { _, _ in prefs.persist() }
        .onChange(of: prefs.inertiaDecayMs) { _, _ in prefs.persist() }
    }

    // MARK: Scroll button — ball (decorative) + one clickable button + code.

    private var scrollSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 26) {
                decorativeBall

                VStack(alignment: .leading, spacing: 8) {
                    // The one clickable button. Click → wait for the user to press
                    // their trackball's scroll button; that becomes it. Resting
                    // colour is dark grey; while the (currently set) trackball
                    // button is held, it turns bright red. Text stays centered.
                    Button {
                        if prefs.probeActivePosition != nil && !prefs.probeSequential {
                            prefs.cancelProbe()
                        } else {
                            prefs.startSingleProbe(.smallRight) // any button: the press wins
                        }
                    } label: {
                        ZStack {   // centered by default → text sits in the middle
                            RoundedRectangle(cornerRadius: 8)
                                .fill(buttonFill)
                            HStack(spacing: 6) {
                                Image(systemName: "cursorarrow.click.2")
                                Text(prefs.probeActivePosition != nil ? "Press it on the trackball" : "Set scroll button")
                                    .fontWeight(.semibold)
                            }
                            .foregroundStyle(.white)
                        }
                        .frame(width: 240, height: 54)
                    }
                    .buttonStyle(.plain)
                    .help("Click, then press the trackball button you want to use for scroll. While that button is held on the trackball, this button stays bright red.")

                    // Current scroll button as plain text; hover it for the bubble.
                    HStack(spacing: 6) {
                        Text("Currently selected button: \(prefs.activatorCGButton)")
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                    .help("This is the button number macOS sees when you press your scroll button. Press and hold that button on the trackball — \"Set scroll button\" above turns bright red while you're holding it, proving it's wired up. Change it by clicking the button and pressing a different one.")

                    if prefs.probeActivePosition != nil {
                        HStack(spacing: 8) {
                            Circle().fill(.blue).frame(width: 7, height: 7)
                            Text(prefs.probeSequential ? prefs.probeStatusText
                                                       : "Waiting — press the button you want to use for scrolling.")
                                .font(.caption)
                            Spacer()
                            Button("Cancel") { prefs.cancelProbe() }
                                .controlSize(.small)
                        }
                    }
                }

                Spacer(minLength: 0)
            }

            if !prefs.probeCompleted {
                HStack(spacing: 6) {
                    Button("Probe all buttons…") { prefs.startSequentialProbe() }
                        .controlSize(.small)
                }
                .help("Walks through every trackball button in turn and records each one. Usually not needed — the \"Set scroll button\" flow above is enough for a single scroll button.")
            }
        }
    }

    /// Glossy red ball with texture speckles — decorative, not clickable.
    private var decorativeBall: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    gradient: Gradient(colors: [Color(red: 0.98, green: 0.45, blue: 0.4),
                                                Color(red: 0.92, green: 0.2, blue: 0.23),
                                                Color(red: 0.58, green: 0.07, blue: 0.1)]),
                    center: .init(x: 0.35, y: 0.3),
                    startRadius: 2, endRadius: ballSize * 0.62))
            // Tiny texture speckles — identical layout to the app icon (dense even
            // field). AppKit is y-up so flip Y for SwiftUI's y-down coords. Dot
            // diameter = sp.r * ballSize (sp.r is a fraction of ball radius, so
            // 2·(sp.r·R) = sp.r·ballSize).
            ForEach(Array(BallScrollIconRenderer.ballSpeckles.enumerated()), id: \.offset) { _, sp in
                Circle()
                    .fill(Color.black.opacity(0.34))
                    .frame(width: sp.r * ballSize, height: sp.r * ballSize)
                    .offset(x: sp.p.x * (ballSize / 2), y: -sp.p.y * (ballSize / 2))
            }
            Circle().stroke(Color.black.opacity(0.35), lineWidth: 2)
        }
        .frame(width: ballSize, height: ballSize)
    }

    private var buttonFill: Color {
        // Bright red while the currently-set scroll button is physically held on
        // the trackball; dark grey otherwise. (No timed flash — stays red for as
        // long as it's held, grey on release.)
        if prefs.activatorPressed {
            return Color(red: 1.0, green: 0.24, blue: 0.2)
        }
        return Color(red: 0.32, green: 0.34, blue: 0.37)   // dark grey
    }

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $prefs.invertDirection) { Text("Invert scroll direction") }
                .toggleStyle(.switch)
                .help("Reverses the scroll direction: rolling the ball forward scrolls down instead of up (or vice versa).")

            Toggle(isOn: $prefs.horizontalScrolling) { Text("Enable horizontal scrolling") }
                .toggleStyle(.switch)
                .help("Rolling the ball side to side scrolls horizontally (wide pages, timelines). Off = only vertical scrolling.")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text("Scroll speed")
                    Spacer()
                    Text("\(prefs.speedMultiplier, format: .number.precision(.fractionLength(1)))")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $prefs.speedMultiplier, in: 1...20)
            }
            .help("How far the page moves per unit of ball rotation. Higher = faster scrolling.")

            Toggle(isOn: $prefs.emulateInertia) { Text("Emulate inertia effect") }
                .toggleStyle(.switch)
                .help("Adds a short glide after you stop rolling, so scrolling feels like it has momentum instead of stopping instantly.")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text("Inertia decay time")
                    Spacer()
                    Text(prefs.inertiaDecayMs < 100 ? String(format: "%.0f ms", prefs.inertiaDecayMs)
                                                     : String(format: "%.2f s", prefs.inertiaDecayMs / 1000))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                // Log-scaled slider (position 0…1 ↔ decay 25…1000 ms). Fine
                // precision at the low end; coarser toward 1 s.
                Slider(value: inertiaDecayBinding, in: 0...1)
            }
            .disabled(!prefs.emulateInertia)
            .help("How long the scroll keeps coasting AFTER you release — a smooth brake from your release speed down to a stop. Lower = stops almost immediately (25 ms ≈ no visible inertia); higher = it keeps rolling for a while (1 s is a long roll-out). The scale is logarithmic, so the left half gives fine control in the low range where 'barely any inertia' lives.")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text("Scroll deadzone")
                    Spacer()
                    Text("\(prefs.deadzonePx, format: .number.precision(.fractionLength(0))) px")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $prefs.deadzonePx, in: 0...100)
            }
            .help("How much tiny ball wobble (in pixels of raw movement) to ignore before scrolling starts. Stops a loose/wobbly ball or hand tremor from causing accidental scroll jumps. 0 = off (most responsive).")
        }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $prefs.loginItemEnabled) { Text("Automatically start at login") }
                .toggleStyle(.switch)
                .help("Launch BallScroll automatically when you sign in to macOS, so your trackball scroll button works from boot. While the settings window is open the app also shows its icon in the Dock; when it's closed only the menu-bar icon remains.")

            Divider()

            HStack(spacing: 8) {
                Circle().fill(prefs.trackballConnected ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                if prefs.trackballConnected {
                    Text("Logitech USB Trackball (0x46D:0xC3C) connected").font(.callout)
                } else {
                    Text(prefs.hasInputMonitoringPermission ? "Trackball not connected"
                                                            : "Trackball not detected — needs Input Monitoring")
                        .font(.callout)
                }
            }
            .help(prefs.trackballConnected
                  ? "Your trackball is plugged in and being read. Green = working."
                  : "The trackball isn't being seen. Plug it in, or grant Input Monitoring so macOS lets the app read its raw reports.")

            if !prefs.hasAccessibilityPermission { permissionRow("Accessibility", AXPermissions.openAccessibilitySettings) }
            if !prefs.hasInputMonitoringPermission { permissionRow("Input Monitoring", AXPermissions.openInputMonitoringSettings) }

            Divider()

            HStack(spacing: 10) {
                BallScrollAppIconSmall().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("BallScroll \(appVersion)").font(.callout.weight(.semibold))
                    Text("Hold the scroll button and roll to scroll.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func permissionRow(_ title: String, _ open: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("\(title) permission required")
            Button("Open System Settings…", action: open)
        }
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
}

// MARK: - Small colored app icon (for the settings footer) — shares its drawing
// with AppDelegate's menu-bar icon so both match.

struct BallScrollAppIconSmall: View {
    private let image: NSImage

    init() {
        self.image = BallScrollIconRenderer.appIcon(sizePt: 28)
    }

    var body: some View {
        Image(nsImage: image).resizable()
    }
}
