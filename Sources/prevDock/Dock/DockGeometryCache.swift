import ApplicationServices
import Cocoa
import CoreGraphics

final class DockGeometryCache {
    static let shared = DockGeometryCache()

    private var cachedInteractionRects = [CGRect]()
    private var cachedEdgeEntryRects = [CGRect]()
    private var cachedNativeLabelSuppressionRects = [CGRect]()
    private var cachedPreviewAnchor: CGRect?
    private var recentlyResolvedDockItemRect: CGRect?
    private var recentlyResolvedDockItemAt = -TimeInterval.infinity
    private var provisionalInteractionRects = [CGRect]()
    private var provisionalInteractionExpiresAt = -TimeInterval.infinity
    private var lastFallbackProbeAt = -TimeInterval.infinity
    private var cachedDockPID: pid_t?
    private var lastRefresh = -TimeInterval.infinity
    private var hasReliableGeometry = false
    private var screenObserver: NSObjectProtocol?
    private var dockObservers = [NSObjectProtocol]()
    private let refreshInterval: TimeInterval = 10
    private let failedRefreshInterval: TimeInterval = 1
    private let fallbackPadding: CGFloat = 24
    private let autoHideFallbackThickness: CGFloat = 32
    private let nativeLabelPadding: CGFloat = 4
    private let resolvedDockItemLifetime: TimeInterval = 0.75
    private let fallbackProbeInterval: TimeInterval = 0.3
    private let provisionalInteractionLifetime: TimeInterval = 0.8
    private let provisionalInteractionThickness: CGFloat = 96

    private init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshNow()
        }
        installDockObservers()
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        dockObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    func refreshNow() {
        guard AXIsProcessTrusted(),
              let dock = dockApplication() else {
            clear()
            return
        }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        let deadline = ProcessInfo.processInfo.systemUptime + DockAccessibility.maximumScanDuration
        var dockRects = [CGRect]()
        var dockItemRects = [CGRect]()
        collectDockGeometry(in: dockElement, deadline: deadline, lists: &dockRects, items: &dockItemRects)
        let labelSuppressionSourceRects = dockItemRects.isEmpty ? dockRects : dockItemRects
        cachedInteractionRects = dockRects.compactMap(interactionRect)
        cachedEdgeEntryRects = dockRects.compactMap(edgeEntryRect)
        cachedNativeLabelSuppressionRects = labelSuppressionSourceRects.compactMap(nativeLabelSuppressionRect)
        cachedPreviewAnchor = dockRects.compactMap(nativeLabelSuppressionRect).max {
            $0.width * $0.height < $1.width * $1.height
        }
        cachedDockPID = dock.processIdentifier
        hasReliableGeometry = !cachedInteractionRects.isEmpty && ProcessInfo.processInfo.systemUptime < deadline
        lastRefresh = ProcessInfo.processInfo.systemUptime
    }

    func refreshIfStale() {
        let interval = hasReliableGeometry ? refreshInterval : failedRefreshInterval
        guard (ProcessInfo.processInfo.systemUptime - lastRefresh) > interval else { return }
        refreshNow()
    }

    func previewAnchor() -> CGRect? {
        refreshIfStale()
        return cachedPreviewAnchor
    }

    func isInDockInteractionStrip(_ point: CGPoint, refreshIfStale: Bool = true) -> Bool {
        if refreshIfStale {
            self.refreshIfStale()
        }

        if cachedInteractionRects.contains(where: { $0.contains(point) }) ||
            cachedEdgeEntryRects.contains(where: { $0.contains(point) }) ||
            containsRecentlyResolvedDockItem(point) ||
            containsProvisionalInteraction(point) {
            return true
        }
        guard isInFallbackDockStrip(point) else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        guard (now - lastFallbackProbeAt) >= fallbackProbeInterval else { return false }
        lastFallbackProbeAt = now
        provisionalInteractionRects = makeProvisionalInteractionRects(at: point)
        provisionalInteractionExpiresAt = (now + provisionalInteractionLifetime)
        return true
    }

    func isInNativeLabelSuppressionStrip(_ point: CGPoint, refreshIfStale: Bool = true) -> Bool {
        if refreshIfStale {
            self.refreshIfStale()
        }

        if cachedNativeLabelSuppressionRects.contains(where: { $0.contains(point) }) {
            return true
        }
        return containsRecentlyResolvedDockItem(point)
    }

    func noteResolvedDockItem(anchor: CGRect) {
        guard let screen = ScreenGeometry.screen(containing: anchor) else { return }
        let rect = anchor
            .insetBy(dx: -nativeLabelPadding, dy: -nativeLabelPadding)
            .intersection(screen.frame)
        guard !rect.isNull, !rect.isEmpty else { return }
        recentlyResolvedDockItemRect = rect
        recentlyResolvedDockItemAt = ProcessInfo.processInfo.systemUptime
    }

    private func clear() {
        cachedInteractionRects = []
        cachedEdgeEntryRects = []
        cachedNativeLabelSuppressionRects = []
        cachedPreviewAnchor = nil
        recentlyResolvedDockItemRect = nil
        recentlyResolvedDockItemAt = -TimeInterval.infinity
        provisionalInteractionRects = []
        provisionalInteractionExpiresAt = -TimeInterval.infinity
        lastFallbackProbeAt = -TimeInterval.infinity
        cachedDockPID = nil
        hasReliableGeometry = false
        lastRefresh = ProcessInfo.processInfo.systemUptime
    }

    private func containsRecentlyResolvedDockItem(_ point: CGPoint) -> Bool {
        guard (ProcessInfo.processInfo.systemUptime - recentlyResolvedDockItemAt) <= resolvedDockItemLifetime else {
            recentlyResolvedDockItemRect = nil
            return false
        }
        return recentlyResolvedDockItemRect?.contains(point) == true
    }

    private func containsProvisionalInteraction(_ point: CGPoint) -> Bool {
        guard ProcessInfo.processInfo.systemUptime <= provisionalInteractionExpiresAt else {
            provisionalInteractionRects = []
            return false
        }
        return provisionalInteractionRects.contains { $0.contains(point) }
    }

    private func makeProvisionalInteractionRects(at point: CGPoint) -> [CGRect] {
        guard let screen = ScreenGeometry.screen(containing: point) else { return [] }
        let frame = screen.frame
        let visibleFrame = screen.visibleFrame
        var rects = [CGRect]()
        if visibleFrame.minY > frame.minY + 1 || point.y - frame.minY <= autoHideFallbackThickness {
            rects.append(CGRect(
                x: frame.minX,
                y: frame.minY,
                width: frame.width,
                height: provisionalInteractionThickness
            ))
        }
        if visibleFrame.minX > frame.minX + 1 || point.x - frame.minX <= autoHideFallbackThickness {
            rects.append(CGRect(
                x: frame.minX,
                y: frame.minY,
                width: provisionalInteractionThickness,
                height: frame.height
            ))
        }
        if visibleFrame.maxX < frame.maxX - 1 || frame.maxX - point.x <= autoHideFallbackThickness {
            rects.append(CGRect(
                x: frame.maxX - provisionalInteractionThickness,
                y: frame.minY,
                width: provisionalInteractionThickness,
                height: frame.height
            ))
        }
        return rects
    }

    private func dockApplication() -> NSRunningApplication? {
        let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        if cachedDockPID != nil, cachedDockPID != dock?.processIdentifier {
            cachedInteractionRects = []
            cachedEdgeEntryRects = []
            cachedNativeLabelSuppressionRects = []
            cachedPreviewAnchor = nil
            hasReliableGeometry = false
            DockHoverTargetResolver.invalidateDockCache()
        }
        return dock
    }

    private func installDockObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let notifications: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]
        dockObservers = notifications.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleDockLifecycleChange(notification)
            }
        }
    }

    private func handleDockLifecycleChange(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.apple.dock" else {
            return
        }
        clear()
        lastRefresh = -TimeInterval.infinity
        DockHoverTargetResolver.invalidateDockCache()
    }

    private func collectDockGeometry(
        in element: AXUIElement,
        depth: Int = 0,
        deadline: TimeInterval,
        lists: inout [CGRect],
        items: inout [CGRect]
    ) {
        guard depth < 7, ProcessInfo.processInfo.systemUptime < deadline else { return }
        DockAccessibility.prepare(element)
        let role = AccessibilityHelpers.stringAttribute(element, kAXRoleAttribute as CFString) ?? ""
        if role == "AXList", depth < 5, let rect = dockRect(for: element) {
            lists.append(rect)
        }
        if isDockItem(element, role: role), let rect = dockRect(for: element) {
            items.append(rect)
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else { return }
        let children = AccessibilityHelpers.elementArrayAttribute(element, kAXChildrenAttribute as CFString)
        for child in children {
            collectDockGeometry(in: child, depth: depth + 1, deadline: deadline, lists: &lists, items: &items)
        }
    }

    private func isDockItem(_ element: AXUIElement, role: String) -> Bool {
        if role == "AXDockItem" { return true }
        let subrole = AccessibilityHelpers.stringAttribute(element, kAXSubroleAttribute as CFString) ?? ""
        return subrole.localizedCaseInsensitiveContains("DockItem")
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
        guard let screen = ScreenGeometry.screen(containing: dockRect) else { return nil }
        let rect = dockRect
            .insetBy(dx: -nativeLabelPadding, dy: -nativeLabelPadding)
            .intersection(screen.frame)
        return rect.isNull || rect.isEmpty ? nil : rect
    }

    private func edgeEntryRect(for dockRect: CGRect) -> CGRect? {
        guard let screen = ScreenGeometry.screen(containing: dockRect) else { return nil }
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
        guard let screen = ScreenGeometry.screen(containing: dockRect) else { return nil }
        let rect = dockRect.intersection(screen.frame)
        guard !rect.isNull, !rect.isEmpty else { return nil }
        return rect
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
}
