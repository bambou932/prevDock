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
    private static var lastDockLookup = -TimeInterval.infinity
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
        lastDockLookup = -TimeInterval.infinity
    }

    private static func currentDockElement() -> AXUIElement? {
        let now = ProcessInfo.processInfo.systemUptime
        if let cachedDockElement,
           (now - lastDockLookup) < dockLookupInterval {
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
            if let cachedDockElement {
                DockAccessibility.prepare(cachedDockElement)
            }
        }
        return cachedDockElement
    }

    private static func hitChainResolution(at mouse: CGPoint, dockElement: AXUIElement) -> DockHoverResolution? {
        let scan = DockHoverTargetScan()
        let axPoint = AccessibilityHelpers.accessibilityPoint(fromAppKitPoint: mouse)
        guard let item = scan.item(at: axPoint, dockElement: dockElement),
              let target = hoverTarget(from: item, fallback: mouse, scan: scan) else {
            return nil
        }
        return DockHoverResolution(target: target, source: .axHitChain)
    }

    private static func hoverTarget(
        from item: DockHoverTargetScan.Item,
        fallback mouse: CGPoint,
        scan: DockHoverTargetScan
    ) -> DockHoverTarget? {
        let app = RunningAppMatcher.matchDockItem(title: item.title, url: item.url)
        guard app != nil || item.subrole == "AXApplicationDockItem" else { return nil }
        guard let displayTitle = displayTitle(
            for: item.title, url: item.url, app: app, roleDescription: item.roleDescription
        ), !displayTitle.isEmpty else { return nil }
        return DockHoverTarget(
            app: app,
            title: displayTitle,
            url: item.url,
            anchor: scan.anchor(for: item.element, fallback: mouse)
        )
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
            return DockHoverTargetScan.cleanedTitle(roleDescription ?? "")
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

struct DockHoverTargetScan {
    struct Access {
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var prepare: (AXUIElement) -> Void = DockAccessibility.prepare
        var hit: (AXUIElement, CGPoint) -> AXUIElement? = { element, point in
            var result: AXUIElement?
            guard AXUIElementCopyElementAtPosition(element, Float(point.x), Float(point.y), &result) == .success else {
                return nil
            }
            return result
        }
        var string: (AXUIElement, CFString) -> String? = AccessibilityHelpers.stringAttribute
        var url: (AXUIElement, CFString) -> URL? = AccessibilityHelpers.urlAttribute
        var parent: (AXUIElement) -> AXUIElement? = AccessibilityHelpers.parent
        var position: (AXUIElement, CFString) -> CGPoint? = AccessibilityHelpers.pointAttribute
        var size: (AXUIElement, CFString) -> CGSize? = AccessibilityHelpers.sizeAttribute
    }

    struct Item {
        let element: AXUIElement
        let title: String?
        let subrole: String
        let roleDescription: String?
        let url: URL?
    }

    private let access: Access
    private let deadline: TimeInterval

    init(access: Access = Access()) {
        self.access = access
        deadline = access.now() + DockAccessibility.maximumScanDuration
    }

    func item(at point: CGPoint, dockElement: AXUIElement) -> Item? {
        var current = read { access.hit(dockElement, point) }
        var depth = 0
        while let element = current, depth < 8, hasTimeRemaining {
            access.prepare(element)
            if let item = candidate(from: element) { return item }
            current = read { access.parent(element) }
            depth += 1
        }
        return nil
    }

    func anchor(for element: AXUIElement, fallback mouse: CGPoint) -> CGRect {
        guard let position = read({ access.position(element, kAXPositionAttribute as CFString) }),
              let size = read({ access.size(element, kAXSizeAttribute as CFString) }),
              size.width > 0, size.height > 0 else {
            return CGRect(x: mouse.x - 24, y: mouse.y - 24, width: 48, height: 48)
        }
        return AccessibilityHelpers.appKitRect(fromAccessibilityPosition: position, size: size)
    }

    static func cleanedTitle(_ title: String) -> String {
        let firstLine = title.components(separatedBy: .newlines).first ?? title
        return firstLine
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasTimeRemaining: Bool { access.now() < deadline }

    private func read<Value>(_ operation: () -> Value?) -> Value? {
        // One budget covers the hit, parent chain, metadata, and geometry; a slow field cannot reset it.
        guard hasTimeRemaining else { return nil }
        return operation()
    }

    private func candidate(from element: AXUIElement) -> Item? {
        let role = read { access.string(element, kAXRoleAttribute as CFString) } ?? ""
        let roleDescription = read { access.string(element, kAXRoleDescriptionAttribute as CFString) }
        let subrole = read { access.string(element, kAXSubroleAttribute as CFString) } ?? ""
        guard role == "AXDockItem" || role == kAXButtonRole as String ||
            (roleDescription?.localizedCaseInsensitiveContains("dock") ?? false) ||
            subrole.localizedCaseInsensitiveContains("dock") else { return nil }
        let title = bestTitle(for: element)
        let url = read { access.url(element, "AXURL" as CFString) }
        guard hasTimeRemaining, title != nil || url != nil else { return nil }
        return Item(element: element, title: title, subrole: subrole, roleDescription: roleDescription, url: url)
    }

    private func bestTitle(for element: AXUIElement) -> String? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
            guard let value = read({ access.string(element, attribute as CFString) }) else { continue }
            let title = Self.cleanedTitle(value)
            if !title.isEmpty { return title }
        }
        return nil
    }
}
