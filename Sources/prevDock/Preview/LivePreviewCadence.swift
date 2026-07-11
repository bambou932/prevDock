import Cocoa

enum LivePreviewCadence {
    private static let fallbackFramesPerSecond = 60
    private static let maximumCaptureRequestsPerSecond = 24

    // Window-server capture is heavier than display compositing; keep live previews smooth without
    // asking SkyLight to produce a new bitmap on every physical display refresh.
    static func interval(forWindowBounds bounds: CGRect) -> TimeInterval {
        let frame = appKitFrame(fromWindowBounds: bounds)
        let screen = ScreenGeometry.screen(containing: frame) ?? NSScreen.main
        let framesPerSecond = min(
            max(screen?.maximumFramesPerSecond ?? fallbackFramesPerSecond, 1),
            maximumCaptureRequestsPerSecond
        )
        return 1.0 / TimeInterval(framesPerSecond)
    }

    static func appKitFrame(fromWindowBounds bounds: CGRect) -> NSRect {
        AccessibilityHelpers.appKitFrame(fromQuartzWindowBounds: bounds)
    }
}
