import AppKit

// These services never reach Sparkle, ServiceManagement, or the system permission prompts.
final class UpdateController: NSObject {
    var stateDidChange: (() -> Void)?
    var automaticallyInstallsUpdates = false
    var canCheckForUpdates = true
    let currentVersionText = "1.2.3 (45)"
    private(set) var checkCount = 0

    @objc func checkForUpdates(_ sender: Any?) {
        checkCount += 1
        canCheckForUpdates = false
        stateDidChange?()
    }
}

enum LaunchAtLoginController {
    static var isEnabled = false
    static var requested = [Bool]()
    static func setEnabled(_ enabled: Bool) throws {
        requested.append(enabled)
        isEnabled = enabled
    }
}

enum PermissionManager {
    static let didChangeNotification = Notification.Name("SettingsWindowLayoutTests.permissions")
    static var status = Status(accessibilityGranted: true, screenRecordingGranted: true)
    static var requested = [Permission]()
    static var opened = [Permission]()

    enum Permission: CaseIterable {
        case accessibility, screenRecording
        var title: String { self == .accessibility ? "Accessibility" : "Screen Recording" }
    }

    struct Status: Equatable {
        let accessibilityGranted: Bool
        let screenRecordingGranted: Bool
        var allGranted: Bool { accessibilityGranted && screenRecordingGranted }
        var missingPermissions: [Permission] { Permission.allCases.filter { !isGranted($0) } }
        func isGranted(_ permission: Permission) -> Bool {
            permission == .accessibility ? accessibilityGranted : screenRecordingGranted
        }
    }

    static func request(_ permission: Permission) { requested.append(permission) }
    static func openSystemSettings(for permission: Permission) -> Bool {
        opened.append(permission)
        return true
    }

    static func publish(accessibility: Bool, recording: Bool) {
        status = Status(accessibilityGranted: accessibility, screenRecordingGranted: recording)
        NotificationCenter.default.post(name: didChangeNotification, object: status)
    }
}

enum DockScreenLocator {
    static func previewAnchor() -> CGRect? {
        ScreenGeometry.fixtureFrame
    }
}

enum ScreenGeometry {
    static var fixtureFrame = NSRect.zero
    static var appKitReferenceMaxY: CGFloat { fixtureFrame.maxY }
    static func screen(containing rect: CGRect) -> NSScreen? { SettingsFixtureScreen() }
}

private final class SettingsFixtureScreen: NSScreen {
    override var frame: NSRect { ScreenGeometry.fixtureFrame }
}

final class WindowPeekController {
    static let shared = WindowPeekController()
    func show(preview: WindowPreview) {}
    func updateSnapshot(preview: WindowPreview) {}
    func hide() {}
    func hide(windowID: CGWindowID) {}
}

struct WindowPreview {
    let windowID: CGWindowID
    let title: String
    let bounds: CGRect
    let isMinimized: Bool
    let isFullscreen: Bool
    let isFocused: Bool
    let desktop: WindowDesktop?
    let image: NSImage?
    let app: NSRunningApplication

    func replacingImage(with image: NSImage?) -> WindowPreview {
        WindowPreview(
            windowID: windowID, title: title, bounds: bounds, isMinimized: isMinimized,
            isFullscreen: isFullscreen, isFocused: isFocused, desktop: desktop, image: image, app: app
        )
    }
}

struct WindowDesktop: Hashable {
    let id: UInt64
    let title: String
    let sortOrder: Int
    let isCurrent: Bool
}
