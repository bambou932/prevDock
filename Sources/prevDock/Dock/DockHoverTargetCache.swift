import Cocoa

final class DockHoverTargetCache {
    private weak var previewController: PreviewPanelController?
    private var cachedHoverTarget: DockHoverTarget?
    private var cachedHoverTargetResolvedAt: TimeInterval = 0
    private var cachedHoverResolutionPoint = CGPoint.zero
    private var hasCachedHoverResolution = false
    private let hoverTargetCacheInterval: TimeInterval = 0.12
    private let hoverTargetCachePadding: CGFloat = 3
    private let negativeHoverTargetCacheInterval: TimeInterval = 0.2
    private let negativeHoverTargetCacheRadius: CGFloat = 8

    init(previewController: PreviewPanelController) {
        self.previewController = previewController
    }

    func target(_ mouse: CGPoint) -> DockHoverTarget? {
        guard previewController?.contains(mouse) != true else {
            return nil
        }

        guard DockGeometryCache.shared.isInDockInteractionStrip(mouse) else {
            clear()
            return nil
        }

        if let cachedHoverTarget,
           ProcessInfo.processInfo.systemUptime - cachedHoverTargetResolvedAt < hoverTargetCacheInterval,
           cachedHoverTarget.anchor
            .insetBy(dx: -hoverTargetCachePadding, dy: -hoverTargetCachePadding)
            .contains(mouse) {
            DockGeometryCache.shared.noteResolvedDockItem(anchor: cachedHoverTarget.anchor)
            return cachedHoverTarget
        }
        if hasCachedHoverResolution,
           cachedHoverTarget == nil,
           ProcessInfo.processInfo.systemUptime - cachedHoverTargetResolvedAt < negativeHoverTargetCacheInterval,
           squaredDistance(from: mouse, to: cachedHoverResolutionPoint) <=
            negativeHoverTargetCacheRadius * negativeHoverTargetCacheRadius {
            return nil
        }

        let target = DockHoverTargetResolver.target(at: mouse)
        if let target {
            DockGeometryCache.shared.noteResolvedDockItem(anchor: target.anchor)
        }
        cachedHoverTarget = target
        cachedHoverTargetResolvedAt = ProcessInfo.processInfo.systemUptime
        cachedHoverResolutionPoint = mouse
        hasCachedHoverResolution = true
        return target
    }

    func freshTarget(_ mouse: CGPoint) -> DockHoverTarget? {
        guard previewController?.contains(mouse) != true,
              DockGeometryCache.shared.isInDockInteractionStrip(mouse) else {
            return nil
        }
        let target = DockHoverTargetResolver.target(at: mouse)
        if let target {
            DockGeometryCache.shared.noteResolvedDockItem(anchor: target.anchor)
        }
        cachedHoverTarget = target
        cachedHoverTargetResolvedAt = ProcessInfo.processInfo.systemUptime
        cachedHoverResolutionPoint = mouse
        hasCachedHoverResolution = true
        return target
    }

    func clear() {
        cachedHoverTarget = nil
        cachedHoverTargetResolvedAt = 0
        cachedHoverResolutionPoint = .zero
        hasCachedHoverResolution = false
    }

    private func squaredDistance(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }
}
