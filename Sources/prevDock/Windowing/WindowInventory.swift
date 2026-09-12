import Cocoa
import ApplicationServices
import CoreGraphics

enum WindowInventory {
    private static let workQueue = DispatchQueue(label: "prevDock.window-inventory", qos: .userInitiated)
    private static let cachedPreviewsLock = NSLock()
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
    private static var previewElementsByPID = [pid_t: [CGWindowID: AXUIElement]]()
    private static var cachedPreviewsSnapshotByPID = [pid_t: [WindowPreview]]()
    private static var cachedMetadataRefreshedAtByPID = [pid_t: TimeInterval]()
    private static var cacheAccessByPID = [pid_t: TimeInterval]()
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
    private static let metadataRefreshTimeLimit: TimeInterval = 1.5
    private static let applicationTerminationObserver: NSObjectProtocol = {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            WindowDiscovery.removeRemoteWindows(for: app.processIdentifier)
            workQueue.async {
                purgeCachedApplication(pid: app.processIdentifier)
            }
        }
    }()

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
        cacheAccessByPID[app.processIdentifier] = ProcessInfo.processInfo.systemUptime
        cachedPreviewsLock.unlock()
        if let maximumAge {
            guard let refreshedAt,
                  (ProcessInfo.processInfo.systemUptime - refreshedAt) <= maximumAge else {
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
        let deadline = ProcessInfo.processInfo.systemUptime + metadataRefreshTimeLimit
        let shouldContinue = {
            refreshCoordinator.shouldContinue(generation) &&
                ProcessInfo.processInfo.systemUptime < deadline
        }
        guard let refresh = WindowDiscovery.makePreviews(
            for: app,
            previousPreviews: previewsByPID[pid] ?? [],
            previousElements: previewElementsByPID[pid] ?? [:],
            cachedImage: { cachedThumbnailImage(pid: pid, windowID: $0, bounds: $1) },
            shouldContinue: shouldContinue
        ),
              shouldContinue() else {
            deliverCachedRefresh(for: app, generation: generation)
            return
        }
        let callbacks = refreshCoordinator.complete(generation)
        guard !callbacks.isEmpty else { return }
        guard !app.isTerminated else {
            WindowDiscovery.removeRemoteWindows(for: pid)
            purgeCachedApplication(pid: pid)
            DispatchQueue.main.async {
                callbacks.forEach { $0.metadata([]) }
            }
            return
        }
        let previews = refresh.previews
        WindowDiscovery.commit(refresh.remoteResolution)
        pruneThumbnailCache(for: pid, keeping: previews.map(\.windowID))

        previewsByPID[pid] = previews
        previewElementsByPID[pid] = refresh.windowElements
        publishCachedPreviews(
            previews,
            for: pid,
            metadataRefreshed: refresh.remoteResolution.unresolvedWindowIDs?.isEmpty == true
        )
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

    private static func deliverCachedRefresh(
        for app: NSRunningApplication,
        generation: WindowRefreshGeneration<pid_t>
    ) {
        let callbacks = refreshCoordinator.complete(generation)
        guard !callbacks.isEmpty else { return }
        let previews = app.isTerminated ? [] : cachedWindows(for: app)
        DispatchQueue.main.async {
            let deliverablePreviews = app.isTerminated ? [] : previews
            callbacks.forEach { $0.metadata(deliverablePreviews) }
        }
    }

    @discardableResult
    static func warmPreviewCache(
        for app: NSRunningApplication,
        metadata: @escaping ([WindowPreview]) -> Void = { _ in }
    ) -> WindowRefreshRequest {
        refreshWindows(for: app, thumbnailPolicy: .none, metadata: metadata, thumbnail: { _, _ in })
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

    @discardableResult
    static func focusWindow(
        windowID: CGWindowID,
        app: NSRunningApplication,
        completion: @escaping (Bool) -> Void = { _ in }
    ) -> WindowFocusRequest {
        WindowCommands.focusWindow(windowID: windowID, app: app, completion: completion)
    }

    static func closeWindow(
        windowID: CGWindowID,
        app: NSRunningApplication,
        isFullscreen: Bool = false,
        completion: @escaping (Bool) -> Void
    ) {
        WindowCommands.closeWindow(
            windowID: windowID,
            app: app,
            isFullscreen: isFullscreen,
            completion: completion
        )
    }

    static func removeClosedWindow(
        windowID: CGWindowID,
        app: NSRunningApplication,
        completion: @escaping () -> Void
    ) {
        let pid = app.processIdentifier
        let key = WindowCacheKey(pid: pid, windowID: windowID)
        WindowDiscovery.removeRemoteWindow(pid: pid, windowID: windowID)
        workQueue.async {
            previewsByPID[pid]?.removeAll { $0.windowID == windowID }
            previewElementsByPID[pid]?.removeValue(forKey: windowID)
            thumbnailsByWindow.removeValue(forKey: key)
            thumbnailFailureBackoff.recordSuccess(for: key)
            invalidateCapture(for: key)
            publishCachedPreviews(previewsByPID[pid] ?? [], for: pid, metadataRefreshed: true)
            DispatchQueue.main.async(execute: completion)
        }
    }

    private static func cachedThumbnailImage(pid: pid_t, windowID: CGWindowID, bounds: CGRect) -> NSImage? {
        let key = WindowCacheKey(pid: pid, windowID: windowID)
        let geometry = WindowCaptureGeometry(bounds)
        return thumbnailsByWindow[key].flatMap { entry in
            entry.geometry == geometry ? entry.image : nil
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
            return (ProcessInfo.processInfo.systemUptime - entry.capturedAt) < minimumAge ? entry.image : nil
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
                (now - $0.capturedAt) >= thumbnailLiveRefreshMinimumAge
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
        let lhsTime = captureTime(for: lhs, key: lhsKey)
        let rhsTime = captureTime(for: rhs, key: rhsKey)
        if lhsTime != rhsTime { return lhsTime < rhsTime }
        if lhs.preview.isFocused != rhs.preview.isFocused { return lhs.preview.isFocused }
        return lhs.preview.windowID < rhs.preview.windowID
    }

    private static func captureTime(
        for candidate: ThumbnailCaptureCandidate,
        key: WindowCacheKey
    ) -> TimeInterval {
        let geometry = WindowCaptureGeometry(candidate.preview.bounds)
        guard let entry = thumbnailsByWindow[key],
              entry.geometry == geometry else {
            return -TimeInterval.infinity
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
        metadataRefreshed: Bool? = nil
    ) {
        cachedPreviewsLock.lock()
        cachedPreviewsSnapshotByPID[pid] = previews
        cacheAccessByPID[pid] = ProcessInfo.processInfo.systemUptime
        if let metadataRefreshed {
            if metadataRefreshed {
                cachedMetadataRefreshedAtByPID[pid] = ProcessInfo.processInfo.systemUptime
            } else {
                cachedMetadataRefreshedAtByPID.removeValue(forKey: pid)
            }
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
                accessByPID[$0, default: -TimeInterval.infinity] < accessByPID[$1, default: -TimeInterval.infinity]
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
        previewElementsByPID.removeValue(forKey: pid)
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
                let capturedImage = image.map(WindowThumbnailImage.hasUsableWindowAlpha) == true ? image : nil
                let cachedImage = capturedImage.map {
                    WindowThumbnailImage.downscaled($0, maximumPixelDimension: maximumCachedThumbnailPixelDimension)
                }
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
                capturedAt: ProcessInfo.processInfo.systemUptime,
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
    let capturedAt: TimeInterval
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
