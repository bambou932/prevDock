import AppKit
import ApplicationServices
import Foundation

private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value
}

private func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
    attribute(element, name) as? String
}

private func boolAttribute(_ element: AXUIElement, _ name: CFString) -> Bool? {
    guard let raw = attribute(element, name), CFGetTypeID(raw) == CFBooleanGetTypeID() else { return nil }
    return CFBooleanGetValue((raw as! CFBoolean))
}

private func children(of element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
}

private func actionNames(of element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return names as? [String] ?? []
}

private func pointAttribute(_ element: AXUIElement, _ name: CFString) -> CGPoint? {
    guard let raw = attribute(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(raw as! AXValue, .cgPoint, &point) else { return nil }
    return point
}

private func sizeAttribute(_ element: AXUIElement, _ name: CFString) -> CGSize? {
    guard let raw = attribute(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(raw as! AXValue, .cgSize, &size) else { return nil }
    return size
}

private func descendants(
    of root: AXUIElement,
    maximumDepth: Int = 8,
    matching predicate: (AXUIElement) -> Bool
) -> [AXUIElement] {
    var matches = [AXUIElement]()
    var visited = Set<CFHashCode>()

    func visit(_ element: AXUIElement, depth: Int) {
        guard depth <= maximumDepth else { return }
        let identifier = CFHash(element)
        guard visited.insert(identifier).inserted else { return }
        if predicate(element) {
            matches.append(element)
        }
        children(of: element).forEach { visit($0, depth: depth + 1) }
    }

    visit(root, depth: 0)
    return matches
}

private func bestTitle(for element: AXUIElement) -> String {
    [
        stringAttribute(element, kAXTitleAttribute as CFString),
        stringAttribute(element, kAXDescriptionAttribute as CFString),
        stringAttribute(element, kAXHelpAttribute as CFString)
    ]
    .compactMap { $0?.components(separatedBy: .newlines).first }
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    .first { !$0.isEmpty } ?? ""
}

private func runningApplication(bundleIdentifier: String) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
}

private func applicationElement(bundleIdentifier: String) -> AXUIElement? {
    runningApplication(bundleIdentifier: bundleIdentifier).map {
        AXUIElementCreateApplication($0.processIdentifier)
    }
}

private func dockItems() -> [AXUIElement] {
    guard let root = applicationElement(bundleIdentifier: "com.apple.dock") else { return [] }
    return descendants(of: root) {
        stringAttribute($0, kAXSubroleAttribute as CFString) == "AXApplicationDockItem"
    }
}

private func matchingDockItem(_ query: String) -> AXUIElement? {
    dockItems().first {
        bestTitle(for: $0).localizedCaseInsensitiveContains(query)
    }
}

private func printDockItems(query: String?) {
    for item in dockItems() {
        let title = bestTitle(for: item)
        guard query == nil || title.localizedCaseInsensitiveContains(query!) else { continue }
        let position = pointAttribute(item, kAXPositionAttribute as CFString) ?? .zero
        let size = sizeAttribute(item, kAXSizeAttribute as CFString) ?? .zero
        let center = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        let actions = actionNames(of: item).joined(separator: ",")
        print(
            "item title=\(title.debugDescription) " +
                "quartzCenter=\(Int(center.x)),\(Int(center.y)) " +
                "size=\(Int(size.width))x\(Int(size.height)) actions=\(actions)"
        )
    }
}

private func menuElements(bundleIdentifier: String) -> [AXUIElement] {
    guard let root = applicationElement(bundleIdentifier: bundleIdentifier) else { return [] }
    return descendants(of: root) {
        stringAttribute($0, kAXRoleAttribute as CFString) == kAXMenuRole as String
    }
}

private func printMenuState(includeHidden: Bool) {
    let bundles = ["com.apple.dock.helper", "com.apple.dock"]
    for bundleIdentifier in bundles {
        for menu in menuElements(bundleIdentifier: bundleIdentifier) {
            let size = sizeAttribute(menu, kAXSizeAttribute as CFString)
            if !includeHidden && !isVisibleMenuSize(size) {
                continue
            }
            let items = children(of: menu).compactMap { child -> String? in
                guard stringAttribute(child, kAXRoleAttribute as CFString) == kAXMenuItemRole as String else {
                    return nil
                }
                return bestTitle(for: child)
            }
            let visible = boolAttribute(menu, "AXVisible" as CFString)
            let position = pointAttribute(menu, kAXPositionAttribute as CFString)
            print(
                "axMenu owner=\(bundleIdentifier) role=AXMenu visible=\(String(describing: visible)) " +
                    "position=\(String(describing: position)) size=\(String(describing: size)) items=\(items)"
            )
        }
    }

    let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] ?? []
    for window in windows {
        let owner = window[kCGWindowOwnerName as String] as? String ?? ""
        guard owner == "Dock" || owner == "DockHelper" else { continue }
        let layer = window[kCGWindowLayer as String] as? Int ?? 0
        guard layer >= NSWindow.Level.popUpMenu.rawValue else { continue }
        let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
        let name = window[kCGWindowName as String] as? String ?? ""
        let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        print("popup owner=\(owner) id=\(number) layer=\(layer) name=\(name.debugDescription) bounds=\(bounds)")
    }
}

private func printWindowState(query: String?) {
    let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] ?? []
    let referenceMaxY = NSScreen.screens.map(\.frame.maxY).max() ?? 0
    for window in windows {
        let owner = window[kCGWindowOwnerName as String] as? String ?? ""
        let name = window[kCGWindowName as String] as? String ?? ""
        if let query,
           !owner.localizedCaseInsensitiveContains(query),
           !name.localizedCaseInsensitiveContains(query) {
            continue
        }
        guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let quartzFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
            continue
        }
        let appKitFrame = CGRect(
            x: quartzFrame.minX,
            y: referenceMaxY - quartzFrame.maxY,
            width: quartzFrame.width,
            height: quartzFrame.height
        )
        let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
        let layer = window[kCGWindowLayer as String] as? Int ?? 0
        print(
            "window owner=\(owner.debugDescription) name=\(name.debugDescription) " +
                "id=\(number) layer=\(layer) quartz=\(formatted(quartzFrame)) appKit=\(formatted(appKitFrame))"
        )
    }
}

private func printScreens() {
    for (index, screen) in NSScreen.screens.enumerated() {
        print(
            "screen index=\(index) frame=\(formatted(screen.frame)) " +
                "visible=\(formatted(screen.visibleFrame)) scale=\(screen.backingScaleFactor)"
        )
    }
}

private func formatted(_ rect: CGRect) -> String {
    String(
        format: "%.1f,%.1f,%.1f,%.1f",
        rect.origin.x,
        rect.origin.y,
        rect.width,
        rect.height
    )
}

private func isVisibleMenuSize(_ size: CGSize?) -> Bool {
    guard let size else { return false }
    return size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
}

private func cancelMenus() {
    var cancelled = false
    for bundleIdentifier in ["com.apple.dock.helper", "com.apple.dock"] {
        for menu in menuElements(bundleIdentifier: bundleIdentifier) {
            cancelled = AXUIElementPerformAction(menu, kAXCancelAction as CFString) == .success || cancelled
        }
    }
    print("cancelled=\(cancelled)")
}

guard AXIsProcessTrusted() else {
    fputs("Accessibility permission is required\n", stderr)
    exit(3)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "items":
    printDockItems(query: arguments.dropFirst().first)
case "menus":
    printMenuState(includeHidden: false)
case "menus-all":
    printMenuState(includeHidden: true)
case "windows":
    printWindowState(query: arguments.dropFirst().first)
case "screens":
    printScreens()
case "show-menu":
    guard let query = arguments.dropFirst().first,
          let item = matchingDockItem(query) else {
        fputs("usage: DockMenuQAProbe show-menu <dock-item-title> [hold-seconds]\n", stderr)
        exit(2)
    }
    let result = AXUIElementPerformAction(item, kAXShowMenuAction as CFString)
    print("showMenuResult=\(result.rawValue)")
    if let rawHold = arguments.dropFirst(2).first,
       let hold = TimeInterval(rawHold),
       hold > 0 {
        RunLoop.current.run(until: Date().addingTimeInterval(hold))
    }
case "cancel-menus":
    cancelMenus()
default:
    fputs(
        "usage: DockMenuQAProbe items [query] | menus | menus-all | windows [query] | screens | " +
            "show-menu <query> [hold-seconds] | cancel-menus\n",
        stderr
    )
    exit(2)
}
