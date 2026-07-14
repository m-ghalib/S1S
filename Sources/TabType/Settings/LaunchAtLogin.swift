import Foundation
import ServiceManagement

/// Wraps `SMAppService` to toggle "launch TabType at login". Works only for a
/// properly bundled, signed .app.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("TabType: launch-at-login toggle failed: \(error.localizedDescription)")
        }
    }
}
