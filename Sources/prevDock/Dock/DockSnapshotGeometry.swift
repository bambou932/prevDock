import CoreGraphics
import Foundation

struct DockSnapshotWindowCandidate {
    let windowID: CGWindowID
    let ownerPID: Int32
    let layer: Int
    let bounds: CGRect
    let name: String?
    let isOnScreen: Bool
    let alpha: CGFloat
}

struct DockSnapshotCropGeometry {
    let pixelCropRect: CGRect
    let pointCropRect: CGRect
    let geometry: DockSnapshotGeometry
}

enum DockSnapshotGeometryCalculator {
    static func isUsable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.minX.isFinite && rect.minY.isFinite &&
            rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }

    static func edge(forQuartzDockRect dock: CGRect, in screen: CGRect) -> DockSnapshotEdge {
        guard dock.width < dock.height else { return .bottom }
        return abs(dock.minX - screen.minX) <= abs(screen.maxX - dock.maxX) ? .left : .right
    }

    static func visibleFinder(_ finder: CGRect, dock: CGRect, screen: CGRect) -> Bool {
        guard isUsable(finder), isUsable(dock), isUsable(screen) else { return false }
        let visible = finder.intersection(screen)
        guard isUsable(visible), isUsable(dock.intersection(screen)) else { return false }
        // An auto-hidden Dock can retain a thin on-screen window and valid AX elements.
        return visible.width * visible.height >= finder.width * finder.height * 0.8
    }

    static func bestWindowCandidate(
        from candidates: [DockSnapshotWindowCandidate], dockPID: Int32,
        dockRect: CGRect, preferredWindowID: CGWindowID?
    ) -> DockSnapshotWindowCandidate? {
        let viable = candidates.filter {
            $0.ownerPID == dockPID && $0.windowID != 0 && $0.isOnScreen && $0.alpha > 0 &&
                isUsable($0.bounds) && isUsable($0.bounds.intersection(dockRect)) && !isWallpaper($0.name)
        }
        if let preferredWindowID, let exact = viable.first(where: { $0.windowID == preferredWindowID }) {
            return exact
        }
        return viable.filter { $0.layer > 0 }.max { score($0, dock: dockRect) < score($1, dock: dockRect) }
    }

    static func cropGeometry(
        windowBounds: CGRect, dockRect: CGRect, finderRect: CGRect,
        imagePixelSize: CGSize, edge: DockSnapshotEdge, padding: CGFloat = 8
    ) -> DockSnapshotCropGeometry? {
        guard isUsable(windowBounds), isUsable(dockRect), isUsable(finderRect),
              imagePixelSize.width.isFinite, imagePixelSize.height.isFinite,
              imagePixelSize.width >= 1, imagePixelSize.height >= 1 else { return nil }
        let scaleX = imagePixelSize.width / windowBounds.width
        let scaleY = imagePixelSize.height / windowBounds.height
        let requested = dockRect.union(finderRect).insetBy(dx: -padding, dy: -padding).intersection(windowBounds)
        guard isUsable(requested) else { return nil }
        let minX = floor((requested.minX - windowBounds.minX) * scaleX)
        let minY = floor((requested.minY - windowBounds.minY) * scaleY)
        let maxX = ceil((requested.maxX - windowBounds.minX) * scaleX)
        let maxY = ceil((requested.maxY - windowBounds.minY) * scaleY)
        let pixels = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .intersection(CGRect(origin: .zero, size: imagePixelSize))
        guard isUsable(pixels), pixels.width * pixels.height <= 16_777_216 else { return nil }
        let points = CGRect(x: windowBounds.minX + pixels.minX / scaleX,
                            y: windowBounds.minY + pixels.minY / scaleY,
                            width: pixels.width / scaleX, height: pixels.height / scaleY)
        guard let dock = imageLocalRect(dockRect, croppedTo: points),
              let finder = imageLocalRect(finderRect, croppedTo: points) else { return nil }
        return DockSnapshotCropGeometry(pixelCropRect: pixels, pointCropRect: points, geometry: DockSnapshotGeometry(
            edge: edge, imageSize: points.size, dockRectInImage: dock, finderRectInImage: finder
        ))
    }

    static func imageLocalRect(_ rect: CGRect, croppedTo crop: CGRect) -> CGRect? {
        let clipped = rect.intersection(crop)
        guard isUsable(clipped) else { return nil }
        return CGRect(x: clipped.minX - crop.minX, y: crop.maxY - clipped.maxY,
                      width: clipped.width, height: clipped.height)
    }

    private static func score(_ candidate: DockSnapshotWindowCandidate, dock: CGRect) -> CGFloat {
        let intersection = candidate.bounds.intersection(dock)
        let area = intersection.width * intersection.height
        return area / max(1, dock.width * dock.height) * 10_000 +
            area / max(1, candidate.bounds.width * candidate.bounds.height) * 1_000
    }

    private static func isWallpaper(_ name: String?) -> Bool {
        name?.localizedCaseInsensitiveContains("wallpaper") == true ||
            name?.localizedCaseInsensitiveContains("desktop picture") == true
    }
}

enum DockSnapshotImageProcessor {
    static func tightCrop(_ image: CGImage, to pixelRect: CGRect) -> CGImage? {
        guard let cropped = image.cropping(to: pixelRect),
              let context = CGContext(data: nil, width: cropped.width, height: cropped.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // A cropped CGImage can retain its entire original framebuffer; copy only this crop.
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        return context.makeImage()
    }

    static func hasUsableAlpha(_ image: CGImage) -> Bool {
        let width = min(64, image.width)
        let height = min(64, image.height)
        guard width > 0, height > 0 else { return false }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        return bytes.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let pixels = storage.bindMemory(to: UInt8.self)
            let visible = stride(from: 3, to: pixels.count, by: 4).reduce(0) { $0 + (pixels[$1] > 8 ? 1 : 0) }
            return visible >= max(1, width * height / 200)
        }
    }
}
