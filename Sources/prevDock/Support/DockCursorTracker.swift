import Cocoa

final class DockCursorTracker {
    static let shared = DockCursorTracker()
    private static let cachedLocationLifetime: TimeInterval = 0.25

    private let lock = NSLock()
    private var eventTapMouseLocation: CGPoint?
    private var eventTapMouseLocationUpdatedAt: TimeInterval = 0

    private init() {}

    @discardableResult
    func updateFromEventTap(quartzPoint: CGPoint) -> CGPoint {
        let point = AccessibilityHelpers.appKitPoint(fromQuartzPoint: quartzPoint)
        updateFromAppKitPoint(point)
        return point
    }

    func updateFromAppKitPoint(_ point: CGPoint) {
        lock.lock()
        eventTapMouseLocation = point
        eventTapMouseLocationUpdatedAt = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    func currentMouseLocation(preferEventTap: Bool = false) -> CGPoint {
        lock.lock()
        let point = eventTapMouseLocation
        let updatedAt = eventTapMouseLocationUpdatedAt
        lock.unlock()

        let age = ProcessInfo.processInfo.systemUptime - updatedAt
        let hasFreshEventTapLocation = point != nil && age <= Self.cachedLocationLifetime
        if (preferEventTap || PrevDockSettings.nativeDockLabelSuppressionEnabled),
           hasFreshEventTapLocation {
            return point ?? NSEvent.mouseLocation
        }

        return NSEvent.mouseLocation
    }
}
