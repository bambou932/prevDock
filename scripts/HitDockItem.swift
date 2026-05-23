import ApplicationServices
import AppKit
import Foundation

guard CommandLine.arguments.count == 3,
      let x = Double(CommandLine.arguments[1]),
      let y = Double(CommandLine.arguments[2]) else {
    fputs("usage: HitDockItem appkitX appkitY\n", stderr)
    exit(2)
}

func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
    return value as? String
}

func parent(_ element: AXUIElement) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success else { return nil }
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func bestTitle(_ element: AXUIElement) -> String {
    [
        stringAttribute(element, kAXTitleAttribute as CFString),
        stringAttribute(element, kAXDescriptionAttribute as CFString),
        stringAttribute(element, kAXHelpAttribute as CFString)
    ]
    .compactMap { $0?.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) }
    .first { !$0.isEmpty } ?? ""
}

let globalDisplayMaxY = NSScreen.screens.map(\.frame.maxY).max() ?? (NSScreen.main?.frame.height ?? 0)
let axPoint = CGPoint(x: x, y: globalDisplayMaxY - y)

guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
    fatalError("Dock not found")
}

let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
var hit: AXUIElement?
let error = AXUIElementCopyElementAtPosition(dockElement, Float(axPoint.x), Float(axPoint.y), &hit)
print("query appKit=(\(Int(x)),\(Int(y))) ax=(\(Int(axPoint.x)),\(Int(axPoint.y))) error=\(error.rawValue)")

var current = hit
for depth in 0..<8 {
    guard let element = current else { break }
    let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? ""
    let roleDescription = stringAttribute(element, kAXRoleDescriptionAttribute as CFString) ?? ""
    let subrole = stringAttribute(element, kAXSubroleAttribute as CFString) ?? ""
    print("depth=\(depth) role=\(role) roleDescription=\(roleDescription) subrole=\(subrole) title=\(bestTitle(element))")
    current = parent(element)
}
