//  TrackballGate.swift — FR-8 device gate, driven by raw IOHID input reports.
//
//  `CGEventGetSource` is not available in this SDK (verified at link time), so
//  a CGEvent cannot be attributed to its HID device. The gate therefore owns an
//  IOHIDManager matched EXACTLY to the T-BC21 (0x46D:0xC3C) and runs it on a
//  dedicated background run loop. It exposes, under one lock:
//    * connection state (removal callback clears it) — NFR-4
//    * lastActivity     (monotonic time of the latest raw report)
//    * pending movement (raw ball X/Y deltas accumulated since last drain)
//  and fires, on a background thread (engine hops to main):
//    * onPress / onRelease with the physical HID bit index + monotonic time.
//
//  The engine (main run loop, CG tap) reads this state per event. Because the
//  gate only sees trackball reports, "affects only the T-BC21" (FR-8) is built
//  in: Magic Mouse / trackpad events never move the gate, so they are always
//  passed through untouched (AC #8). Raw deltas bypass the macOS pointer
//  pipeline, so no cursor acceleration is baked into scroll (G1 linearity).

import Foundation
import IOKit.hid
import CoreGraphics

final class TrackballGate {
    static let vendorID = 0x46D   // Logitech
    static let productID = 0xC3C  // USB Trackball / Marble T-BC21

    /// Physical button bit indices (HID report byte 0, bit n-1 = libinput btn_n):
    /// largeLeft=bit0, (emulated middle)=bit1, largeRight=bit2,
    /// smallLeft(side)=bit3, smallRight(extra) = bit4  ← Abnormal Mouse "button 5".
    static let idxLargeLeft   = 0
    static let idxMiddleEmul  = 1
    static let idxLargeRight  = 2
    static let idxSmallLeft   = 3
    static let idxSmallRight  = 4

    struct Movement { var dx: CGFloat; var dy: CGFloat }

    private let lock = NSLock()
    private var connected = false
    private var lastActivity: CFTimeInterval = 0          // monotonic
    private var buttonsDown: Set<Int> = []                // bit indices
    private var pendingDX: CGFloat = 0
    private var pendingDY: CGFloat = 0

    private var manager: IOHIDManager?

    // MARK: Hooks (fire on the main run loop — keep them light)

    var onPress: ((Int, CFTimeInterval) -> Void)?
    var onRelease: ((Int, CFTimeInterval) -> Void)?
    /// Connection changed (true = at least one device matched). Delivered on main.
    var onChange: ((Bool) -> Void)?

    // MARK: Lifecycle (call on main thread)

    func start() {
        guard manager == nil else { return } // idempotent (stop() then start())

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(0))
        self.manager = manager

        let match: [String: Any] = ["VendorID": Self.vendorID, "ProductID": Self.productID]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

        let ctx = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterInputReportCallback(manager, { ctx, _, _, _, _, ptr, len in
            guard let ctx else { return }
            Unmanaged<TrackballGate>.fromOpaque(ctx).takeUnretainedValue().handleReport(ptr, len: Int(len))
        }, ctx)

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, _ in
            guard let ctx else { return }
            Unmanaged<TrackballGate>.fromOpaque(ctx).takeUnretainedValue().noteConnect()
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, _ in
            guard let ctx else { return }
            Unmanaged<TrackballGate>.fromOpaque(ctx).takeUnretainedValue().noteDisconnect()
        }, ctx)

        // Schedule on the MAIN run loop (the CG tap already runs there too):
        // a bare RunLoop on a GCD worker thread traps under this SDK, and the
        // main loop is already spinning. HID sources deliver their callbacks on
        // whatever run loop they're scheduled with → all gate + tap state now
        // lives on the main thread (no cross-thread handoff, still lock-guarded).
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain()!, CFRunLoopMode.commonModes.rawValue)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(0))
        if openResult != 0 {
            NSLog("BallScroll: IOHIDManagerOpen = \(openResult) (needs Input Monitoring?)")
        }

        // Device may already be plugged in before start().
        if let devs = IOHIDManagerCopyDevices(manager) as? [IOHIDDevice], !devs.isEmpty {
            noteConnect()
        } else {
            DebugLog.log("start: no matched device yet (IOHIDManagerOpen=\(openResult))")
        }
        DebugLog.log("gate started: open=\(openResult) connected=\(isConnected)")
    }

    func stop() {
        if let m = manager {
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain()!, CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(m, IOOptionBits(0))
        }
        manager = nil
    }

    // MARK: State access (thread-safe; the engine reads these per event)

    /// True if the trackball is connected and produced a report within `window` s.
    func isActive(window: CFTimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return connected && (CACurrentMediaTimeNow() - lastActivity) <= window
    }

    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return connected }

    /// Drain accumulated raw ball movement since the last call (main loop only).
    func drainMovement() -> Movement? {
        lock.lock(); defer { lock.unlock() }
        if pendingDX == 0 && pendingDY == 0 { return nil }
        let m = Movement(dx: pendingDX, dy: pendingDY)
        pendingDX = 0; pendingDY = 0
        return m
    }

    /// Drop any accumulated movement (called when arming, so the button press's
    /// own jitter isn't counted toward the deadzone). Main loop only.
    func clearPendingMovement() {
        lock.lock(); pendingDX = 0; pendingDY = 0; lock.unlock()
    }

    // MARK: - Handlers (fire on the main run loop — keep them light)

    private func handleReport(_ ptr: UnsafeMutablePointer<UInt8>, len: Int) {
        let now = CACurrentMediaTimeNow()
        guard len >= 3 else { return }

        let mask = Int(ptr[0])
        var newDown: Set<Int> = []
        for i in 0..<8 where (mask >> i) & 1 == 1 { newDown.insert(i) }

        // Raw pointer deltas are signed bytes (little-endian, mouse usage page).
        let dx = CGFloat(Int8(bitPattern: ptr[1]))
        let dy = CGFloat(Int8(bitPattern: ptr[2]))

        // Throttled: raw reports fire ~60–125 Hz; we want to see activity,
        // not flood the file. State transitions (press/release) log separately.
        DebugLog.logThrottled("report len=\(len) mask=0b\(String(mask, radix: 2)) dx=\(dx) dy=\(dy)", atMostEvery: 0.5)

        lock.lock()
        for b in newDown where !buttonsDown.contains(b) {
            DebugLog.log("PRESS bit \(b)")
            onPress?(b, now)
        }
        for b in buttonsDown where !newDown.contains(b) {
            DebugLog.log("RELEASE bit \(b)")
            onRelease?(b, now)
        }
        buttonsDown = newDown
        lastActivity = now

        // Accumulate always (the engine drains and decides: armed deadzone vs
        // scrolling). No button filtering here — hold-to-scroll needs the moves.
        pendingDX += dx
        pendingDY += dy
        lock.unlock()
    }

    private func noteConnect() {
        lock.lock(); let changed = connected; connected = true; lock.unlock()
        if !changed {
            DebugLog.log("DEVICE CONNECTED")
            DispatchQueue.main.async { [weak self] in self?.onChange?(true) }
        }
    }

    private func noteDisconnect() {
        lock.lock(); let was = connected; connected = false; buttonsDown.removeAll(); lock.unlock()
        if was {
            DebugLog.log("DEVICE DISCONNECTED")
            DispatchQueue.main.async { [weak self] in self?.onChange?(false) }
        }
    }
}

/// CACurrentMediaTime (mach_absolute_time), monotonic and thread-comparable.
func CACurrentMediaTimeNow() -> CFTimeInterval {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return Double(mach_absolute_time()) * Double(tb.numer) / Double(tb.denom)
}

/// Opt-in debug trace (BALLSCROLL_DEBUG_LOG=1): gate + state machine events.
/// Also appends to BALLSCROLL_DEBUG_LOG_FILE (default ~/ballscroll_debug.log) so
/// it survives across reboots regardless of the unified-log subsystem.
enum DebugLog {
    /// Enabled by env `BALLSCROLL_DEBUG_LOG` OR UserDefaults key `DebugLog=1`.
    /// (The env path covers a manually launched build; the UserDefaults key
    /// survives a reboot when the app is started by LaunchServices.)
    static let enabled =
        ProcessInfo.processInfo.environment["BALLSCROLL_DEBUG_LOG"] != nil ||
        UserDefaults.standard.bool(forKey: "BallScrollDebugLog")
    private static let fileURL: URL = {
        let path = ProcessInfo.processInfo.environment["BALLSCROLL_DEBUG_LOG_FILE"] ?? "~/ballscroll_debug.log"
        return URL(fileURLWithPath: path.replacingOccurrences(of: "~", with: NSHomeDirectory()))
    }()
    private static let fileLock = NSLock()
    private static var lastFileWrite: CFTimeInterval = 0

    static func log(_ s: String) {
        guard enabled else { return }
        NSLog("[BallScroll] \(s)")
        write(s)
    }

    static func logThrottled(_ s: String, atMostEvery seconds: CFTimeInterval = 0.5) {
        guard enabled else { return }
        NSLog("[BallScroll] \(s)")
        let now = CACurrentMediaTimeNow()
        fileLock.lock()
        defer { fileLock.unlock() }
        if now - lastFileWrite < seconds { return }
        lastFileWrite = now
        appendToFile(s)
    }

    private static func write(_ s: String) {
        fileLock.lock(); defer { fileLock.unlock() }
        appendToFile(s)
    }

    private static func appendToFile(_ s: String) {
        let line = "[BallScroll] \(s)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: fileURL) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
            try? h.close()
        }
    }
}
