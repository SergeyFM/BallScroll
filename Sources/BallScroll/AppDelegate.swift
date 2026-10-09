//  AppDelegate.swift — menu-bar app shell (NFR-1, FR-11/12).
//
//  AppKit NSStatusItem for the dropdown (AM parity); SwiftUI for settings.

import AppKit
import Combine
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let prefs = PreferencesModel()
    private var settingsWindowController: SettingsWindowController?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard (NFR): another BallScroll already running → exit
        // so we never run two taps over the same events (e.g. dev build/ copy
        // alongside the /Applications install, or a manual double-launch).
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.sergey.BallScroll")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            DebugLog.log("single-instance: another BallScroll (pid \(others[0].processIdentifier)) is running — exiting")
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory) // menu-bar only

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rebuildMenu()

        // statusItem.button can be nil on the first run-loop turn after creation
        // (macOS version-dependent) — rebuildMenu's guard then no-ops and the menu
        // bar shows nothing until a click (didBecomeActive) re-triggers it. Re-apply
        // the icon once the button is actually ready so it's visible at launch.
        DispatchQueue.main.async { [weak self] in
            if let b = self?.statusItem.button, b.image == nil { self?.rebuildMenu() }
        }

        // Engine (FR-12: needs Accessibility for the tap, Input Monitoring for
        // the raw IOHID gate). Start now; it self-disables until permitted.
        BallScrollEngine.shared.onProbeButtonPressed = { [weak self] bit in
            // Fired by the gate (hopped to main) → dispatch before touching UI.
            // Small delay: let the engine's onProbeCGDown land first so the
            // CG button number (the identity we actually match) is recorded.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.prefs.handleProbedButton(bit: bit) }
        }
        BallScrollEngine.shared.onProbeCGDown = { [weak self] number in
            DispatchQueue.main.async { self?.prefs.lastSeenCGButton = number }
        }
        BallScrollEngine.shared.start(prefs: prefs, enabled: AXPermissions.isTrusted && prefs.enabled)

        // Re-check BOTH permissions on app activation (FR-12, AM parity).
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshPermissionState() }
            .store(in: &cancellables)

        // Device / permission state changes → refresh the menu-bar icon
        // immediately. Previously only a click (didBecomeActive) or the 1.5s
        // permission poller triggered rebuildMenu, so at launch the icon kept
        // showing the "attention" mark until you clicked it even though the
        // trackball had already connected.
        prefs.$trackballConnected
            .sink { [weak self] _ in self?.refreshMenu() }
            .store(in: &cancellables)
        prefs.$hasAccessibilityPermission
            .sink { [weak self] _ in self?.refreshMenu() }
            .store(in: &cancellables)
        prefs.$hasInputMonitoringPermission
            .sink { [weak self] _ in self?.refreshMenu() }
            .store(in: &cancellables)

        // NFR-4: wake from sleep → re-arm tap + refresh device sources.
        registerWakeObservers()

        // One-shot: user wants it as a normal always-on app → enable the login
        // item automatically (FR-11). No-op if already registered; idempotent.
        if !prefs.loginItemEnabled { prefs.loginItemEnabled = true }

        // Menu-bar (.accessory) apps never "become active", so the didBecomeActive
        // hook alone misses permission grants made in System Settings. Poll both
        // TCC states until fully granted, then re-arm (FR-12). Cheap: two API calls
        // / 1.5s; stops once both are true (wake re-check still covers later).
        startPermissionPoller()

        // First-run: prompt for the permissions we're missing, then guide to
        // the button probe. (Input Monitoring is needed because the device gate
        // reads raw IOHID — CGEventGetSource is absent in this SDK.)
        if !AXPermissions.isTrusted || !AXPermissions.inputMonitoringGranted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.showPermissionPanel()
            }
        } else if !prefs.probeCompleted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                self.showSettings()
                self.prefs.startSequentialProbe()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        BallScrollEngine.shared.stop()
        prefs.persist()
    }

    // MARK: - Permission state (FR-12)

    private func refreshPermissionState() {
        let trusted = AXPermissions.isTrusted
        let imGranted = AXPermissions.inputMonitoringGranted

        // Accessibility changed → (re)install or drop the event tap.
        if trusted != prefs.hasAccessibilityPermission {
            prefs.hasAccessibilityPermission = trusted
            BallScrollEngine.shared.isEnabled = trusted && prefs.enabled
        }

        // Input Monitoring changed → the raw IOHID gate must be restarted to
        // pick it up (it opened before the grant, so it sees no device).
        if imGranted != prefs.hasInputMonitoringPermission {
            prefs.hasInputMonitoringPermission = imGranted
            if imGranted { BallScrollEngine.shared.restartGate() }
        }

        rebuildMenu()
    }

    private func showPermissionPanel() {
        guard !AXPermissions.isTrusted || !AXPermissions.inputMonitoringGranted else { return }

        // Fire the native system prompts (each shows once per identity). We
        // deliberately avoid our own modal NSAlert here: a menu-bar (.accessory)
        // app has no window to host it, so it would either fall back to runModal
        // (blocking the main loop + our poller) or float invisibly behind other
        // windows. Instead the app self-arms via the background permission
        // poller, and the Settings window (menu bar icon) offers an explicit
        // "Open System Settings…" button for manual action.
        if !AXPermissions.isTrusted { AXPermissions.requestPrompt() }
        AXPermissions.requestInputMonitoring()
        DebugLog.log("permission prompts fired (poller will self-arm on grant)")
    }

    // MARK: - Menu bar dropdown (PRD §9)

    private func rebuildMenu() {
        guard let button = statusItem.button else { return }
        let ok = prefs.hasAccessibilityPermission && prefs.hasInputMonitoringPermission && BallScrollEngine.shared.isTrackballConnected()
        button.image = BallScrollIconRenderer.menuBarIcon(warning: !ok)

        let menu = NSMenu()
        let trusted = prefs.hasAccessibilityPermission
        let imOK = prefs.hasInputMonitoringPermission
        let on = trusted && imOK && prefs.enabled

        // Status line (AM-style).
        let statusTitle: String
        if !trusted || !imOK { statusTitle = "Permissions needed (Accessibility / Input Monitoring)" }
        else if BallScrollEngine.shared.isTrackballConnected() { statusTitle = on ? "BallScroll is functioning." : "BallScroll is not enabled." }
        else { statusTitle = "Trackball not detected" }
        let statusItem_ = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusItem_.isEnabled = false
        menu.addItem(statusItem_)

        menu.addItem(.separator())

        // Enable / Disable (FR-11).
        let enableItem = NSMenuItem(title: on ? "Disable" : "Enable",
                                    action: #selector(toggleEnabled), keyEquivalent: "")
        enableItem.target = self
        menu.addItem(enableItem)

        // Invert direction quick flip (FR-4).
        let invertItem = NSMenuItem(title: "Invert scroll direction: \(prefs.invertDirection ? "Inverted" : "Normal")",
                                    action: #selector(toggleInvert), keyEquivalent: "")
        invertItem.target = self
        menu.addItem(invertItem)

        menu.addItem(.separator())

        let prefsItem = NSMenuItem(title: "Show Preferences…", action: #selector(showSettings), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        let quitItem = NSMenuItem(title: "Quit BallScroll", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Rebuild the dropdown title (called when state changes while open).
    func refreshMenu() { rebuildMenu() }

    @objc private func toggleEnabled() {
        prefs.enabled.toggle()
        prefs.persist()
        BallScrollEngine.shared.isEnabled =
            prefs.hasAccessibilityPermission && prefs.hasInputMonitoringPermission && prefs.enabled
        rebuildMenu()
    }

    @objc private func toggleInvert() {
        prefs.invertDirection.toggle()
        prefs.persist()
    }

    @objc func showSettings() {
        // "Normal app" behavior while settings are open: Dock (left) + menu-bar
        // (right-top). .accessory → no Dock icon; .regular → both. (LSUIElement
        // in Info.plist keeps it menu-bar-only at launch / when closed.)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if settingsWindowController == nil {
            let wc = SettingsWindowController(prefs: prefs, onClosed: { [weak self] in
                guard let self else { return }
                self.settingsWindowController = nil
                // Settings closed → back to menu-bar only (no Dock icon).
                NSApp.setActivationPolicy(.accessory)
            })
            settingsWindowController = wc
        }
        settingsWindowController?.show()
    }

    @objc private func quit() {
        prefs.persist()
        NSApp.terminate(nil)
    }

    // MARK: - Sleep/wake (NFR-4)

    private func registerWakeObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    // MARK: - Permission polling (FR-12, menu-bar apps don't get didBecomeActive)

    private var permissionPollTimer: Timer?
    private func startPermissionPoller() {
        guard !AXPermissions.isTrusted || !AXPermissions.inputMonitoringGranted else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let trusted = AXPermissions.isTrusted
            let imGranted = AXPermissions.inputMonitoringGranted
            if trusted != self.prefs.hasAccessibilityPermission { DebugLog.log("poll: Accessibility -> \(trusted)") }
            if imGranted != self.prefs.hasInputMonitoringPermission { DebugLog.log("poll: Input Monitoring -> \(imGranted)") }
            self.refreshPermissionState() // installs/restarts tap+gate on change, updates menu
            if trusted && imGranted {
                t.invalidate()
                self.permissionPollTimer = nil
            }
        }
        permissionPollTimer = timer
    }

    @objc private func handleWake() {
        BallScrollEngine.shared.handleWake()
        refreshMenu()
    }
}
