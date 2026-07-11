import Foundation
import ServiceManagement

enum LaunchAtLoginController {
    private static var didAttemptDefaultThisLaunch = false

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func applyDefaultIfNeeded(isFreshInstall: Bool) {
        if isFreshInstall, !PrevDockSettings.launchAtLoginDefaultApplied {
            PrevDockSettings.launchAtLoginDefaultPending = true
        }
        guard PrevDockSettings.launchAtLoginDefaultPending,
              !PrevDockSettings.launchAtLoginDefaultApplied,
              !didAttemptDefaultThisLaunch else {
            return
        }
        didAttemptDefaultThisLaunch = true

        do {
            try updateService(enabled: true)
            markDefaultHandled()
        } catch {
            NSLog("Could not enable prevDock login item by default: \(error.localizedDescription)")
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        try updateService(enabled: enabled)
        markDefaultHandled()
    }

    private static func updateService(enabled: Bool) throws {
        if enabled {
            try register()
        } else {
            try unregister()
        }
    }

    private static func markDefaultHandled() {
        PrevDockSettings.launchAtLoginDefaultApplied = true
        PrevDockSettings.launchAtLoginDefaultPending = false
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
