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
}

struct WindowDesktop: Hashable {
    let id: UInt64
    let title: String
    let sortOrder: Int
    let isCurrent: Bool
}

enum WindowInventory {
    private static let workQueue = DispatchQueue(label: "prevDock.window-inventory", qos: .userInitiated)
    private static let captureQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "prevDock.window-capture"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 3
        return queue
    }()
    private static let liveCaptureQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "prevDock.window-live-capture"
        queue.qualityOfService = .userInteractive
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private static var previewsByPID = [pid_t: [WindowPreview]]()
    private static var thumbnailsByWindow = [WindowCacheKey: ThumbnailCacheEntry]()
    private static var inFlightRefreshes = Set<pid_t>()
    private static var inFlightCaptures = Set<WindowCaptureRequestKey>()
    private static var refreshCallbacksByPID = [pid_t: [WindowRefreshCallbacks]]()
    // Multiple preview views can ask for the same window image during hover; keep one capture alive.
    private static var captureCompletionsByWindow = [WindowCaptureRequestKey: [(NSImage?) -> Void]]()
    private static let remoteTokenFallbackScanLimit: UInt64 = 1000
    private static let remoteTokenMaximumScanLimit: UInt64 = 20000
    private static let remoteTokenScanPadding: UInt64 = 1000
    private static let thumbnailLiveRefreshMinimumAge: TimeInterval = 1.5
    private static let axFullScreenAttribute = "AXFullScreen" as CFString
    private static var focusRestorationObserver: NSObjectProtocol?
    private static var pendingFocusRestoration: FocusRestoration?

    private struct FocusRestoration {
        let sourceDesktopIDs: Set<UInt64>
        let targetDesktopIDs: Set<UInt64>
        let sourceAppPID: pid_t
        let sourceWindowID: CGWindowID?
        let targetAppPID: pid_t
    }

    static func cachedWindows(for app: NSRunningApplication) -> [WindowPreview] {
        workQueue.sync {
            previewsByPID[app.processIdentifier] ?? []
        }
    }

    static func currentWindows(for app: NSRunningApplication) -> [WindowPreview] {
        workQueue.sync {
            let previews = makePreviews(for: app)
            previewsByPID[app.processIdentifier] = previews
            return previews
        }
    }

    static func refreshWindows(
        for app: NSRunningApplication,
        refreshThumbnails: Bool = false,
        metadata: @escaping ([WindowPreview]) -> Void,
        thumbnail: @escaping (CGWindowID, NSImage) -> Void
    ) {
        let pid = app.processIdentifier
        let callbacks = WindowRefreshCallbacks(
            refreshThumbnails: refreshThumbnails,
            metadata: metadata,
            thumbnail: thumbnail
        )
        let shouldStart = workQueue.sync { () -> Bool in
            refreshCallbacksByPID[pid, default: []].append(callbacks)
            if inFlightRefreshes.contains(pid) { return false }
            inFlightRefreshes.insert(pid)
            return true
        }
        guard shouldStart else { return }

        workQueue.async {
            let previews = makePreviews(for: app)
            pruneThumbnailCache(for: pid, keeping: previews.map(\.windowID))

            previewsByPID[pid] = previews
            let callbacks = refreshCallbacksByPID.removeValue(forKey: pid) ?? []
            let shouldRefreshThumbnails = callbacks.contains { $0.refreshThumbnails }
            inFlightRefreshes.remove(pid)

            DispatchQueue.main.async {
                callbacks.forEach { $0.metadata(previews) }
            }

            DispatchQueue.main.async {
                for preview in previews where shouldRefreshThumbnails || preview.image == nil {
                    let mode = thumbnailCaptureMode(refreshingCachedImage: shouldRefreshThumbnails, preview: preview)
                    captureThumbnail(for: preview, mode: mode) { image in
                        guard let image else { return }
                        DispatchQueue.main.async {
                            callbacks.forEach { $0.thumbnail(preview.windowID, image) }
                        }
                    }
                }
            }
        }
    }

    static func warmPreviewCache(for app: NSRunningApplication) {
        refreshWindows(for: app, refreshThumbnails: true, metadata: { _ in }, thumbnail: { _, _ in })
    }

    private static func makePreviews(for app: NSRunningApplication) -> [WindowPreview] {
        let pid = app.processIdentifier
        let records = axWindows(for: app)
        let descriptions = windowDescriptions(records.map(\.windowID))
        let spaceSnapshot = WindowSpaceSnapshot.current()
        let focusedWindowID = focusedWindowID(for: pid)
        return records
            .filter { record in
                guard let description = descriptions[record.windowID] else { return false }
                return description.ownerPID == pid
            }
            .filter { isDisplayable($0, app: app) }
            .sorted { focusedWindowFirst($0, $1, focusedWindowID: focusedWindowID) }
            .map {
                preview(
                    from: $0,
                    app: app,
                    pid: pid,
                    description: descriptions[$0.windowID],
                    spaceSnapshot: spaceSnapshot,
                    focusedWindowID: focusedWindowID
                )
            }
    }

    private static func preview(
        from record: WindowRecord,
        app: NSRunningApplication,
        pid: pid_t,
        description: WindowDescription?,
        spaceSnapshot: WindowSpaceSnapshot,
        focusedWindowID: CGWindowID?
    ) -> WindowPreview {
        let key = WindowCacheKey(pid: pid, windowID: record.windowID)
        let size = description?.bounds.size ?? record.size ?? .zero
        let position = description?.bounds.origin ?? record.position ?? .zero
        return WindowPreview(
            windowID: record.windowID,
            title: previewTitle(for: record, app: app),
            bounds: CGRect(origin: position, size: size),
            isMinimized: record.isMinimized,
            isFullscreen: record.isFullscreen,
            isFocused: record.windowID == focusedWindowID,
            desktop: spaceSnapshot.desktop(for: record.windowID),
            image: thumbnailsByWindow[key]?.image,
            app: app
        )
    }

    private static func previewTitle(for record: WindowRecord, app: NSRunningApplication) -> String {
        if let title = record.title, !title.isEmpty {
            return title
        }
        return app.localizedName ?? "Window"
    }

    static func refreshThumbnails(
        for app: NSRunningApplication,
        thumbnail: @escaping (CGWindowID, NSImage) -> Void
    ) {
        let pid = app.processIdentifier
        let previews = workQueue.sync {
            previewsByPID[pid] ?? []
        }

        DispatchQueue.main.async {
            for preview in previews {
                captureThumbnail(for: preview, mode: .staleAfter(thumbnailLiveRefreshMinimumAge)) { image in
                    guard let image else { return }
                    DispatchQueue.main.async {
                        thumbnail(preview.windowID, image)
                    }
                }
            }
        }
    }

    static func captureFreshThumbnail(for preview: WindowPreview, completion: @escaping (NSImage?) -> Void) {
        captureThumbnail(for: preview, mode: .fresh, completion: completion)
    }

    static func focusWindow(windowID: CGWindowID, app: NSRunningApplication) {
        guard let window = axWindowElement(windowID: windowID, app: app) else {
            return
        }

        prepareFocusRestoration(targetWindowID: windowID, targetApp: app)
        unminimize(window)
        applySingleWindowFocus(
            to: window,
            windowID: windowID,
            pid: app.processIdentifier
        )
        raiseFocusedWindowIfStillActive(windowID: windowID, app: app)
    }

    private static func raiseFocusedWindowIfStillActive(
        windowID: CGWindowID,
        app: NSRunningApplication
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard app.isActive,
                  let window = axWindowElement(windowID: windowID, app: app) else {
                return
            }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }

    static func closeWindow(
        windowID: CGWindowID,
        app: NSRunningApplication,
        isFullscreen: Bool = false,
        completion: @escaping (Bool) -> Void
    ) {
        guard let window = axWindowElement(windowID: windowID, app: app) else {
            completion(false)
            return
        }

        if isFullscreen {
            AXUIElementSetAttributeValue(window, axFullScreenAttribute, kCFBooleanFalse)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                closePreparedWindow(windowID: windowID, app: app, completion: completion)
            }
            return
        }

        closePreparedWindow(windowID: windowID, app: app, completion: completion)
    }

    private static func closePreparedWindow(
        windowID: CGWindowID,
        app: NSRunningApplication,
        completion: @escaping (Bool) -> Void
    ) {
        guard let window = axWindowElement(windowID: windowID, app: app) else {
            completion(false)
            return
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        activate(app)
        applyFocus(to: window, appElement: appElement)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let requestedClose = requestClose(for: window)
            verifyClosed(windowID: windowID, app: app, requestedClose: requestedClose, completion: completion)
        }
    }

    private static func requestClose(for window: AXUIElement) -> Bool {
        if let closeButton = axElementAttribute(window, kAXCloseButtonAttribute as CFString) {
            let result = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
            if result == .success { return true }
        }

        return AXUIElementPerformAction(window, "AXClose" as CFString) == .success
    }

    private static func applyFocus(to window: AXUIElement, appElement: AXUIElement) {
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    private static func unminimize(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }

    private static func applySingleWindowFocus(
        to window: AXUIElement,
        windowID: CGWindowID,
        pid: pid_t
    ) {
        SkyLightCapture.focusWindow(windowID: windowID, pid: pid)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    private static func prepareFocusRestoration(targetWindowID: CGWindowID, targetApp: NSRunningApplication) {
        guard let restoration = focusRestoration(targetWindowID: targetWindowID, targetApp: targetApp) else {
            pendingFocusRestoration = nil
            return
        }
        pendingFocusRestoration = restoration
        installFocusRestorationObserver()
    }

    private static func focusRestoration(
        targetWindowID: CGWindowID,
        targetApp: NSRunningApplication
    ) -> FocusRestoration? {
        guard let sourceApp = NSWorkspace.shared.frontmostApplication,
              sourceApp.processIdentifier != targetApp.processIdentifier else {
            return nil
        }
        let sourceDesktopIDs = SkyLightCapture.currentDesktopIDs()
        let targetDesktopIDs = Set(SkyLightCapture.spaceIDs(windowID: targetWindowID))
        guard !sourceDesktopIDs.isEmpty,
              !targetDesktopIDs.isEmpty,
              targetDesktopIDs.isDisjoint(with: sourceDesktopIDs) else {
            return nil
        }
        return FocusRestoration(
            sourceDesktopIDs: sourceDesktopIDs,
            targetDesktopIDs: targetDesktopIDs,
            sourceAppPID: sourceApp.processIdentifier,
            sourceWindowID: focusedWindowID(for: sourceApp.processIdentifier),
            targetAppPID: targetApp.processIdentifier
        )
    }

    private static func installFocusRestorationObserver() {
        guard focusRestorationObserver == nil else { return }
        focusRestorationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            restoreFocusAfterSpaceChange()
        }
    }

    private static func restoreFocusAfterSpaceChange() {
        guard let restoration = pendingFocusRestoration else { return }
        let currentDesktopIDs = SkyLightCapture.currentDesktopIDs()
        guard currentDesktopIDs.isDisjoint(with: restoration.targetDesktopIDs),
              !currentDesktopIDs.isDisjoint(with: restoration.sourceDesktopIDs) else {
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == restoration.targetAppPID else {
            pendingFocusRestoration = nil
            return
        }
        pendingFocusRestoration = nil
        restoreFocus(restoration)
    }

    private static func restoreFocus(_ restoration: FocusRestoration) {
        guard let app = NSRunningApplication(processIdentifier: restoration.sourceAppPID) else { return }
        guard let windowID = restoration.sourceWindowID,
              let window = axWindowElement(windowID: windowID, app: app) else {
            activate(app)
            return
        }
        applySingleWindowFocus(to: window, windowID: windowID, pid: restoration.sourceAppPID)
        raiseFocusedWindowIfStillActive(windowID: windowID, app: app)
    }

    @discardableResult
    private static func activate(_ app: NSRunningApplication) -> Bool {
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: app)
            return app.activate(from: NSRunningApplication.current, options: [])
        }
        return app.activate(options: [])
    }

    private static func verifyClosed(
        windowID: CGWindowID,
        app: NSRunningApplication,
        requestedClose: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard requestedClose, !isWindowOpen(windowID: windowID, app: app) else {
                completion(false)
                return
            }

            markClosed(windowID: windowID, app: app)
            completion(true)
        }
    }

    private static func isWindowOpen(windowID: CGWindowID, app: NSRunningApplication) -> Bool {
        axWindowElement(windowID: windowID, app: app) != nil
    }

    private static func markClosed(windowID: CGWindowID, app: NSRunningApplication) {
        let pid = app.processIdentifier
        let key = WindowCacheKey(pid: pid, windowID: windowID)
        workQueue.async {
            previewsByPID[pid]?.removeAll { $0.windowID == windowID }
            thumbnailsByWindow.removeValue(forKey: key)
        }
    }

    private static func pruneThumbnailCache(for pid: pid_t, keeping windowIDs: [CGWindowID]) {
        let validKeys = Set(windowIDs.map { WindowCacheKey(pid: pid, windowID: $0) })
        thumbnailsByWindow.keys
            .filter { $0.pid == pid && !validKeys.contains($0) }
            .forEach { thumbnailsByWindow.removeValue(forKey: $0) }
    }

    private static func thumbnailCaptureMode(
        refreshingCachedImage: Bool,
        preview: WindowPreview
    ) -> ThumbnailCaptureMode {
        guard refreshingCachedImage, preview.image != nil else { return .missingOnly }
        return .staleAfter(thumbnailLiveRefreshMinimumAge)
    }

    private static func cachedThumbnail(for key: WindowCacheKey, mode: ThumbnailCaptureMode) -> NSImage? {
        guard let entry = thumbnailsByWindow[key] else { return nil }
        switch mode {
        case .missingOnly:
            return entry.image
        case .staleAfter(let minimumAge):
            return Date().timeIntervalSince(entry.capturedAt) < minimumAge ? entry.image : nil
        case .fresh:
            return nil
        }
    }

    private static func replaceCachedImage(_ image: NSImage, for key: WindowCacheKey) {
        for pid in previewsByPID.keys {
            previewsByPID[pid] = previewsByPID[pid]?.map { preview in
                guard WindowCacheKey(pid: preview.app.processIdentifier, windowID: preview.windowID) == key else {
                    return preview
                }
                return WindowPreview(
                    windowID: preview.windowID,
                    title: preview.title,
                    bounds: preview.bounds,
                    isMinimized: preview.isMinimized,
                    isFullscreen: preview.isFullscreen,
                    isFocused: preview.isFocused,
                    desktop: preview.desktop,
                    image: image,
                    app: preview.app
                )
            }
        }
    }

    private static func captureThumbnail(
        for preview: WindowPreview,
        mode: ThumbnailCaptureMode = .missingOnly,
        completion: @escaping (NSImage?) -> Void
    ) {
        let key = WindowCacheKey(pid: preview.app.processIdentifier, windowID: preview.windowID)
        let action = workQueue.sync { () -> ThumbnailCaptureAction in
            let priority = mode.capturePriority
            if let cachedImage = cachedThumbnail(for: key, mode: mode) {
                return mode.deliversCachedHit ? .complete(cachedImage) : .skip
            }
            if let request = queuedCaptureRequest(for: key, priority: priority) {
                captureCompletionsByWindow[request, default: []].append(completion)
                return .skip
            }
            let request = WindowCaptureRequestKey(cacheKey: key, priority: priority)
            inFlightCaptures.insert(request)
            captureCompletionsByWindow[request] = [completion]
            return .start(request)
        }

        switch action {
        case .complete(let image):
            completion(image)
        case .skip:
            return
        case .start(let request):
            queue(for: request.priority).addOperation {
                capture(windowID: preview.windowID) { image in
                    workQueue.async {
                        let stableImage: NSImage?
                        if let image, image.hasUsableWindowAlpha {
                            thumbnailsByWindow[key] = ThumbnailCacheEntry(image: image, capturedAt: Date())
                            stableImage = image
                            replaceCachedImage(image, for: key)
                        } else {
                            stableImage = thumbnailsByWindow[key]?.image
                        }
                        inFlightCaptures.remove(request)
                        let completions = captureCompletionsByWindow.removeValue(forKey: request) ?? []
                        completions.forEach { $0(stableImage) }
                    }
                }
            }
        }
    }

    private static func queuedCaptureRequest(
        for key: WindowCacheKey,
        priority: ThumbnailCapturePriority
    ) -> WindowCaptureRequestKey? {
        let liveRequest = WindowCaptureRequestKey(cacheKey: key, priority: .live)
        if inFlightCaptures.contains(liveRequest) { return liveRequest }
        guard priority == .background else { return nil }
        let backgroundRequest = WindowCaptureRequestKey(cacheKey: key, priority: .background)
        return inFlightCaptures.contains(backgroundRequest) ? backgroundRequest : nil
    }

    private static func queue(for priority: ThumbnailCapturePriority) -> OperationQueue {
        switch priority {
        case .background:
            return captureQueue
        case .live:
            return liveCaptureQueue
        }
    }

    private static func capture(windowID: CGWindowID, completion: @escaping (NSImage?) -> Void) {
        completion(captureWithSkyLight(windowID: windowID))
    }

    private static func captureWithSkyLight(windowID: CGWindowID) -> NSImage? {
        guard let cgImage = SkyLightCapture.capture(windowID: windowID) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func axWindows(for app: NSRunningApplication) -> [WindowRecord] {
        let windows = axWindowElements(for: app.processIdentifier)
        var records = [WindowRecord]()

        for window in windows {
            guard let id = windowID(for: window) else { continue }
            let title = AccessibilityHelpers.stringAttribute(window, kAXTitleAttribute as CFString)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let role = AccessibilityHelpers.stringAttribute(window, kAXRoleAttribute as CFString)
            let subrole = AccessibilityHelpers.stringAttribute(window, kAXSubroleAttribute as CFString)
            records.append(WindowRecord(
                windowID: id,
                title: title,
                role: role,
                subrole: subrole,
                position: AccessibilityHelpers.pointAttribute(window, kAXPositionAttribute as CFString),
                size: AccessibilityHelpers.sizeAttribute(window, kAXSizeAttribute as CFString),
                isMinimized: AccessibilityHelpers.boolAttribute(window, kAXMinimizedAttribute as CFString) ?? false,
                isFullscreen: AccessibilityHelpers.boolAttribute(window, axFullScreenAttribute) ?? false,
                level: SkyLightCapture.level(windowID: id)
            ))
        }

        return unique(records)
    }

    private static func axWindowElement(windowID: CGWindowID, app: NSRunningApplication) -> AXUIElement? {
        axWindowElements(for: app.processIdentifier).first { window in
            self.windowID(for: window) == windowID
        }
    }

    private static func axElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func axWindowElements(for pid: pid_t) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(pid)
        let axWindows = AccessibilityHelpers.elementArrayAttribute(appElement, kAXWindowsAttribute as CFString)
        let knownWindowIDs = Set(axWindows.compactMap(windowID))
        return axWindows + windowsByBruteForce(pid: pid, knownWindowIDs: knownWindowIDs)
    }

    private static func windowsByBruteForce(pid: pid_t, knownWindowIDs: Set<CGWindowID>) -> [AXUIElement] {
        let targetWindowIDs = bruteForceTargetWindowIDs(pid: pid)
        var missingWindowIDs = targetWindowIDs.subtracting(knownWindowIDs)
        if !targetWindowIDs.isEmpty && missingWindowIDs.isEmpty { return [] }
        var remoteToken = Data(count: 20)
        remoteToken.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        remoteToken.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        remoteToken.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })

        let scanLimit = remoteTokenScanLimit(targetWindowIDs: targetWindowIDs)
        let deadline = Date().addingTimeInterval(targetWindowIDs.isEmpty ? 0.10 : 0.35)
        var windows = [AXUIElement]()
        for axElementID in UInt64(0)..<scanLimit {
            guard Date() < deadline else { break }
            remoteToken.replaceSubrange(12..<20, with: withUnsafeBytes(of: axElementID) { Data($0) })
            guard let element = _AXUIElementCreateWithRemoteToken(remoteToken as CFData)?.takeRetainedValue() else {
                continue
            }
            guard isAXWindowElement(element) else { continue }
            windows.append(element)
            if let windowID = windowID(for: element) {
                missingWindowIDs.remove(windowID)
            }
            if !targetWindowIDs.isEmpty && missingWindowIDs.isEmpty { break }
        }
        return windows
    }

    private static func bruteForceTargetWindowIDs(pid: pid_t) -> Set<CGWindowID> {
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(windows.compactMap { description in
            guard isBruteForceTargetWindow(description, pid: pid) else { return nil }
            return description[kCGWindowNumber as String] as? CGWindowID
        })
    }

    private static func isBruteForceTargetWindow(_ description: [String: Any], pid: pid_t) -> Bool {
        guard description[kCGWindowOwnerPID as String] as? pid_t == pid,
              (description[kCGWindowName as String] as? String)?.isEmpty == false,
              (description[kCGWindowLayer as String] as? Int ?? 0) <= CGWindowLevelForKey(.floatingWindow) else {
            return false
        }
        let bounds = (description[kCGWindowBounds as String] as? NSDictionary)
            .flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
        return bounds.width >= 80 && bounds.height >= 60
    }

    private static func remoteTokenScanLimit(targetWindowIDs: Set<CGWindowID>) -> UInt64 {
        guard let maxWindowID = targetWindowIDs.max() else { return remoteTokenFallbackScanLimit }
        let paddedLimit = UInt64(maxWindowID) + remoteTokenScanPadding
        return min(max(remoteTokenFallbackScanLimit, paddedLimit), remoteTokenMaximumScanLimit)
    }

    private static func isAXWindowElement(_ element: AXUIElement) -> Bool {
        let subrole = AccessibilityHelpers.stringAttribute(element, kAXSubroleAttribute as CFString)
        return [
            kAXStandardWindowSubrole as String,
            kAXDialogSubrole as String,
            kAXFloatingWindowSubrole as String
        ].contains(subrole ?? "")
    }

    private static func windowID(for element: AXUIElement) -> CGWindowID? {
        var id = CGWindowID(0)
        guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    private static func focusedWindowID(for pid: pid_t) -> CGWindowID? {
        let appElement = AXUIElementCreateApplication(pid)
        guard let focusedWindow = axElementAttribute(appElement, kAXFocusedWindowAttribute as CFString) else {
            return nil
        }
        return windowID(for: focusedWindow)
    }

    private static func unique(_ records: [WindowRecord]) -> [WindowRecord] {
        var seen = Set<CGWindowID>()
        return records.filter { record in
            if seen.contains(record.windowID) { return false }
            seen.insert(record.windowID)
            return true
        }
    }

    private static func windowDescriptions(_ ids: [CGWindowID]) -> [CGWindowID: WindowDescription] {
        guard !ids.isEmpty else { return [:] }
        let rawIds: CFArray = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }.withUnsafeBufferPointer {
            CFArrayCreate(nil, UnsafeMutablePointer(mutating: $0.baseAddress), $0.count, nil)
        }
        guard let descriptions = CGWindowListCreateDescriptionFromArray(rawIds) as? [[CFString: Any]] else {
            return [:]
        }
        return descriptions.reduce(into: [CGWindowID: WindowDescription]()) { result, description in
            guard let windowID = description[kCGWindowNumber] as? CGWindowID,
                  let ownerPID = description[kCGWindowOwnerPID] as? pid_t else { return }
            let bounds = (description[kCGWindowBounds] as? NSDictionary)
                .flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
            result[windowID] = WindowDescription(ownerPID: ownerPID, bounds: bounds)
        }
    }

    private static func isDisplayable(_ record: WindowRecord, app: NSRunningApplication) -> Bool {
        guard record.role == kAXWindowRole as String else { return false }
        let size = record.size ?? .zero
        guard size.width >= 80 &&
            size.height >= 60 &&
            record.level <= CGWindowLevelForKey(.floatingWindow) else {
            return false
        }

        return isStandardWindowSubrole(record.subrole) ||
            isAppSpecificDisplayableWindow(record, app: app, size: size)
    }

    private static func isStandardWindowSubrole(_ subrole: String?) -> Bool {
        [
            kAXStandardWindowSubrole as String,
            kAXDialogSubrole as String,
            kAXFloatingWindowSubrole as String
        ].contains(subrole ?? "")
    }

    private static func isAppSpecificDisplayableWindow(
        _ record: WindowRecord,
        app: NSRunningApplication,
        size: CGSize
    ) -> Bool {
        guard record.subrole == kAXUnknownSubrole as String else { return false }
        let bundleID = app.bundleIdentifier ?? ""
        if bundleID.hasPrefix("org.mozilla.firefox") {
            return size.height > 400
        }
        if bundleID.hasPrefix("org.videolan.vlc") {
            return true
        }
        return false
    }

    private static func oldestWindowFirst(_ lhs: WindowRecord, _ rhs: WindowRecord) -> Bool {
        lhs.windowID < rhs.windowID
    }

    private static func focusedWindowFirst(_ lhs: WindowRecord, _ rhs: WindowRecord, focusedWindowID: CGWindowID?) -> Bool {
        if let focusedWindowID {
            let lhsFocused = lhs.windowID == focusedWindowID
            let rhsFocused = rhs.windowID == focusedWindowID
            if lhsFocused != rhsFocused { return lhsFocused }
        }
        return oldestWindowFirst(lhs, rhs)
    }
}

private struct WindowCacheKey: Hashable {
    let pid: pid_t
    let windowID: CGWindowID
}

private struct WindowCaptureRequestKey: Hashable {
    let cacheKey: WindowCacheKey
    let priority: ThumbnailCapturePriority
}

private struct ThumbnailCacheEntry {
    let image: NSImage
    let capturedAt: Date
}

private enum ThumbnailCapturePriority: Hashable {
    case background
    case live
}

private enum ThumbnailCaptureMode {
    case missingOnly
    case staleAfter(TimeInterval)
    case fresh

    var deliversCachedHit: Bool {
        if case .missingOnly = self { return true }
        return false
    }

    var capturePriority: ThumbnailCapturePriority {
        if case .fresh = self { return .live }
        return .background
    }
}

private enum ThumbnailCaptureAction {
    case complete(NSImage)
    case skip
    case start(WindowCaptureRequestKey)
}

private struct WindowRefreshCallbacks {
    let refreshThumbnails: Bool
    let metadata: ([WindowPreview]) -> Void
    let thumbnail: (CGWindowID, NSImage) -> Void
}

private struct WindowDescription {
    let ownerPID: pid_t
    let bounds: CGRect
}

private struct WindowSpaceSnapshot {
    private let desktopsByID: [UInt64: WindowDesktop]

    static func current() -> WindowSpaceSnapshot {
        guard PrevDockSettings.previewDesktopGroupingEnabled else {
            return WindowSpaceSnapshot(desktops: [])
        }
        return WindowSpaceSnapshot(desktops: SkyLightCapture.managedDesktopSpaces())
    }

    init(desktops: [WindowDesktop]) {
        desktopsByID = Dictionary(uniqueKeysWithValues: desktops.map { ($0.id, $0) })
    }

    func desktop(for windowID: CGWindowID) -> WindowDesktop? {
        guard !desktopsByID.isEmpty else { return nil }
        let desktops = SkyLightCapture.spaceIDs(windowID: windowID).compactMap { desktopsByID[$0] }
        return desktops.first(where: \.isCurrent) ?? desktops.min { $0.sortOrder < $1.sortOrder }
    }
}

private extension NSImage {
    var hasUsableWindowAlpha: Bool {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return true }
        let width = 12
        let height = 12
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var alphaTotal = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let a = pixels[index + 3]
            alphaTotal += Int(a)
        }
        return alphaTotal >= width * height * 8
    }
}

private struct WindowRecord {
    let windowID: CGWindowID
    let title: String?
    let role: String?
    let subrole: String?
    let position: CGPoint?
    let size: CGSize?
    let isMinimized: Bool
    let isFullscreen: Bool
    let level: CGWindowLevel
}
