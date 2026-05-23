import ApplicationServices
import Cocoa
import CoreGraphics

final class DockGeometryCache {
    static let shared = DockGeometryCache()

    private var cachedInteractionRects = [CGRect]()
    private var cachedEdgeEntryRects = [CGRect]()
    private var cachedNativeLabelSuppressionRects = [CGRect]()
    private var cachedDockPID: pid_t?
    private var lastRefresh = Date.distantPast
    private let refreshInterval: TimeInterval = 10
    private let fallbackPadding: CGFloat = 24
    private let autoHideFallbackThickness: CGFloat = 32
    private let nativeLabelOutset: CGFloat = 96
    private let nativeLabelCrossAxisPadding: CGFloat = 36

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshNow()
        }
    }

    func refreshNow() {
        guard AXIsProcessTrusted(),
              let dock = dockApplication() else {
            clear()
            return
        }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        let dockRects = dockLists(in: dockElement).compactMap(dockRect)
        let dockItemRects = dockItems(in: dockElement).compactMap(dockRect)
        let labelSuppressionSourceRects = dockItemRects.isEmpty ? dockRects : dockItemRects
        cachedInteractionRects = dockRects.compactMap(interactionRect)
        cachedEdgeEntryRects = dockRects.compactMap(edgeEntryRect)
        cachedNativeLabelSuppressionRects = labelSuppressionSourceRects.compactMap(nativeLabelSuppressionRect)
        cachedDockPID = dock.processIdentifier
        lastRefresh = Date()
    }

    func refreshIfStale() {
        guard Date().timeIntervalSince(lastRefresh) > refreshInterval else { return }
        refreshNow()
    }

    func isInDockInteractionStrip(_ point: CGPoint, refreshIfStale: Bool = true) -> Bool {
        if refreshIfStale {
            self.refreshIfStale()
        }

        if !cachedInteractionRects.isEmpty || !cachedEdgeEntryRects.isEmpty {
            return cachedInteractionRects.contains(where: { $0.contains(point) }) ||
                cachedEdgeEntryRects.contains(where: { $0.contains(point) })
        }

        return isInFallbackDockStrip(point)
    }

    func isInNativeLabelSuppressionStrip(_ point: CGPoint, refreshIfStale: Bool = true) -> Bool {
        if refreshIfStale {
            self.refreshIfStale()
        }

        guard !cachedNativeLabelSuppressionRects.isEmpty else {
            return isInFallbackDockStrip(point)
        }
        return cachedNativeLabelSuppressionRects.contains { $0.contains(point) }
    }

    private func clear() {
        cachedInteractionRects = []
        cachedEdgeEntryRects = []
        cachedNativeLabelSuppressionRects = []
        cachedDockPID = nil
        lastRefresh = Date()
    }

    private func dockApplication() -> NSRunningApplication? {
        let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        if cachedDockPID != nil, cachedDockPID != dock?.processIdentifier {
            cachedInteractionRects = []
            cachedEdgeEntryRects = []
            cachedNativeLabelSuppressionRects = []
        }
        return dock
    }

    private func dockLists(in element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < 5 else { return [] }
        let role = AccessibilityHelpers.stringAttribute(element, kAXRoleAttribute as CFString) ?? ""
        let children = AccessibilityHelpers.elementArrayAttribute(element, kAXChildrenAttribute as CFString)
        let childLists = children.flatMap { dockLists(in: $0, depth: depth + 1) }
        return role == "AXList" ? [element] + childLists : childLists
    }

    private func dockItems(in element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < 7 else { return [] }
        let children = AccessibilityHelpers.elementArrayAttribute(element, kAXChildrenAttribute as CFString)
        let childItems = children.flatMap { dockItems(in: $0, depth: depth + 1) }
        return isDockItem(element) ? [element] + childItems : childItems
    }

    private func isDockItem(_ element: AXUIElement) -> Bool {
        let role = AccessibilityHelpers.stringAttribute(element, kAXRoleAttribute as CFString) ?? ""
        let subrole = AccessibilityHelpers.stringAttribute(element, kAXSubroleAttribute as CFString) ?? ""
        return role == "AXDockItem" || subrole.localizedCaseInsensitiveContains("DockItem")
    }

    private func dockRect(for element: AXUIElement) -> CGRect? {
        guard let position = AccessibilityHelpers.pointAttribute(element, kAXPositionAttribute as CFString),
              let size = AccessibilityHelpers.sizeAttribute(element, kAXSizeAttribute as CFString),
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return AccessibilityHelpers.appKitRect(fromAccessibilityPosition: position, size: size)
    }

    private func interactionRect(for dockRect: CGRect) -> CGRect? {
        guard let screen = screen(containing: dockRect) else { return nil }
        let rect = dockRect.intersection(screen.frame)
        return rect.isNull || rect.isEmpty ? nil : rect
    }

    private func edgeEntryRect(for dockRect: CGRect) -> CGRect? {
        guard let screen = screen(containing: dockRect) else { return nil }
        let frame = screen.frame
        let pad: CGFloat = 18
        let gapPadding: CGFloat = 4

        if dockRect.width >= dockRect.height {
            if dockRect.midY < frame.midY {
                let height = max(0, dockRect.minY - frame.minY + gapPadding)
                return nonEmptyRect(x: dockRect.minX - pad, y: frame.minY, width: dockRect.width + pad * 2, height: height, clippedTo: frame)
            }
            let y = dockRect.maxY - gapPadding
            return nonEmptyRect(x: dockRect.minX - pad, y: y, width: dockRect.width + pad * 2, height: frame.maxY - y, clippedTo: frame)
        }

        if dockRect.midX < frame.midX {
            let width = max(0, dockRect.minX - frame.minX + gapPadding)
            return nonEmptyRect(x: frame.minX, y: dockRect.minY - pad, width: width, height: dockRect.height + pad * 2, clippedTo: frame)
        }

        let x = dockRect.maxX - gapPadding
        return nonEmptyRect(x: x, y: dockRect.minY - pad, width: frame.maxX - x, height: dockRect.height + pad * 2, clippedTo: frame)
    }

    private func nativeLabelSuppressionRect(for dockRect: CGRect) -> CGRect? {
        guard let screen = screen(containing: dockRect) else { return nil }
        let frame = screen.frame
        let rect = dockRect.intersection(frame)
        guard !rect.isNull, !rect.isEmpty else { return nil }

        if rect.width >= rect.height {
            return horizontalNativeLabelSuppressionRect(for: rect, in: frame)
        }
        return verticalNativeLabelSuppressionRect(for: rect, in: frame)
    }

    private func horizontalNativeLabelSuppressionRect(for rect: CGRect, in frame: CGRect) -> CGRect? {
        let x = rect.minX - nativeLabelCrossAxisPadding
        let width = rect.width + nativeLabelCrossAxisPadding * 2

        if rect.midY < frame.midY {
            return nonEmptyRect(
                x: x,
                y: rect.minY,
                width: width,
                height: rect.height + nativeLabelOutset,
                clippedTo: frame
            )
        }

        let y = rect.minY - nativeLabelOutset
        return nonEmptyRect(
            x: x,
            y: y,
            width: width,
            height: rect.height + nativeLabelOutset,
            clippedTo: frame
        )
    }

    private func verticalNativeLabelSuppressionRect(for rect: CGRect, in frame: CGRect) -> CGRect? {
        let y = rect.minY - nativeLabelCrossAxisPadding
        let height = rect.height + nativeLabelCrossAxisPadding * 2

        if rect.midX < frame.midX {
            return nonEmptyRect(
                x: rect.minX,
                y: y,
                width: rect.width + nativeLabelOutset,
                height: height,
                clippedTo: frame
            )
        }

        let x = rect.minX - nativeLabelOutset
        return nonEmptyRect(
            x: x,
            y: y,
            width: rect.width + nativeLabelOutset,
            height: height,
            clippedTo: frame
        )
    }

    private func nonEmptyRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, clippedTo frame: CGRect) -> CGRect? {
        let rect = CGRect(x: x, y: y, width: width, height: height).intersection(frame)
        return rect.isNull || rect.isEmpty ? nil : rect
    }

    private func isInFallbackDockStrip(_ point: CGPoint) -> Bool {
        NSScreen.screens.contains { screen in
            isInReservedDockStrip(point, screen: screen) || isInAutoHideFallbackStrip(point, screen: screen)
        }
    }

    private func isInReservedDockStrip(_ point: CGPoint, screen: NSScreen) -> Bool {
        let frame = screen.frame
        let visibleFrame = screen.visibleFrame

        if visibleFrame.minY > frame.minY + 1 {
            let height = visibleFrame.minY - frame.minY + fallbackPadding
            return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: height).contains(point)
        }

        if visibleFrame.minX > frame.minX + 1 {
            let width = visibleFrame.minX - frame.minX + fallbackPadding
            return CGRect(x: frame.minX, y: frame.minY, width: width, height: frame.height).contains(point)
        }

        if visibleFrame.maxX < frame.maxX - 1 {
            let width = frame.maxX - visibleFrame.maxX + fallbackPadding
            return CGRect(x: visibleFrame.maxX - fallbackPadding, y: frame.minY, width: width, height: frame.height).contains(point)
        }

        return false
    }

    private func isInAutoHideFallbackStrip(_ point: CGPoint, screen: NSScreen) -> Bool {
        let frame = screen.frame
        let thickness = autoHideFallbackThickness
        let bottom = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: thickness)
        let left = CGRect(x: frame.minX, y: frame.minY, width: thickness, height: frame.height)
        let right = CGRect(x: frame.maxX - thickness, y: frame.minY, width: thickness, height: frame.height)
        return bottom.contains(point) || left.contains(point) || right.contains(point)
    }

    private func screen(containing rect: CGRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(rect) || $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }
    }
}
