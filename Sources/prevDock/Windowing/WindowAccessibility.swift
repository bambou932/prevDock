import Cocoa
import ApplicationServices
import CoreGraphics

enum WindowAccessibility {
    static let accessibilityMessagingTimeout: Float = 0.15

    static func axElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let child = value as! AXUIElement
        AXUIElementSetMessagingTimeout(child, accessibilityMessagingTimeout)
        return child
    }

    static func windowID(for element: AXUIElement) -> CGWindowID? {
        readWindowID(for: element).windowID
    }

    static func readWindowID(for element: AXUIElement) -> (error: AXError, windowID: CGWindowID?) {
        var id = CGWindowID(0)
        let error = _AXUIElementGetWindow(element, &id)
        return (error, error == .success && id != 0 ? id : nil)
    }

    static func focusedWindowID(for pid: pid_t) -> CGWindowID? {
        let appElement = applicationElement(for: pid)
        guard let focusedWindow = axElementAttribute(appElement, kAXFocusedWindowAttribute as CFString) else {
            return nil
        }
        return windowID(for: focusedWindow)
    }

    static func applicationElement(for pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, accessibilityMessagingTimeout)
        return element
    }

    static func windowDescriptions(_ ids: [CGWindowID]) -> [CGWindowID: WindowDescription] {
        guard !ids.isEmpty else { return [:] }
        let rawIds: CFArray = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }.withUnsafeBufferPointer {
            CFArrayCreate(nil, UnsafeMutablePointer(mutating: $0.baseAddress), $0.count, nil)
        }
        guard let descriptions = CGWindowListCreateDescriptionFromArray(rawIds) as? [[CFString: Any]] else {
            return [:]
        }
        return descriptions.reduce(into: [CGWindowID: WindowDescription]()) { result, description in
            guard let windowID = description[kCGWindowNumber] as? CGWindowID,
                  let ownerPID = description[kCGWindowOwnerPID] as? pid_t else { return }
            let parsedBounds = (description[kCGWindowBounds] as? NSDictionary)
                .flatMap { CGRect(dictionaryRepresentation: $0) }
            let bounds = parsedBounds.flatMap { bounds in
                bounds.width > 0 && bounds.height > 0 ? bounds : nil
            }
            result[windowID] = WindowDescription(
                ownerPID: ownerPID,
                bounds: bounds,
                level: description[kCGWindowLayer] as? CGWindowLevel
            )
        }
    }
}

struct WindowDescription {
    let ownerPID: pid_t
    let bounds: CGRect?
    let level: CGWindowLevel?
}
