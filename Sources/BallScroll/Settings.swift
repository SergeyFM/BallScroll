//  Settings.swift — persisted configuration (NFR-5: local UserDefaults only)

import Foundation
import CoreGraphics

enum SettingsKeys {
    static let enabled = "BallScrollEnabled"
    static let invert = "InvertScrollDirection"
    static let horizontal = "EnableHorizontalScrolling"
    static let speed = "ScrollSpeedMultiplier"
    static let inertia = "EmulateInertiaEffect"
    static let inertiaDecayMs = "InertiaDecayMs"        // 25…1000 ms, default 80 — brake-to-stop time after release
    static let inertiaStrength = "InertiaStrength"      // legacy (0.1…3.0) — migrated into InertiaDecayMs
    static let inertiaMigrated = "InertiaDecayMigrated" // Bool — set once the legacy value was migrated
    static let deadzone = "ScrollDeadzonePx"
    static let activatorBit = "ActivatorButtonBit"          // Int: physical HID bit index (probe)
    static let activatorBtnNumber = "ActivatorButtonCGNumber" // Int64: CG .mouseEventButtonNumber (engine)
    static let probedBits = "ProbedButtonBits"              // JSON: [positionRaw: bit]
    static let probeDone = "ButtonProbeCompleted"

    /// Abnormal Mouse's default: the small right button ("button 5", btn_extra).
    static let defaultActivatorBit = TrackballGate.idxSmallRight
    static let defaultSpeed = 3
    static let defaultDeadzone = 2.0 // px
}

/// Physical button positions on the T-BC21 (PRD §2). Used by the picker
/// diagram (FR-5) and the first-run probe (FR-10).
enum ProbePosition: Int, CaseIterable, Codable {
    case largeLeft   // big button left  (btn_left)
    case largeRight  // big button right (btn_right)
    case smallLeft   // side button left (btn_side)
    case smallRight  // extra button right — Abnormal Mouse "button 5" (btn_extra)

    var displayName: String {
        switch self {
        case .largeLeft: return "Large left"
        case .largeRight: return "Large right"
        case .smallLeft: return "Small left (side)"
        case .smallRight: return "Small right"
        }
    }

    /// Best-effort physical bit (libinput layout, PRD §2). The probe flow
    /// (FR-10) replaces these with the device's real bits; until then the
    /// engine can still work from factory defaults.
    var defaultBit: Int {
        switch self {
        case .largeLeft: return TrackballGate.idxLargeLeft    // bit 0
        case .largeRight: return TrackballGate.idxLargeRight  // bit 2 (bit 1 = emulated middle)
        case .smallLeft: return TrackballGate.idxSmallLeft    // bit 3
        case .smallRight: return TrackballGate.idxSmallRight  // bit 4
        }
    }
}

/// Observable settings model (UI ↔ engine). Values are read live by the
/// event-tap callback on every event, so changes apply immediately (FR-3/4/6/7).
final class PreferencesModel: ObservableObject {
    @Published var enabled = true            // FR-11 global toggle (default ON)
    @Published var invertDirection = true    // FR-4 — user preference: reversed by default
    @Published var horizontalScrolling = false // FR-3, default OFF (vertical-only)
    @Published var speedMultiplier = Double(SettingsKeys.defaultSpeed) // FR-6, default 3
    @Published var emulateInertia = true     // FR-7, default ON
    /// Inertia decay time (ms): how long after release it takes for the glide to
    /// brake smoothly to a stop. Log-scale slider 25…1000 (sub-ms precision at the
    /// bottom — internally ms with sub-millisecond steps; the "microsecond scale"
    /// you asked for). 25 ms ≈ no visible inertia; 1000 ms = a long roll-out.
    @Published var inertiaDecayMs: Double = 80
    @Published var deadzonePx: Double        // FR-13
    @Published var activatorBit = SettingsKeys.defaultActivatorBit   // FR-5, default small right (bit 4)
    /// CG .mouseEventButtonNumber of the activator — what the engine actually
    /// matches against (AM-style). Set by probing; 3 = first extra button, the
    /// standard macOS number for a mouse's secondary side/extra buttons.
    @Published var activatorCGButton = 3
    @Published var probedBits: [ProbePosition: Int] = [:]            // FR-10
    /// Last CG .mouseEventButtonNumber seen by the engine on a down (probe use).
    var lastSeenCGButton = 3
    /// Transient live feedback (not persisted): true while the current scroll
    /// button is physically pressed — the settings UI flashes the button + its
    /// code bright red so you can see it's working.
    @Published var activatorPressed = false
    @Published var probeCompleted = false

    /// Device / permission state surfaced in the UI.
    @Published var trackballConnected = false
    @Published var hasAccessibilityPermission = AXPermissions.isTrusted
    @Published var hasInputMonitoringPermission = AXPermissions.inputMonitoringGranted
    /// Launch-at-login (FR-11). Backed by SMAppService; the toggle persists via
    /// LoginItem.setEnabled and re-reads isRegistered. Kept here (not @State) so
    /// it builds under bare swiftc (no SwiftUIMacros plugin).
    @Published var loginItemEnabled = false {
        didSet { if oldValue != loginItemEnabled { LoginItem.setEnabled(loginItemEnabled) } }
    }

    // MARK: Probe flow (FR-10) — two modes:
    //  * sequential ("Probe all buttons", first run): press each button in order.
    //  * single (picker, FR-5): user clicks a diagram position, then presses it
    //    on the device; its real signature is recorded AND becomes the activator.
    @Published var probeActivePosition: ProbePosition?
    @Published var probeSequential = false
    @Published var probeStatusText = ""

    private let defaults = UserDefaults.standard

    init() {
        deadzonePx = defaults.object(forKey: SettingsKeys.deadzone) as? Double ?? SettingsKeys.defaultDeadzone
        load()
    }

    func load() {
        defaults.register(defaults: [
            SettingsKeys.enabled: true,
            SettingsKeys.invert: true,   // user default: reversed scroll
            SettingsKeys.horizontal: false,
            SettingsKeys.speed: Double(SettingsKeys.defaultSpeed),
            SettingsKeys.inertia: true,
            SettingsKeys.inertiaDecayMs: 80.0,
        ])
        enabled = defaults.bool(forKey: SettingsKeys.enabled)
        invertDirection = defaults.bool(forKey: SettingsKeys.invert)
        horizontalScrolling = defaults.bool(forKey: SettingsKeys.horizontal)
        speedMultiplier = (defaults.object(forKey: SettingsKeys.speed) as? Double) ?? Double(SettingsKeys.defaultSpeed)
        emulateInertia = defaults.bool(forKey: SettingsKeys.inertia)
        // One-time migration from the old 0.1…3 strength lever: higher old values
        // meant a longer roll-out, so map monotonically into the new decay time.
        // (Must use a dedicated flag: register() above already puts a default under
        // the InertiaDecayMs key, so object(forKey:) can't tell "unset".)
        if !defaults.bool(forKey: SettingsKeys.inertiaMigrated),
           let old = defaults.object(forKey: SettingsKeys.inertiaStrength) as? Double {
            inertiaDecayMs = min(1000, max(25, 40 + old * 300))
            defaults.set(true, forKey: SettingsKeys.inertiaMigrated)
            persist()
        } else {
            inertiaDecayMs = (defaults.object(forKey: SettingsKeys.inertiaDecayMs) as? Double) ?? 80
        }

        activatorBit = (defaults.object(forKey: SettingsKeys.activatorBit) as? Int)
            ?? SettingsKeys.defaultActivatorBit
        activatorCGButton = (defaults.object(forKey: SettingsKeys.activatorBtnNumber) as? Int) ?? 3

        if let data = defaults.data(forKey: SettingsKeys.probedBits),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Int] {
            var map: [ProbePosition: Int] = [:]
            for (k, v) in obj where ProbePosition(rawValue: Int(k) ?? -1) != nil {
                map[ProbePosition(rawValue: Int(k) ?? -1)!] = v
            }
            probedBits = map
        }
        probeCompleted = defaults.bool(forKey: SettingsKeys.probeDone)
        loginItemEnabled = LoginItem.isRegistered
    }

    func persist() {
        defaults.set(enabled, forKey: SettingsKeys.enabled)
        defaults.set(invertDirection, forKey: SettingsKeys.invert)
        defaults.set(horizontalScrolling, forKey: SettingsKeys.horizontal)
        defaults.set(speedMultiplier, forKey: SettingsKeys.speed)
        defaults.set(emulateInertia, forKey: SettingsKeys.inertia)
        defaults.set(inertiaDecayMs, forKey: SettingsKeys.inertiaDecayMs)   // superseded InertiaStrength left for migration
        defaults.set(deadzonePx, forKey: SettingsKeys.deadzone)
        defaults.set(activatorBit, forKey: SettingsKeys.activatorBit)
        defaults.set(Int(activatorCGButton), forKey: SettingsKeys.activatorBtnNumber)

        var probeObj: [String: Int] = [:]
        for (pos, bit) in probedBits { probeObj[String(pos.rawValue)] = bit }
        if let data = try? JSONSerialization.data(withJSONObject: probeObj) {
            defaults.set(data, forKey: SettingsKeys.probedBits)
        }
        defaults.set(probeCompleted, forKey: SettingsKeys.probeDone)
    }

    /// Physical bit actually used for a position: probed value if available, else default.
    func bit(for position: ProbePosition) -> Int {
        probedBits[position] ?? position.defaultBit
    }

    var activatorPosition: ProbePosition {
        ProbePosition.allCases.first(where: { bit(for: $0) == activatorBit }) ?? .smallRight
    }

    // MARK: Probe control (called from UI and from the engine's capture)

    /// First-run sequential probe: press all four buttons in order (FR-10).
    func startSequentialProbe() {
        probeActivePosition = .largeLeft
        probeSequential = true
        updateProbeStatus(.largeLeft)
    }

    /// Picker single probe (FR-5): user clicked a position in the diagram;
    /// waiting for them to press THAT button on the device.
    func startSingleProbe(_ position: ProbePosition) {
        probeActivePosition = position
        probeSequential = false
        // Single (one-shot) probe: any button press wins, so don't name a
        // specific position (codes only). The sequential "probe all" flow sets
        // its own per-position text in updateProbeStatus.
        probeStatusText = ""
    }

    func cancelProbe() {
        probeActivePosition = nil
        probeSequential = false
        probeStatusText = ""
    }

    // MARK: Live "scroll button pressed" feedback (settings UI red)

    private var pressSafety: DispatchWorkItem?

    /// Driven by the engine's real button edges: `pressed == true` on down,
    /// `false` on the paired up. The settings UI stays bright red for as long as
    /// the trackball button is physically held (no timed flash that goes back to
    /// grey a second later). A long safety timer only recovers from a lost up
    /// event (e.g. trackball unplugged mid-press).
    func noteActivator(pressed: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if pressed {
                self.activatorPressed = true
                self.pressSafety?.cancel()
                let w = DispatchWorkItem { [weak self] in
                    guard let self, self.activatorPressed else { return }
                    self.activatorPressed = false   // safety: up event never arrived
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
                self.pressSafety = w
            } else {
                self.activatorPressed = false
                self.pressSafety?.cancel()
            }
        }
    }

    /// Engine reports a real button press as its physical HID bit. Records it
    /// for the active position and advances. Runs on the main run loop (gate
    /// hop) but is dispatched async by AppDelegate before touching UI.
    func handleProbedButton(bit: Int) {
        guard let pos = probeActivePosition else { return }

        // Disambiguate: if another probed position already claimed this bit,
        // swap so each physical button stays 1:1 (mirrors the signature case).
        if let other = ProbePosition.allCases.first(where: { $0 != pos && probedBits[$0] == bit }),
           let oldBit = probedBits[pos] {
            probedBits[other] = oldBit
        }

        // Single-mode probe: the probed button is also chosen as activator.
        if !probeSequential {
            activatorBit = bit
            // The CG number the engine will actually match against (AM-style).
            activatorCGButton = lastSeenCGButton
            probeActivePosition = nil
            // Code-first confirmation — no button-name labels.
            probeStatusText = "Scroll button set — Button \(lastSeenCGButton)."
            persist()
            return
        }

        probedBits[pos] = bit
        let idx = ProbePosition.allCases.firstIndex(of: pos)!
        if idx + 1 < ProbePosition.allCases.count {
            probeActivePosition = ProbePosition.allCases[idx + 1]
            updateProbeStatus(ProbePosition.allCases[idx + 1])
        } else {
            probeActivePosition = nil
            probeSequential = false
            probeCompleted = true
            probeStatusText = "Done — all button bits recorded."
        }
        persist()
    }

    private func updateProbeStatus(_ pos: ProbePosition) {
        probeStatusText = "Now press the \"\(pos.displayName)\" button on the trackball…"
    }
}
