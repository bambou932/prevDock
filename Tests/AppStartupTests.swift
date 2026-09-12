import AppKit
import Darwin

@main
enum AppStartupTests {
    static func main() {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        expect(UpdateController.creationCount == 0, "constructing the app delegate must not start the updater")
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        expect(LaunchAtLoginController.receivedFreshInstall == true,
               "first-launch detection must run before an updater can create persistent defaults")
        expect(UpdateController.creationCount == 1, "the accepted instance should still initialize its updater")
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        print("AppStartupTests: passed")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}

// Exercise the real delegate's startup ordering without changing login items or user permissions.
final class UpdateController: NSObject {
    static var creationCount = 0
    override init() {
        Self.creationCount += 1
        super.init()
    }
    @objc func checkForUpdates(_ sender: Any?) {}
}

enum PrevDockSettings {
    static var hasPersistentSettingsDomain: Bool { UpdateController.creationCount > 0 }
    static let didChangeNotification = Notification.Name("AppStartupTests.settings")
    static let nativeDockLabelSuppressionEnabledKey = "suppression"
    static var permissionSetupShown = false
    static func registerDefaults() {}
}

enum LaunchAtLoginController {
    static var receivedFreshInstall: Bool?
    static func applyDefaultIfNeeded(isFreshInstall: Bool) { receivedFreshInstall = isFreshInstall }
}

enum SingleInstanceCoordinator {
    static func claimInstance() -> Bool { true }
}

enum PermissionManager {
    struct Status: Equatable {
        let screenRecordingGranted = true
        let allGranted = true
    }
    static let status = Status()
    static let didChangeNotification = Notification.Name("AppStartupTests.permissions")
}

final class PreviewPanelController {
    func contains(_ point: CGPoint) -> Bool { false }
    func hide() {}
}

final class DockMouseEventSuppressor {
    var shouldPassThroughMouseMoved: ((CGPoint) -> Bool)?
    var onSuppressedMouseMoved: (() -> Void)?
    func updateForCurrentSettings() {}
    func stop() {}
}

final class HoverDebugPanelController {
    func toggle() {}
}

final class SettingsWindowController {
    let isVisible = false
    init(updateController: UpdateController) {}
    func showSettings() {}
    func showPermissionSettings() {}
}

final class DockHoverMonitor {
    init(previewController: PreviewPanelController) {}
    func wakeForSuppressedMouseMoved() {}
    func start() {}
}

final class DockGeometryCache {
    static let shared = DockGeometryCache()
    func refreshNow() {}
}

enum WindowInventory {
    static func discardCachedThumbnails() {}
}
