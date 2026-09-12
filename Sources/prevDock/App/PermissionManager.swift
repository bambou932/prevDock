import ApplicationServices
import AppKit
import CoreGraphics

enum PermissionManager {
    static let didChangeNotification = Notification.Name("PrevDockPermissionsDidChange")
    private static let statusCache = PermissionStatusCache(
        unavailableValue: Status(accessibilityGranted: false, screenRecordingGranted: false),
        probe: {
            Status(
                accessibilityGranted: AXIsProcessTrusted(),
                screenRecordingGranted: CGPreflightScreenCaptureAccess()
            )
        },
        onChange: { status in
            NotificationCenter.default.post(name: didChangeNotification, object: status)
        }
    )

    enum Permission: CaseIterable {
        case accessibility
        case screenRecording

        var title: String {
            switch self {
            case .accessibility:
                return "Accessibility"
            case .screenRecording:
                return "Screen Recording"
            }
        }

        fileprivate var settingsAnchor: String {
            switch self {
            case .accessibility:
                return "Privacy_Accessibility"
            case .screenRecording:
                return "Privacy_ScreenCapture"
            }
        }
    }

    struct Status: Equatable {
        let accessibilityGranted: Bool
        let screenRecordingGranted: Bool

        var allGranted: Bool {
            accessibilityGranted && screenRecordingGranted
        }

        var missingPermissions: [Permission] {
            Permission.allCases.filter { !isGranted($0) }
        }

        func isGranted(_ permission: Permission) -> Bool {
            switch permission {
            case .accessibility:
                return accessibilityGranted
            case .screenRecording:
                return screenRecordingGranted
            }
        }
    }

    static var status: Status {
        statusCache.value
    }

    @discardableResult
    static func refreshStatus() -> Status {
        statusCache.refresh()
    }

    static func request(_ permission: Permission) {
        defer { refreshStatus() }
        switch permission {
        case .accessibility:
            requestAccessibility()
        case .screenRecording:
            requestScreenRecording()
        }
    }

    static func requestAccessibility() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func requestScreenRecording() {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
    }

    @discardableResult
    static func openSystemSettings(for permission: Permission) -> Bool {
        let pane = "x-apple.systempreferences:com.apple.preference.security?\(permission.settingsAnchor)"
        if let url = URL(string: pane), NSWorkspace.shared.open(url) {
            return true
        }

        let settingsApp = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        return NSWorkspace.shared.open(settingsApp)
    }
}
