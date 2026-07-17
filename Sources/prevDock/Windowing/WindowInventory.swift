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

enum WindowInventory {
    private static let workQueue = DispatchQueue(label: "prevDock.window-inventory", qos: .userInitiated)
    private static let actionQueue = DispatchQueue(label: "prevDock.window-actions", qos: .userInteractive)
    private static let cachedPreviewsLock = NSLock()
    private static let remoteWindowElementResolver = RemoteWindowElementResolver()
    private static let refreshCoordinator = WindowRefreshCoordinator<pid_t, WindowRefreshCallbacks>()
    private static let captureQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "prevDock.window-capture"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = WindowThumbnailCapturePlan.maximumConcurrentCaptureCount
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
    private static var cachedPreviewsSnapshotByPID = [pid_t: [WindowPreview]]()
    private static var cachedMetadataRefreshedAtByPID = [pid_t: Date]()
    private static var cacheAccessByPID = [pid_t: Date]()
    private static var thumbnailsByWindow = [WindowCacheKey: ThumbnailCacheEntry]()
    private static var inFlightCaptures = Set<WindowCaptureRequestKey>()
    // Multiple preview views can ask for the same window image during hover; keep one capture alive.
    private static var captureCompletionsByWindow = [WindowCaptureRequestKey: [(FreshThumbnailCaptureResult) -> Void]]()
    private static var captureOperationsByRequest = [WindowCaptureRequestKey: Operation]()
    private static var backgroundThumbnailTargetPID: pid_t?
    private static var captureInvalidationGenerationByWindow = [WindowCacheKey: UInt64]()
    private static var latestCaptureSequenceByWindow = [WindowCacheKey: UInt64]()
    private static var thumbnailFailureBackoff = WindowThumbnailFailureBackoff<
        WindowCacheKey,
        WindowCaptureSignature
    >()
    private static var nextCaptureSequence: UInt64 = 0
    private static let thumbnailLiveRefreshMinimumAge: TimeInterval = 1.5
    private static let maximumCachedThumbnailPixelDimension = 1200
    private static let maximumCachedApplications = 8
    private static let axFullScreenAttribute = "AXFullScreen" as CFString
    private static var focusRestorationObserver: NSObjectProtocol?
    private static var pendingFocusRestoration: FocusRestoration?
    private static var focusRestorationGeneration = 0
    private static let applicationTerminationObserver: NSObjectProtocol = {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            remoteWindowElementResolver.removeAll(for: app.processIdentifier)
            workQueue.async {
                purgeCachedApplication(pid: app.processIdentifier)
            }
        }
    }()

    private struct FocusRestoration {
        let sourceDesktopIDs: Set<UInt64>
        let targetDesktopIDs: Set<UInt64>
        let sourceAppPID: pid_t
        let sourceWindowID: CGWindowID?
        let targetAppPID: pid_t
    }

    static func cachedWindows(for app: NSRunningApplication) -> [WindowPreview] {
        cachedWindows(for: app, refreshedWithin: nil) ?? []
    }

    static func cachedWindows(
        for app: NSRunningApplication,
        refreshedWithin maximumAge: TimeInterval
    ) -> [WindowPreview]? {
        cachedWindows(for: app, refreshedWithin: Optional(maximumAge))
    }

    private static func cachedWindows(
        for app: NSRunningApplication,
        refreshedWithin maximumAge: TimeInterval?
    ) -> [WindowPreview]? {
        ensureApplicationTerminationObservation()
        cachedPreviewsLock.lock()
        let previews = cachedPreviewsSnapshotByPID[app.processIdentifier] ?? []
        let refreshedAt = cachedMetadataRefreshedAtByPID[app.processIdentifier]
        cacheAccessByPID[app.processIdentifier] = Date()
        cachedPreviewsLock.unlock()
        if let maximumAge {
            guard let refreshedAt,
                  Date().timeIntervalSince(refreshedAt) <= maximumAge else {
                return nil
            }
        }
        guard PermissionManager.status.screenRecordingGranted else {
            return previews.map { $0.replacingImage(with: nil) }
        }
        return previews
    }

    static func discardCachedThumbnails() {
        cachedPreviewsLock.lock()
        cachedPreviewsSnapshotByPID = cachedPreviewsSnapshotByPID.mapValues { previews in
            previews.map { $0.replacingImage(with: nil) }
        }
        cachedPreviewsLock.unlock()

        workQueue.async {
            let keys = Set(thumbnailsByWindow.keys)
                .union(inFlightCaptures.map(\.cacheKey))
            thumbnailsByWindow.removeAll()
            thumbnailFailureBackoff.removeAll()
            keys.forEach(invalidateCapture)
            previewsByPID = previewsByPID.mapValues { previews in
                previews.map { $0.replacingImage(with: nil) }
            }
            previewsByPID.forEach { pid, previews in
                publishCachedPreviews(previews, for: pid)
            }
        }
    }

    @discardableResult
    static func refreshWindows(
        for app: NSRunningApplication,
        thumbnailPolicy: WindowThumbnailRefreshPolicy = .none,
        metadata: @escaping ([WindowPreview]) -> Void,
        thumbnail: @escaping (CGWindowID, NSImage) -> Void
    ) -> WindowRefreshRequest {
        ensureApplicationTerminationObservation()
        let pid = app.processIdentifier
        let callbacks = WindowRefreshCallbacks(
            thumbnailPolicy: thumbnailPolicy,
            metadata: metadata,
            thumbnail: thumbnail
        )
        let registration = refreshCoordinator.register(key: pid, payload: callbacks)
        if let generation = registration.generationToStart {
            workQueue.async {
                performWindowRefresh(for: app, pid: pid, generation: generation)
            }
        }
        return registration.request
    }

    private static func performWindowRefresh(
        for app: NSRunningApplication,
        pid: pid_t,
        generation: WindowRefreshGeneration<pid_t>
    ) {
        guard refreshCoordinator.begin(generation) else { return }
        let shouldContinue = { refreshCoordinator.shouldContinue(generation) }
        guard let refresh = makePreviews(for: app, shouldContinue: shouldContinue),
              shouldContinue() else {
            _ = refreshCoordinator.complete(generation)
            return
        }
        let callbacks = refreshCoordinator.complete(generation)
        guard !callbacks.isEmpty else { return }
        guard !app.isTerminated else {
            remoteWindowElementResolver.removeAll(for: pid)
            purgeCachedApplication(pid: pid)
            DispatchQueue.main.async {
                callbacks.forEach { $0.metadata([]) }
            }
            return
        }
        let previews = refresh.previews
        remoteWindowElementResolver.commit(refresh.remoteResolution)
        pruneThumbnailCache(for: pid, keeping: previews.map(\.windowID))

        previewsByPID[pid] = previews
        publishCachedPreviews(previews, for: pid, metadataRefreshed: true)
        pruneApplicationCachesIfNeeded(keeping: pid)
        let thumbnailPolicy = callbacks
            .map(\.thumbnailPolicy)
            .max(by: { $0.rawValue < $1.rawValue }) ?? .none
        let candidates = thumbnailRefreshPlan(from: previews, policy: thumbnailPolicy).candidates

        DispatchQueue.main.async {
            guard !app.isTerminated else {
                callbacks.forEach { $0.metadata([]) }
                return
            }
            let deliverablePreviews = refresh.screenRecordingGranted ?
                previews : previews.map { $0.replacingImage(with: nil) }
            callbacks.forEach { $0.metadata(deliverablePreviews) }
            startThumbnailCaptures(candidates) { windowID, result in
                guard let image = result.image else { return }
                callbacks.forEach { $0.thumbnail(windowID, image) }
            }
        }
    }

    @discardableResult
    static func warmPreviewCache(
        for app: NSRunningApplication,
        metadata: @escaping ([WindowPreview]) -> Void = { _ in }
    ) -> WindowRefreshRequest {
        refreshWindows(for: app, thumbnailPolicy: .none, metadata: metadata, thumbnail: { _, _ in })
    }

    private static func makePreviews(
        for app: NSRunningApplication,
        shouldContinue: () -> Bool
    ) -> WindowPreviewRefreshResult? {
        let pid = app.processIdentifier
        guard let windowResult = axWindows(for: app, shouldContinue: shouldContinue),
              shouldContinue() else {
            return nil
        }
        let records = windowResult.records
        let descriptions = windowDescriptions(records.map(\.windowID))
        guard shouldContinue() else { return nil }
        let spaceSnapshot = WindowSpaceSnapshot.current()
        let focusedWindowID = focusedWindowID(for: pid)
        guard shouldContinue() else { return nil }
        let screenRecordingGranted = PermissionManager.status.screenRecordingGranted
        guard shouldContinue() else { return nil }
        let previews = records
            .filter { record in
                guard let description = descriptions[record.windowID] else { return true }
                return description.ownerPID == pid
            }
            .filter { isDisplayable($0, description: descriptions[$0.windowID], app: app) }
            .sorted { focusedWindowFirst($0, $1, focusedWindowID: focusedWindowID) }
            .map {
                preview(
                    from: $0,
                    app: app,
                    pid: pid,
                    description: descriptions[$0.windowID],
                    spaceSnapshot: spaceSnapshot,
                    focusedWindowID: focusedWindowID,
                    screenRecordingGranted: screenRecordingGranted
                )
            }
        guard shouldContinue() else { return nil }
        return WindowPreviewRefreshResult(
            previews: previews,
            remoteResolution: windowResult.remoteResolution,
            screenRecordingGranted: screenRecordingGranted
        )
    }

    private static func preview(
        from record: WindowRecord,
        app: NSRunningApplication,
        pid: pid_t,
        description: WindowDescription?,
        spaceSnapshot: WindowSpaceSnapshot,
        focusedWindowID: CGWindowID?,
        screenRecordingGranted: Bool
    ) -> WindowPreview {
        let key = WindowCacheKey(pid: pid, windowID: record.windowID)
        let size = description?.bounds?.size ?? record.size ?? .zero
        let position = description?.bounds?.origin ?? record.position ?? .zero
        let bounds = CGRect(origin: position, size: size)
        let geometry = WindowCaptureGeometry(bounds)
        let cachedImage = thumbnailsByWindow[key].flatMap { entry in
            entry.geometry == geometry ? entry.image : nil
        }
        return WindowPreview(
            windowID: record.windowID,
            title: previewTitle(for: record, app: app),
            bounds: bounds,
            isMinimized: record.isMinimized,
            isFullscreen: record.isFullscreen,
            isFocused: record.windowID == focusedWindowID,
            desktop: spaceSnapshot.desktop(for: record.windowID),
            image: screenRecordingGranted ? cachedImage : nil,
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
        maximumStaleCount: Int = 2,
        completion: @escaping (CGWindowID, FreshThumbnailCaptureResult) -> Void
    ) {
        let pid = app.processIdentifier
        workQueue.async {
            guard backgroundThumbnailTargetPID == pid else { return }
            let previews = previewsByPID[pid] ?? []
            guard PermissionManager.status.screenRecordingGranted else {
                DispatchQueue.main.async {
                    previews.forEach { completion($0.windowID, .unavailable) }
                }
                return
            }
            let refreshPlan = thumbnailRefreshPlan(
                from: previews,
                policy: .refreshStale
            )
            let orderedCandidates = refreshPlan.candidates
                .sorted(by: oldestCaptureFirst)
            let candidates = WindowThumbnailCapturePlan.select(
                from: orderedCandidates,
                maximumStaleCount: maximumStaleCount,
                isMissing: { $0.mode.isMissing }
            )
            DispatchQueue.main.async {
                refreshPlan.unavailableWindowIDs.forEach { completion($0, .unavailable) }
                startThumbnailCaptures(
                    candidates,
                    requiredBackgroundTargetPID: pid,
                    completion: completion
                )
            }
        }
    }

    static func setBackgroundThumbnailTarget(pid: pid_t?) {
        workQueue.async {
            backgroundThumbnailTargetPID = pid
            cancelBackgroundThumbnailCaptures(except: pid)
        }
    }

    static func resetThumbnailFailuresForSpaceChange() {
        workQueue.async {
            thumbnailFailureBackoff.removeAll()
        }
    }

    static func captureFreshThumbnail(
        for preview: WindowPreview,
        completion: @escaping (FreshThumbnailCaptureResult) -> Void
    ) {
        captureThumbnail(for: preview, mode: .fresh, completion: completion)
    }

    static func focusWindow(
        windowID: CGWindowID,
        app: NSRunningApplication,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        actionQueue.async {
            guard !app.isTerminated,
                  let window = axWindowElement(windowID: windowID, app: app) else {
                completeWindowAction(false, completion: completion)
                return
            }

            DispatchQueue.main.async {
                guard !app.isTerminated else {
                    completion(false)
                    return
                }
                prepareFocusRestoration(targetWindowID: windowID, targetApp: app)
                unminimize(window)
                let focused = applySingleWindowFocus(
                    to: window,
                    windowID: windowID,
                    app: app
                )
                if focused {
                    raiseFocusedWindowIfStillActive(window, windowID: windowID, app: app)
                }
                verifyFocusedWindow(
                    windowID: windowID,
                    app: app,
                    requestedFocus: focused,
                    observedFocusedWindow: false,
                    attempt: 0,
                    completion: completion
                )
            }
        }
    }

    private static func verifyFocusedWindow(
        windowID: CGWindowID,
        app: NSRunningApplication,
        requestedFocus: Bool,
        observedFocusedWindow: Bool,
        attempt: Int,
        completion: @escaping (Bool) -> Void
    ) {
        actionQueue.asyncAfter(deadline: .now() + 0.1) {
            guard !app.isTerminated else {
                completeWindowAction(false, completion: completion)
                return
            }
            let focusedID = focusedWindowID(for: app.processIdentifier)
            if focusedID == windowID, app.isActive {
                completeWindowAction(true, completion: completion)
                return
            }
            let observedFocusedWindow = observedFocusedWindow || focusedID != nil
            guard attempt < 15 else {
                let succeededWithoutAXVerification = requestedFocus &&
                    app.isActive &&
                    !observedFocusedWindow
                completeWindowAction(succeededWithoutAXVerification, completion: completion)
                return
            }
            verifyFocusedWindow(
                windowID: windowID,
                app: app,
                requestedFocus: requestedFocus,
                observedFocusedWindow: observedFocusedWindow,
                attempt: attempt + 1,
                completion: completion
            )
        }
    }

    private static func raiseFocusedWindowIfStillActive(
        _ window: AXUIElement,
        windowID: CGWindowID,
        app: NSRunningApplication
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard app.isActive,
                  focusedWindowID(for: app.processIdentifier) == windowID else {
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
        actionQueue.async {
            guard let window = axWindowElement(windowID: windowID, app: app) else {
                completeWindowAction(false, completion: completion)
                return
            }

            if isFullscreen,
               AXUIElementSetAttributeValue(window, axFullScreenAttribute, kCFBooleanFalse) == .success {
                closeAfterFullscreenExit(
                    window,
                    windowID: windowID,
                    app: app,
                    attempt: 0,
                    completion: completion
                )
                return
            }
            requestCloseAndVerify(window, windowID: windowID, app: app, completion: completion)
        }
    }

    private static func closeAfterFullscreenExit(
        _ window: AXUIElement,
        windowID: CGWindowID,
        app: NSRunningApplication,
        attempt: Int,
        completion: @escaping (Bool) -> Void
    ) {
        let isStillFullscreen = AccessibilityHelpers.boolAttribute(window, axFullScreenAttribute) == true
        guard isStillFullscreen, attempt < 12 else {
            requestCloseAndVerify(window, windowID: windowID, app: app, completion: completion)
            return
        }
        actionQueue.asyncAfter(deadline: .now() + 0.15) {
            closeAfterFullscreenExit(
                window,
                windowID: windowID,
                app: app,
                attempt: attempt + 1,
                completion: completion
            )
        }
    }

    private static func requestCloseAndVerify(
        _ window: AXUIElement,
        windowID: CGWindowID,
        app: NSRunningApplication,
        completion: @escaping (Bool) -> Void
    ) {
        requestCloseWithRetry(
            window,
            windowID: windowID,
            app: app,
            attempt: 0,
            completion: completion
        )
    }

    private static func requestCloseWithRetry(
        _ window: AXUIElement,
        windowID: CGWindowID,
        app: NSRunningApplication,
        attempt: Int,
        completion: @escaping (Bool) -> Void
    ) {
        let didRequestClose = requestClose(for: window)
        guard !didRequestClose, attempt < 2 else {
            verifyClosed(
                window,
                windowID: windowID,
                app: app,
                closedObservationCount: 0,
                attempt: 0,
                completion: completion
            )
            return
        }
        actionQueue.asyncAfter(deadline: .now() + 0.1) {
            requestCloseWithRetry(
                window,
                windowID: windowID,
                app: app,
                attempt: attempt + 1,
                completion: completion
            )
        }
    }

    private static func requestClose(for window: AXUIElement) -> Bool {
        if let closeButton = axElementAttribute(window, kAXCloseButtonAttribute as CFString) {
            let result = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
            if result == .success { return true }
        }

        return AXUIElementPerformAction(window, "AXClose" as CFString) == .success
    }

    private static func applyFocus(to window: AXUIElement, appElement: AXUIElement) -> Bool {
        let frontmost = AXUIElementSetAttributeValue(
            appElement,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        let focusedWindow = AXUIElementSetAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            window
        )
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        return frontmost == .success || focusedWindow == .success || raised == .success
    }

    private static func unminimize(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }

    private static func applySingleWindowFocus(
        to window: AXUIElement,
        windowID: CGWindowID,
        app: NSRunningApplication
    ) -> Bool {
        if SkyLightCapture.focusWindow(windowID: windowID, pid: app.processIdentifier) {
            return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success || app.isActive
        }
        let activated = activate(app)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return applyFocus(to: window, appElement: appElement) || activated
    }

    private static func prepareFocusRestoration(targetWindowID: CGWindowID, targetApp: NSRunningApplication) {
        focusRestorationGeneration += 1
        let generation = focusRestorationGeneration
        guard let restoration = focusRestoration(targetWindowID: targetWindowID, targetApp: targetApp) else {
            pendingFocusRestoration = nil
            return
        }
        pendingFocusRestoration = restoration
        installFocusRestorationObserver()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            guard focusRestorationGeneration == generation else { return }
            pendingFocusRestoration = nil
        }
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
        guard let windowID = restoration.sourceWindowID else {
            activate(app)
            return
        }
        actionQueue.async {
            guard let window = axWindowElement(windowID: windowID, app: app) else {
                DispatchQueue.main.async { _ = activate(app) }
                return
            }
            DispatchQueue.main.async {
                if applySingleWindowFocus(to: window, windowID: windowID, app: app) {
                    raiseFocusedWindowIfStillActive(window, windowID: windowID, app: app)
                }
            }
        }
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
        _ window: AXUIElement,
        windowID: CGWindowID,
        app: NSRunningApplication,
        closedObservationCount: Int,
        attempt: Int,
        completion: @escaping (Bool) -> Void
    ) {
        actionQueue.asyncAfter(deadline: .now() + 0.15) {
            let presence = windowPresence(window, windowID: windowID, app: app)
            if presence == .closed, closedObservationCount >= 1 {
                markClosed(windowID: windowID, app: app) { completion(true) }
                return
            }
            guard attempt < 8 else {
                completeWindowAction(false, completion: completion)
                return
            }
            verifyClosed(
                window,
                windowID: windowID,
                app: app,
                closedObservationCount: presence == .closed ? closedObservationCount + 1 : 0,
                attempt: attempt + 1,
                completion: completion
            )
        }
    }

    private static func windowPresence(
        _ window: AXUIElement,
        windowID: CGWindowID,
        app: NSRunningApplication
    ) -> WindowPresence {
        guard !app.isTerminated else { return .closed }
        if let description = windowDescriptions([windowID])[windowID] {
            return description.ownerPID == app.processIdentifier ? .open : .closed
        }

        var role: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            window,
            kAXRoleAttribute as CFString,
            &role
        )
        switch result {
        case .success:
            guard let currentWindowID = self.windowID(for: window) else { return .unknown }
            return currentWindowID == windowID ? .open : .closed
        case .invalidUIElement, .noValue:
            return .closed
        default:
            return .unknown
        }
    }

    private static func completeWindowAction(
        _ success: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.main.async {
            completion(success)
        }
    }

    private static func markClosed(
        windowID: CGWindowID,
        app: NSRunningApplication,
        completion: @escaping () -> Void
    ) {
        let pid = app.processIdentifier
        let key = WindowCacheKey(pid: pid, windowID: windowID)
        remoteWindowElementResolver.remove(pid: pid, windowID: windowID)
        workQueue.async {
            previewsByPID[pid]?.removeAll { $0.windowID == windowID }
            thumbnailsByWindow.removeValue(forKey: key)
            thumbnailFailureBackoff.recordSuccess(for: key)
            invalidateCapture(for: key)
            publishCachedPreviews(previewsByPID[pid] ?? [], for: pid, metadataRefreshed: true)
            DispatchQueue.main.async(execute: completion)
        }
    }

    private static func pruneThumbnailCache(for pid: pid_t, keeping windowIDs: [CGWindowID]) {
        let validKeys = Set(windowIDs.map { WindowCacheKey(pid: pid, windowID: $0) })
        let removedKeys = Set(thumbnailsByWindow.keys.filter { $0.pid == pid && !validKeys.contains($0) })
            .union(inFlightCaptures.map(\.cacheKey).filter { $0.pid == pid && !validKeys.contains($0) })
            .union(captureInvalidationGenerationByWindow.keys.filter {
                $0.pid == pid && !validKeys.contains($0)
            })
            .union(latestCaptureSequenceByWindow.keys.filter {
                $0.pid == pid && !validKeys.contains($0)
            })
        for key in removedKeys {
            thumbnailsByWindow.removeValue(forKey: key)
            invalidateCapture(for: key)
        }
        thumbnailFailureBackoff.removeAll { key in
            key.pid == pid && !validKeys.contains(key)
        }
    }

    private static func cachedThumbnail(
        for key: WindowCacheKey,
        geometry: WindowCaptureGeometry,
        mode: ThumbnailCaptureMode
    ) -> NSImage? {
        guard PermissionManager.status.screenRecordingGranted else { return nil }
        guard let entry = thumbnailsByWindow[key],
              entry.geometry == geometry else {
            return nil
        }
        switch mode {
        case .missingOnly:
            return entry.image
        case .staleAfter(let minimumAge):
            return Date().timeIntervalSince(entry.capturedAt) < minimumAge ? entry.image : nil
        case .fresh:
            return nil
        }
    }

    private static func thumbnailRefreshPlan(
        from previews: [WindowPreview],
        policy: WindowThumbnailRefreshPolicy
    ) -> ThumbnailRefreshPlan {
        guard PermissionManager.status.screenRecordingGranted else { return .empty }
        let now = ProcessInfo.processInfo.systemUptime
        let captureDate = Date()
        var candidates = [ThumbnailCaptureCandidate]()
        var unavailableWindowIDs = [CGWindowID]()
        for preview in previews {
            let key = WindowCacheKey(pid: preview.app.processIdentifier, windowID: preview.windowID)
            let geometry = WindowCaptureGeometry(preview.bounds)
            let signature = WindowCaptureSignature(
                geometry: geometry,
                isMinimized: preview.isMinimized
            )
            let entry = thumbnailsByWindow[key].flatMap {
                $0.geometry == geometry ? $0 : nil
            }
            let isBackingOff = !thumbnailFailureBackoff.allowsAttempt(
                for: key,
                signature: signature,
                now: now
            )
            let isInFlight = inFlightCaptures.contains {
                isCurrentCaptureRequest($0, for: key, signature: signature)
            }
            let isStale = entry.map {
                captureDate.timeIntervalSince($0.capturedAt) >= thumbnailLiveRefreshMinimumAge
            } ?? false
            let decision = WindowThumbnailAttemptPolicy.decide(
                hasCachedImage: entry != nil,
                isMinimized: preview.isMinimized,
                isStale: isStale,
                isInFlight: isInFlight,
                isBackingOff: isBackingOff,
                allowsMissingCapture: policy != .none,
                allowsStaleCapture: policy == .refreshStale
            )
            switch decision {
            case .none:
                break
            case .captureMissing:
                candidates.append(ThumbnailCaptureCandidate(preview: preview, mode: .missingOnly))
            case .captureStale:
                candidates.append(ThumbnailCaptureCandidate(
                    preview: preview,
                    mode: .staleAfter(thumbnailLiveRefreshMinimumAge)
                ))
            case .unavailableBackoff:
                unavailableWindowIDs.append(preview.windowID)
            }
        }
        return ThumbnailRefreshPlan(
            candidates: candidates,
            unavailableWindowIDs: unavailableWindowIDs
        )
    }

    private static func oldestCaptureFirst(
        _ lhs: ThumbnailCaptureCandidate,
        _ rhs: ThumbnailCaptureCandidate
    ) -> Bool {
        let lhsKey = WindowCacheKey(
            pid: lhs.preview.app.processIdentifier,
            windowID: lhs.preview.windowID
        )
        let rhsKey = WindowCacheKey(
            pid: rhs.preview.app.processIdentifier,
            windowID: rhs.preview.windowID
        )
        let lhsDate = captureDate(for: lhs, key: lhsKey)
        let rhsDate = captureDate(for: rhs, key: rhsKey)
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        if lhs.preview.isFocused != rhs.preview.isFocused { return lhs.preview.isFocused }
        return lhs.preview.windowID < rhs.preview.windowID
    }

    private static func captureDate(
        for candidate: ThumbnailCaptureCandidate,
        key: WindowCacheKey
    ) -> Date {
        let geometry = WindowCaptureGeometry(candidate.preview.bounds)
        guard let entry = thumbnailsByWindow[key],
              entry.geometry == geometry else {
            return .distantPast
        }
        return entry.capturedAt
    }

    private static func startThumbnailCaptures(
        _ candidates: [ThumbnailCaptureCandidate],
        requiredBackgroundTargetPID: pid_t? = nil,
        completion: @escaping (CGWindowID, FreshThumbnailCaptureResult) -> Void
    ) {
        for candidate in candidates {
            captureThumbnail(
                for: candidate.preview,
                mode: candidate.mode,
                requiredBackgroundTargetPID: requiredBackgroundTargetPID
            ) { result in
                DispatchQueue.main.async {
                    if result.image != nil,
                       !PermissionManager.status.screenRecordingGranted {
                        return
                    }
                    completion(candidate.preview.windowID, result)
                }
            }
        }
    }

    private static func replaceCachedImage(_ image: NSImage, for key: WindowCacheKey) {
        guard let previews = previewsByPID[key.pid] else { return }
        guard let geometry = thumbnailsByWindow[key]?.geometry else { return }
        let updated = previews.map { preview in
            let matchesCapture = preview.windowID == key.windowID &&
                WindowCaptureGeometry(preview.bounds) == geometry
            return matchesCapture ? preview.replacingImage(with: image) : preview
        }
        previewsByPID[key.pid] = updated
        publishCachedPreviews(updated, for: key.pid)
    }

    private static func publishCachedPreviews(
        _ previews: [WindowPreview],
        for pid: pid_t,
        metadataRefreshed: Bool = false
    ) {
        cachedPreviewsLock.lock()
        cachedPreviewsSnapshotByPID[pid] = previews
        cacheAccessByPID[pid] = Date()
        if metadataRefreshed {
            cachedMetadataRefreshedAtByPID[pid] = Date()
        }
        cachedPreviewsLock.unlock()
    }

    private static func ensureApplicationTerminationObservation() {
        _ = applicationTerminationObserver
    }

    private static func pruneApplicationCachesIfNeeded(keeping activePID: pid_t?) {
        guard previewsByPID.count > maximumCachedApplications else { return }
        cachedPreviewsLock.lock()
        let accessByPID = cacheAccessByPID
        cachedPreviewsLock.unlock()

        let purgeablePIDs = previewsByPID.keys
            .filter { pid in
                (activePID == nil || pid != activePID) &&
                    !refreshCoordinator.isInFlight(for: pid) &&
                    !inFlightCaptures.contains(where: { $0.cacheKey.pid == pid })
            }
            .sorted {
                accessByPID[$0, default: .distantPast] < accessByPID[$1, default: .distantPast]
            }
        let excessCount = previewsByPID.count - maximumCachedApplications
        purgeablePIDs.prefix(excessCount).forEach { purgeCachedApplication(pid: $0) }
    }

    private static func purgeCachedApplication(pid: pid_t) {
        let keys = Set(thumbnailsByWindow.keys.filter { $0.pid == pid })
            .union(inFlightCaptures.map(\.cacheKey).filter { $0.pid == pid })
            .union(captureInvalidationGenerationByWindow.keys.filter { $0.pid == pid })
            .union(latestCaptureSequenceByWindow.keys.filter { $0.pid == pid })
        keys.forEach {
            thumbnailsByWindow.removeValue(forKey: $0)
            invalidateCapture(for: $0)
        }
        thumbnailFailureBackoff.removeAll { $0.pid == pid }
        previewsByPID.removeValue(forKey: pid)
        cachedPreviewsLock.lock()
        cachedPreviewsSnapshotByPID.removeValue(forKey: pid)
        cachedMetadataRefreshedAtByPID.removeValue(forKey: pid)
        cacheAccessByPID.removeValue(forKey: pid)
        cachedPreviewsLock.unlock()
    }

    private static func captureThumbnail(
        for preview: WindowPreview,
        mode: ThumbnailCaptureMode = .missingOnly,
        requiredBackgroundTargetPID: pid_t? = nil,
        completion: @escaping (FreshThumbnailCaptureResult) -> Void
    ) {
        let key = WindowCacheKey(pid: preview.app.processIdentifier, windowID: preview.windowID)
        let geometry = WindowCaptureGeometry(preview.bounds)
        let signature = WindowCaptureSignature(
            geometry: geometry,
            isMinimized: preview.isMinimized
        )
        workQueue.async {
            if let requiredBackgroundTargetPID,
               backgroundThumbnailTargetPID != requiredBackgroundTargetPID {
                completion(.unavailable)
                return
            }
            guard PermissionManager.status.screenRecordingGranted else {
                completion(.unavailable)
                return
            }
            let priority = mode.capturePriority
            if let cachedImage = cachedThumbnail(for: key, geometry: geometry, mode: mode) {
                completion(.cached(cachedImage))
                return
            }
            if let request = queuedCaptureRequest(for: key, signature: signature, priority: priority) {
                captureCompletionsByWindow[request, default: []].append(completion)
                return
            }
            nextCaptureSequence &+= 1
            let request = WindowCaptureRequestKey(
                cacheKey: key,
                signature: signature,
                priority: priority,
                sequence: nextCaptureSequence,
                invalidationGeneration: captureInvalidationGenerationByWindow[key, default: 0]
            )
            latestCaptureSequenceByWindow[key] = request.sequence
            inFlightCaptures.insert(request)
            captureCompletionsByWindow[request] = [completion]
            startThumbnailCapture(request, preview: preview)
        }
    }

    private static func startThumbnailCapture(
        _ request: WindowCaptureRequestKey,
        preview: WindowPreview
    ) {
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation] in
            guard operation?.isCancelled == false else { return }
            capture(
                windowID: preview.windowID,
                resolution: request.priority.captureResolution
            ) { image in
                let capturedImage = image?.hasUsableWindowAlpha == true ? image : nil
                let cachedImage = capturedImage?.downscaled(
                    maximumPixelDimension: maximumCachedThumbnailPixelDimension
                )
                let deliveredImage = request.priority == .live ? capturedImage : cachedImage
                workQueue.async {
                    finishThumbnailCapture(
                        request,
                        cachedImage: cachedImage,
                        deliveredImage: deliveredImage
                    )
                }
            }
        }
        captureOperationsByRequest[request] = operation
        queue(for: request.priority).addOperation(operation)
    }

    private static func finishThumbnailCapture(
        _ request: WindowCaptureRequestKey,
        cachedImage: NSImage?,
        deliveredImage: NSImage?
    ) {
        let key = request.cacheKey
        let currentSignature = previewsByPID[key.pid]?
            .first(where: { $0.windowID == key.windowID })
            .map {
                WindowCaptureSignature(
                    geometry: WindowCaptureGeometry($0.bounds),
                    isMinimized: $0.isMinimized
                )
            }
        let isLatestRequest = request.sequence == latestCaptureSequenceByWindow[key]
        let isValidRequest = request.invalidationGeneration ==
            captureInvalidationGenerationByWindow[key, default: 0] &&
            currentSignature == request.signature &&
            PermissionManager.status.screenRecordingGranted &&
            isLatestRequest
        let result: FreshThumbnailCaptureResult
        let existingEntry = thumbnailsByWindow[key].flatMap {
            $0.geometry == request.geometry ? $0 : nil
        }
        let shouldStoreCapturedImage = existingEntry.map {
            $0.sequence < request.sequence
        } ?? true
        if isValidRequest {
            if cachedImage == nil, request.priority == .background {
                thumbnailFailureBackoff.recordFailure(
                    for: key,
                    signature: request.signature,
                    now: ProcessInfo.processInfo.systemUptime
                )
            } else if cachedImage != nil {
                thumbnailFailureBackoff.recordSuccess(for: key)
            }
        }
        if isValidRequest,
           let cachedImage,
           let deliveredImage,
           shouldStoreCapturedImage {
            thumbnailsByWindow[key] = ThumbnailCacheEntry(
                image: cachedImage,
                capturedAt: Date(),
                geometry: request.geometry,
                sequence: request.sequence
            )
            replaceCachedImage(cachedImage, for: key)
            result = .captured(deliveredImage)
        } else if isValidRequest, let existingEntry {
            result = .cached(existingEntry.image)
        } else {
            result = .unavailable
        }
        inFlightCaptures.remove(request)
        captureOperationsByRequest.removeValue(forKey: request)
        let completions = captureCompletionsByWindow.removeValue(forKey: request) ?? []
        cleanupCaptureState(for: request)
        pruneApplicationCachesIfNeeded(keeping: nil)
        completions.forEach { $0(result) }
    }

    private static func cancelBackgroundThumbnailCaptures(except retainedPID: pid_t?) {
        let requests = inFlightCaptures.filter { request in
            request.priority == .background && request.cacheKey.pid != retainedPID
        }
        requests.forEach(cancelThumbnailCapture)
    }

    private static func cancelThumbnailCapture(_ request: WindowCaptureRequestKey) {
        captureOperationsByRequest.removeValue(forKey: request)?.cancel()
        inFlightCaptures.remove(request)
        let completions = captureCompletionsByWindow.removeValue(forKey: request) ?? []
        cleanupCaptureState(for: request)
        completions.forEach { $0(.unavailable) }
    }

    private static func queuedCaptureRequest(
        for key: WindowCacheKey,
        signature: WindowCaptureSignature,
        priority: ThumbnailCapturePriority
    ) -> WindowCaptureRequestKey? {
        if let liveRequest = inFlightCaptures.first(where: {
            isCurrentCaptureRequest($0, for: key, signature: signature) && $0.priority == .live
        }) {
            return liveRequest
        }
        guard priority == .background else { return nil }
        return inFlightCaptures.first {
            isCurrentCaptureRequest($0, for: key, signature: signature) && $0.priority == .background
        }
    }

    private static func isCurrentCaptureRequest(
        _ request: WindowCaptureRequestKey,
        for key: WindowCacheKey,
        signature: WindowCaptureSignature
    ) -> Bool {
        request.cacheKey == key &&
            request.signature == signature &&
            request.invalidationGeneration == captureInvalidationGenerationByWindow[key, default: 0] &&
            request.sequence == latestCaptureSequenceByWindow[key]
    }

    private static func invalidateCapture(for key: WindowCacheKey) {
        captureInvalidationGenerationByWindow[key, default: 0] &+= 1
        latestCaptureSequenceByWindow.removeValue(forKey: key)
        cleanupCaptureStateIfIdle(for: key)
    }

    private static func cleanupCaptureState(for request: WindowCaptureRequestKey) {
        let key = request.cacheKey
        if latestCaptureSequenceByWindow[key] == request.sequence {
            latestCaptureSequenceByWindow.removeValue(forKey: key)
        }
        cleanupCaptureStateIfIdle(for: key)
    }

    private static func cleanupCaptureStateIfIdle(for key: WindowCacheKey) {
        guard !inFlightCaptures.contains(where: { $0.cacheKey == key }) else { return }
        captureInvalidationGenerationByWindow.removeValue(forKey: key)
        latestCaptureSequenceByWindow.removeValue(forKey: key)
    }

    private static func queue(for priority: ThumbnailCapturePriority) -> OperationQueue {
        switch priority {
        case .background:
            return captureQueue
        case .live:
            return liveCaptureQueue
        }
    }

    private static func capture(
        windowID: CGWindowID,
        resolution: SkyLightWindowCaptureResolution,
        completion: @escaping (NSImage?) -> Void
    ) {
        completion(captureWithSkyLight(windowID: windowID, resolution: resolution))
    }

    private static func captureWithSkyLight(
        windowID: CGWindowID,
        resolution: SkyLightWindowCaptureResolution
    ) -> NSImage? {
        guard let cgImage = SkyLightCapture.capture(
            windowID: windowID,
            resolution: resolution
        ) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func axWindows(
        for app: NSRunningApplication,
        shouldContinue: () -> Bool
    ) -> AXWindowRecordResult? {
        guard let windowResult = axWindowElements(
            for: app.processIdentifier,
            shouldContinue: shouldContinue
        ) else {
            return nil
        }
        let windows = windowResult.elements
        var records = [WindowRecord]()

        for window in windows {
            guard shouldContinue() else { return nil }
            guard let id = windowID(for: window) else { continue }
            let title = AccessibilityHelpers.stringAttribute(window, kAXTitleAttribute as CFString)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let role = AccessibilityHelpers.stringAttribute(window, kAXRoleAttribute as CFString)
            let subrole = AccessibilityHelpers.stringAttribute(window, kAXSubroleAttribute as CFString)
            let size = AccessibilityHelpers.sizeAttribute(window, kAXSizeAttribute as CFString)
            records.append(WindowRecord(
                windowID: id,
                title: title,
                role: role,
                subrole: subrole,
                position: AccessibilityHelpers.pointAttribute(window, kAXPositionAttribute as CFString),
                size: validWindowSize(size),
                isMinimized: AccessibilityHelpers.boolAttribute(window, kAXMinimizedAttribute as CFString) ?? false,
                isFullscreen: AccessibilityHelpers.boolAttribute(window, axFullScreenAttribute) ?? false,
                level: SkyLightCapture.level(windowID: id)
            ))
        }

        return AXWindowRecordResult(
            records: unique(records),
            remoteResolution: windowResult.remoteResolution
        )
    }

    private static func validWindowSize(_ size: CGSize?) -> CGSize? {
        guard let size, size.width > 0, size.height > 0 else { return nil }
        return size
    }

    private static func axWindowElement(windowID: CGWindowID, app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let windows = AccessibilityHelpers.elementArrayAttribute(appElement, kAXWindowsAttribute as CFString)
        if let match = windows.first(where: { self.windowID(for: $0) == windowID }) {
            return match
        }
        let knownWindowElements = windows.reduce(into: [CGWindowID: AXUIElement]()) { result, element in
            guard let windowID = self.windowID(for: element) else { return }
            result[windowID] = element
        }
        guard let resolution = remoteWindowResolution(
            pid: app.processIdentifier,
            knownWindowElements: knownWindowElements
        ) else {
            return nil
        }
        remoteWindowElementResolver.commit(resolution)
        return resolution.windows.first { self.windowID(for: $0) == windowID }
    }

    private static func axElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func axWindowElements(
        for pid: pid_t,
        shouldContinue: () -> Bool
    ) -> AXWindowElementResult? {
        guard shouldContinue() else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        let axWindows = AccessibilityHelpers.elementArrayAttribute(appElement, kAXWindowsAttribute as CFString)
        guard shouldContinue() else { return nil }
        let knownWindowElements = axWindows.reduce(into: [CGWindowID: AXUIElement]()) { result, element in
            guard let windowID = windowID(for: element) else { return }
            result[windowID] = element
        }
        guard let remoteResolution = remoteWindowResolution(
            pid: pid,
            knownWindowElements: knownWindowElements,
            shouldContinue: shouldContinue
        ) else {
            return nil
        }
        return AXWindowElementResult(
            elements: axWindows + remoteResolution.windows,
            remoteResolution: remoteResolution
        )
    }

    private static func remoteWindowResolution(
        pid: pid_t,
        knownWindowElements: [CGWindowID: AXUIElement],
        shouldContinue: () -> Bool = { true }
    ) -> RemoteWindowElementResolution? {
        guard shouldContinue() else { return nil }
        guard let snapshot = bruteForceWindowSnapshot(
            pid: pid,
            shouldContinue: shouldContinue
        ) else {
            return nil
        }
        return remoteWindowElementResolver.resolve(
            pid: pid,
            knownWindowIDs: Set(knownWindowElements.keys),
            knownWindowElements: knownWindowElements,
            targetWindowIDs: snapshot.targetWindowIDs,
            shouldContinue: shouldContinue
        )
    }

    private static func bruteForceWindowSnapshot(
        pid: pid_t,
        shouldContinue: () -> Bool
    ) -> BruteForceWindowSnapshot? {
        guard shouldContinue() else { return nil }
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return BruteForceWindowSnapshot(targetWindowIDs: nil)
        }
        var targetWindowIDs = Set<CGWindowID>()
        for description in windows {
            guard shouldContinue() else { return nil }
            guard description[kCGWindowOwnerPID as String] as? pid_t == pid,
                  let windowID = description[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }
            if isBruteForceTargetWindow(description, pid: pid),
               isAssignedToUserSpaceOrUnknown(windowID: windowID) {
                targetWindowIDs.insert(windowID)
            }
        }
        return BruteForceWindowSnapshot(targetWindowIDs: Optional(targetWindowIDs))
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

    private static func isAssignedToUserSpaceOrUnknown(windowID: CGWindowID) -> Bool {
        WindowSpaceMembership.isRemoteRecoveryCandidate(
            spaceIDs: SkyLightCapture.spaceIDsIfAvailable(windowID: windowID)
        )
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
            let parsedBounds = (description[kCGWindowBounds] as? NSDictionary)
                .flatMap { CGRect(dictionaryRepresentation: $0) }
            let bounds = parsedBounds.flatMap { bounds in
                bounds.width > 0 && bounds.height > 0 ? bounds : nil
            }
            result[windowID] = WindowDescription(
                ownerPID: ownerPID,
                bounds: bounds,
                level: description[kCGWindowLayer] as? CGWindowLevel
            )
        }
    }

    private static func isDisplayable(
        _ record: WindowRecord,
        description: WindowDescription?,
        app: NSRunningApplication
    ) -> Bool {
        guard record.role == kAXWindowRole as String else { return false }
        let size = record.size ?? description?.bounds?.size ?? .zero
        let level = record.level ?? description?.level ?? CGWindowLevel(0)
        guard size.width >= 80 &&
            size.height >= 60 &&
            level <= CGWindowLevelForKey(.floatingWindow) else {
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
    let signature: WindowCaptureSignature
    let priority: ThumbnailCapturePriority
    let sequence: UInt64
    let invalidationGeneration: UInt64

    var geometry: WindowCaptureGeometry {
        signature.geometry
    }
}

private struct ThumbnailCacheEntry {
    let image: NSImage
    let capturedAt: Date
    let geometry: WindowCaptureGeometry
    let sequence: UInt64
}

private struct WindowCaptureGeometry: Hashable {
    let width: UInt64
    let height: UInt64

    init(_ bounds: CGRect) {
        width = Double(bounds.width).bitPattern
        height = Double(bounds.height).bitPattern
    }
}

private struct WindowCaptureSignature: Hashable {
    let geometry: WindowCaptureGeometry
    let isMinimized: Bool
}

private enum ThumbnailCapturePriority: Hashable {
    case background
    case live

    var captureResolution: SkyLightWindowCaptureResolution {
        switch self {
        case .background:
            return .nominal
        case .live:
            return .best
        }
    }
}

private enum ThumbnailCaptureMode {
    case missingOnly
    case staleAfter(TimeInterval)
    case fresh

    var capturePriority: ThumbnailCapturePriority {
        if case .fresh = self { return .live }
        return .background
    }

    var isMissing: Bool {
        if case .missingOnly = self { return true }
        return false
    }
}

private struct ThumbnailCaptureCandidate {
    let preview: WindowPreview
    let mode: ThumbnailCaptureMode
}

private struct ThumbnailRefreshPlan {
    let candidates: [ThumbnailCaptureCandidate]
    let unavailableWindowIDs: [CGWindowID]

    static let empty = ThumbnailRefreshPlan(candidates: [], unavailableWindowIDs: [])
}

private struct WindowRefreshCallbacks {
    let thumbnailPolicy: WindowThumbnailRefreshPolicy
    let metadata: ([WindowPreview]) -> Void
    let thumbnail: (CGWindowID, NSImage) -> Void
}

private struct WindowDescription {
    let ownerPID: pid_t
    let bounds: CGRect?
    let level: CGWindowLevel?
}

private struct BruteForceWindowSnapshot {
    let targetWindowIDs: Set<CGWindowID>?
}

private struct AXWindowElementResult {
    let elements: [AXUIElement]
    let remoteResolution: RemoteWindowElementResolution
}

private struct AXWindowRecordResult {
    let records: [WindowRecord]
    let remoteResolution: RemoteWindowElementResolution
}

private struct WindowPreviewRefreshResult {
    let previews: [WindowPreview]
    let remoteResolution: RemoteWindowElementResolution
    let screenRecordingGranted: Bool
}

private enum WindowPresence: Equatable {
    case open
    case closed
    case unknown
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
    func downscaled(maximumPixelDimension: Int) -> NSImage {
        guard maximumPixelDimension > 0,
              let image = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return self
        }
        let largestDimension = max(image.width, image.height)
        guard largestDimension > maximumPixelDimension else { return self }

        let scale = CGFloat(maximumPixelDimension) / CGFloat(largestDimension)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return self
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaledImage = context.makeImage() else { return self }
        return NSImage(cgImage: scaledImage, size: size)
    }

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
    let level: CGWindowLevel?
}
