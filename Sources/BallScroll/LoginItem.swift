//  LoginItem.swift — launch at login (FR-11) via SMAppService.

import Foundation
import ServiceManagement

enum LoginItem {
    static var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("BallScroll: login item registration failed: \(error.localizedDescription)")
            return false
        }
        return true
    }
}
