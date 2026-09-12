import ApplicationServices
import Foundation

enum DockAccessibility {
    static let maximumScanDuration: TimeInterval = 0.12

    static func prepare(_ element: AXUIElement) {
        // AX timeouts belong to individual objects; children do not inherit the application's timeout.
        AXUIElementSetMessagingTimeout(element, 0.025)
    }
}
