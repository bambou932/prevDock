import ApplicationServices
import Cocoa

final class DockHoverMonitor {
    private weak var previewController: PreviewPanelController?
    private let targetCache: DockHoverTargetCache
    private let refreshes = DockPreviewRefreshController()
    private lazy var clicks = DockClickPreviewController(
        refreshes: refreshes, retryInterval: fastTickInterval
    ) { [weak self] event in
        self?.handleDockClickEvent(event)
    }
    private lazy var scheduler = DockHoverScheduler { [weak self] in self?.tick() }
    private lazy var inputMonitor = DockInputMonitor(handlers: .init(
        mouseDown: { [weak self] input in
            self?.handleMouseDown(
                kind: input.kind, isContextClick: input.isContextClick,
                allowsPreviewInterception: input.allowsPreviewInterception,
                mouse: input.mouse, fallbackMouse: input.fallbackMouse,
                canSuppressDefault: input.canSuppressDefault
            ) ?? false
        },
        mouseMoved: { [weak self] in self?.scheduler.wake() },
        focusNavigation: { [weak self] in self?.cancelFocusForKeyboardNavigation() },
        mouseDragged: { [weak self] kind in self?.suppression.shouldSuppressMouseDrag(kind: kind) ?? false },
        mouseUp: { [weak self] kind in self?.suppression.consumeSuppressedMouseUpIfNeeded(kind: kind) ?? false }
    ))
    private var settingsObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var lastTargetKey: String?
    private var lastAnchor: CGRect?
    private var hoverExitStartedAt: TimeInterval?
    private var pendingTarget: DockHoverTarget?
    private var pendingTargetStartedAt = -TimeInterval.infinity
    private var suppression = DockHoverSuppressionState()
    private var focusReturnTarget: (key: String, anchor: CGRect, pid: pid_t?)?
    private let fastTickInterval: TimeInterval = 0.08
    private let watchdogTickInterval: TimeInterval = 1.0
    private let liveThumbnailRefreshInterval: TimeInterval = 0.45
    private let previewHideGraceInterval: TimeInterval = 0.20
    private let pendingTargetClickFallbackLifetime: TimeInterval = 0.25

    init(previewController: PreviewPanelController) {
        self.previewController = previewController
        targetCache = DockHoverTargetCache(previewController: previewController)
        previewController.onFocusTransitionStarted = { [weak self] in
            self?.handleFocusTransitionStarted()
        }
        previewController.onFocusTransitionFinished = { [weak self] success in
            self?.handleFocusTransitionFinished(success: success)
        }
    }

    func start() {
        resumePreviewForInteraction()
        clicks.advanceGeneration()
        clicks.cancel()
        refreshes.cancelRefreshRequests()
        refreshes.resetThumbnailTarget()
        scheduler.cancelTimer()
        inputMonitor.start()
        installSettingsObserver()
        installSpaceObserver()
        scheduler.schedule(after: fastTickInterval)
    }

    func wakeForSuppressedMouseMoved() {
        scheduler.wake()
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
    }

    private func tick() {
        scheduler.cancelTimer()
        inputMonitor.repairIfNeeded()

        defer {
            scheduleNextTickIfNeeded()
        }

        clicks.discardInvalidDockClickIfNeeded()
        let mouse = currentMouseLocationForTick()
        previewController?.synchronizeHoverEffects(at: mouse)
        let overPreview = previewController?.contains(mouse) == true
        let now = ProcessInfo.processInfo.systemUptime
        updateHover(at: mouse, overPreview: overPreview, now: now)
    }

    private func updateHover(at mouse: CGPoint, overPreview: Bool, now: TimeInterval) {
        if isMouseButtonPressed {
            if overPreview || shouldHoldClickPreview() || targetCache.target(mouse) != nil {
                clearHoverExitGrace()
                return
            }
            hideAndResetHover()
            return
        }

        if overPreview {
            clearHoverExitGrace()
            clearPendingTarget()
            refreshVisiblePreviewThumbnails(now: now)
            return
        }

        if shouldHoldClickPreview() {
            clearHoverExitGrace()
            refreshVisiblePreviewThumbnails(now: now)
            return
        }

        if shouldSuppressHover(at: mouse) {
            hideAndResetHover()
            return
        }

        guard AXIsProcessTrusted() else {
            hideAndResetHover()
            return
        }

        guard let rawTarget = targetCache.target(mouse) else {
            if previewController?.contains(mouse) == true {
                clearHoverExitGrace()
                clearPendingTarget()
                refreshVisiblePreviewThumbnails(now: now)
            } else {
                guard !shouldDelayPreviewHide(now: now) else { return }
                hideAndResetHover()
            }
            return
        }

        clearHoverExitGrace()
        refreshes.cancelRefreshRequests(except: rawTarget.key)
        refreshes.warmPreviewCacheIfNeeded(
            for: rawTarget, now: now, pendingTarget: pendingTarget,
            pendingTargetStartedAt: pendingTargetStartedAt, fastTickInterval: fastTickInterval
        )
        guard let target = targetAfterSwitchDelay(rawTarget, now: now) else {
            return
        }

        presentHoverTarget(target, now: now)
    }

    private func presentHoverTarget(_ target: DockHoverTarget, now: TimeInterval) {
        refreshes.setThumbnailTargetPID(target.app?.processIdentifier)
        let targetChanged = lastTargetKey != target.key
        if targetChanged {
            resumePreviewForInteraction()
        }
        lastTargetKey = target.key

        if targetChanged || lastAnchor == nil {
            lastAnchor = target.anchor
        }

        guard let app = target.app else {
            previewController?.hide()
            return
        }

        refreshPresentation(for: app, target: target, targetChanged: targetChanged, now: now)
    }

    private func refreshPresentation(
        for app: NSRunningApplication,
        target: DockHoverTarget,
        targetChanged: Bool,
        now: TimeInterval
    ) {
        let panelVisible = previewController?.isVisible == true
        let needsPresentation = targetChanged || !panelVisible
        let freshCachedPreviews = needsPresentation ? WindowInventory.cachedWindows(
            for: app,
            refreshedWithin: 1.0
        ) : nil
        let pid = app.processIdentifier
        let needsSpaceRefresh = refreshes.needsSpaceRefresh(for: pid)
        let metadataRefreshDue = (now - refreshes.lastMetadataRefresh) > 1.0
        // An empty shelf stays hidden; that is not a reason to rescan on every hover tick.
        let needsMetadata = needsSpaceRefresh || (needsPresentation ?
            freshCachedPreviews == nil && (targetChanged || metadataRefreshDue) : metadataRefreshDue)
        let needsLiveThumbnails = panelVisible &&
            (now - refreshes.lastLiveThumbnailRefresh) > liveThumbnailRefreshInterval
        guard needsPresentation || needsMetadata || needsLiveThumbnails else { return }

        var presentedCachedPreviews = false
        if needsPresentation {
            let cached = freshCachedPreviews ?? WindowInventory.cachedWindows(for: app)
            if cached.isEmpty {
                if targetChanged {
                    previewController?.hide()
                }
            } else {
                previewController?.show(previews: cached, app: app, anchoredTo: lastAnchor ?? target.anchor)
                presentedCachedPreviews = true
            }
            if freshCachedPreviews != nil, targetChanged || presentedCachedPreviews {
                refreshes.noteMetadataPresentation(at: now)
            }
        }

        if needsLiveThumbnails {
            refreshes.noteThumbnailRefresh(at: now)
        }

        let expectedTargetKey = target.key
        if needsMetadata {
            refreshMetadata(for: app, target: target)
        } else if needsLiveThumbnails || presentedCachedPreviews {
            refreshPreviewThumbnails(for: app, expectedTargetKey: expectedTargetKey, now: now)
        }
    }

    private func refreshVisiblePreviewThumbnails(now: TimeInterval) {
        guard previewController?.isVisible == true,
              let app = previewController?.visibleApp,
              let expectedTargetKey = lastTargetKey else {
            return
        }

        // A pending Dock switch can be abandoned by moving back into the existing preview.
        refreshes.setThumbnailTargetPID(app.processIdentifier)
        if (now - refreshes.lastMetadataRefresh) > 1, let anchor = lastAnchor {
            refreshMetadata(for: app, expectedTargetKey: expectedTargetKey, anchor: anchor)
        }
        guard (now - refreshes.lastLiveThumbnailRefresh) > liveThumbnailRefreshInterval else {
            return
        }
        refreshPreviewThumbnails(for: app, expectedTargetKey: expectedTargetKey, now: now)
    }

    private func refreshPreviewThumbnails(
        for app: NSRunningApplication,
        expectedTargetKey: String,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        refreshes.noteThumbnailRefresh(at: now)
        guard previewController?.needsBackgroundThumbnails == true else { return }
        // Keep new windows readable during peek without refreshing already captured thumbnails.
        let maximumStaleCount = WindowPeekController.shared.isShowingLivePreview ? 0 : 2
        refreshes.refreshThumbnails(for: app, maximumStaleCount: maximumStaleCount) { [weak self] windowID, result in
            guard let self, self.lastTargetKey == expectedTargetKey,
                  self.previewController?.isVisible == true else { return }
            if let image = result.image {
                self.previewController?.updateThumbnail(windowID: windowID, image: image)
            } else {
                self.previewController?.markThumbnailUnavailable(windowID: windowID)
            }
        }
    }

    private func refreshMetadata(for app: NSRunningApplication, target: DockHoverTarget) {
        refreshMetadata(for: app, expectedTargetKey: target.key, anchor: target.anchor)
    }

    private func refreshMetadata(for app: NSRunningApplication, expectedTargetKey: String, anchor: CGRect) {
        refreshes.refreshMetadata(for: app, targetKey: expectedTargetKey) { [weak self] app, previews in
            guard let self, self.lastTargetKey == expectedTargetKey else { return }
            self.refreshes.didCompleteMetadataRefresh(for: app.processIdentifier)
            self.previewController?.show(previews: previews, app: app, anchoredTo: self.lastAnchor ?? anchor)
            self.refreshPreviewThumbnails(for: app, expectedTargetKey: expectedTargetKey)
        }
    }

    private var isMouseButtonPressed: Bool {
        NSEvent.pressedMouseButtons & 0b111 != 0
    }

    private func installSettingsObserver() {
        guard settingsObserver == nil else { return }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: PrevDockSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleSettingsChange(key: notification.object as? String)
        }
    }

    private func installSpaceObserver() {
        guard spaceObserver == nil else { return }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleActiveSpaceChange()
        }
    }

    private func handleActiveSpaceChange() {
        clicks.advanceGeneration()
        refreshes.spaceDidChange()
        clicks.cancel()
        targetCache.clear()
        hideAndResetHover()
        WindowInventory.resetThumbnailFailuresForSpaceChange()
        scheduler.wake()
    }

    private func handleSettingsChange(key: String?) {
        clearPendingTarget()
        suppression.clearClickPreviewHold()
        let presentationKeys: Set<String> = [
            PrevDockSettings.previewOverflowModeKey,
            PrevDockSettings.previewAutoFitEnabledKey,
            PrevDockSettings.previewContentSizeKey,
            PrevDockSettings.previewWindowHeightKey,
            PrevDockSettings.previewCloseButtonEnabledKey,
            PrevDockSettings.previewDesktopGroupingEnabledKey
        ]
        if let key, !presentationKeys.contains(key) { return }
        guard previewController?.isVisible == true else { return }
        previewController?.refreshForSettingsChange()
    }

    @discardableResult
    private func handleMouseDown(
        kind: MouseDownKind,
        isContextClick: Bool,
        allowsPreviewInterception: Bool,
        mouse: CGPoint,
        fallbackMouse: CGPoint,
        canSuppressDefault: Bool
    ) -> Bool {
        defer {
            scheduleNextTickIfNeeded()
        }

        clicks.cancel()
        clicks.advanceGeneration()
        suppression.prepareForMouseDown(kind: kind)
        let dockTarget = dockTargetUnderMouseDown(eventMouse: mouse, trackedMouse: fallbackMouse)
        let overPreview = previewContainsMouseDown(eventMouse: mouse, trackedMouse: fallbackMouse)

        if overPreview {
            return false
        }

        resumePreviewForInteraction()
        if isContextClick {
            if dockTarget != nil {
                suppression.suppressDockContextMenu(for: 120)
                hideAndResetHover()
            }
            return false
        }

        if kind == .left {
            guard allowsPreviewInterception else {
                if dockTarget != nil {
                    suppressHover(for: 0.35, untilDockExit: true)
                }
                return false
            }
            let shouldDismissDockContextMenu = suppression.isSuppressingDockContextMenu
            suppression.clearDockContextMenu()
            if let dockTarget {
                return handleDockAppClick(
                    dockTarget,
                    canSuppressDefault: canSuppressDefault,
                    shouldDismissDockContextMenu: shouldDismissDockContextMenu
                )
            }
            return false
        }

        if dockTarget != nil {
            return false
        } else {
            suppressHover(for: 0.25, untilDockExit: false)
            return false
        }
    }

    private func handleDockAppClick(
        _ target: DockHoverTarget,
        canSuppressDefault: Bool,
        shouldDismissDockContextMenu: Bool
    ) -> Bool {
        guard let app = target.app else {
            hideAndResetHover()
            return false
        }

        guard PrevDockSettings.dockAppClickPreviewEnabled else {
            suppressHover(for: 0.35, untilDockExit: false)
            return false
        }
        guard canSuppressDefault else {
            suppressHover(for: 0.35, untilDockExit: false)
            return false
        }

        let freshPreviews = WindowInventory.cachedWindows(
            for: app,
            refreshedWithin: 1.25
        )
        guard DockClickPreviewState.shouldIntercept(completeCachedWindowCount: freshPreviews?.count) else {
            suppressHover(for: 0.35, untilDockExit: !shouldDismissDockContextMenu)
            return false
        }

        if shouldDismissDockContextMenu && !DockContextMenuController.dismissIfVisible() {
            hideAndResetHover()
            suppressHover(for: 0.35, untilDockExit: false)
            return false
        }
        beginDockAppClick(
            target,
            app: app,
            previews: freshPreviews ?? WindowInventory.cachedWindows(for: app)
        )
        holdSuppressedMouseUp(kind: .left)
        return true
    }

    private func beginDockAppClick(
        _ target: DockHoverTarget,
        app: NSRunningApplication,
        previews: [WindowPreview]
    ) {
        resumePreviewForInteraction()
        refreshes.cancelRefreshRequests(except: target.key)
        refreshes.setThumbnailTargetPID(app.processIdentifier)
        suppression.clearHoverSuppression()
        clearHoverExitGrace()
        clearPendingTarget()
        lastTargetKey = target.key
        lastAnchor = target.anchor
        let now = ProcessInfo.processInfo.systemUptime
        clicks.begin(target: target, app: app, previews: previews, now: now)
    }

    private func handleDockClickEvent(_ event: DockClickPreviewController.Event) {
        switch event {
        case .initial(let target, let app, let previews):
            if previews.count >= 2 {
                previewController?.show(previews: previews, app: app, anchoredTo: target.anchor)
            } else {
                previewController?.hide()
            }
        case .resolved(let target, let app, let resolution, let previews):
            applyDockClickResolution(resolution, target: target, app: app, previews: previews)
        case .discarded(let targetKey):
            guard lastTargetKey == targetKey else { return }
            suppressHover(for: 0.35, untilDockExit: true)
        }
    }

    private func applyDockClickResolution(
        _ resolution: DockClickPreviewState.Resolution,
        target: DockHoverTarget,
        app: NSRunningApplication,
        previews: [WindowPreview]
    ) {
        switch resolution {
        case .showPreview:
            holdClickPreview()
            previewController?.show(previews: previews, app: app, anchoredTo: target.anchor)
            refreshPreviewThumbnails(for: app, expectedTargetKey: target.key)
        case .restoreNativeClick:
            suppressHover(for: 0.35, untilDockExit: true)
        case .keepPreview:
            holdClickPreview()
            refreshPreviewThumbnails(for: app, expectedTargetKey: target.key)
        case .retry:
            break
        }
    }

    private func dockTargetUnderMouseDown(eventMouse: CGPoint, trackedMouse: CGPoint) -> DockHoverTarget? {
        if let target = targetCache.freshTarget(eventMouse) {
            return target
        }
        if eventMouse != trackedMouse, let target = targetCache.freshTarget(trackedMouse) {
            return target
        }
        guard let pendingTarget,
              (ProcessInfo.processInfo.systemUptime - pendingTargetStartedAt) <= pendingTargetClickFallbackLifetime else {
            return nil
        }
        let points = eventMouse == trackedMouse ? [eventMouse] : [eventMouse, trackedMouse]
        let isValidFallback = points.contains { point in
            pendingTarget.anchor.contains(point) &&
                DockGeometryCache.shared.isInDockInteractionStrip(point, refreshIfStale: false)
        }
        return isValidFallback ? pendingTarget : nil
    }

    private func previewContainsMouseDown(eventMouse: CGPoint, trackedMouse: CGPoint) -> Bool {
        if previewController?.contains(eventMouse) == true {
            return true
        }
        guard eventMouse != trackedMouse else { return false }
        return previewController?.contains(trackedMouse) == true
    }

    private func suppressHover(for interval: TimeInterval, untilDockExit: Bool) {
        suppression.suppressHover(for: interval, untilDockExit: untilDockExit)
        hideAndResetHover()
    }

    private func handleFocusTransitionStarted() {
        if let key = lastTargetKey, let anchor = lastAnchor {
            focusReturnTarget = (key, anchor, refreshes.thumbnailTargetPID)
        }
        clicks.advanceGeneration()
        clicks.cancel()
        let mouse = DockCursorTracker.shared.currentMouseLocation(preferEventTap: true)
        let requiresDockExit = DockGeometryCache.shared.isInDockInteractionStrip(mouse, refreshIfStale: false)
        suppressHover(for: 0.35, untilDockExit: requiresDockExit)
        scheduleNextTickIfNeeded()
    }

    private func handleFocusTransitionFinished(success: Bool) {
        let target = focusReturnTarget
        focusReturnTarget = nil
        guard !success, previewController?.isVisible == true, let target else { return }
        suppression.clearHoverSuppression()
        lastTargetKey = target.key
        lastAnchor = target.anchor
        refreshes.setThumbnailTargetPID(target.pid)
        holdClickPreview()
        scheduler.wake()
    }

    private func resumePreviewForInteraction() {
        focusReturnTarget = nil
        previewController?.resumePresentationForInteraction()
    }

    private func cancelFocusForKeyboardNavigation() {
        guard previewController?.isFocusTransitionActive == true else { return }
        resumePreviewForInteraction()
        suppressHover(for: 0.35, untilDockExit: true)
    }

    private func shouldSuppressHover(at mouse: CGPoint) -> Bool {
        if suppression.shouldSuppressDockContextMenu(visibility: {
            DockContextMenuController.visibility()
        }) {
            return true
        }
        return suppression.shouldSuppressHover(
            isStillInDockOrPreview: targetCache.target(mouse) != nil || previewController?.contains(mouse) == true
        )
    }

    private func holdClickPreview() {
        suppression.holdClickPreview(for: 0.35)
    }

    private func shouldHoldClickPreview() -> Bool {
        // A swallowed mouse-down must reach its bounded result even if the pointer leaves the Dock.
        if clicks.isHoldingPendingClick { return true }
        guard previewController?.isVisible == true,
              lastTargetKey != nil else {
            return false
        }
        return suppression.shouldHoldClickPreview()
    }

    private func holdSuppressedMouseUp(kind: MouseDownKind) {
        suppression.holdSuppressedMouseUp(kind: kind)
    }

    private func hideAndResetHover() {
        refreshes.cancelRefreshRequests()
        refreshes.setThumbnailTargetPID(nil)
        previewController?.hide()
        clearHoverExitGrace()
        clearPendingTarget()
        targetCache.clear()
        lastTargetKey = nil
        lastAnchor = nil
        suppression.clearClickPreviewHold()
    }

    private func targetAfterSwitchDelay(_ target: DockHoverTarget, now: TimeInterval) -> DockHoverTarget? {
        if lastTargetKey == target.key {
            clearPendingTarget()
            return target
        }

        let delay = PrevDockSettings.previewSwitchDelay
        guard delay > 0 else {
            clearPendingTarget()
            return target
        }

        if pendingTarget?.key != target.key {
            pendingTarget = target
            pendingTargetStartedAt = now
            return nil
        }

        guard (now - pendingTargetStartedAt) >= delay else {
            return nil
        }

        clearPendingTarget()
        return target
    }

    private func clearPendingTarget() {
        pendingTarget = nil
        pendingTargetStartedAt = -TimeInterval.infinity
    }

    private func shouldDelayPreviewHide(now: TimeInterval) -> Bool {
        guard previewController?.isVisible == true,
              lastTargetKey != nil else {
            clearHoverExitGrace()
            return false
        }

        guard let startedAt = hoverExitStartedAt else {
            hoverExitStartedAt = now
            return true
        }

        return (now - startedAt) < previewHideGraceInterval
    }

    private func clearHoverExitGrace() {
        hoverExitStartedAt = nil
    }

    private func currentMouseLocationForTick() -> CGPoint {
        DockCursorTracker.shared.currentMouseLocation(preferEventTap: true)
    }

    private func scheduleNextTickIfNeeded() {
        guard let interval = nextTickInterval() else { return }
        scheduler.schedule(after: interval)
    }

    private func nextTickInterval() -> TimeInterval? {
        if let hoverExitStartedAt {
            return max(0.01, previewHideGraceInterval - (ProcessInfo.processInfo.systemUptime - hoverExitStartedAt))
        }
        if let interval = suppression.dockContextMenuCheckInterval {
            return interval
        }

        if pendingTarget != nil ||
            previewController?.isVisible == true ||
            isMouseButtonPressed ||
            shouldHoldClickPreview() ||
            suppression.hasShortTimedState {
            return fastTickInterval
        }

        if !inputMonitor.hasGlobalMouseMovedMonitor {
            return fastTickInterval
        }

        return watchdogTickInterval
    }
}
