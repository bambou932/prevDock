import Cocoa
import CoreGraphics

enum ScreenGeometry {
    static var appKitReferenceMaxY: CGFloat {
        primaryScreen?.frame.maxY ?? 0
    }

    static var primaryScreen: NSScreen? {
        let mainDisplayID = CGMainDisplayID()
        return NSScreen.screens.first { displayID(for: $0) == mainDisplayID } ??
            NSScreen.screens.first { $0.frame.origin == .zero } ??
            NSScreen.screens.first
    }

    static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    static func screen(containing rect: CGRect) -> NSScreen? {
        let matches = NSScreen.screens.compactMap { screen -> (NSScreen, CGFloat)? in
            let intersection = screen.frame.intersection(rect)
            guard !intersection.isNull, !intersection.isEmpty else { return nil }
            return (screen, intersection.width * intersection.height)
        }
        if let largestMatch = matches.max(by: { $0.1 < $1.1 }) {
            return largestMatch.0
        }
        return screen(containing: CGPoint(x: rect.midX, y: rect.midY))
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }
}
