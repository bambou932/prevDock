import Cocoa

enum DockScreenLocator {
    static func previewAnchor() -> CGRect? {
        DockGeometryCache.shared.previewAnchor() ?? fallbackDockAnchor()
    }

    private static func fallbackDockAnchor() -> CGRect? {
        for screen in NSScreen.screens {
            let frame = screen.frame
            let visibleFrame = screen.visibleFrame
            if visibleFrame.minY > frame.minY + 1 {
                return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: visibleFrame.minY - frame.minY)
            }
            if visibleFrame.minX > frame.minX + 1 {
                return CGRect(x: frame.minX, y: frame.minY, width: visibleFrame.minX - frame.minX, height: frame.height)
            }
            if visibleFrame.maxX < frame.maxX - 1 {
                return CGRect(x: visibleFrame.maxX, y: frame.minY, width: frame.maxX - visibleFrame.maxX, height: frame.height)
            }
        }
        return NSScreen.main?.frame
    }
}
