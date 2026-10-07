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
        NSApp.setActivationPolicy(.accessory) // menu-bar only

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rebuildMenu()

        // Engine (FR-12: needs Accessibility for the tap, Input Monitoring for
        // the raw IOHID gate). Start now; it self-disables until permitted.
        BallScrollEngine.shared.onProbeButtonPressed = { [weak self] bit in
            // Fired by the gate (hopped to main) → dispatch before touching UI.
            DispatchQueue.main.async { self?.prefs.handleProbedButton(bit: bit) }
        }
        BallScrollEngine.shared.start(prefs: prefs, enabled: AXPermissions.isTrusted && prefs.enabled)

        // Re-check BOTH permissions on app activation (FR-12, AM parity).
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshPermissionState() }
            .store(in: &cancellables)

        // NFR-4: wake from sleep → re-arm tap + refresh device sources.
        registerWakeObservers()

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
                self.showSettings(tab: 0)
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

        // Fire the native prompts (each shows once per identity).
        if !AXPermissions.isTrusted { AXPermissions.requestPrompt() }
        AXPermissions.requestInputMonitoring()

        let alert = NSAlert()
        alert.messageText = "BallScroll needs two permissions"
        var missing = [String]()
        if !AXPermissions.isTrusted { missing.append("Accessibility — to watch and consume the trackball's mouse events (like Abnormal Mouse)") }
        if !AXPermissions.inputMonitoringGranted { missing.append("Input Monitoring — to read the trackball's raw button + ball reports (device identification)") }
        alert.informativeText = """
        \(missing.joined(separator: "\n"))

        BallScroll does not read your keystrokes and sends no data off this Mac.
        If the toggle isn't available, open System Settings → Privacy & Security.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        let open = { AXPermissions.openAccessibilitySettings(); AXPermissions.openInputMonitoringSettings() }
        if let window = NSApp.keyWindow ?? NSApp.windows.first {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { open() }
            }
        } else {
            let response = alert.runModal()
            if response == .alertFirstButtonReturn { open() }
        }
    }

    // MARK: - Menu bar dropdown (PRD §9)

    private func rebuildMenu() {
        guard let button = statusItem.button else { return }
        if prefs.hasAccessibilityPermission && prefs.hasInputMonitoringPermission && BallScrollEngine.shared.isTrackballConnected() {
            button.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "BallScroll")
        } else {
            button.image = NSImage(systemSymbolName: "arrow.up.arrow.down.circle.badge.exclamationmark",
                                   accessibilityDescription: "BallScroll")
        }

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

    @objc func showSettings(tab: Int = 0) {
        NSApp.activate(ignoringOtherApps: true)
        if settingsWindowController == nil {
            let wc = SettingsWindowController(prefs: prefs, onClosed: { [weak self] in
                self?.settingsWindowController = nil
            })
            settingsWindowController = wc
        }
        settingsWindowController?.show(tab: tab)
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

    @objc private func handleWake() {
        BallScrollEngine.shared.handleWake()
        refreshMenu()
    }
}
