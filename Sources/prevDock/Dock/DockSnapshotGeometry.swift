import CoreGraphics
import Foundation

enum DockSnapshotEdge: String, CaseIterable, Hashable {
    case bottom
    case top
    case left
    case right
}

struct DockSnapshotGeometry: Equatable {
    let edge: DockSnapshotEdge
    let imageSize: CGSize
    let dockRectInImage: CGRect
    let finderRectInImage: CGRect
}

struct DockSnapshotGeometryKey: Hashable {
    let displayID: UInt32
    let edge: DockSnapshotEdge
    let dockWidthInCentipoints: Int
    let dockHeightInCentipoints: Int
    let imagePixelWidth: Int
    let imagePixelHeight: Int
}

struct DockSnapshotScreenFrameKey: Hashable {
    let minXInCentipoints: Int
    let minYInCentipoints: Int
    let widthInCentipoints: Int
    let heightInCentipoints: Int

    init(frame: CGRect) {
        minXInCentipoints = Self.centipoints(frame.minX)
        minYInCentipoints = Self.centipoints(frame.minY)
        widthInCentipoints = Self.centipoints(frame.width)
        heightInCentipoints = Self.centipoints(frame.height)
    }

    private static func centipoints(_ value: CGFloat) -> Int {
        guard value.isFinite else { return 0 }
        return Int((value * 100).rounded())
    }
}

struct DockSnapshotWindowCandidate: Equatable {
    let windowID: CGWindowID
    let ownerPID: Int32
    let layer: Int
    let bounds: CGRect
    let name: String?
    let ownerName: String?
    let isOnScreen: Bool
}

struct DockSnapshotCropGeometry: Equatable {
    let pixelCropRect: CGRect
    let pointCropRect: CGRect
    let scaleX: CGFloat
    let scaleY: CGFloat
    let geometry: DockSnapshotGeometry
}

enum DockSnapshotImageProcessor {
    static func tightCrop(_ image: CGImage, to pixelRect: CGRect) -> CGImage? {
        guard let cropped = image.cropping(to: pixelRect),
              cropped.width > 0,
              cropped.height > 0 else {
            return nil
        }

        let bytesPerPixel = max(1, cropped.bitsPerPixel / 8)
        let bytesPerRow = cropped.width * bytesPerPixel
        let colorSpace = cropped.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: cropped.width,
            height: cropped.height,
            bitsPerComponent: cropped.bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: cropped.bitmapInfo.rawValue
        ) else {
            return nil
        }

        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        return context.makeImage()
    }
}

enum DockSnapshotAlphaValidator {
    static func hasUsableAlpha(_ image: CGImage) -> Bool {
        let width = min(64, max(1, image.width))
        let height = min(64, max(1, image.height))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }

            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return false }

        let visiblePixels = stride(from: 3, to: pixels.count, by: 4).reduce(into: 0) { count, index in
            if pixels[index] > 8 { count += 1 }
        }
        return visiblePixels >= max(1, width * height / 200)
    }
}

enum DockSnapshotGeometryCalculator {
    static func edge(for dockRect: CGRect, in screenFrame: CGRect) -> DockSnapshotEdge {
        let distances: [(DockSnapshotEdge, CGFloat)]
        if dockRect.width >= dockRect.height {
            distances = [
                (.bottom, abs(dockRect.minY - screenFrame.minY)),
                (.top, abs(screenFrame.maxY - dockRect.maxY))
            ]
        } else {
            distances = [
                (.left, abs(dockRect.minX - screenFrame.minX)),
                (.right, abs(screenFrame.maxX - dockRect.maxX))
            ]
        }
        return closestEdge(in: distances)
    }

    static func geometryKey(
        displayID: UInt32,
        edge: DockSnapshotEdge,
        dockRect: CGRect,
        imagePixelSize: CGSize
    ) -> DockSnapshotGeometryKey {
        DockSnapshotGeometryKey(
            displayID: displayID,
            edge: edge,
            dockWidthInCentipoints: quantizedCentipoints(dockRect.width),
            dockHeightInCentipoints: quantizedCentipoints(dockRect.height),
            imagePixelWidth: max(0, Int(imagePixelSize.width.rounded())),
            imagePixelHeight: max(0, Int(imagePixelSize.height.rounded()))
        )
    }

    static func bestWindowCandidate(
        from candidates: [DockSnapshotWindowCandidate],
        dockPID: Int32,
        dockRect: CGRect,
        preferredWindowID: CGWindowID?
    ) -> DockSnapshotWindowCandidate? {
        if let preferredWindowID,
           let exact = candidates.first(where: {
               $0.windowID == preferredWindowID &&
                   isExactMatchViable($0, dockPID: dockPID, dockRect: dockRect)
           }) {
            return exact
        }
        return candidates
            .filter { isViable($0, dockPID: dockPID, dockRect: dockRect) }
            .max { lhs, rhs in
                candidateScore(lhs, dockRect: dockRect, preferredWindowID: preferredWindowID) <
                    candidateScore(rhs, dockRect: dockRect, preferredWindowID: preferredWindowID)
            }
    }

    static func cropGeometry(
        windowBounds: CGRect,
        dockRect: CGRect,
        finderRect: CGRect,
        imagePixelSize: CGSize,
        screenFrame: CGRect,
        padding: CGFloat = 8
    ) -> DockSnapshotCropGeometry? {
        cropGeometry(
            windowBounds: windowBounds,
            dockRect: dockRect,
            finderRect: finderRect,
            imagePixelSize: imagePixelSize,
            edge: edge(forQuartzDockRect: dockRect, in: screenFrame),
            padding: padding
        )
    }

    static func cropGeometry(
        windowBounds: CGRect,
        dockRect: CGRect,
        finderRect: CGRect,
        imagePixelSize: CGSize,
        edge: DockSnapshotEdge,
        padding: CGFloat = 8
    ) -> DockSnapshotCropGeometry? {
        guard isUsable(windowBounds),
              isUsable(dockRect),
              isUsable(finderRect),
              imagePixelSize.width >= 1,
              imagePixelSize.height >= 1 else {
            return nil
        }

        let scaleX = imagePixelSize.width / windowBounds.width
        let scaleY = imagePixelSize.height / windowBounds.height
        guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else { return nil }

        let requested = dockRect
            .union(finderRect)
            .insetBy(dx: -max(0, padding), dy: -max(0, padding))
        let clipped = requested.intersection(windowBounds)
        guard isUsable(clipped) else { return nil }

        let pixelCropRect = pixelAlignedCropRect(
            clipped,
            in: windowBounds,
            scaleX: scaleX,
            scaleY: scaleY,
            imagePixelSize: imagePixelSize
        )
        guard isUsable(pixelCropRect) else { return nil }

        let pointCropRect = CGRect(
            x: windowBounds.minX + pixelCropRect.minX / scaleX,
            y: windowBounds.minY + pixelCropRect.minY / scaleY,
            width: pixelCropRect.width / scaleX,
            height: pixelCropRect.height / scaleY
        )
        guard let dockRectInImage = imageLocalRect(dockRect, croppedTo: pointCropRect),
              let finderRectInImage = imageLocalRect(finderRect, croppedTo: pointCropRect) else {
            return nil
        }

        let snapshotGeometry = DockSnapshotGeometry(
            edge: edge,
            imageSize: pointCropRect.size,
            dockRectInImage: dockRectInImage,
            finderRectInImage: finderRectInImage
        )
        return DockSnapshotCropGeometry(
            pixelCropRect: pixelCropRect,
            pointCropRect: pointCropRect,
            scaleX: scaleX,
            scaleY: scaleY,
            geometry: snapshotGeometry
        )
    }

    static func edge(forQuartzDockRect dockRect: CGRect, in screenFrame: CGRect) -> DockSnapshotEdge {
        let distances: [(DockSnapshotEdge, CGFloat)]
        if dockRect.width >= dockRect.height {
            distances = [
                (.top, abs(dockRect.minY - screenFrame.minY)),
                (.bottom, abs(screenFrame.maxY - dockRect.maxY))
            ]
        } else {
            distances = [
                (.left, abs(dockRect.minX - screenFrame.minX)),
                (.right, abs(screenFrame.maxX - dockRect.maxX))
            ]
        }
        return closestEdge(in: distances)
    }

    private static func closestEdge(
        in distances: [(DockSnapshotEdge, CGFloat)]
    ) -> DockSnapshotEdge {
        return distances.min { lhs, rhs in
            if lhs.1 == rhs.1 {
                return edgeSortOrder(lhs.0) < edgeSortOrder(rhs.0)
            }
            return lhs.1 < rhs.1
        }?.0 ?? .bottom
    }

    static func imageLocalRect(_ rect: CGRect, croppedTo pointCropRect: CGRect) -> CGRect? {
        let clipped = rect.intersection(pointCropRect)
        guard isUsable(clipped) else { return nil }
        return CGRect(
            x: clipped.minX - pointCropRect.minX,
            y: pointCropRect.maxY - clipped.maxY,
            width: clipped.width,
            height: clipped.height
        )
    }

    private static func pixelAlignedCropRect(
        _ rect: CGRect,
        in windowBounds: CGRect,
        scaleX: CGFloat,
        scaleY: CGFloat,
        imagePixelSize: CGSize
    ) -> CGRect {
        let minX = floor((rect.minX - windowBounds.minX) * scaleX)
        let minY = floor((rect.minY - windowBounds.minY) * scaleY)
        let maxX = ceil((rect.maxX - windowBounds.minX) * scaleX)
        let maxY = ceil((rect.maxY - windowBounds.minY) * scaleY)
        let pixelBounds = CGRect(origin: .zero, size: imagePixelSize)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .intersection(pixelBounds)
            .integral
    }

    private static func isViable(
        _ candidate: DockSnapshotWindowCandidate,
        dockPID: Int32,
        dockRect: CGRect
    ) -> Bool {
        guard candidate.ownerPID == dockPID,
              candidate.windowID != 0,
              candidate.layer > 0,
              candidate.isOnScreen,
              isUsable(candidate.bounds),
              isUsable(candidate.bounds.intersection(dockRect)) else {
            return false
        }
        return !isWallpaper(candidate.name) && !isWallpaper(candidate.ownerName)
    }

    private static func isExactMatchViable(
        _ candidate: DockSnapshotWindowCandidate,
        dockPID: Int32,
        dockRect: CGRect
    ) -> Bool {
        guard candidate.ownerPID == dockPID,
              candidate.windowID != 0,
              candidate.isOnScreen,
              isUsable(candidate.bounds),
              isUsable(candidate.bounds.intersection(dockRect)) else {
            return false
        }
        return !isWallpaper(candidate.name) && !isWallpaper(candidate.ownerName)
    }

    private static func candidateScore(
        _ candidate: DockSnapshotWindowCandidate,
        dockRect: CGRect,
        preferredWindowID: CGWindowID?
    ) -> Double {
        let intersection = candidate.bounds.intersection(dockRect)
        let dockArea = max(1, dockRect.width * dockRect.height)
        let candidateArea = max(1, candidate.bounds.width * candidate.bounds.height)
        let coverage = Double(intersection.width * intersection.height / dockArea)
        let compactness = Double(intersection.width * intersection.height / candidateArea)
        let preferred = candidate.windowID == preferredWindowID ? 1_000_000.0 : 0
        let dockName = candidate.name?.localizedCaseInsensitiveContains("Dock") == true ? 100.0 : 0
        return preferred + coverage * 10_000 + compactness * 1_000 + dockName - Double(candidate.windowID) * 0.000_001
    }

    private static func isWallpaper(_ value: String?) -> Bool {
        value?.localizedCaseInsensitiveContains("wallpaper") == true ||
            value?.localizedCaseInsensitiveContains("desktop picture") == true
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        !rect.isNull &&
            !rect.isInfinite &&
            rect.origin.x.isFinite &&
            rect.origin.y.isFinite &&
            rect.width.isFinite &&
            rect.height.isFinite &&
            rect.width > 0 &&
            rect.height > 0
    }

    private static func quantizedCentipoints(_ value: CGFloat) -> Int {
        guard value.isFinite else { return 0 }
        return Int((value * 100).rounded())
    }

    private static func edgeSortOrder(_ edge: DockSnapshotEdge) -> Int {
        switch edge {
        case .bottom: return 0
        case .top: return 1
        case .left: return 2
        case .right: return 3
        }
    }
}
