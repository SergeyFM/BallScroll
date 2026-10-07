//  SettingsWindow.swift — SwiftUI settings window (NFR-1, AM parity).
//  Tabs: Scroll / Advanced / General.

import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {
    private let onClosed: () -> Void

    init(prefs: PreferencesModel, onClosed: @escaping () -> Void) {
        self.onClosed = onClosed

        let root = SettingsRootView(prefs: prefs)
            .frame(width: 560, height: 420)
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hosting)
        window.title = "BallScroll Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 560, height: 420))
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(tab: Int = 0) {
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { onClosed() }
}

// MARK: - Root tab view

struct SettingsRootView: View {
    @ObservedObject var prefs: PreferencesModel

    var body: some View {
        TabView(selection: .constant(0)) {
            ScrollTab(prefs: prefs).tabItem { Label("Scroll", systemImage: "arrow.up.arrow.down") }
                .tag(0)
            AdvancedTab(prefs: prefs).tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
                .tag(1)
            GeneralTab(prefs: prefs).tabItem { Label("General", systemImage: "gearshape") }
                .tag(2)
        }
    }
}

// MARK: - Scroll tab (PRD §9)

struct ScrollTab: View {
    @ObservedObject var prefs: PreferencesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Usage tip (dynamic per chosen button — AM style).
            Text("Hold **\(prefs.activatorPosition.displayName)** then roll the ball to scroll.")
                .font(.callout)
                .foregroundStyle(.secondary)

            // Scroll button picker (FR-5): T-BC21 diagram + single-position probe.
            GroupBox("Scroll button") {
                VStack(alignment: .leading, spacing: 10) {
                    TrackballDiagram(prefs: prefs) { position in
                        // Clicked a diagram button → single-position probe (FR-5/10).
                        if prefs.probeActivePosition == position {
                            prefs.cancelProbe()
                        } else {
                            prefs.startSingleProbe(position)
                        }
                    }

                    if prefs.probeActivePosition != nil {
                        HStack(spacing: 8) {
                            Circle().fill(.blue).frame(width: 8, height: 8)
                            Text(prefs.probeStatusText)
                                .font(.caption)
                            Spacer()
                            Button("Cancel") { prefs.cancelProbe() }
                                .controlSize(.small)
                        }
                    } else {
                        Text("Click a button in the diagram, then press it on the trackball to make it your scroll button. (Each physical button is detected from its raw HID report — no guessing.)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !prefs.probeCompleted {
                        Button("Probe all buttons…") { prefs.startSequentialProbe() }
                            .controlSize(.small)
                    }
                }
            }

            // Direction invert (FR-4).
            Toggle(isOn: $prefs.invertDirection) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Invert scroll direction")
                    Text("Aligns the ball with trackpad \"natural\" scrolling — flipping it makes rolling up/down match your trackpad feel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Horizontal toggle (FR-3, default OFF).
            Toggle(isOn: $prefs.horizontalScrolling) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable horizontal scrolling")
                    Text("Off = vertical only (sideways roll does nothing). On = rolling sideways also scrolls horizontally.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Scroll speed (FR-6, default 3).
            VStack(alignment: .leading, spacing: 4) {
                Text("Scroll speed: \(prefs.speedMultiplier, format: .number.precision(.fractionLength(1)))")
                Slider(value: $prefs.speedMultiplier, in: 1...20)
                Text("Controls how much ball motion is scaled into scrolling. Higher = the page moves further per unit of ball travel (matches Abnormal Mouse's \"Scroll speed\").")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Inertia (FR-7, default ON).
            Toggle(isOn: $prefs.emulateInertia) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Emulate inertia effect")
                    Text("Adds a short decay tail after you stop rolling. Some apps (e.g. certain web views) respond more smoothly to this than raw pixel scroll.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(16)
        .onChange(of: prefs.invertDirection) { _, _ in prefs.persist() }
        .onChange(of: prefs.horizontalScrolling) { _, _ in prefs.persist() }
        .onChange(of: prefs.speedMultiplier) { _, _ in prefs.persist() }
        .onChange(of: prefs.emulateInertia) { _, _ in prefs.persist() }
    }
}

// MARK: - T-BC21 button diagram (FR-5)

struct TrackballDiagram: View {
    @ObservedObject var prefs: PreferencesModel
    let onSelect: (ProbePosition) -> Void

    private func buttonStyle(_ pos: ProbePosition, size: CGSize) -> some View {
        let isActive = prefs.probeActivePosition == pos
        let isActivator = prefs.bit(for: pos) == prefs.activatorBit
        return Button {
            onSelect(pos)
        } label: {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: size.height / 4)
                    .fill(isActivator ? Color.accentColor.opacity(0.55)
                            : isActive ? Color.orange.opacity(0.6)
                            : Color.secondary.opacity(0.25))
                VStack(spacing: 1) {
                    if isActivator { Image(systemName: "checkmark").font(.caption2) }
                    Text(pos.displayName.uppercased())
                        .font(.system(size: 8, weight: .bold))
                        .lineLimit(2)
                }
                .foregroundStyle(.white)
                .padding(4)
            }
            .frame(width: size.width, height: size.height)
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            // Big buttons (left/right).
            HStack(spacing: 10) {
                buttonStyle(.largeLeft, size: CGSize(width: 52, height: 34))
                buttonStyle(.largeRight, size: CGSize(width: 52, height: 34))
            }
            .padding(.bottom, 18)

            // Ball.
            ZStack {
                Circle().fill(
                    RadialGradient(colors: [Color.primary.opacity(0.5), Color.primary.opacity(0.18)],
                                   center: .topLeading, startRadius: 2, endRadius: 46)
                )
                Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 1)
            }
            .frame(width: 46, height: 46)

            // Small buttons (side / extra).
            VStack(spacing: 10) {
                buttonStyle(.smallLeft, size: CGSize(width: 40, height: 26))
                buttonStyle(.smallRight, size: CGSize(width: 40, height: 26))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Advanced tab

struct AdvancedTab: View {
    @ObservedObject var prefs: PreferencesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Scroll deadzone (FR-13)") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Minimum ball movement before scrolling starts: \(prefs.deadzonePx, format: .number.precision(.fractionLength(0))) px")
                    Slider(value: $prefs.deadzonePx, in: 0...10)
                    Text("Absorbs tiny jitter so the cursor never scrolls on its own. Raise if you see scroll creep without rolling.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("Per-app exclusions") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Coming in v1.1 — disable BallScroll for specific apps (Abnormal Mouse \"Advanced\" parity).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("Modifier-gated horizontal") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Coming in v1.1 — hold ⌥ while scrolling to scroll horizontally, instead of the plain toggle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(16)
        .onChange(of: prefs.deadzonePx) { _, _ in prefs.persist() }
    }
}

// MARK: - General tab (FR-11) + About

struct GeneralTab: View {
    @ObservedObject var prefs: PreferencesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14)
        {
            Toggle(isOn: $prefs.loginItemEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatically start at login") // AM's exact label (PRD §9)
                    Text("BallScroll launches after reboot via the system Login Items (SMAppService).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Device status.
            HStack(spacing: 8) {
                Circle()
                    .fill(prefs.trackballConnected ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                if prefs.trackballConnected {
                    Text("Logitech USB Trackball (0x46D:0xC3C) detected")
                } else {
                    if prefs.hasInputMonitoringPermission {
                        Text("Trackball not detected — plug in the T-BC21")
                    } else {
                        Text("Trackball not detected — needs Input Monitoring (below)")
                    }
                }
            }
            .font(.callout)

            if !prefs.hasAccessibilityPermission {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Accessibility permission required")
                    Button("Open System Settings…") { AXPermissions.openAccessibilitySettings() }
                }
            }

            if !prefs.hasInputMonitoringPermission {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Input Monitoring permission required (raw trackball read)")
                    Button("Open System Settings…") { AXPermissions.openInputMonitoringSettings() }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("BallScroll \(appVersion)")
                    .font(.headline)
                Text("A thin menu-bar utility that turns your Logitech T-BC21 trackball's held-button + ball motion into scroll — vertical-only by default, with invertible direction. Built to replace Abnormal Mouse's \"Move to Scroll\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return v
    }
}
