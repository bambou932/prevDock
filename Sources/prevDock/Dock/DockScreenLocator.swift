import ApplicationServices
import Cocoa

enum DockScreenLocator {
    static func previewAnchor() -> CGRect? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return fallbackDockAnchor()
        }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        return dockLists(in: dockElement)
            .compactMap(dockRect)
            .sorted(by: largestAreaFirst)
            .first ?? fallbackDockAnchor()
    }

    private static func dockLists(in element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < 5 else { return [] }
        let role = AccessibilityHelpers.stringAttribute(element, kAXRoleAttribute as CFString) ?? ""
        let children = AccessibilityHelpers.elementArrayAttribute(element, kAXChildrenAttribute as CFString)
        let childLists = children.flatMap { dockLists(in: $0, depth: depth + 1) }
        return role == "AXList" ? [element] + childLists : childLists
    }

    private static func dockRect(for element: AXUIElement) -> CGRect? {
        guard let position = AccessibilityHelpers.pointAttribute(element, kAXPositionAttribute as CFString),
              let size = AccessibilityHelpers.sizeAttribute(element, kAXSizeAttribute as CFString),
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        let rect = AccessibilityHelpers.appKitRect(fromAccessibilityPosition: position, size: size)
        guard let screen = ScreenGeometry.screen(containing: rect) else { return rect }
        let clipped = rect.intersection(screen.frame)
        return clipped.isNull || clipped.isEmpty ? rect : clipped
    }

    private static func fallbackDockAnchor() -> CGRect? {
        for screen in NSScreen.screens {
            let frame = screen.frame
            let visibleFrame = screen.visibleFrame
            if visibleFrame.minY > frame.minY + 1 {
                return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: visibleFrame.minY - frame.minY)
            }
            if visibleFrame.minX > frame.minX + 1 {
                return CGRect(x: frame.minX, y: frame.minY, width: visibleFrame.minX - frame.minX, height: frame.height)
            }
            if visibleFrame.maxX < frame.maxX - 1 {
                return CGRect(x: visibleFrame.maxX, y: frame.minY, width: frame.maxX - visibleFrame.maxX, height: frame.height)
            }
        }
        return NSScreen.main?.frame
    }
    private static func largestAreaFirst(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        lhs.width * lhs.height > rhs.width * rhs.height
    }
}
