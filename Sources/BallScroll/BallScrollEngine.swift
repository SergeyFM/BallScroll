//  BallScrollEngine.swift — the core hold-to-scroll engine.
//
//  Architecture (verified on this host, PRD §8 with M0 findings):
//    * TrackballGate (IOHID, matched to 0x46D:0xC3C) is the device-certain
//      source of truth: raw ball deltas + which physical button bits are down.
//    * A single CG session event tap (active) consumes the trackball's
//      pointer/button events and posts synthetic scroll wheels. Because the CG
//      tap cannot attribute an event to a device (CGEventGetSource is absent
//      in this SDK), the tap only acts while the gate reports fresh trackball
//      activity — Magic Mouse / trackpad events never trigger it (FR-8).
//
//  State machine (PRD §8.3, D2 — no tap branch):
//    IDLE → activator bit pressed (gate) → ARMED, consume its CG down.
//    ARMED → raw movement past deadzone → SCROLLING;
//            activator released before deadzone → consume up, IDLE (tap = nothing).
//    SCROLLING → drain raw deltas → post pixel scroll (§8.4/8.5), consume CG move;
//                activator released → flush inertia tail (FR-7) → IDLE.
//
//  The CG callback is @convention(c) (no captures); all mutable state lives here,
//  touched only on the main run loop. Allocation-light (NFR-2).

import Foundation
import CoreGraphics
import AppKit
import IOKit.hid

final class BallScrollEngine {
    static let shared = BallScrollEngine()

    // MARK: Live config — read per event.
    private(set) var prefs: PreferencesModel!
    var isEnabled = true { didSet { applyEnabled() } }

    /// Trackball reports within this many seconds count as "trackball active".
    private let activityWindow: CFTimeInterval = 0.35

    // MARK: State-machine state (main run loop only)
    private enum Mode { case idle, armed, scrolling }
    private var mode: Mode = .idle

    /// CGEventType of a button-down we consumed (so its paired up is also
    /// swallowed — prevents a leaked stray click if the gate release lags).
    private var consumedDownType: CGEventType?

    /// Accumulated raw movement since ARMED (deadzone check, FR-13).
    private var armedDX: CGFloat = 0
    private var armedDY: CGFloat = 0

    /// Inertia velocity in px/second, measured between drains.
    private var velocity: (x: CGFloat, y: CGFloat) = (0, 0)
    private var lastDrainTime: CFTimeInterval?
    private var inertiaTimer: Timer?

    // MARK: Gate + tap
    let gate = TrackballGate()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // MARK: - Lifecycle (main thread only)

    func start(prefs model: PreferencesModel, enabled: Bool) {
        guard eventTap == nil else { return }
        prefs = model
        isEnabled = enabled

        gate.onChange = { [weak self] connected in
            DispatchQueue.main.async {
                guard let self, let p = self.prefs else { return }
                p.trackballConnected = connected
            }
        }

        // Gate drives the state machine on its own (device-certain).
        gate.onPress = { [weak self] idx, _ in
            DispatchQueue.main.async { self?.activatorEdge(idx: idx, pressed: true) }
        }
        gate.onRelease = { [weak self] idx, _ in
            DispatchQueue.main.async { self?.activatorEdge(idx: idx, pressed: false) }
        }

        gate.start()

        if let p = prefs { p.trackballConnected = gate.isConnected }
        DebugLog.log("engine.start: AXTrusted=\(AXPermissions.isTrusted) enabled=\(isEnabled)")
        installEventTap()
    }

    func stop() {
        removeEventTap()
        gate.stop()
        prefs = nil
    }

    func applyEnabled() {
        if isEnabled { installEventTap() } else { removeEventTap() }
    }

    /// NFR-4: sleep/wake or permission re-grant → the tap may be disabled by
    /// the system; reinstall and let the gate keep running (it recovers alone).
    func handleWake() {
        if prefs != nil, isEnabled { installEventTap(replace: true) }
    }

    /// Input Monitoring was granted after the gate first opened (it saw no
    /// device pre-grant). Restart the raw IOHID manager so it picks up access.
    /// Idempotent and safe to call from the main run loop (it is).
    func restartGate() {
        gate.stop()
        gate.start()
        if let p = prefs { p.trackballConnected = gate.isConnected }
    }

    func isTrackballConnected() -> Bool { gate.isConnected }

    /// The physical button bit currently selected as activator (probe result
    /// preferred; PRD-§2 estimate otherwise).
    private var activatorBit: Int { prefs?.activatorBit ?? TrackballGate.idxSmallRight }

    // MARK: - Gate edges (hopped to main)

    private func activatorEdge(idx: Int, pressed: Bool) {
        let model = guardPrefs()
        // Probe mode (FR-10): forward every physical press for recording.
        if model.probeActivePosition != nil {
            onProbeButtonPressed?(idx)
        }

        guard idx == activatorBit else { return }

        if pressed && mode == .idle {
            // ARMED (FR-1). Reset deadzone accumulator + drop pre-press jitter.
            mode = .armed
            armedDX = 0; armedDY = 0
            gate.clearPendingMovement()
            stopInertiaTimer()
            velocity = (0, 0)
            DebugLog.log("ARMED (bit \(idx))")
        } else if !pressed && (mode == .armed || mode == .scrolling) {
            // Release: tap-no-move does nothing (D2); scrolling flushes inertia.
            let wasScrolling = (mode == .scrolling)
            mode = .idle
            consumedDownType = nil // gesture ended; stop swallowing button ups
            DebugLog.log(wasScrolling ? "RELEASE from SCROLLING (v=\(velocity.x),\(velocity.y))" : "RELEASE from ARMED (tap = nothing)")
            startInertiaTail(model) // no-op if inertia off / velocity ~0
        }
    }

    private func guardPrefs() -> PreferencesModel {
        if let p = prefs { return p }
        fatalError("engine used before start()")
    }

    /// Probed-button sink for the first-run probe (FR-10): physical bit index.
    var onProbeButtonPressed: ((Int) -> Void)?

    // MARK: - Tap management

    private func installEventTap(replace: Bool = false) {
        guard isEnabled else { return }
        if !AXPermissions.isTrusted { DebugLog.log("installEventTap: skipped (Accessibility not trusted)"); return }
        if replace || eventTap != nil { removeEventTap() }

        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)

        let cb: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<BallScrollEngine>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
        }

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,      // active: may consume
                                          eventsOfInterest: mask,
                                          callback: cb, userInfo: ctx) else { return }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        DebugLog.log("event tap installed (session, active)")
        runLoopSource = source
    }

    private func removeEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - The tap callback (main run loop, C context)

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Tap disabled by the system (timeout/user input) — re-enable, pass through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let model = guardPrefs()
        guard model.enabled else { return Unmanaged.passUnretained(event) }

        let isDown = (type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown)
        let isUp = (type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp)
        let isMove = (type == .mouseMoved || type == .leftMouseDragged || type == .otherMouseDragged)

        guard isDown || isUp || isMove else { return Unmanaged.passUnretained(event) }

        // Only react when the trackball is actually driving events right now
        // (fresh raw report within the activity window) — FR-8. This is what
        // protects the Magic Mouse and built-in trackpad (AC #8).
        guard gate.isActive(window: activityWindow) else { return Unmanaged.passUnretained(event) }

        // Probe mode (FR-10): pass everything through; recording is driven by
        // gate.onPress. (The CG event here just confirms the tap sees them.)
        if model.probeActivePosition != nil { return Unmanaged.passUnretained(event) }

        // While a hold-to-scroll gesture is live (armed/scrolling), swallow ALL
        // button down+up from the trackball: it keeps the activator's paired
        // up from leaking through as a stray click (FR-9) and stops any
        // secondary button during the gesture from producing a spurious click.
        if (mode == .armed || mode == .scrolling) && (isDown || isUp) {
            if isDown { consumedDownType = type } else {
                if let c = consumedDownType, type == pairedUp(for: c) { consumedDownType = nil }
            }
            return nil
        }

        switch mode {
        case .armed:
            if isMove {
                let dz = CGFloat(model.deadzonePx)
                // Drain once: first report after the down is the activator's own.
                if let m = gate.drainMovement() { armedDX += m.dx; armedDY += m.dy }
                if abs(armedDX) >= dz || abs(armedDY) >= dz {
                    mode = .scrolling
                    DebugLog.log("SCROLLING (dz crossed: \(armedDX),\(armedDY))")
                }
            }
            return nil // consume: no cursor drift while armed/scrolling (FR-9)

        case .scrolling:
            if isMove { scrollFromRawDeltas(model: model) }
            return nil // consume (FR-9)

        default:
            break
        }

        // Idle or non-trackball device: pass through untouched.
        return Unmanaged.passUnretained(event)
    }

    /// The CGEventType paired with a given button-down (left/right/other).
    private func pairedUp(for down: CGEventType) -> CGEventType {
        switch down {
        case .leftMouseDown: return .leftMouseUp
        case .rightMouseDown: return .rightMouseUp
        default: return .otherMouseUp
        }
    }

    // MARK: - Translation & posting (PRD §8.4, §8.5)

    private func scrollFromRawDeltas(model: PreferencesModel) {
        let now = CACurrentMediaTimeNow()
        guard let move = gate.drainMovement() else { return }

        // Velocity (px/s) for the inertia tail.
        if let last = lastDrainTime {
            let dt = now - last
            if dt > 0 { velocity = (move.dx / CGFloat(dt), move.dy / CGFloat(dt)) }
        }
        lastDrainTime = now

        // §8.4 — vertical-only by default; horizontal only when enabled (FR-3).
        let speed = CGFloat(model.speedMultiplier)
        var sx: CGFloat = 0
        let sy = move.dy * speed
        if model.horizontalScrolling { sx = move.dx * speed }

        // §8.4 — invert (FR-4). Positive pixel delta = content scrolls up
        // (natural-wheel direction); the ball's raw dy is screen-down positive,
        // so mapping as-is matches trackpad "natural" scrolling; invert flips.
        let sign: CGFloat = model.invertDirection ? -1 : 1
        postScroll(x: sx * sign, y: sy * sign)
    }

    /// Post a smooth (pixel-unit) scroll wheel event at the HID tap point (§8.5).
    private func postScroll(x: CGFloat, y: CGFloat) {
        guard x != 0 || y != 0 else { return }

        let source = CGEventSource(stateID: .hidSystemState)
        let ev = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                         wheelCount: 2,
                         wheel1: Int32(y.rounded()), // axis 1 = vertical (pixels)
                         wheel2: Int32(x.rounded()), // axis 2 = horizontal (pixels)
                         wheel3: 0)
        guard let ev else { return }

        // Point-delta fields AFTER the wheel fields, kept consistent
        // (Scroll Reverser's ordering constraint, PRD §8.5).
        ev.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(y.rounded()))
        ev.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(x.rounded()))

        ev.post(tap: .cghidEventTap)
    }

    // MARK: - Inertia (FR-7)

    private func startInertiaTail(_ model: PreferencesModel) {
        guard model.emulateInertia else { velocity = (0, 0); return }

        let speedHypot = sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
        guard speedHypot > 25 else { velocity = (0, 0); return } // below tail threshold

        stopInertiaTimer()
        lastDrainTime = nil
        let decayPerSecond: CGFloat = 0.12   // exponential falloff constant
        let tick: CFTimeInterval = 1.0 / 60.0

        let timer = Timer(timeInterval: tick, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            var v = self.velocity
            // Exponential decay: multiply by exp(-decay*dt).
            let f = CGFloat(exp(Double(-decayPerSecond * tick)))
            v.x *= f; v.y *= f

            let sign: CGFloat = model.invertDirection ? -1 : 1
            self.postScroll(x: v.x * tick * sign, y: v.y * tick * sign)
            self.velocity = (v.x, v.y)

            let s2 = sqrt(v.x * v.x + v.y * v.y)
            // Stop when decayed below threshold, or as soon as a new gesture
            // has started (the engine left .idle).
            if self.mode != .idle || s2 < 8 {
                t.invalidate()
                self.inertiaTimer = nil
            }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        inertiaTimer = timer
    }

    private func stopInertiaTimer() {
        inertiaTimer?.invalidate()
        inertiaTimer = nil
    }
}
