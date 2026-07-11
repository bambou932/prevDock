import ApplicationServices
import Cocoa
import CoreGraphics

struct DockSnapshotAXLocation {
    let dockPID: Int32
    let preferredWindowID: CGWindowID?
    let displayID: UInt32
    let edge: DockSnapshotEdge
    let dockRect: CGRect
    let finderRect: CGRect
    let screenFrame: CGRect
    let appKitScreenFrame: CGRect
    let backingScaleFactor: CGFloat
    let tileSizePreference: CGFloat?
}

enum DockScreenLocator {
    static func previewAnchor() -> CGRect? {
        guard AXIsProcessTrusted(), let dock = dockApplication() else {
            return fallbackDockAnchor()
        }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        return dockListLocations(in: dockElement)
            .map { clippedPreviewRect($0.appKitRect) }
            .sorted(by: largestAreaFirst)
            .first ?? fallbackDockAnchor()
    }

    static func snapshotLocation(for requestedScreen: NSScreen?) -> DockSnapshotAXLocation? {
        guard AXIsProcessTrusted(),
              let dock = dockApplication(),
              let preferredScreen = requestedScreen ?? NSScreen.main ?? NSScreen.screens.first else {
            return nil
        }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        let locations = dockListLocations(in: dockElement)
        let preferredScreenFrame = quartzRect(fromAppKitRect: preferredScreen.frame)
        guard let selection = bestDockList(from: locations, intersecting: preferredScreenFrame) ??
                largestDockList(from: locations),
              let screen = screen(intersecting: selection.location.quartzRect) ??
                screen(nearestTo: selection.location.quartzRect) ?? requestedScreen ?? NSScreen.main,
              let displayID = displayID(for: screen),
              let finderRect = quartzRect(for: selection.finder) else {
            return nil
        }
        let list = selection.location
        let screenFrame = quartzRect(fromAppKitRect: screen.frame)

        return DockSnapshotAXLocation(
            dockPID: dock.processIdentifier,
            preferredWindowID: windowID(for: list.element),
            displayID: displayID,
            edge: DockSnapshotGeometryCalculator.edge(
                forQuartzDockRect: list.quartzRect,
                in: screenFrame
            ),
            dockRect: list.quartzRect,
            finderRect: finderRect,
            screenFrame: screenFrame,
            appKitScreenFrame: screen.frame,
            backingScaleFactor: screen.backingScaleFactor,
            tileSizePreference: DockSystemPreferences.tileSize
        )
    }

    private static func dockApplication() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
    }

    private static func dockListLocations(
        in element: AXUIElement,
        depth: Int = 0
    ) -> [DockListLocation] {
        guard depth < 6 else { return [] }
        let role = AccessibilityHelpers.stringAttribute(element, kAXRoleAttribute as CFString) ?? ""
        let children = AccessibilityHelpers.elementArrayAttribute(element, kAXChildrenAttribute as CFString)
        let descendants = children.flatMap { dockListLocations(in: $0, depth: depth + 1) }
        guard role == kAXListRole as String, let rect = quartzRect(for: element) else {
            return descendants
        }
        return [DockListLocation(element: element, quartzRect: rect)] + descendants
    }

    private static func bestDockList(
        from locations: [DockListLocation],
        intersecting screenFrame: CGRect
    ) -> DockListSelection? {
        locations
            .compactMap { location -> DockListSelection? in
                guard usableArea(location.quartzRect.intersection(screenFrame)) > 0,
                      let finder = finderItem(in: location.element) else {
                    return nil
                }
                return DockListSelection(location: location, finder: finder)
            }
            .max { lhs, rhs in
                dockListScore(lhs.location, screenFrame: screenFrame) <
                    dockListScore(rhs.location, screenFrame: screenFrame)
            }
    }

    private static func dockListScore(_ location: DockListLocation, screenFrame: CGRect) -> CGFloat {
        let intersectionArea = usableArea(location.quartzRect.intersection(screenFrame))
        let locationArea = max(1, usableArea(location.quartzRect))
        return intersectionArea + intersectionArea / locationArea * 1_000
    }

    private static func largestDockList(from locations: [DockListLocation]) -> DockListSelection? {
        locations
            .compactMap { location in
                finderItem(in: location.element).map { DockListSelection(location: location, finder: $0) }
            }
            .max { usableArea($0.location.quartzRect) < usableArea($1.location.quartzRect) }
    }

    private static func finderItem(in list: AXUIElement) -> AXUIElement? {
        dockItems(in: list)
            .map { ($0, finderScore($0)) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?
            .0
    }

    private static func dockItems(in element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < 8 else { return [] }
        let children = AccessibilityHelpers.elementArrayAttribute(element, kAXChildrenAttribute as CFString)
        let descendants = children.flatMap { dockItems(in: $0, depth: depth + 1) }
        return isDockItem(element) ? [element] + descendants : descendants
    }

    private static func isDockItem(_ element: AXUIElement) -> Bool {
        let role = AccessibilityHelpers.stringAttribute(element, kAXRoleAttribute as CFString) ?? ""
        let subrole = AccessibilityHelpers.stringAttribute(element, kAXSubroleAttribute as CFString) ?? ""
        return role == "AXDockItem" || subrole.localizedCaseInsensitiveContains("DockItem")
    }

    private static func finderScore(_ element: AXUIElement) -> Int {
        let url = AccessibilityHelpers.urlAttribute(element, "AXURL" as CFString)
        if url?.lastPathComponent.localizedCaseInsensitiveCompare("Finder.app") == .orderedSame {
            return 1_000
        }

        let labels = [
            AccessibilityHelpers.stringAttribute(element, kAXTitleAttribute as CFString),
            AccessibilityHelpers.stringAttribute(element, kAXDescriptionAttribute as CFString),
            AccessibilityHelpers.stringAttribute(element, kAXHelpAttribute as CFString)
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        if labels.contains(where: { $0.localizedCaseInsensitiveCompare("Finder") == .orderedSame }) {
            return 100
        }
        return labels.contains { $0.localizedCaseInsensitiveContains("Finder") } ? 10 : 0
    }

    private static func windowID(for element: AXUIElement) -> CGWindowID? {
        var current: AXUIElement? = element
        var depth = 0
        while let candidate = current, depth < 5 {
            var identifier = CGWindowID(0)
            if _AXUIElementGetWindow(candidate, &identifier) == .success, identifier != 0 {
                return identifier
            }
            current = AccessibilityHelpers.parent(candidate)
            depth += 1
        }
        return nil
    }

    private static func quartzRect(for element: AXUIElement) -> CGRect? {
        guard let position = AccessibilityHelpers.pointAttribute(element, kAXPositionAttribute as CFString),
              let size = AccessibilityHelpers.sizeAttribute(element, kAXSizeAttribute as CFString),
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func quartzRect(fromAppKitRect rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: ScreenGeometry.appKitReferenceMaxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private static func fallbackDockAnchor() -> CGRect? {
        for screen in NSScreen.screens {
            if let rect = reservedDockRect(for: screen) {
                return rect
            }
        }
        return NSScreen.main?.frame
    }

    private static func reservedDockRect(for screen: NSScreen) -> CGRect? {
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
        return nil
    }

    private static func displayID(for screen: NSScreen) -> UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    private static func screen(intersecting quartzRect: CGRect) -> NSScreen? {
        NSScreen.screens
            .map { screen in
                (screen, usableArea(quartzRect.intersection(self.quartzRect(fromAppKitRect: screen.frame))))
            }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?
            .0
    }

    private static func screen(nearestTo quartzRect: CGRect) -> NSScreen? {
        NSScreen.screens.min { lhs, rhs in
            rectDistanceSquared(quartzRect, self.quartzRect(fromAppKitRect: lhs.frame)) <
                rectDistanceSquared(quartzRect, self.quartzRect(fromAppKitRect: rhs.frame))
        }
    }

    private static func rectDistanceSquared(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let dx = max(0, max(lhs.minX - rhs.maxX, rhs.minX - lhs.maxX))
        let dy = max(0, max(lhs.minY - rhs.maxY, rhs.minY - lhs.maxY))
        return dx * dx + dy * dy
    }

    private static func clippedPreviewRect(_ rect: CGRect) -> CGRect {
        guard let screen = ScreenGeometry.screen(containing: rect) else { return rect }
        let clipped = rect.intersection(screen.frame)
        return clipped.isNull || clipped.isEmpty ? rect : clipped
    }

    private static func usableArea(_ rect: CGRect) -> CGFloat {
        guard !rect.isNull, !rect.isEmpty, !rect.isInfinite else { return 0 }
        return rect.width * rect.height
    }

    private static func largestAreaFirst(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        lhs.width * lhs.height > rhs.width * rhs.height
    }
}

private struct DockListLocation {
    let element: AXUIElement
    let quartzRect: CGRect

    var appKitRect: CGRect {
        AccessibilityHelpers.appKitFrame(fromQuartzWindowBounds: quartzRect)
    }
}

private struct DockListSelection {
    let location: DockListLocation
    let finder: AXUIElement
}
