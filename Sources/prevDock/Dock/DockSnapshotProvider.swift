import ApplicationServices
import Cocoa
import CoreGraphics

struct DockSnapshot {
    let image: NSImage
    let geometry: DockSnapshotGeometry
    let geometryKey: DockSnapshotGeometryKey
    let screenFrame: CGRect
    let tileSizePreference: CGFloat?

    var edge: DockSnapshotEdge { geometry.edge }
    var dockRectInImage: CGRect { geometry.dockRectInImage }
    var finderRectInImage: CGRect { geometry.finderRectInImage }
}

enum DockSnapshotProvider {
    private static let captureQueue = DispatchQueue(
        label: "com.prevdock.settings-dock-snapshot",
        qos: .userInitiated
    )
    private static var cache = [DockSnapshotCacheKey: DockSnapshot]()
    private static var cacheOrder = [DockSnapshotCacheKey]()
    private static let maximumCacheEntries = 6

    static func capture(for screen: NSScreen?, completion: @escaping (DockSnapshot?) -> Void) {
        let prepare = {
            prepareCapture(for: screen, completion: completion)
        }
        if Thread.isMainThread {
            prepare()
        } else {
            DispatchQueue.main.async(execute: prepare)
        }
    }

    private static func prepareCapture(
        for screen: NSScreen?,
        completion: @escaping (DockSnapshot?) -> Void
    ) {
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess(),
              let location = DockScreenLocator.snapshotLocation(for: screen) else {
            finish(nil, completion: completion)
            return
        }

        captureQueue.async {
            let key = DockSnapshotCacheKey(location: location)
            let freshSnapshot = makeSnapshot(at: location)
            if let freshSnapshot {
                store(freshSnapshot, for: key)
            }
            let snapshot = freshSnapshot ?? cache[key]
            finish(snapshot, completion: completion)
        }
    }

    private static func makeSnapshot(at location: DockSnapshotAXLocation) -> DockSnapshot? {
        let candidates = windowCandidates(preferredWindowID: location.preferredWindowID)
        guard let window = DockSnapshotGeometryCalculator.bestWindowCandidate(
            from: candidates,
            dockPID: location.dockPID,
            dockRect: location.dockRect,
            preferredWindowID: location.preferredWindowID
        ), let sourceImage = SkyLightCapture.capture(windowID: window.windowID) else {
            return nil
        }

        let sourcePixelSize = CGSize(width: sourceImage.width, height: sourceImage.height)
        guard let crop = DockSnapshotGeometryCalculator.cropGeometry(
            windowBounds: window.bounds,
            dockRect: location.dockRect,
            finderRect: location.finderRect,
            imagePixelSize: sourcePixelSize,
            edge: location.edge,
            padding: 8
        ), let croppedImage = DockSnapshotImageProcessor.tightCrop(sourceImage, to: crop.pixelCropRect),
           DockSnapshotAlphaValidator.hasUsableAlpha(croppedImage) else {
            return nil
        }

        let image = NSImage(cgImage: croppedImage, size: crop.geometry.imageSize)
        let geometryKey = DockSnapshotGeometryCalculator.geometryKey(
            displayID: location.displayID,
            edge: location.edge,
            dockRect: location.dockRect,
            imagePixelSize: CGSize(width: croppedImage.width, height: croppedImage.height)
        )
        return DockSnapshot(
            image: image,
            geometry: crop.geometry,
            geometryKey: geometryKey,
            screenFrame: location.appKitScreenFrame,
            tileSizePreference: location.tileSizePreference
        )
    }

    private static func windowCandidates(preferredWindowID: CGWindowID?) -> [DockSnapshotWindowCandidate] {
        var descriptions = windowDescriptions(
            options: [.optionOnScreenOnly, .excludeDesktopElements],
            relativeTo: kCGNullWindowID
        )
        if let preferredWindowID {
            descriptions += windowDescriptions(
                options: [.optionIncludingWindow],
                relativeTo: preferredWindowID
            )
        }

        var seen = Set<CGWindowID>()
        return descriptions.compactMap(windowCandidate).filter { candidate in
            guard !seen.contains(candidate.windowID) else { return false }
            seen.insert(candidate.windowID)
            return true
        }
    }

    private static func windowDescriptions(
        options: CGWindowListOption,
        relativeTo windowID: CGWindowID
    ) -> [[String: Any]] {
        CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]] ?? []
    }

    private static func windowCandidate(_ description: [String: Any]) -> DockSnapshotWindowCandidate? {
        guard let windowID = number(description, key: kCGWindowNumber)?.uint32Value,
              let ownerPID = number(description, key: kCGWindowOwnerPID)?.int32Value,
              let layer = number(description, key: kCGWindowLayer)?.intValue,
              let boundsDictionary = description[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
              bounds.width > 0,
              bounds.height > 0 else {
            return nil
        }

        return DockSnapshotWindowCandidate(
            windowID: windowID,
            ownerPID: ownerPID,
            layer: layer,
            bounds: bounds,
            name: description[kCGWindowName as String] as? String,
            ownerName: description[kCGWindowOwnerName as String] as? String,
            isOnScreen: number(description, key: kCGWindowIsOnscreen)?.boolValue ?? true
        )
    }

    private static func number(_ dictionary: [String: Any], key: CFString) -> NSNumber? {
        dictionary[key as String] as? NSNumber
    }

    private static func store(_ snapshot: DockSnapshot, for key: DockSnapshotCacheKey) {
        cache[key] = snapshot
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > maximumCacheEntries {
            let oldest = cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    private static func finish(
        _ snapshot: DockSnapshot?,
        completion: @escaping (DockSnapshot?) -> Void
    ) {
        DispatchQueue.main.async {
            completion(snapshot)
        }
    }
}

private struct DockSnapshotCacheKey: Hashable {
    let displayID: UInt32
    let edge: DockSnapshotEdge
    let dockWidthInCentipoints: Int
    let dockHeightInCentipoints: Int
    let screenFrameKey: DockSnapshotScreenFrameKey
    let backingScaleInCentipoints: Int
    let tileSizeInCentipoints: Int

    init(location: DockSnapshotAXLocation) {
        displayID = location.displayID
        edge = location.edge
        dockWidthInCentipoints = Self.centipoints(location.dockRect.width)
        dockHeightInCentipoints = Self.centipoints(location.dockRect.height)
        screenFrameKey = DockSnapshotScreenFrameKey(frame: location.appKitScreenFrame)
        backingScaleInCentipoints = Self.centipoints(location.backingScaleFactor)
        tileSizeInCentipoints = location.tileSizePreference.map(Self.centipoints) ?? -1
    }

    private static func centipoints(_ value: CGFloat) -> Int {
        guard value.isFinite else { return 0 }
        return Int((value * 100).rounded())
    }
}
