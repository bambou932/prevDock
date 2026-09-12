import AppKit
import CoreGraphics

@main
enum DockSnapshotGeometryTests {
    static func main() {
        cropPreservesPointsAcrossDisplaysAndScales()
        localCoordinatesUseBottomLeftOrigin()
        clippedDockRetainsConsistentGlobalOrigin()
        hiddenDockRequiresVisibleFinder()
        candidateSelectionRejectsForeignAndConcealedWindows()
        invalidGeometryIsRejected()
        cropCopiesPixelsAndRejectsTransparentImages()
        metadataComparisonUsesNativePixelPrecision()
        print("Dock snapshot geometry tests passed")
    }

    private static func cropPreservesPointsAcrossDisplaysAndScales() {
        for edge in DockSnapshotEdge.allCases {
            for scale: CGFloat in [1, 2] {
                let screen = CGRect(x: -1600, y: -300, width: 1600, height: 1000)
                let dock: CGRect
                let finder: CGRect
                switch edge {
                case .bottom:
                    dock = CGRect(x: -1400, y: 620, width: 1000, height: 80)
                    finder = CGRect(x: -1388, y: 628, width: 64, height: 64)
                case .left:
                    dock = CGRect(x: -1600, y: -150, width: 80, height: 700)
                    finder = CGRect(x: -1592, y: -138, width: 64, height: 64)
                case .right:
                    dock = CGRect(x: -80, y: -150, width: 80, height: 700)
                    finder = CGRect(x: -72, y: -138, width: 64, height: 64)
                }
                let window = dock.insetBy(dx: -8, dy: -8)
                let crop = DockSnapshotGeometryCalculator.cropGeometry(
                    windowBounds: window, dockRect: dock, finderRect: finder,
                    imagePixelSize: CGSize(width: window.width * scale, height: window.height * scale), edge: edge
                )!
                check(crop.geometry.imageSize == window.size, "point size must not double on Retina displays")
                check(crop.pixelCropRect.size == CGSize(width: window.width * scale, height: window.height * scale), "pixel crop must retain native resolution")
                check(crop.geometry.finderRectInImage.size == finder.size, "Finder size stays in points")
                check(DockSnapshotGeometryCalculator.edge(forQuartzDockRect: dock, in: screen) == edge, "edge inference must support negative display origins")
                check(DockSnapshotGeometryCalculator.visibleFinder(finder, dock: dock, screen: screen), "all three fully visible Dock orientations are usable")
            }
        }
    }

    private static func localCoordinatesUseBottomLeftOrigin() {
        let crop = CGRect(x: 10, y: 20, width: 100, height: 80)
        let item = CGRect(x: 30, y: 25, width: 20, height: 30)
        let local = DockSnapshotGeometryCalculator.imageLocalRect(item, croppedTo: crop)
        check(local == CGRect(x: 20, y: 45, width: 20, height: 30), "Quartz top-left must map to image bottom-left")
        let clipped = DockSnapshotGeometryCalculator.cropGeometry(
            windowBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            dockRect: CGRect(x: 0.25, y: 0.75, width: 80.5, height: 80.5),
            finderRect: CGRect(x: 2, y: 2, width: 20, height: 20),
            imagePixelSize: CGSize(width: 200, height: 200), edge: .left
        )!
        check(clipped.pixelCropRect.minX == 0 && clipped.pixelCropRect.minY == 0, "padding must clamp to the source image")
        check(clipped.pixelCropRect == clipped.pixelCropRect.integral, "fractional points must crop at exact pixel boundaries")
    }

    private static func hiddenDockRequiresVisibleFinder() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let finder = CGRect(x: 210, y: 892, width: 64, height: 64)
        let hidden = CGRect(x: 200, y: 898, width: 800, height: 80)
        check(!DockSnapshotGeometryCalculator.visibleFinder(finder, dock: hidden, screen: screen), "a thin on-screen Dock strip cannot count as shown")
        check(DockSnapshotGeometryCalculator.edge(forQuartzDockRect: hidden, in: screen) == .bottom, "off-screen bottom Dock must not become a side Dock")
        check(!DockSnapshotGeometryCalculator.visibleFinder(CGRect(x: -63, y: 100, width: 64, height: 64),
                                                            dock: CGRect(x: -79, y: 50, width: 80, height: 600), screen: screen), "hidden left Dock must not show stale pixels")
        check(!DockSnapshotGeometryCalculator.visibleFinder(CGRect(x: 1199, y: 100, width: 64, height: 64),
                                                            dock: CGRect(x: 1199, y: 50, width: 80, height: 600), screen: screen), "hidden right Dock must not show stale pixels")
    }

    private static func clippedDockRetainsConsistentGlobalOrigin() {
        let window = CGRect(x: 100, y: 300, width: 300, height: 200)
        let dock = CGRect(x: 90, y: 290, width: 290, height: 190)
        let finder = CGRect(x: 95, y: 295, width: 64, height: 64)
        let crop = DockSnapshotGeometryCalculator.cropGeometry(windowBounds: window, dockRect: dock, finderRect: finder,
                                                              imagePixelSize: CGSize(width: 600, height: 400), edge: .left)!
        let imageFrame = CGRect(x: crop.pointCropRect.minX, y: 900 - crop.pointCropRect.maxY,
                               width: crop.pointCropRect.width, height: crop.pointCropRect.height)
        let globalDock = crop.geometry.dockRectInImage.offsetBy(dx: imageFrame.minX, dy: imageFrame.minY)
        let globalFinder = crop.geometry.finderRectInImage.offsetBy(dx: imageFrame.minX, dy: imageFrame.minY)
        check(globalDock == CGRect(x: 100, y: 420, width: 280, height: 180), "global Dock geometry must describe the same clipped region as the image-local geometry")
        check(globalFinder == CGRect(x: 100, y: 541, width: 59, height: 59), "Finder must use the same crop origin when partly clipped")
        check(globalDock.minX - crop.geometry.dockRectInImage.minX == imageFrame.minX &&
              globalDock.minY - crop.geometry.dockRectInImage.minY == imageFrame.minY,
              "the stage must be able to recover the exact image origin from global and local Dock rects")
    }

    private static func candidateSelectionRejectsForeignAndConcealedWindows() {
        let dock = CGRect(x: 100, y: 700, width: 800, height: 80)
        func candidate(_ id: UInt32, pid: Int32 = 42, layer: Int = 20, name: String? = "Dock", shown: Bool = true, alpha: CGFloat = 1) -> DockSnapshotWindowCandidate {
            DockSnapshotWindowCandidate(windowID: id, ownerPID: pid, layer: layer, bounds: dock, name: name, isOnScreen: shown, alpha: alpha)
        }
        let candidates = [candidate(1, pid: 99), candidate(2, name: "Wallpaper"), candidate(3, shown: false),
                          candidate(4, alpha: 0), candidate(5, layer: 0), candidate(6)]
        let selected = DockSnapshotGeometryCalculator.bestWindowCandidate(from: candidates, dockPID: 42, dockRect: dock, preferredWindowID: 3)
        check(selected?.windowID == 6, "a hidden old preferred window must allow the current Dock candidate")
        let exact = DockSnapshotGeometryCalculator.bestWindowCandidate(from: candidates, dockPID: 42, dockRect: dock, preferredWindowID: 5)
        check(exact?.windowID == 5, "a directly associated Dock surface may use layer zero")
        check(DockSnapshotGeometryCalculator.bestWindowCandidate(from: [candidate(1, pid: 99)], dockPID: 42,
                                                                 dockRect: dock, preferredWindowID: 1) == nil, "window ID reuse by a foreign process must be rejected")
    }

    private static func invalidGeometryIsRejected() {
        let valid = CGRect(x: 0, y: 0, width: 100, height: 80)
        for invalid in [CGRect.zero, CGRect.null, CGRect.infinite, CGRect(x: CGFloat.nan, y: 0, width: 100, height: 80)] {
            check(DockSnapshotGeometryCalculator.cropGeometry(windowBounds: invalid, dockRect: valid, finderRect: valid,
                                                              imagePixelSize: valid.size, edge: .bottom) == nil, "invalid bounds must fail before pixel allocation")
        }
        check(DockSnapshotGeometryCalculator.cropGeometry(windowBounds: valid, dockRect: valid, finderRect: valid,
                                                          imagePixelSize: CGSize(width: 100_000, height: 100_000), edge: .bottom) == nil, "unreasonable crop allocations must be rejected")
    }

    private static func cropCopiesPixelsAndRejectsTransparentImages() {
        let context = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let transparent = context.makeImage()!
        check(!DockSnapshotImageProcessor.hasUsableAlpha(transparent), "fully transparent capture is unavailable")
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        let crop = DockSnapshotImageProcessor.tightCrop(context.makeImage()!, to: CGRect(x: 10, y: 10, width: 20, height: 32))!
        check(crop.width == 20 && crop.height == 32, "tight crop uses only the requested pixels")
        check(crop.bytesPerRow < 256 * 4, "cropped image must not retain the large source framebuffer stride")
        check(DockSnapshotImageProcessor.hasUsableAlpha(crop), "tight copy preserves visible pixels")
    }

    private static func metadataComparisonUsesNativePixelPrecision() {
        let display = DockSnapshotDisplay(id: 1, name: "Display", frame: CGRect(x: 0, y: 0, width: 1200, height: 900),
                                          visibleFrame: CGRect(x: 0, y: 70, width: 1200, height: 800), backingScaleFactor: 2)
        let context = DockSnapshotContext(windowNumber: 1, preferredDisplayID: 1, displays: [display], referenceMaxY: 900, dockPID: 42)
        func metadata(_ offset: CGFloat, id: UInt32 = 10) -> DockSnapshotMetadata {
            DockSnapshotMetadata(context: context, display: display, windowID: id, edge: .bottom,
                                 windowBounds: CGRect(x: 0, y: 800, width: 1000, height: 100),
                                 dockRect: CGRect(x: 1 + offset, y: 802, width: 998, height: 98), finderRect: CGRect(x: 10, y: 810, width: 64, height: 64))
        }
        check(metadata(0).matchesCapture(metadata(0.01)), "subpixel numerical noise must not trigger captures")
        check(!metadata(0).matchesCapture(metadata(0.5)), "a native pixel change affects crop alignment")
        check(!metadata(0).matchesCapture(metadata(0, id: 11)), "Dock window replacement invalidates pixels")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
