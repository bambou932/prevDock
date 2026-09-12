import ApplicationServices
import Cocoa

enum DockContextMenuController {
    private static var cachedVisibility: Bool?
    private static var hasCachedVisibility = false
    private static var lastVisibilityCheck: TimeInterval = 0
    private static let visibilityCacheLifetime: TimeInterval = 0.15

    static func dismissIfVisible() -> Bool {
        guard visibility(forceRefresh: true) != false else { return true }
        let deadline = ProcessInfo.processInfo.systemUptime + DockAccessibility.maximumScanDuration
        if cancelMenu(inBundleIdentifier: "com.apple.dock.helper", deadline: deadline) {
            return true
        }
        return cancelMenu(inBundleIdentifier: "com.apple.dock", deadline: deadline)
    }

    static func visibility(forceRefresh: Bool = false) -> Bool? {
        let now = ProcessInfo.processInfo.systemUptime
        if !forceRefresh,
           hasCachedVisibility,
           now - lastVisibilityCheck < visibilityCacheLifetime {
            return cachedVisibility
        }
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            cachedVisibility = nil
            hasCachedVisibility = true
            lastVisibilityCheck = now
            return nil
        }

        cachedVisibility = windows.contains { window in
            let owner = window[kCGWindowOwnerName as String] as? String
            guard owner == "DockHelper" || owner == "Dock" else {
                return false
            }
            return (window[kCGWindowLayer as String] as? Int ?? 0) >= NSWindow.Level.popUpMenu.rawValue
        }
        hasCachedVisibility = true
        lastVisibilityCheck = now
        return cachedVisibility
    }

    private static func cancelMenu(inBundleIdentifier bundleIdentifier: String, deadline: TimeInterval) -> Bool {
        guard ProcessInfo.processInfo.systemUptime < deadline,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return false
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return cancelMenu(in: appElement, deadline: deadline)
    }

    private static func cancelMenu(in element: AXUIElement, deadline: TimeInterval, depth: Int = 0) -> Bool {
        guard depth < 4, ProcessInfo.processInfo.systemUptime < deadline else { return false }
        DockAccessibility.prepare(element)
        if AccessibilityHelpers.stringAttribute(element, kAXRoleAttribute as CFString) == kAXMenuRole as String {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            return AXUIElementPerformAction(element, kAXCancelAction as CFString) == .success
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
        for child in AccessibilityHelpers.elementArrayAttribute(element, kAXChildrenAttribute as CFString) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            if cancelMenu(in: child, deadline: deadline, depth: depth + 1) {
                return true
            }
        }
        return false
    }
}
