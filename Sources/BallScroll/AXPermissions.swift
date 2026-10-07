//  AXPermissions.swift — TCC handling, FR-12.
//
//  Two permissions are now required (the PRD originally assumed only Accessibility,
//  before we found `CGEventGetSource` is absent in this SDK — so the device gate
//  reads raw IOHID, which needs Input Monitoring):
//    * Accessibility — required to install the active CGEventTap (consume/post).
//    * Input Monitoring — required for IOHIDManager to enumerate the trackball and
//      deliver raw input reports (the FR-8 device gate).
//
//  Both bind to code identity → ad-hoc sign + stable bundle ID (PRD §8.10).

import AppKit
import CoreGraphics
import IOKit.hid

enum AXPermissions {
    // MARK: Accessibility (the event tap)

    /// Is this process trusted for Accessibility?
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Show the system Accessibility prompt (once per identity until granted).
    static func requestPrompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: Input Monitoring (the raw IOHID device gate)

    /// Is this process granted to listen to HID input reports?
    static var inputMonitoringGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Request Input Monitoring (prompts once per identity). Returns whether a
    /// prompt was issued; the user still has to approve in System Settings.
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    // MARK: Aggregate (used by UI + first-run flow)

    /// Both permissions satisfied → the app can actually transform events.
    static var isFullyPermitted: Bool { isTrusted && inputMonitoringGranted }
}
