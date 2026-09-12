import Cocoa

struct PreviewInitialHoverGate {
    private let suppressionPoint: CGPoint?
    private var isSuppressionActive: Bool

    init(suppressionPoint: CGPoint?) {
        self.suppressionPoint = suppressionPoint
        isSuppressionActive = suppressionPoint != nil
    }

    mutating func blocksHoverActivation(at screenPoint: CGPoint? = nil) -> Bool {
        guard isSuppressionActive, let suppressionPoint else { return false }
        let mouse = screenPoint ?? DockCursorTracker.shared.currentMouseLocation(preferEventTap: true)
        if mouse.distanceSquared(to: suppressionPoint) <= 4 {
            return true
        }
        isSuppressionActive = false
        return false
    }
}

private extension CGPoint {
    func distanceSquared(to point: CGPoint) -> CGFloat {
        let dx = x - point.x
        let dy = y - point.y
        return dx * dx + dy * dy
    }
}
