import ApplicationServices
import Cocoa

enum DockHoverTargetSource: String {
    case axHitChain = "ax-hit-chain"
}

struct DockHoverResolution {
    let target: DockHoverTarget
    let source: DockHoverTargetSource
}

enum DockHoverTargetResolver {
    private static var cachedDockPID: pid_t?
    private static var cachedDockElement: AXUIElement?
    private static var lastDockLookup = Date.distantPast
    private static let dockLookupInterval: TimeInterval = 2

    static func target(at mouse: CGPoint) -> DockHoverTarget? {
        resolution(at: mouse)?.target
    }

    static func resolution(at mouse: CGPoint) -> DockHoverResolution? {
        guard let dockElement = currentDockElement() else { return nil }
        return hitChainResolution(at: mouse, dockElement: dockElement)
    }

    static func invalidateDockCache() {
        cachedDockPID = nil
        cachedDockElement = nil
        lastDockLookup = .distantPast
    }

    private static func currentDockElement() -> AXUIElement? {
        let now = Date()
        if let cachedDockElement,
           now.timeIntervalSince(lastDockLookup) < dockLookupInterval {
            return cachedDockElement
        }

        lastDockLookup = now
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            invalidateDockCache()
            return nil
        }

        if cachedDockPID != dock.processIdentifier || cachedDockElement == nil {
            cachedDockPID = dock.processIdentifier
            cachedDockElement = AXUIElementCreateApplication(dock.processIdentifier)
        }
        return cachedDockElement
    }

    private static func hitChainResolution(at mouse: CGPoint, dockElement: AXUIElement) -> DockHoverResolution? {
        let axPoint = AccessibilityHelpers.accessibilityPoint(fromAppKitPoint: mouse)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(dockElement, Float(axPoint.x), Float(axPoint.y), &hit) == .success,
              let hit,
              let item = dockItemInHitChain(from: hit),
              let target = hoverTarget(from: item, fallback: mouse) else {
            return nil
        }

        return DockHoverResolution(target: target, source: .axHitChain)
    }

    private static func dockItemInHitChain(from element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var depth = 0

        while let element = current, depth < 8 {
            if isDockItemCandidate(element) {
                return element
            }

            current = AccessibilityHelpers.parent(element)
            depth += 1
        }

        return nil
    }

    private static func isDockItemCandidate(_ element: AXUIElement) -> Bool {
        let role = AccessibilityHelpers.stringAttribute(element, kAXRoleAttribute as CFString) ?? ""
        let roleDescription = AccessibilityHelpers.stringAttribute(element, kAXRoleDescriptionAttribute as CFString) ?? ""
        let subrole = AccessibilityHelpers.stringAttribute(element, kAXSubroleAttribute as CFString) ?? ""
        guard role == "AXDockItem" ||
            role == kAXButtonRole as String ||
            roleDescription.localizedCaseInsensitiveContains("dock") ||
            subrole.localizedCaseInsensitiveContains("dock") else {
            return false
        }

        return bestTitle(for: element) != nil || dockURL(for: element) != nil
    }

    private static func hoverTarget(from item: AXUIElement, fallback mouse: CGPoint) -> DockHoverTarget? {
        let title = bestTitle(for: item)
        let subrole = AccessibilityHelpers.stringAttribute(item, kAXSubroleAttribute as CFString) ?? ""
        let roleDescription = AccessibilityHelpers.stringAttribute(item, kAXRoleDescriptionAttribute as CFString)
        let url = dockURL(for: item)
        let app = RunningAppMatcher.matchDockItem(title: title, url: url)
        let showsInactiveLabel = app == nil && subrole == "AXApplicationDockItem"
        guard app != nil || showsInactiveLabel else { return nil }
        guard let displayTitle = displayTitle(for: title, url: url, app: app, roleDescription: roleDescription),
              !displayTitle.isEmpty else {
            return nil
        }

        return DockHoverTarget(
            app: app,
            title: displayTitle,
            url: url,
            anchor: dockItemAnchor(for: item, fallback: mouse),
            showsInactiveLabel: showsInactiveLabel
        )
    }

    private static func dockURL(for element: AXUIElement) -> URL? {
        AccessibilityHelpers.urlAttribute(element, "AXURL" as CFString)
    }

    private static func dockItemAnchor(for element: AXUIElement, fallback mouse: CGPoint) -> CGRect {
        guard let position = AccessibilityHelpers.pointAttribute(element, kAXPositionAttribute as CFString),
              let size = AccessibilityHelpers.sizeAttribute(element, kAXSizeAttribute as CFString),
              size.width > 0,
              size.height > 0 else {
            return CGRect(x: mouse.x - 24, y: mouse.y - 24, width: 48, height: 48)
        }
        return AccessibilityHelpers.appKitRect(fromAccessibilityPosition: position, size: size)
    }

    private static func bestTitle(for element: AXUIElement) -> String? {
        [
            AccessibilityHelpers.stringAttribute(element, kAXTitleAttribute as CFString),
            AccessibilityHelpers.stringAttribute(element, kAXDescriptionAttribute as CFString),
            AccessibilityHelpers.stringAttribute(element, kAXHelpAttribute as CFString)
        ]
        .compactMap { $0 }
        .map(cleanedDockTitle)
        .first { !$0.isEmpty }
    }

    private static func cleanedDockTitle(_ title: String) -> String {
        let firstLine = title.components(separatedBy: .newlines).first ?? title
        return firstLine
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func displayTitle(
        for title: String?,
        url: URL?,
        app: NSRunningApplication?,
        roleDescription: String?
    ) -> String? {
        if let appName = app?.localizedName, !appName.isEmpty {
            return appName
        }
        if let title, !title.isEmpty {
            return title
        }

        guard let url else {
            return cleanedDockTitle(roleDescription ?? "")
        }
        guard url.isFileURL && url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            return url.deletingPathExtension().lastPathComponent
        }

        if let bundle = Bundle(url: url) {
            if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
               !displayName.isEmpty {
                return displayName
            }
            if let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
               !bundleName.isEmpty {
                return bundleName
            }
        }

        return url.deletingPathExtension().lastPathComponent
    }
}
