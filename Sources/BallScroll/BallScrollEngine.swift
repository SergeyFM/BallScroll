//  BallScrollEngine.swift — hold-trackball-button-to-scroll engine.
//
//  Architecture — modeled directly on Abnormal Mouse's MoveToScroll
//  (github.com/intitni/AbnormalMouseApp), which is proven to work for exactly
//  this feature on macOS:
//    * ONE active CG session event tap is the only event source in the hot
//      path. NO IOHID raw reports (our earlier dual pipeline mixed two clocks —
//      IOHID's mach time vs CACurrentMediaTimeNow() — so isActive() was always
//      false and every gesture bailed to pass-through).
//    * Hold detection (their TapHoldGestureRecognizer): the tap reads
//      event[.mouseEventButtonNumber] on otherMouseDown/Up. The activator is a
//      button NUMBER; only the T-BC21 has its extra buttons, so Magic Mouse and
//      the built-in trackpad can never trigger a gesture (FR-8, implicit scope).
//    * Ball movement (their MouseMovementGestureRecognizer): while the activator
//      is held, mouseMoved/…Dragged events are consumed (.discarded → no cursor
//      drift) and their BUILT-IN .mouseEventDeltaX/Y fields are accumulated.
//    * Scroll output (their EmulateEventPoster.postScroll): pixel-unit wheel
//      events with .scrollWheelEventIsContinuous=1 and an explicit scroll phase
//      (began → changed… → ended). Point-delta fields are set consistently too.
//    * The cursor is pinned (CGWarpMouseCursorPosition) at the position captured
//      when the gesture armed — AM's belt-and-suspenders against drift.
//  The IOHID TrackballGate is demoted to a cold path: connection status for the
//  menu bar, and first-run button probing (FR-10). It never gates gestures.
//
//  State machine:
//    IDLE   → activator down            → ARMED (pin cursor, swallow the up)
//    ARMED  → movement past deadzone    → SCROLLING (post began, then changed)
//           → activator up before that  → IDLE (tap = nothing, D2)
//           → no movement for 150 ms    → IDLE (hold without moving = nothing)
//    SCROLLING → movement               → post changed (+ inertia velocity)
//              → activator up           → end scroll (ended phase), inertia tail, IDLE

import Foundation
import CoreGraphics
import AppKit
import IOKit.hid

final class BallScrollEngine {
    static let shared = BallScrollEngine()

    private(set) var prefs: PreferencesModel!
    var isEnabled = true { didSet { applyEnabled() } }

    // MARK: State (main run loop only)
    private enum Mode { case idle, armed, scrolling }
    private var mode: Mode = .idle

    /// Cursor position captured at ARM; warped back after each consumed move.
    private var pinnedLocation = CGPoint.zero

    /// Accumulated CG deltas since ARM (deadzone, FR-13).
    private var armedDX: CGFloat = 0
    private var armedDY: CGFloat = 0

    // Inertia (FR-7) — velocity in posted px/s, low-passed from the last moves.
    private var velocity: (x: CGFloat, y: CGFloat) = (0, 0)
    private var lastMoveTime: CFTimeInterval?
    private var inertiaTimer: Timer?

    // MARK: Gate (cold path) + tap
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

        // Probe (FR-10) rides on the gate's physical bit edges.
        gate.onPress = { [weak self] idx, _ in
            DispatchQueue.main.async { self?.activatorEdge(idx: idx, pressed: true) }
        }

        gate.start()
        if let p = prefs { p.trackballConnected = gate.isConnected }
        DebugLog.log("engine.start (AM-style single tap): AXTrusted=\(AXPermissions.isTrusted) enabled=\(isEnabled)")
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

    /// NFR-4: sleep/wake → the system may disable the tap; reinstall.
    func handleWake() {
        if prefs != nil, isEnabled { installEventTap(replace: true) }
    }

    func restartGate() {
        gate.stop(); gate.start()
        if let p = prefs { p.trackballConnected = gate.isConnected }
    }

    func isTrackballConnected() -> Bool { gate.isConnected }

    /// Probed-button sink for the first-run probe (FR-10): physical bit index.
    var onProbeButtonPressed: ((Int) -> Void)?
    /// CG .mouseEventButtonNumber seen on a down while a probe is active — the
    /// engine-side identity the settings record for the activator.
    var onProbeCGDown: ((Int) -> Void)?

    // MARK: - Gate edges (probe only — gestures are driven by the CG tap)

    private func activatorEdge(idx: Int, pressed: Bool) {
        guard let model = prefs else { return }
        if model.probeActivePosition != nil, pressed {
            onProbeButtonPressed?(idx)
        }
    }

    // MARK: - Tap management

    private func installEventTap(replace: Bool = false) {
        guard isEnabled else { return }
        if !AXPermissions.isTrusted { DebugLog.log("installEventTap: skipped (Accessibility not trusted)"); return }
        if replace || eventTap != nil { removeEventTap() }

        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) | (1 << CGEventType.otherMouseDragged.rawValue) | (1 << CGEventType.rightMouseDragged.rawValue) |
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
        runLoopSource = source
        DebugLog.log("event tap installed (session, active) — AM-style")
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
        // Tap disabled by the system — re-enable, pass through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard let model = prefs, model.enabled else { return Unmanaged.passUnretained(event) }

        let isDown = (type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown)
        let isUp = (type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp)
        let isMove = (type == .mouseMoved || type == .leftMouseDragged || type == .otherMouseDragged || type == .rightMouseDragged)
        guard isDown || isUp || isMove else { return Unmanaged.passUnretained(event) }

        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
        let activator = Int64(model.activatorCGButton)

        // Raw live feedback for the scroll-button picker — independent of arming
        // so it stays bright red exactly while that trackball button is held and
        // returns to grey on the paired up (no timed flash). In probe mode any
        // button's press lights it, so you can see the app is listening.
        if model.probeActivePosition != nil {
            if isDown {
                onProbeCGDown?(Int(buttonNumber))
                model.noteActivator(pressed: true)   // live "it's listening" indicator
            } else if isUp {
                model.noteActivator(pressed: false)
            }
            return Unmanaged.passUnretained(event)
        }

        if isDown && buttonNumber == activator {
            model.noteActivator(pressed: true)   // red while held
        } else if isUp && buttonNumber == activator {
            model.noteActivator(pressed: false)  // grey on release
        }

        switch mode {
        case .idle:
            // AM TapHold: only the activator's down arms; everything else is a
            // normal click on whatever device produced it (FR-8).
            if isDown && buttonNumber == activator {
                arm(location: event.location, model: model)
                return nil // consume the activator's down (FR-9)
            }
            return Unmanaged.passUnretained(event)

        case .armed:
            if isUp && buttonNumber == activator {
                // Tap with no movement — D2: nothing happens.
                disarm()
                DebugLog.log("RELEASE from ARMED (tap = nothing)")
                return nil // consume the paired up so it never leaks as a click
            }
            if isMove {
                accumulateMove(event: event, model: model)
                return nil // consume: no cursor drift while armed/scrolling (FR-9)
            }
            // Any other button during a hold passes through untouched.
            return Unmanaged.passUnretained(event)

        case .scrolling:
            if isUp && buttonNumber == activator {
                endScroll(model: model)
                return nil // consume the paired up (FR-9)
            }
            if isMove {
                accumulateMove(event: event, model: model)
                return nil // consume (FR-9)
            }
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: Gesture transitions (AM MoveToScrollController — no watchdog; a
    // pure hold simply has no move events, and the paired up always ends it)

    private func arm(location: CGPoint, model: PreferencesModel) {
        mode = .armed
        armedDX = 0; armedDY = 0
        velocity = (0, 0); lastMoveTime = nil
        pinnedLocation = location
        // If a momentum tail was still running, close it out (post its .ended) so
        // we never leave a began-without-ended that confuses gesture-tracking apps.
        if inertiaTimer != nil { postScrollPhase(v: 0, h: 0, phase: .ended) }
        stopInertiaTimer()

        DebugLog.log("ARMED (CG btn \(model.activatorCGButton), pin @\(Int(location.x)),\(Int(location.y)))")
    }

    private func accumulateMove(event: CGEvent, model: PreferencesModel) {
        // AM MouseMovementGestureRecognizer: accumulate the event's built-in deltas.
        let dx = CGFloat(event.getDoubleValueField(.mouseEventDeltaX))
        let dy = CGFloat(event.getDoubleValueField(.mouseEventDeltaY))
        armedDX += dx; armedDY += dy

        // Pin the cursor exactly like AM (CGWarpMouseCursorPosition).
        CGWarpMouseCursorPosition(pinnedLocation)

        switch mode {
        case .armed:
            let dz = CGFloat(model.deadzonePx)
            if abs(armedDX) >= dz || abs(armedDY) >= dz {
                mode = .scrolling
                DebugLog.log("SCROLLING (dz crossed: \(Int(armedDX)),\(Int(armedDY)))")
                postFirstScrollFrame(dx: dx, dy: dy, model: model)
            }
        case .scrolling:
            scrollFromMove(dx: dx, dy: dy, model: model)
        case .idle:
            break
        }
    }

    private func endScroll(model: PreferencesModel) {
        mode = .idle
        // NOTE: no `.ended` here. The inertia tail (if any) continues the SAME
        // gesture and posts its own `.ended` last — apps key on the final phase,
        // so posting .ended before the momentum deltas made them look "outside a
        // gesture" and some apps dropped them. If there is no inertia, post it now.
        DebugLog.log("RELEASE from SCROLLING (v=\(Int(velocity.x)),\(Int(velocity.y))) t=\(String(format:"%.3f",CACurrentMediaTimeNow()))")
        if startInertiaTail(model) {
            // tail owns the .ended
        } else {
            postScrollPhase(v: 0, h: 0, phase: .ended)
        }
    }

    private func disarm() {
        mode = .idle
    }

    // MARK: - Translation & posting (AM EmulateEventPoster.postScroll)

    /// Deadzone crossed: post the .began frame carrying this move's delta
    /// (AM posts began with zero, then the first changed; folding them keeps a
    /// 60 Hz pipeline lossless — one frame, same total pixels).
    private func postFirstScrollFrame(dx: CGFloat, dy: CGFloat, model: PreferencesModel) {
        let now = CACurrentMediaTimeNow()
        lastMoveTime = now
        velocity = (0, 0)
        scrollMoveCount = 0

        let speed = CGFloat(model.speedMultiplier)
        var sx: CGFloat = 0
        let sy = dy * speed
        if model.horizontalScrolling { sx = dx * speed }

        let sign: CGFloat = model.invertDirection ? -1 : 1
        postScrollPhase(v: sy * sign, h: sx * sign, phase: .began)
    }

    private func scrollFromMove(dx: CGFloat, dy: CGFloat, model: PreferencesModel) {
        let now = CACurrentMediaTimeNow()   // NANOSECONDS (see note below)
        var instX: CGFloat = 0
        var instY: CGFloat = 0
        // NOTE: CACurrentMediaTimeNow() returns NANOSECONDS (it multiplies mach
        // ticks by numer/denom but omits the /1e9 its name implies) — a dt of
        // ~2e7 means 20 ms. The original code divided by the raw (ns) dt, giving
        // ~1e-6 px/s that Int()-rounded to 0, so `velocity` never left (0,0) and
        // the inertia gate (v>25) never passed. Convert to seconds first.
        if let last = lastMoveTime {
            let dtSec = (now - last) / 1_000_000_000
            if dtSec > 0.001 {   // skip same-timestamp batches (dt ≈ 0)
                let spd = CGFloat(model.speedMultiplier)
                instX = dx * spd / CGFloat(dtSec)   // posted px/s (both axes tracked,
                instY = dy * spd / CGFloat(dtSec)   // so horizontal flings get inertia too)
                velocity.x += (instX - velocity.x) * 0.4   // light low-pass
                velocity.y += (instY - velocity.y) * 0.4   // light low-pass
            }
        }
        lastMoveTime = now

        let speed = CGFloat(model.speedMultiplier)
        var sx: CGFloat = 0
        let sy = dy * speed
        if model.horizontalScrolling { sx = dx * speed }

        scrollMoveCount += 1
        if scrollMoveCount <= 3 || scrollMoveCount % 25 == 0 {
            DebugLog.log("SCROLL move #\(scrollMoveCount) dx=\(Int(dx)) dy=\(Int(dy)) inst=(\(String(format:"%.0f",instX)),\(String(format:"%.0f",instY))) v=(\(Int(velocity.x)),\(Int(velocity.y)))")
        }

        let sign: CGFloat = model.invertDirection ? -1 : 1
        postScrollPhase(v: sy * sign, h: sx * sign, phase: .changed)
    }

    private var scrollMoveCount = 0

    /// Pixel-unit continuous scroll wheel with an explicit phase — AM's format,
    /// including the point-delta fields (kept consistent, PRD §8.5) and field
    /// 101 = 4 which AM sets on every postScroll ("magic" in their code).
    private func postScrollPhase(v: CGFloat, h: CGFloat, phase: CGScrollPhase) {
        let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                         wheel1: Int32(v.rounded()),   // axis 1 = vertical (pixels)
                         wheel2: Int32(h.rounded()),   // axis 2 = horizontal (pixels)
                         wheel3: 0)
        guard let ev else { return }
        // Raw field numbers from CGEventTypes.h (this SDK's Swift overlay lacks
        // the subscripts AM's package adds): IsContinuous=88, ScrollPhase=99.
        ev.setIntegerValueField(CGEventField(rawValue: 88)!, value: 1)
        ev.setIntegerValueField(CGEventField(rawValue: 99)!, value: Int64(phase.rawValue))
        ev.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(v.rounded()))
        ev.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(h.rounded()))
        if phase == .changed { ev.setIntegerValueField(CGEventField(rawValue: 101)!, value: 4) }
        ev.post(tap: .cghidEventTap)
    }

    // MARK: - Inertia (FR-7) — momentum tail, real pixel deltas.
    // BUG FIX: the old postMomentumFrame built events with wheel1/wheel2 = 0 and
    // only set the point-delta fields, but a continuous pixel-wheel scroll reads
    // its movement from wheel1/wheel2 — so every momentum frame moved 0 px and
    // the effect was invisible. We now reuse postScrollPhase(v:h:phase:) (the same
    // path live rolling uses, which DOES scroll), with real pixel deltas.
    // Returns true if a tail was started (it then owns the final `.ended` frame),
    // false otherwise — so endScroll can post `.ended` itself when there's no tail.

    private func startInertiaTail(_ model: PreferencesModel) -> Bool {
        guard model.emulateInertia else { velocity = (0, 0); return false }

        // `velocity` is already in posted px/s (scroll rate at release, tracked in
        // scrollFromMove). Need a real fling to carry momentum.
        let relSpeed = sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
        guard relSpeed > 25 else { velocity = (0, 0); return false }

        stopInertiaTimer()
        let tick: CFTimeInterval = 1.0 / 60.0

        // Smooth braking (exponential): the glide starts at FULL release speed —
        // exactly what your fingers were doing, so there's no sudden "drop" when you
        // let go — and decays exponentially, reaching ~2% of release speed (i.e.
        // imperceptible) exactly at the user's decay time. The lever IS that brake
        // time: "how long after release it takes to stop." Small value = the page
        // coasts a few pixels and stops (invisible inertia); large value = it keeps
        // rolling for seconds.
        let decayS = max(0.02, CGFloat(model.inertiaDecayMs) / 1000.0)   // e.g. 80 ms → 0.08 s
        let sign: CGFloat = model.invertDirection ? -1 : 1
        let doH = model.horizontalScrolling
        var elapsed: CFTimeInterval = 0

        let timer = Timer(timeInterval: tick, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            elapsed += tick
            // v(t) = v0 · e^(-4t/T): ≈91% of release at t=T/5, ~2% (imperceptible)
            // exactly at the set decay time T. Pure exponential = perfectly smooth,
            // no kink or plateau anywhere in the curve.
            let f = exp(-4 * CGFloat(elapsed / decayS))

            // Stop when the per-frame movement is under half a pixel (or on re-arm):
            // that lands just after T, so the effective coast ≈ the set decay time.
            let mag = sqrt(self.velocity.x * self.velocity.x + self.velocity.y * self.velocity.y)
            if self.mode != .idle || f * mag < 0.5 / CGFloat(tick) {
                t.invalidate()
                self.inertiaTimer = nil
                DebugLog.log("TAIL stopped (t=\(String(format:"%.0f", elapsed * 1000))ms decay=\(Int(model.inertiaDecayMs.rounded()))ms)")
                self.postScrollPhase(v: 0, h: 0, phase: .ended)
                return
            }

            self.postScrollPhase(v: self.velocity.y * f * tick * sign,
                                 h: (doH ? self.velocity.x : 0) * f * tick * sign, phase: .changed)
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        inertiaTimer = timer
        DebugLog.log("TAIL started (startV=\(Int(velocity.x)),\(Int(velocity.y)) decay=\(Int(model.inertiaDecayMs.rounded()))ms)")
        return true
    }

    private func stopInertiaTimer() {
        inertiaTimer?.invalidate()
        inertiaTimer = nil
    }
}
