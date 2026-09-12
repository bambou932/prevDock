import Cocoa
import ApplicationServices
import CoreGraphics

struct WindowPreview {
    let windowID: CGWindowID
    let title: String
    let bounds: CGRect
    let isMinimized: Bool
    let isFullscreen: Bool
    let isFocused: Bool
    let desktop: WindowDesktop?
    let image: NSImage?
    let app: NSRunningApplication

    func replacingImage(with image: NSImage?) -> WindowPreview {
        WindowPreview(
            windowID: windowID,
            title: title,
            bounds: bounds,
            isMinimized: isMinimized,
            isFullscreen: isFullscreen,
            isFocused: isFocused,
            desktop: desktop,
            image: image,
            app: app
        )
    }
}

struct WindowDesktop: Hashable {
    let id: UInt64
    let title: String
    let sortOrder: Int
    let isCurrent: Bool
}

enum WindowThumbnailRefreshPolicy: Int {
    case none
    case missingOnly
    case refreshStale
}

enum FreshThumbnailCaptureResult {
    case captured(NSImage)
    case cached(NSImage)
    case unavailable

    var image: NSImage? {
        switch self {
        case .captured(let image), .cached(let image):
            return image
        case .unavailable:
            return nil
        }
    }
}
