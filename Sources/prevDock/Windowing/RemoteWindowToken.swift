import ApplicationServices
import CoreGraphics
import Foundation

struct RemoteWindowToken {
    private var data: Data

    init(pid: pid_t) {
        var remoteToken = Data(count: 20)
        remoteToken.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        remoteToken.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        remoteToken.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
        data = remoteToken
    }

    mutating func element(for elementID: UInt64, messagingTimeout: Float? = 0.03) -> AXUIElement? {
        data.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })
        guard let element = _AXUIElementCreateWithRemoteToken(data as CFData)?.takeRetainedValue() else {
            return nil
        }
        if let messagingTimeout {
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
        }
        return element
    }

    static func element(pid: pid_t, elementID: UInt64) -> AXUIElement? {
        var token = RemoteWindowToken(pid: pid)
        return token.element(for: elementID)
    }
}

enum RemoteWindowElementValidation {
    static func isExpectedWindow(_ element: AXUIElement, windowID expectedWindowID: CGWindowID) -> Bool {
        isAXWindowElement(element) && windowID(for: element) == expectedWindowID
    }

    static func isAXWindowElement(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &value
        ) == .success else {
            return false
        }
        return RemoteWindowRolePolicy.accepts(subrole: value as? String) {
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success else {
                return nil
            }
            return role as? String
        }
    }

    static func windowID(for element: AXUIElement) -> CGWindowID? {
        var id = CGWindowID(0)
        guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }
}

enum RemoteWindowRolePolicy {
    static func accepts(subrole: String?, readRole: () -> String?) -> Bool {
        if [kAXStandardWindowSubrole, kAXDialogSubrole, kAXFloatingWindowSubrole].contains(subrole ?? "") {
            return true
        }
        // Some supported apps expose ordinary windows as AXUnknown; downstream app filters still apply.
        guard subrole == kAXUnknownSubrole else { return false }
        return readRole() == kAXWindowRole
    }
}
