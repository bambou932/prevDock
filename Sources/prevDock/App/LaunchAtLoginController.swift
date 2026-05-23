import Foundation
import ServiceManagement

enum LaunchAtLoginController {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func applyDefaultIfNeeded(isFreshInstall: Bool) {
        guard isFreshInstall, !PrevDockSettings.launchAtLoginDefaultApplied else { return }
        defer { PrevDockSettings.launchAtLoginDefaultApplied = true }

        do {
            try setEnabled(true)
        } catch {
            NSLog("Could not enable prevDock login item by default: \(error.localizedDescription)")
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try register()
        } else {
            try unregister()
        }
    }

    private static func register() throws {
        guard SMAppService.mainApp.status != .enabled else { return }
        try SMAppService.mainApp.register()
    }

    private static func unregister() throws {
        guard SMAppService.mainApp.status != .notRegistered else { return }
        try SMAppService.mainApp.unregister()
    }
}
