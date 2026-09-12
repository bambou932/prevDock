import ApplicationServices
import AppKit
import CoreGraphics

final class DockSnapshotBackend: DockSnapshotBackendProviding {
    private let probeQueue = DispatchQueue(label: "prevDock.settings-dock-probe", qos: .utility)
    private let captureQueue = DispatchQueue(label: "prevDock.settings-dock-capture", qos: .utility)
    private var elements: DockSnapshotElements?
    private var elementContext: DockSnapshotContext?
    private var nextDiscoveryAt: TimeInterval = 0
    private var nextWindowDiscoveryAt: TimeInterval = 0
    private var wasHidden = false

    func probe(context: DockSnapshotContext, completion: @escaping (DockSnapshotProbeResult) -> Void) {
        probeQueue.async { [weak self] in
            guard let self else { return }
            let result = self.probeNow(context)
            DispatchQueue.main.async { completion(result) }
        }
    }

    func capture(metadata: DockSnapshotMetadata, completion: @escaping (DockSnapshot?) -> Void) {
        captureQueue.async {
            let result = Self.captureNow(metadata)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func probeNow(_ context: DockSnapshotContext) -> DockSnapshotProbeResult {
        if elementContext != context {
            elements = nil
            nextDiscoveryAt = 0
            nextWindowDiscoveryAt = 0
            elementContext = context
        }
        guard let pid = context.dockPID else { return .unavailable }
        let scan = DockSnapshotAXScan()
        guard let elements = resolveElements(pid: pid, scan: scan),
              let dock = scan.rect(elements.list), let finder = scan.rect(elements.finder) else {
            self.elements = nil
            return .unavailable
        }
        let preferences = DockSnapshotPreferences.read()
        guard let display = display(for: dock, context: context) else {
            return concealedResult(autoHides: preferences.autoHides, geometric: true)
        }
        let screen = quartzFrame(display.frame, context: context)
        let edge = preferences.orientation ?? DockSnapshotGeometryCalculator.edge(forQuartzDockRect: dock, in: screen)
        guard DockSnapshotGeometryCalculator.visibleFinder(finder, dock: dock, screen: screen) else {
            return concealedResult(autoHides: preferences.autoHides, geometric: true)
        }
        if wasHidden { nextWindowDiscoveryAt = 0 }
        wasHidden = false
        return windowMetadata(context: context, elements: elements, display: display,
                              dock: dock, finder: finder, edge: edge, autoHides: preferences.autoHides)
    }

    private func resolveElements(pid: Int32, scan: DockSnapshotAXScan) -> DockSnapshotElements? {
        if let elements { return elements }
        guard ProcessInfo.processInfo.systemUptime >= nextDiscoveryAt else { return nil }
        nextDiscoveryAt = ProcessInfo.processInfo.systemUptime + 5
        let found = scan.findElements(pid: pid)
        elements = found
        return found
    }

    private func windowMetadata(
        context: DockSnapshotContext, elements: DockSnapshotElements, display: DockSnapshotDisplay,
        dock: CGRect, finder: CGRect, edge: DockSnapshotEdge, autoHides: Bool
    ) -> DockSnapshotProbeResult {
        guard let pid = context.dockPID else { return .unavailable }
        let preferred = elements.windowID.flatMap(Self.windowCandidate)
        guard let candidate = resolveWindow(preferred: preferred, pid: pid, dock: dock) else {
            if let preferred, preferred.ownerPID == pid,
               (!preferred.isOnScreen || preferred.alpha == 0 ||
                !DockSnapshotGeometryCalculator.visibleFinder(finder, dock: dock, screen: preferred.bounds)) {
                return concealedResult(autoHides: autoHides)
            }
            return .unavailable
        }
        guard DockSnapshotGeometryCalculator.visibleFinder(finder, dock: dock, screen: candidate.bounds) else {
            return concealedResult(autoHides: autoHides)
        }
        self.elements = DockSnapshotElements(list: elements.list, finder: elements.finder, windowID: candidate.windowID)
        return .visible(DockSnapshotMetadata(context: context, display: display, windowID: candidate.windowID,
                                            edge: edge, windowBounds: candidate.bounds, dockRect: dock, finderRect: finder))
    }

    private func display(for dock: CGRect, context: DockSnapshotContext) -> DockSnapshotDisplay? {
        let matches = context.displays.map { display in
            (display, dock.intersection(quartzFrame(display.frame, context: context)))
        }.filter { DockSnapshotGeometryCalculator.isUsable($0.1) }
        return matches.max { lhs, rhs in
            let left = lhs.1.width * lhs.1.height
            let right = rhs.1.width * rhs.1.height
            if left == right { return rhs.0.id == context.preferredDisplayID }
            return left < right
        }?.0
    }

    private func quartzFrame(_ frame: CGRect, context: DockSnapshotContext) -> CGRect {
        CGRect(x: frame.minX, y: context.referenceMaxY - frame.maxY, width: frame.width, height: frame.height)
    }

    private func concealedResult(autoHides: Bool, geometric: Bool = false) -> DockSnapshotProbeResult {
        if geometric { wasHidden = autoHides }
        return autoHides ? .hidden : .unavailable
    }

    private func resolveWindow(preferred: DockSnapshotWindowCandidate?, pid: Int32, dock: CGRect) -> DockSnapshotWindowCandidate? {
        if let preferred, let exact = DockSnapshotGeometryCalculator.bestWindowCandidate(
            from: [preferred], dockPID: pid, dockRect: dock, preferredWindowID: preferred.windowID
        ) { return exact }
        guard ProcessInfo.processInfo.systemUptime >= nextWindowDiscoveryAt else { return nil }
        nextWindowDiscoveryAt = ProcessInfo.processInfo.systemUptime + 5
        let descriptions = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return DockSnapshotGeometryCalculator.bestWindowCandidate(from: descriptions.compactMap(Self.windowCandidate),
                                                                  dockPID: pid, dockRect: dock, preferredWindowID: nil)
    }

    private static func windowCandidate(_ id: CGWindowID) -> DockSnapshotWindowCandidate? {
        let descriptions = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []
        return descriptions.compactMap(windowCandidate).first { $0.windowID == id }
    }

    private static func windowCandidate(_ value: [String: Any]) -> DockSnapshotWindowCandidate? {
        guard let id = value[kCGWindowNumber as String] as? NSNumber,
              let pid = value[kCGWindowOwnerPID as String] as? NSNumber,
              let layer = value[kCGWindowLayer as String] as? NSNumber,
              let bounds = value[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds), DockSnapshotGeometryCalculator.isUsable(rect) else { return nil }
        return DockSnapshotWindowCandidate(windowID: id.uint32Value, ownerPID: pid.int32Value,
                                            layer: layer.intValue, bounds: rect,
                                            name: value[kCGWindowName as String] as? String,
                                            isOnScreen: (value[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
                                            alpha: (value[kCGWindowAlpha as String] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 1)
    }

    private static func captureNow(_ metadata: DockSnapshotMetadata) -> DockSnapshot? {
        guard let image = SkyLightCapture.capture(windowID: metadata.windowID, resolution: .best),
              let crop = DockSnapshotGeometryCalculator.cropGeometry(
                windowBounds: metadata.windowBounds, dockRect: metadata.dockRect, finderRect: metadata.finderRect,
                imagePixelSize: CGSize(width: image.width, height: image.height), edge: metadata.edge
              ), let cropped = DockSnapshotImageProcessor.tightCrop(image, to: crop.pixelCropRect),
              DockSnapshotImageProcessor.hasUsableAlpha(cropped) else { return nil }
        let imageFrame = metadata.context.appKitRect(crop.pointCropRect)
        return DockSnapshot(image: NSImage(cgImage: cropped, size: crop.geometry.imageSize), geometry: crop.geometry,
                            dockRect: crop.geometry.dockRectInImage.offsetBy(dx: imageFrame.minX, dy: imageFrame.minY),
                            finderRect: crop.geometry.finderRectInImage.offsetBy(dx: imageFrame.minX, dy: imageFrame.minY),
                            screenFrame: metadata.display.frame, screenVisibleFrame: metadata.display.visibleFrame,
                            displayID: metadata.display.id, displayName: metadata.display.name,
                            backingScaleFactor: metadata.display.backingScaleFactor)
    }
}

private struct DockSnapshotElements {
    let list: AXUIElement
    let finder: AXUIElement
    let windowID: CGWindowID?
}

private struct DockSnapshotPreferences {
    let autoHides: Bool
    let orientation: DockSnapshotEdge?

    static func read() -> DockSnapshotPreferences {
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)
        let autoHides = (CFPreferencesCopyAppValue("autohide" as CFString, domain) as? NSNumber)?.boolValue ?? false
        let orientation = (CFPreferencesCopyAppValue("orientation" as CFString, domain) as? String).flatMap(DockSnapshotEdge.init(rawValue:))
        return DockSnapshotPreferences(autoHides: autoHides, orientation: orientation)
    }
}

private final class DockSnapshotAXScan {
    private let deadline = ProcessInfo.processInfo.systemUptime + DockAccessibility.maximumScanDuration
    private var canRead: Bool { ProcessInfo.processInfo.systemUptime < deadline }

    func rect(_ element: AXUIElement) -> CGRect? {
        DockAccessibility.prepare(element)
        guard canRead, let position = AccessibilityHelpers.pointAttribute(element, kAXPositionAttribute as CFString),
              canRead, let size = AccessibilityHelpers.sizeAttribute(element, kAXSizeAttribute as CFString) else { return nil }
        let rect = CGRect(origin: position, size: size)
        return DockSnapshotGeometryCalculator.isUsable(rect) ? rect : nil
    }

    func findElements(pid: Int32) -> DockSnapshotElements? {
        var pending: [(AXUIElement, Int, AXUIElement?)] = [(AXUIElementCreateApplication(pid), 0, nil)]
        var index = 0
        while index < pending.count, index < 192, canRead {
            let (element, depth, parentList) = pending[index]
            index += 1
            DockAccessibility.prepare(element)
            let role = AccessibilityHelpers.stringAttribute(element, kAXRoleAttribute as CFString)
            let list = role == kAXListRole as String ? element : parentList
            if let list, isFinder(element, role: role) {
                return DockSnapshotElements(list: list, finder: element, windowID: windowID(list))
            }
            guard depth < 7, canRead else { continue }
            for child in children(element, remaining: 192 - pending.count) {
                pending.append((child, depth + 1, list))
            }
        }
        return nil
    }

    private func isFinder(_ element: AXUIElement, role: String?) -> Bool {
        guard canRead else { return false }
        if role != "AXDockItem" {
            guard let subrole = AccessibilityHelpers.stringAttribute(element, kAXSubroleAttribute as CFString),
                  subrole.localizedCaseInsensitiveContains("DockItem"), canRead else { return false }
        }
        if let url = AccessibilityHelpers.urlAttribute(element, "AXURL" as CFString) {
            return url.isFileURL && url.standardizedFileURL.path == "/System/Library/CoreServices/Finder.app"
        }
        guard canRead else { return false }
        return AccessibilityHelpers.stringAttribute(element, kAXTitleAttribute as CFString) == "Finder"
    }

    private func children(_ element: AXUIElement, remaining: Int) -> [AXUIElement] {
        guard remaining > 0, canRead else { return [] }
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success,
              count > 0, canRead else { return [] }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0,
                                              min(count, remaining), &values) == .success else { return [] }
        return values as? [AXUIElement] ?? []
    }

    private func windowID(_ element: AXUIElement) -> CGWindowID? {
        var candidate: AXUIElement? = element
        for _ in 0..<5 {
            guard let current = candidate, canRead else { return nil }
            DockAccessibility.prepare(current)
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(current, &id) == .success, id != 0 { return id }
            guard canRead else { return nil }
            candidate = AccessibilityHelpers.parent(current)
        }
        return nil
    }
}
