import Cocoa

final class DockCursorTracker {
    static let shared = DockCursorTracker()

    private let lock = NSLock()
    private var eventTapMouseLocation: CGPoint?

    private init() {}

    @discardableResult
    func updateFromEventTap(quartzPoint: CGPoint) -> CGPoint {
        let point = AccessibilityHelpers.appKitPoint(fromQuartzPoint: quartzPoint)
        lock.lock()
        eventTapMouseLocation = point
        lock.unlock()
        return point
    }

    func currentMouseLocation(preferEventTap: Bool = false) -> CGPoint {
        lock.lock()
        let point = eventTapMouseLocation
        lock.unlock()

        if preferEventTap || PrevDockSettings.nativeDockLabelSuppressionEnabled {
            return point ?? NSEvent.mouseLocation
        }

        return NSEvent.mouseLocation
    }
}
