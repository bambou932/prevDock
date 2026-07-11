import ApplicationServices
import Cocoa

final class DockHoverMonitor {
    private weak var previewController: PreviewPanelController?
    private weak var labelController: DockLabelPanelController?
    private var timer: Timer?
    private var settingsObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var eventMonitors = [Any]()
    private var mouseDownEventTap: CFMachPort?
    private var mouseDownEventTapSource: CFRunLoopSource?
    private var lastEventTapInstallAttempt: TimeInterval = 0
    private var lastTargetKey: String?
    private var lastTarget: DockHoverTarget?
    private var lastMetadataRefresh = Date.distantPast
    private var lastLiveThumbnailRefresh = Date.distantPast
    private var lastAnchor: CGRect?
    private var hoverExitStartedAt: Date?
    private var pendingTarget: DockHoverTarget?
    private var pendingTargetStartedAt = Date.distantPast
    private var lastWarmupByPID = [pid_t: Date]()
    private var cachedHoverTarget: DockHoverTarget?
    private var cachedHoverTargetResolvedAt: TimeInterval = 0
    private var cachedHoverResolutionPoint = CGPoint.zero
    private var hasCachedHoverResolution = false
    private var suppression = DockHoverSuppressionState()
    private var dockClickActionGeneration = 0
    private var previewRequestGeneration = 0
    private var nativeDockMenuGeneration = 0
    private var nativeDockMenuState: NativeDockMenuState?
    private var nativeDockMenuLateCleanup: NativeDockMenuLateCleanup?
    private var nativeDockMenuHoverSessionGeneration = 0
    private var nativeDockMenuPointerOutsideSource = false
    private var nativeDockMenuAttemptLatch: NativeDockMenuAttemptLatch?
    private var nativeDockMenuContainmentRefreshKey: NativeDockMenuContainmentRefreshKey?
    private var dismissedNativeDockMenuHoverSessionGeneration: Int?
    private var dismissedNativeDockMenuAnchor: CGRect?
    private var lastDockContextClick: DockContextClickFingerprint?
    private var wakeTickScheduled = false
    private let nativeDockMenuQueue = DispatchQueue(
        label: "app.prevdock.native-dock-menu",
        qos: .userInitiated
    )
    private let fastTickInterval: TimeInterval = 0.08
    private let watchdogTickInterval: TimeInterval = 1.0
    private let liveThumbnailRefreshInterval: TimeInterval = 0.45
    private let previewWarmupInterval: TimeInterval = 3.0
    private let previewHideGraceInterval: TimeInterval = 0.20
    private let hoverTargetCacheInterval: TimeInterval = 0.12
    private let hoverTargetCachePadding: CGFloat = 3
    private let negativeHoverTargetCacheInterval: TimeInterval = 0.2
    private let negativeHoverTargetCacheRadius: CGFloat = 8
    private let pendingTargetClickFallbackLifetime: TimeInterval = 0.25
    private let nativeDockMenuAppearanceTimeout: TimeInterval = 1.25
    private let nativeDockMenuAbsenceRecheckInterval: TimeInterval = 0.16
    private let dockContextClickDeduplicationInterval: TimeInterval = 0.08
    private let dockContextClickDeduplicationRadius: CGFloat = 4

    init(
        previewController: PreviewPanelController,
        labelController: DockLabelPanelController
    ) {
        self.previewController = previewController
        self.labelController = labelController
    }

    func start() {
        dockClickActionGeneration &+= 1
        previewRequestGeneration &+= 1
        resetNativeDockMenuState()
        lastDockContextClick = nil
        timer?.invalidate()
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
        uninstallMouseDownEventTap()

        installMouseDownEventTap(force: true)
        installMouseEventMonitors()
        installSettingsObserver()
        installSpaceObserver()
        scheduleTick(after: fastTickInterval)
    }

    func wakeForSuppressedMouseMoved() {
        wakeForMouseMoved()
    }

    deinit {
        timer?.invalidate()
        eventMonitors.forEach(NSEvent.removeMonitor)
        uninstallMouseDownEventTap()
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
    }

    private func tick() {
        timer?.invalidate()
        timer = nil
        repairMouseDownEventTapIfNeeded()

        defer {
            scheduleNextTickIfNeeded()
        }

        let mouse = currentMouseLocationForTick()
        updateNativeDockMenuHoverSession(at: mouse)
        previewController?.deactivateStaleHoverEffects(at: mouse)
        let overPreview = previewController?.contains(mouse) == true
        let now = Date()

        serviceNativeDockMenuLateCleanup(now: now)
        if nativeDockMenuLateCleanup?.mode.blocksPresentation == true {
            previewController?.hide()
            labelController?.hide()
            return
        }

        if isMouseButtonPressed {
            if overPreview ||
                shouldHoldClickPreview() ||
                nativeDockMenuState?.needsFastVisibilityChecks == true ||
                dockTargetUnderPointer(mouse) != nil {
                clearHoverExitGrace()
                return
            }
            hideAndResetHover()
            return
        }

        if overPreview {
            clearHoverExitGrace()
            clearPendingTarget()
            labelController?.hide()
            refreshVisiblePreviewThumbnails(now: now)
            return
        }

        if shouldHoldClickPreview() {
            clearHoverExitGrace()
            refreshVisiblePreviewThumbnails(now: now)
            return
        }

        if handleNativeDockMenuState(at: mouse, now: now) {
            return
        }

        if shouldSuppressHover(at: mouse) {
            hideAndResetHover()
            return
        }

        guard AXIsProcessTrusted() else {
            previewController?.hide()
            labelController?.hide()
            clearPendingTarget()
            return
        }

        guard let rawTarget = dockTargetUnderPointer(mouse) else {
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
        warmPreviewCacheIfNeeded(for: rawTarget, now: now)
        guard let target = targetAfterSwitchDelay(rawTarget, now: now) else {
            return
        }

        let targetChanged = lastTargetKey != target.key
        if targetChanged {
            previewRequestGeneration &+= 1
            resetNativeDockMenuState()
        }
        lastTargetKey = target.key
        lastTarget = target

        if targetChanged || lastAnchor == nil {
            lastAnchor = target.anchor
        }

        let anchor = lastAnchor ?? target.anchor

        guard let app = target.app else {
            previewController?.hide()
            if target.showsInactiveLabel {
                if targetChanged {
                    labelController?.hide()
                }
                labelController?.show(title: target.title, anchoredTo: anchor)
            } else {
                labelController?.hide()
            }
            return
        }

        labelController?.hide()

        let panelVisible = previewController?.isVisible == true
        let needsPresentation = targetChanged || !panelVisible
        let freshCachedPreviews = needsPresentation ? WindowInventory.cachedWindows(
            for: app,
            refreshedWithin: 1.0
        ) : nil
        let needsMetadata = needsPresentation ?
            freshCachedPreviews == nil : now.timeIntervalSince(lastMetadataRefresh) > 1.0
        let needsLiveThumbnails = panelVisible &&
            now.timeIntervalSince(lastLiveThumbnailRefresh) > liveThumbnailRefreshInterval
        guard needsPresentation || needsMetadata || needsLiveThumbnails else { return }

        if needsPresentation {
            let cached = freshCachedPreviews ?? WindowInventory.cachedWindows(for: app)
            if cached.isEmpty {
                if targetChanged {
                    previewController?.hide()
                }
            } else {
                presentPreviews(
                    cached,
                    app: app,
                    target: target,
                    anchoredTo: lastAnchor ?? target.anchor
                )
            }
            if freshCachedPreviews != nil {
                lastMetadataRefresh = now
            }
        }

        if needsMetadata {
            lastMetadataRefresh = now
        }
        if needsLiveThumbnails {
            lastLiveThumbnailRefresh = now
        }

        let expectedTargetKey = target.key
        let expectedPreviewRequestGeneration = previewRequestGeneration
        if needsMetadata {
            WindowInventory.refreshWindows(
                for: app,
                thumbnailPolicy: needsLiveThumbnails ? .refreshStale : .missingOnly
            ) { [weak self, weak app] previews in
                guard let self else { return }
                guard let app,
                      self.lastTargetKey == expectedTargetKey,
                      self.previewRequestGeneration == expectedPreviewRequestGeneration else {
                    return
                }
                self.presentPreviews(
                    previews,
                    app: app,
                    target: target,
                    anchoredTo: self.lastAnchor ?? target.anchor
                )
            } thumbnail: { [weak self, weak app] windowID, image in
                guard let self,
                      app != nil,
                      self.lastTargetKey == expectedTargetKey,
                      self.previewRequestGeneration == expectedPreviewRequestGeneration else {
                    return
                }
                self.previewController?.updateThumbnail(windowID: windowID, image: image)
            }
        } else if needsLiveThumbnails {
            WindowInventory.refreshThumbnails(for: app) { [weak self, weak app] windowID, image in
                guard let self,
                      app != nil,
                      self.lastTargetKey == expectedTargetKey,
                      self.previewRequestGeneration == expectedPreviewRequestGeneration else {
                    return
                }
                self.previewController?.updateThumbnail(windowID: windowID, image: image)
            }
        }
    }

    private func refreshVisiblePreviewThumbnails(now: Date) {
        guard previewController?.isVisible == true,
              !WindowPeekController.shared.isShowingLivePreview,
              now.timeIntervalSince(lastLiveThumbnailRefresh) > liveThumbnailRefreshInterval,
              let app = previewController?.visibleApp,
              let expectedTargetKey = lastTargetKey else {
            return
        }

        lastLiveThumbnailRefresh = now
        let expectedPreviewRequestGeneration = previewRequestGeneration
        WindowInventory.refreshThumbnails(for: app) { [weak self, weak app] windowID, image in
            guard let self,
                  app != nil,
                  self.lastTargetKey == expectedTargetKey,
                  self.previewRequestGeneration == expectedPreviewRequestGeneration,
                  self.previewController?.isVisible == true else {
                return
            }
            self.previewController?.updateThumbnail(windowID: windowID, image: image)
        }
    }

    private func deferPresentationForNativeDockMenuLateCleanup(
        previews: [WindowPreview],
        app: NSRunningApplication,
        target: DockHoverTarget,
        anchor: CGRect
    ) -> Bool {
        guard var cleanup = nativeDockMenuLateCleanup else { return false }
        guard cleanup.mode.blocksPresentation else { return false }
        if cleanup.mode.defersPresentation || cleanup.defersProtectedPresentation {
            cleanup.deferredPresentation = NativeDockMenuReplacement(
                previews: previews,
                app: app,
                target: target,
                anchor: anchor
            )
            nativeDockMenuLateCleanup = cleanup
        }
        previewController?.hide()
        labelController?.hide()
        return true
    }

    private func serviceNativeDockMenuLateCleanup(now: Date) {
        guard var cleanup = nativeDockMenuLateCleanup else { return }
        guard now >= cleanup.nextVisibilityProbeAt else { return }
        let visibility = lateCleanupVisibility(&cleanup, now: now)
        if cleanup.didPromoteLateMenu {
            nativeDockMenuLateCleanup = nil
            return
        }
        switch visibility {
        case .visible(let windowIDs):
            cleanup.visiblePopupWindowIDs = windowIDs
            cleanup.missingVisibilityObservations = 0
            cleanup.unknownVisibilityObservations = 0
            cleanup.nextVisibilityProbeAt = now
        case .absent:
            let absenceEligible = NativeDockMenuLifecyclePolicy.absenceIsEligible(
                actionGeneration: cleanup.actionGeneration,
                actionCompleted: cleanup.actionCompletedAt != nil,
                now: now,
                safeAfter: cleanup.safeAfter
            )
            if absenceEligible {
                cleanup.unknownVisibilityObservations = 0
                cleanup.missingVisibilityObservations += 1
                if cleanup.missingVisibilityObservations >= 2 {
                    cleanup.visiblePopupWindowIDs.removeAll()
                }
                cleanup.nextVisibilityProbeAt = now.addingTimeInterval(
                    nativeDockMenuAbsenceRecheckInterval
                )
            } else {
                cleanup.missingVisibilityObservations = 0
                if cleanup.actionGeneration != nil,
                   cleanup.actionCompletedAt == nil,
                   now >= cleanup.absoluteDeadline {
                    cleanup.unknownVisibilityObservations += 1
                    let backoff = NativeDockMenuLifecyclePolicy.visibilityBackoff(
                        unknownObservations: cleanup.unknownVisibilityObservations,
                        baseInterval: fastTickInterval
                    )
                    cleanup.nextVisibilityProbeAt = now.addingTimeInterval(backoff)
                } else {
                    cleanup.unknownVisibilityObservations = 0
                    cleanup.nextVisibilityProbeAt = now
                }
            }
        case .unknown:
            cleanup.missingVisibilityObservations = 0
            cleanup.unknownVisibilityObservations += 1
            let backoff = NativeDockMenuLifecyclePolicy.visibilityBackoff(
                unknownObservations: cleanup.unknownVisibilityObservations,
                baseInterval: fastTickInterval
            )
            cleanup.nextVisibilityProbeAt = now.addingTimeInterval(backoff)
        }

        let contextMenuSettled = cleanup.contextClickTargetKey == nil ||
            cleanup.didObserveContextMenu || now >= cleanup.absoluteDeadline
        let safelyAbsent = cleanup.missingVisibilityObservations >= 2 && contextMenuSettled
        guard safelyAbsent else {
            nativeDockMenuLateCleanup = cleanup
            return
        }

        let deferredPresentation = cleanup.deferredPresentation
        let contextClickTargetKey = cleanup.contextClickTargetKey
        nativeDockMenuLateCleanup = nil
        suppression.clearDockContextMenu()
        if let contextClickTargetKey {
            guard cleanup.didObserveContextMenu else {
                if let deferredPresentation {
                    resumePreviewPresentation(deferredPresentation)
                } else {
                    nativeDockMenuState = nil
                    scheduleWakeTick()
                }
                return
            }
            if NativeDockMenuLifecyclePolicy.shouldLatchDismissal(
                sourceHoverSession: cleanup.hoverSessionGeneration,
                currentHoverSession: nativeDockMenuHoverSessionGeneration
            ) {
                latchDismissedNativeDockMenu(
                    targetKey: contextClickTargetKey,
                    anchor: cleanup.contextClickAnchor ?? cleanup.sourceAnchor ?? .zero,
                    hoverSessionGeneration: cleanup.hoverSessionGeneration
                )
            } else {
                if let deferredPresentation {
                    resumePreviewPresentation(deferredPresentation)
                } else {
                    nativeDockMenuState = nil
                    scheduleWakeTick()
                }
            }
            return
        }
        if let deferredPresentation {
            resumePreviewPresentation(deferredPresentation)
        }
    }

    private func lateCleanupVisibility(
        _ cleanup: inout NativeDockMenuLateCleanup,
        now: Date
    ) -> NativeDockMenuVisibility {
        switch cleanup.mode {
        case .dismissLateMenu:
            guard let anchor = cleanup.sourceAnchor else { return .unknown }
            let visibility = cleanupVisibility(anchoredTo: anchor, cleanup: cleanup)
            return dismissLateCleanupVisibility(visibility, cleanup: &cleanup)
        case .watchLateFallback:
            guard let anchor = cleanup.sourceAnchor else { return .unknown }
            let visibility = cleanupVisibility(anchoredTo: anchor, cleanup: cleanup)
            return lateFallbackVisibility(visibility, cleanup: &cleanup)
        case .protectContextMenu(let phase):
            guard let contextAnchor = cleanup.contextClickAnchor else { return .unknown }
            let contextVisibility = cleanupVisibility(
                anchoredTo: contextAnchor,
                cleanup: cleanup
            )
            let protectedVisibility = contextMenuProtectionVisibility(
                contextVisibility,
                phase: phase,
                cleanup: &cleanup,
                now: now
            )
            return mergeProgrammaticCleanupVisibility(
                protectedVisibility,
                cleanup: &cleanup
            )
        }
    }

    private func cleanupVisibility(
        anchoredTo anchor: CGRect,
        cleanup: NativeDockMenuLateCleanup
    ) -> NativeDockMenuVisibility {
        DockContextMenuController.menuVisibility(
            anchoredTo: anchor,
            forceRefresh: true,
            forceAccessibilityRefresh: cleanup.missingVisibilityObservations > 0
        )
    }

    private func mergeProgrammaticCleanupVisibility(
        _ contextVisibility: NativeDockMenuVisibility,
        cleanup: inout NativeDockMenuLateCleanup
    ) -> NativeDockMenuVisibility {
        guard cleanup.actionGeneration != nil || cleanup.tracksSecondarySource,
              let sourceAnchor = cleanup.sourceAnchor,
              let contextAnchor = cleanup.contextClickAnchor,
              sourceAnchor != contextAnchor else {
            return contextVisibility
        }
        let programmaticVisibility = cleanupVisibility(
            anchoredTo: sourceAnchor,
            cleanup: cleanup
        )
        switch programmaticVisibility {
        case .visible(let programmaticWindowIDs):
            if case .visible(let contextWindowIDs) = contextVisibility,
               !contextWindowIDs.intersection(programmaticWindowIDs).isEmpty {
                return .visible(contextWindowIDs.union(programmaticWindowIDs))
            }
            cleanup.certifiedPopupWindowIDs.formUnion(programmaticWindowIDs)
            DockContextMenuController.dismissMenus(intersecting: programmaticWindowIDs)
            if case .visible(let contextWindowIDs) = contextVisibility {
                return .visible(contextWindowIDs.union(programmaticWindowIDs))
            }
            return .visible(programmaticWindowIDs)
        case .absent:
            return contextVisibility
        case .unknown:
            if case .visible = contextVisibility { return contextVisibility }
            return .unknown
        }
    }

    private func lateFallbackVisibility(
        _ visibility: NativeDockMenuVisibility,
        cleanup: inout NativeDockMenuLateCleanup
    ) -> NativeDockMenuVisibility {
        guard case .visible(let visibleWindowIDs) = visibility else { return visibility }
        cleanup.certifiedPopupWindowIDs = visibleWindowIDs
        previewController?.hide()
        labelController?.hide()
        if let request = cleanup.fallbackWatchRequest,
           NativeDockMenuLifecyclePolicy.canPromoteLateMenu(
            requestGeneration: request.generation,
            cleanupGeneration: cleanup.actionGeneration,
            activeFailedGeneration: activeFailedNativeDockMenuGeneration(for: request.target.key),
            sourceHoverSession: cleanup.hoverSessionGeneration,
            currentHoverSession: nativeDockMenuHoverSessionGeneration
           ),
           canPromoteFallbackCancellation(
            request,
            visibleWindowIDs: visibleWindowIDs,
            mouse: currentMouseLocationForTick()
           ) {
            promoteFallbackCancellation(request, visibleWindowIDs: visibleWindowIDs)
            cleanup.didPromoteLateMenu = true
            return .visible(visibleWindowIDs)
        }
        if cleanup.deferredPresentation == nil,
           let request = cleanup.fallbackWatchRequest {
            cleanup.deferredPresentation = NativeDockMenuReplacement(
                previews: request.previews,
                app: request.app,
                target: request.target,
                anchor: request.anchor
            )
        }
        cleanup.fallbackWatchRequest = nil
        cleanup.mode = .dismissLateMenu
        DockContextMenuController.dismissMenus(intersecting: visibleWindowIDs)
        return .visible(visibleWindowIDs)
    }

    private func dismissLateCleanupVisibility(
        _ visibility: NativeDockMenuVisibility,
        cleanup: inout NativeDockMenuLateCleanup
    ) -> NativeDockMenuVisibility {
        guard case .visible(let visibleWindowIDs) = visibility else { return visibility }
        cleanup.certifiedPopupWindowIDs = visibleWindowIDs
        DockContextMenuController.dismissMenus(intersecting: visibleWindowIDs)
        return .visible(visibleWindowIDs)
    }

    private func contextMenuProtectionVisibility(
        _ visibility: NativeDockMenuVisibility,
        phase: NativeDockMenuContextProtectionPhase,
        cleanup: inout NativeDockMenuLateCleanup,
        now: Date
    ) -> NativeDockMenuVisibility {
        switch visibility {
        case .visible:
            break
        case .absent where cleanup.missingVisibilityObservations >= 1:
            cleanup.contextPopupWindowIDs.removeAll()
        case .absent, .unknown:
            break
        }
        switch phase {
        case .awaitingFirstMenu(let deadline):
            if case .visible(let menuWindowIDs) = visibility {
                cleanup.didObserveContextMenu = true
                nativeDockMenuPointerOutsideSource = false
                cleanup.contextPopupWindowIDs = menuWindowIDs
                cleanup.mode = .protectContextMenu(.protecting(windowIDs: menuWindowIDs))
                cleanup.certifiedPopupWindowIDs = menuWindowIDs
                return visibility
            }
            guard now >= deadline else { return visibility }
            transitionContextCleanupToLateDismissal(
                &cleanup,
                allowsFirstUserMenu: true
            )
            return contextLateDismissalVisibility(visibility, cleanup: &cleanup)
        case .protecting(let protectedWindowIDs):
            if case .visible(let visibleWindowIDs) = visibility {
                cleanup.didObserveContextMenu = true
                cleanup.contextPopupWindowIDs = visibleWindowIDs
                cleanup.mode = .protectContextMenu(
                    .protecting(windowIDs: protectedWindowIDs.union(visibleWindowIDs))
                )
                cleanup.certifiedPopupWindowIDs = visibleWindowIDs
                return visibility
            }
            guard case .absent = visibility,
                  cleanup.missingVisibilityObservations >= 1 else {
                return visibility
            }
            transitionContextCleanupToLateDismissal(
                &cleanup,
                allowsFirstUserMenu: false
            )
            return .absent
        case .dismissingLateMenu:
            return contextLateDismissalVisibility(visibility, cleanup: &cleanup)
        }
    }

    private func contextLateDismissalVisibility(
        _ visibility: NativeDockMenuVisibility,
        cleanup: inout NativeDockMenuLateCleanup
    ) -> NativeDockMenuVisibility {
        if case .protectContextMenu(.dismissingLateMenu(let allowsFirstUserMenu)) = cleanup.mode,
           allowsFirstUserMenu,
           case .visible(let userMenuWindowIDs) = visibility {
            cleanup.didObserveContextMenu = true
            cleanup.contextPopupWindowIDs = userMenuWindowIDs
            cleanup.mode = .protectContextMenu(
                .protecting(windowIDs: userMenuWindowIDs)
            )
            cleanup.certifiedPopupWindowIDs = userMenuWindowIDs
            return visibility
        }
        return dismissLateCleanupVisibility(visibility, cleanup: &cleanup)
    }

    private func transitionContextCleanupToLateDismissal(
        _ cleanup: inout NativeDockMenuLateCleanup,
        allowsFirstUserMenu: Bool
    ) {
        cleanup.mode = .protectContextMenu(
            .dismissingLateMenu(allowsFirstUserMenu: allowsFirstUserMenu)
        )
        cleanup.missingVisibilityObservations = 0
    }

    private func preserveNativeDockMenuLateCleanup(
        from state: NativeDockMenuState,
        policy: NativeDockMenuCleanupPolicy
    ) {
        guard state.actionStartedAt != nil || !state.certifiedPopupWindowIDs.isEmpty else { return }
        guard nativeDockMenuLateCleanup == nil else { return }
        let now = Date()
        let safeAfter = nativeDockMenuSafeAfter(
            actionStartedAt: state.actionStartedAt,
            actionCompletedAt: state.actionCompletedAt,
            now: now
        )
        let absoluteDeadline = max(safeAfter, now).addingTimeInterval(1)
        DockContextMenuController.dismissMenus(intersecting: state.certifiedPopupWindowIDs)
        nativeDockMenuLateCleanup = NativeDockMenuLateCleanup(
            certifiedPopupWindowIDs: state.certifiedPopupWindowIDs,
            mode: policy == .dismissLateMenu ?
                .dismissLateMenu :
                .protectContextMenu(.awaitingFirstMenu(deadline: absoluteDeadline)),
            contextClickTargetKey: nil,
            contextClickAnchor: nil,
            sourceAnchor: state.targetAnchor,
            safeAfter: safeAfter,
            absoluteDeadline: absoluteDeadline,
            actionGeneration: state.actionGeneration,
            actionCompletedAt: state.actionCompletedAt,
            hoverSessionGeneration: nativeDockMenuHoverSessionGeneration
        )
    }

    private func convertLateCleanupForUserContextMenu(target: DockHoverTarget) {
        let now = Date()
        let contextSafeAfter = now.addingTimeInterval(nativeDockMenuAppearanceTimeout + fastTickInterval)
        guard var cleanup = nativeDockMenuLateCleanup else {
            let absoluteDeadline = contextSafeAfter.addingTimeInterval(1)
            nativeDockMenuLateCleanup = NativeDockMenuLateCleanup(
                certifiedPopupWindowIDs: [],
                mode: .protectContextMenu(.awaitingFirstMenu(deadline: absoluteDeadline)),
                contextClickTargetKey: target.key,
                contextClickAnchor: target.anchor,
                sourceAnchor: target.anchor,
                safeAfter: contextSafeAfter,
                absoluteDeadline: absoluteDeadline,
                hoverSessionGeneration: nativeDockMenuHoverSessionGeneration
            )
            nativeDockMenuPointerOutsideSource = false
            return
        }

        let staleWindowIDs = cleanup.certifiedPopupWindowIDs
        if case .protectContextMenu = cleanup.mode {
            // A deliberate later context click may be acting on the already-open user menu.
        } else {
            DockContextMenuController.dismissMenus(intersecting: staleWindowIDs)
        }
        cleanup.safeAfter = max(cleanup.safeAfter, contextSafeAfter)
        cleanup.absoluteDeadline = cleanup.safeAfter.addingTimeInterval(1)
        cleanup.certifiedPopupWindowIDs.removeAll()
        cleanup.mode = .protectContextMenu(
            .awaitingFirstMenu(deadline: cleanup.absoluteDeadline)
        )
        cleanup.contextClickTargetKey = target.key
        cleanup.contextClickAnchor = target.anchor
        if cleanup.actionGeneration == nil, !cleanup.defersProtectedPresentation {
            cleanup.sourceAnchor = target.anchor
        }
        cleanup.hoverSessionGeneration = nativeDockMenuHoverSessionGeneration
        cleanup.missingVisibilityObservations = 0
        cleanup.unknownVisibilityObservations = 0
        cleanup.nextVisibilityProbeAt = .distantPast
        cleanup.visiblePopupWindowIDs.removeAll()
        cleanup.contextPopupWindowIDs.removeAll()
        cleanup.deferredPresentation = nil
        cleanup.fallbackWatchRequest = nil
        cleanup.didObserveContextMenu = false
        cleanup.didPromoteLateMenu = false
        cleanup.defersProtectedPresentation = false
        nativeDockMenuLateCleanup = cleanup
        nativeDockMenuPointerOutsideSource = false
    }

    private func presentPreviews(
        _ previews: [WindowPreview],
        app: NSRunningApplication,
        target: DockHoverTarget,
        anchoredTo anchor: CGRect
    ) {
        guard let previewController else { return }
        if deferPresentationForNativeDockMenuLateCleanup(
            previews: previews,
            app: app,
            target: target,
            anchor: anchor
        ) {
            return
        }
        if updatePresentationForNativeDockMenuState(
            previews: previews,
            app: app,
            target: target,
            anchor: anchor
        ) {
            return
        }

        switch previewController.show(previews: previews, app: app, anchoredTo: anchor) {
        case .shown:
            retireLateFallbackPromotionIfNeeded(
                replacement: NativeDockMenuReplacement(
                    previews: previews,
                    app: app,
                    target: target,
                    anchor: anchor
                )
            )
            return
        case .requiresNativeDockMenu:
            requestNativeDockMenu(
                previews: previews,
                app: app,
                target: target,
                anchor: anchor
            )
        }
    }

    private func updatePresentationForNativeDockMenuState(
        previews: [WindowPreview],
        app: NSRunningApplication,
        target: DockHoverTarget,
        anchor: CGRect
    ) -> Bool {
        guard let state = nativeDockMenuState else { return false }
        guard state.targetKey == target.key else {
            if case .requesting(let request) = state,
               request.awaitingDefinitePreflight {
                beginNativeDockMenuPreflightQuarantine(
                    request,
                    replacement: NativeDockMenuReplacement(
                        previews: previews,
                        app: app,
                        target: target,
                        anchor: anchor
                    ),
                    targetExited: true
                )
                return true
            }
            resetNativeDockMenuState()
            return false
        }

        switch state {
        case .requesting(var request):
            if previewController?.presentationRequirement(
                previews: previews,
                app: app,
                anchoredTo: anchor
            ) == .shown {
                let replacement = NativeDockMenuReplacement(
                    previews: previews,
                    app: app,
                    target: target,
                    anchor: anchor
                )
                if request.awaitingDefinitePreflight {
                    beginNativeDockMenuPreflightQuarantine(
                        request,
                        replacement: replacement,
                        targetExited: false
                    )
                } else if request.actionStartedAt == nil {
                    nativeDockMenuGeneration &+= 1
                    nativeDockMenuState = nil
                    suppression.clearDockContextMenu()
                    _ = previewController?.show(previews: previews, app: app, anchoredTo: anchor)
                    retireLateFallbackPromotionIfNeeded(replacement: replacement)
                } else {
                    beginNativeDockMenuCancellation(
                        from: .requesting(request),
                        targetKey: target.key,
                        replacement: replacement,
                        clickRestoreContext: nil,
                        resumesHover: false
                    )
                }
                return true
            }
            request.updateFallback(previews: previews, app: app, anchor: anchor)
            nativeDockMenuState = .requesting(request)
        case .visible(var request):
            request.updateFallback(previews: previews, app: app, anchor: anchor)
            nativeDockMenuState = .visible(request)
        case .dismissed:
            break
        case .cancelling(var cancellation):
            if previewController?.presentationRequirement(
                previews: previews,
                app: app,
                anchoredTo: anchor
            ) == .shown {
                cancellation.fallbackRequest = nil
                cancellation.replacement = NativeDockMenuReplacement(
                    previews: previews,
                    app: app,
                    target: target,
                    anchor: anchor
                )
                nativeDockMenuState = .cancelling(cancellation)
            } else if var fallbackRequest = cancellation.fallbackRequest {
                fallbackRequest.updateFallback(previews: previews, app: app, anchor: anchor)
                cancellation.fallbackRequest = fallbackRequest
                nativeDockMenuState = .cancelling(cancellation)
            } else if cancellation.replacement != nil {
                cancellation.replacement = NativeDockMenuReplacement(
                    previews: previews,
                    app: app,
                    target: target,
                    anchor: anchor
                )
                nativeDockMenuState = .cancelling(cancellation)
            }
        case .failed(var request):
            request.updateFallback(previews: previews, app: app, anchor: anchor)
            switch previewController?.show(previews: previews, app: app, anchoredTo: anchor) {
            case .shown:
                retireLateFallbackPromotionIfNeeded(
                    replacement: NativeDockMenuReplacement(
                        previews: previews,
                        app: app,
                        target: target,
                        anchor: anchor
                    )
                )
                nativeDockMenuState = .failed(request)
            case .requiresNativeDockMenu, nil:
                nativeDockMenuState = .failed(request)
                updateLateFallbackWatchRequest(request)
                previewController?.showReadableFallback(previews: previews, app: app, anchoredTo: anchor)
            }
        }
        return true
    }

    private func requestNativeDockMenu(
        previews: [WindowPreview],
        app: NSRunningApplication,
        target: DockHoverTarget,
        anchor: CGRect
    ) {
        if deferNativeDockMenuRequestForLateCleanup(
            previews: previews,
            app: app,
            target: target,
            anchor: anchor
        ) {
            return
        }
        nativeDockMenuGeneration &+= 1
        previewRequestGeneration &+= 1
        let preflightVisibility = DockContextMenuController.menuVisibility(
            anchoredTo: target.anchor,
            forceRefresh: true,
            forceAccessibilityRefresh: true
        )
        var request = NativeDockMenuRequest(
            target: target,
            app: app,
            previews: previews,
            anchor: anchor,
            generation: nativeDockMenuGeneration,
            visibilityDeadline: Date().addingTimeInterval(nativeDockMenuAppearanceTimeout),
            hoverSessionGeneration: nativeDockMenuHoverSessionGeneration
        )

        nativeDockMenuPointerOutsideSource = false
        suppression.suppressDockContextMenu(for: 120)
        clearHoverExitGrace()
        clearPendingTarget()
        previewController?.hide()
        labelController?.hide()
        switch NativeDockMenuLifecyclePolicy.preflightDecision(
            visibility: preflightVisibility
        ) {
        case .adoptVisibleMenu(let windowIDs):
            request.awaitingDefinitePreflight = false
            request.certifiedPopupWindowIDs = windowIDs
            nativeDockMenuState = .visible(request)
        case .performAction:
            request.awaitingDefinitePreflight = false
            if restoreReadableFallbackForRepeatedAttempt(request) {
                return
            }
            nativeDockMenuState = .requesting(request)
            performNativeDockMenuAction(request)
        case .wait:
            waitForNativeDockMenuPreflight(&request, now: Date())
        }
    }

    private func deferNativeDockMenuRequestForLateCleanup(
        previews: [WindowPreview],
        app: NSRunningApplication,
        target: DockHoverTarget,
        anchor: CGRect
    ) -> Bool {
        guard var cleanup = nativeDockMenuLateCleanup,
              cleanup.actionGeneration != nil else {
            return false
        }
        cleanup.mode = .dismissLateMenu
        cleanup.fallbackWatchRequest = nil
        cleanup.deferredPresentation = NativeDockMenuReplacement(
            previews: previews,
            app: app,
            target: target,
            anchor: anchor
        )
        nativeDockMenuLateCleanup = cleanup
        previewController?.hide()
        labelController?.hide()
        return true
    }

    private func retireLateFallbackPromotionIfNeeded(
        replacement: NativeDockMenuReplacement
    ) {
        guard var cleanup = nativeDockMenuLateCleanup,
              case .watchLateFallback = cleanup.mode else {
            return
        }
        cleanup.fallbackWatchRequest = nil
        cleanup.deferredPresentation = replacement
        nativeDockMenuLateCleanup = cleanup
    }

    private func updateLateFallbackWatchRequest(_ request: NativeDockMenuRequest) {
        guard var cleanup = nativeDockMenuLateCleanup,
              case .watchLateFallback = cleanup.mode,
              cleanup.actionGeneration == request.generation else {
            return
        }
        cleanup.fallbackWatchRequest = request
        nativeDockMenuLateCleanup = cleanup
    }

    private func performNativeDockMenuAction(_ request: NativeDockMenuRequest) {
        let element = request.target.dockItemElement
        let generation = request.generation
        let targetKey = request.target.key
        let messagingTimeout = Float(nativeDockMenuAppearanceTimeout)
        nativeDockMenuQueue.async { [weak self] in
            guard self?.shouldPerformNativeDockMenuAction(
                generation: generation,
                targetKey: targetKey
            ) == true else {
                return
            }
            _ = AXUIElementSetMessagingTimeout(element, messagingTimeout)
            let result = AXUIElementPerformAction(element, kAXShowMenuAction as CFString)
            DispatchQueue.main.async {
                self?.nativeDockMenuActionCompleted(result, generation: generation)
            }
        }
    }

    private func shouldPerformNativeDockMenuAction(generation: Int, targetKey: String) -> Bool {
        if Thread.isMainThread {
            return validateNativeDockMenuAction(generation: generation, targetKey: targetKey)
        }

        var shouldPerform = false
        DispatchQueue.main.sync { [weak self] in
            shouldPerform = self?.validateNativeDockMenuAction(
                generation: generation,
                targetKey: targetKey
            ) == true
        }
        return shouldPerform
    }

    private func validateNativeDockMenuAction(generation: Int, targetKey: String) -> Bool {
        guard case .requesting(let request) = nativeDockMenuState,
              request.generation == generation,
              request.target.key == targetKey,
              !request.awaitingDefinitePreflight else {
            return false
        }
        let mouse = currentMouseLocationForTick()
        guard targetIsStillHovered(targetKey, at: mouse, allowsAnchorFallback: false) else {
            resetNativeDockMenuState()
            scheduleWakeTick()
            return false
        }
        switch currentNativeDockMenuVisibility(for: request, forceAccessibilityRefresh: true) {
        case .visible(let windowIDs):
            var visibleRequest = request
            visibleRequest.certifiedPopupWindowIDs = windowIDs
            visibleRequest.hoverSessionGeneration = nativeDockMenuHoverSessionGeneration
            nativeDockMenuState = .visible(visibleRequest)
            nativeDockMenuPointerOutsideSource = false
            return false
        case .unknown:
            var waitingRequest = request
            waitForNativeDockMenuPreflight(&waitingRequest, now: Date())
            return false
        case .absent:
            break
        }
        if restoreReadableFallbackForRepeatedAttempt(request) {
            return false
        }
        var startedRequest = request
        startedRequest.actionStartedAt = Date()
        startedRequest.hoverSessionGeneration = nativeDockMenuHoverSessionGeneration
        recordNativeDockMenuAttempt(startedRequest)
        nativeDockMenuState = .requesting(startedRequest)
        return true
    }

    private func waitForNativeDockMenuPreflight(
        _ request: inout NativeDockMenuRequest,
        now: Date
    ) {
        request.awaitingDefinitePreflight = true
        request.missingVisibilityObservations = 0
        request.unknownVisibilityObservations += 1
        let backoff = NativeDockMenuLifecyclePolicy.visibilityBackoff(
            unknownObservations: request.unknownVisibilityObservations,
            baseInterval: fastTickInterval
        )
        request.nextVisibilityProbeAt = now.addingTimeInterval(backoff)
        nativeDockMenuState = .requesting(request)
    }

    private func recordNativeDockMenuAttempt(_ request: NativeDockMenuRequest) {
        nativeDockMenuAttemptLatch = NativeDockMenuAttemptLatch(
            targetKey: request.target.key,
            anchor: request.target.anchor,
            hoverSessionGeneration: nativeDockMenuHoverSessionGeneration,
            actionGeneration: request.generation
        )
    }

    private func alignNativeDockMenuAttempt(
        generation: Int,
        target: DockHoverTarget
    ) {
        guard var attempt = nativeDockMenuAttemptLatch,
              attempt.actionGeneration == generation,
              attempt.targetKey == target.key else {
            return
        }
        attempt.anchor = target.anchor
        attempt.hoverSessionGeneration = nativeDockMenuHoverSessionGeneration
        nativeDockMenuAttemptLatch = attempt
    }

    private func nativeDockMenuAttemptMatchesCurrentHover(targetKey: String) -> Bool {
        guard let attempt = nativeDockMenuAttemptLatch else { return false }
        return attempt.targetKey == targetKey &&
            attempt.hoverSessionGeneration == nativeDockMenuHoverSessionGeneration
    }

    private func restoreReadableFallbackForRepeatedAttempt(
        _ request: NativeDockMenuRequest
    ) -> Bool {
        guard var attempt = nativeDockMenuAttemptLatch,
              NativeDockMenuLifecyclePolicy.shouldSuppressRepeatedAction(
                attemptTargetKey: attempt.targetKey,
                attemptHoverSession: attempt.hoverSessionGeneration,
                attemptGeneration: attempt.actionGeneration,
                targetKey: request.target.key,
                currentHoverSession: nativeDockMenuHoverSessionGeneration,
                requestGeneration: request.generation
              ) else {
            return false
        }

        attempt.anchor = request.target.anchor
        nativeDockMenuAttemptLatch = attempt
        var failedRequest = request
        failedRequest.awaitingDefinitePreflight = false
        failedRequest.certifiedPopupWindowIDs.removeAll()
        failedRequest.actionStartedAt = nil
        failedRequest.actionCompletedAt = nil
        failedRequest.hoverSessionGeneration = attempt.hoverSessionGeneration
        nativeDockMenuState = .failed(failedRequest)
        nativeDockMenuPointerOutsideSource = false
        lastTarget = request.target
        suppression.clearDockContextMenu()
        previewController?.showReadableFallback(
            previews: request.previews,
            app: request.app,
            anchoredTo: request.anchor
        )
        return true
    }

    private func beginNativeDockMenuPreflightQuarantine(
        _ request: NativeDockMenuRequest,
        replacement: NativeDockMenuReplacement?,
        targetExited: Bool
    ) {
        nativeDockMenuGeneration &+= 1
        previewRequestGeneration &+= 1
        nativeDockMenuState = nil
        let sourceHoverSession = request.hoverSessionGeneration
        if targetExited, sourceHoverSession == nativeDockMenuHoverSessionGeneration {
            nativeDockMenuHoverSessionGeneration &+= 1
        }
        let now = Date()
        nativeDockMenuLateCleanup = NativeDockMenuLateCleanup(
            certifiedPopupWindowIDs: [],
            mode: .protectContextMenu(.awaitingFirstMenu(deadline: now)),
            contextClickTargetKey: request.target.key,
            contextClickAnchor: request.target.anchor,
            sourceAnchor: request.target.anchor,
            safeAfter: now,
            absoluteDeadline: now,
            deferredPresentation: replacement,
            actionGeneration: nil,
            actionCompletedAt: nil,
            hoverSessionGeneration: sourceHoverSession,
            defersProtectedPresentation: true,
            tracksSecondarySource: true
        )
        nativeDockMenuPointerOutsideSource = targetExited
        previewController?.hide()
        labelController?.hide()
    }

    private func nativeDockMenuActionCompleted(_ result: AXError, generation: Int) {
        let completedAt = Date()
        recordNativeDockMenuActionCompletionInLateCleanup(
            result,
            generation: generation,
            completedAt: completedAt
        )
        scheduleWakeTick()
        guard case .requesting(var request) = nativeDockMenuState,
              request.generation == generation else {
            recordNativeDockMenuActionCompletionInActiveState(
                result,
                generation: generation,
                completedAt: completedAt
            )
            return
        }
        request.lastActionError = result
        request.actionCompletedAt = completedAt
        nativeDockMenuState = .requesting(request)
        guard result == .invalidUIElement, !request.didRetryResolvedItem else { return }
        retryNativeDockMenuAction(&request)
    }

    private func recordNativeDockMenuActionCompletionInActiveState(
        _ result: AXError,
        generation: Int,
        completedAt: Date
    ) {
        switch nativeDockMenuState {
        case .visible(var request) where request.generation == generation:
            request.lastActionError = result
            request.actionCompletedAt = completedAt
            nativeDockMenuState = .visible(request)
        case .failed(var request) where request.generation == generation:
            request.lastActionError = result
            request.actionCompletedAt = completedAt
            nativeDockMenuState = .failed(request)
        case .cancelling(var cancellation) where cancellation.actionGeneration == generation:
            cancellation.actionCompletedAt = completedAt
            cancellation.safeRestoreAfter = max(
                cancellation.safeRestoreAfter,
                completedAt.addingTimeInterval(nativeDockMenuAppearanceTimeout + fastTickInterval)
            )
            cancellation.nextVisibilityProbeAt = .distantPast
            if var fallbackRequest = cancellation.fallbackRequest {
                fallbackRequest.lastActionError = result
                fallbackRequest.actionCompletedAt = completedAt
                cancellation.fallbackRequest = fallbackRequest
            }
            nativeDockMenuState = .cancelling(cancellation)
        default:
            break
        }
    }

    private func recordNativeDockMenuActionCompletionInLateCleanup(
        _ result: AXError,
        generation: Int,
        completedAt: Date
    ) {
        guard var cleanup = nativeDockMenuLateCleanup,
              cleanup.actionGeneration == generation else {
            return
        }
        cleanup.actionCompletedAt = completedAt
        cleanup.safeAfter = max(
            cleanup.safeAfter,
            completedAt.addingTimeInterval(nativeDockMenuAppearanceTimeout + fastTickInterval)
        )
        cleanup.nextVisibilityProbeAt = .distantPast
        if var fallbackRequest = cleanup.fallbackWatchRequest {
            fallbackRequest.lastActionError = result
            fallbackRequest.actionCompletedAt = completedAt
            cleanup.fallbackWatchRequest = fallbackRequest
        }
        nativeDockMenuLateCleanup = cleanup
    }

    private func retryNativeDockMenuAction(_ request: inout NativeDockMenuRequest) {
        request.didRetryResolvedItem = true
        DockHoverTargetResolver.invalidateDockCache()
        clearCachedHoverTarget()
        guard let resolvedTarget = resolveCurrentDockTarget(matching: request.target.key) else {
            nativeDockMenuState = .requesting(request)
            return
        }

        request.target = resolvedTarget
        request.actionStartedAt = nil
        request.actionCompletedAt = nil
        request.visibilityDeadline = Date().addingTimeInterval(nativeDockMenuAppearanceTimeout)
        nativeDockMenuState = .requesting(request)
        lastTarget = resolvedTarget
        cachedHoverTarget = resolvedTarget
        performNativeDockMenuAction(request)
    }

    private func resolveCurrentDockTarget(matching targetKey: String) -> DockHoverTarget? {
        guard let anchor = lastTarget?.anchor else { return nil }
        let mouse = currentMouseLocationForTick()
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        for point in [mouse, center] {
            if let target = DockHoverTargetResolver.target(at: point), target.key == targetKey {
                return target
            }
        }
        return nil
    }

    private func handleNativeDockMenuState(at mouse: CGPoint, now: Date) -> Bool {
        guard let state = nativeDockMenuState else { return false }
        switch state {
        case .requesting(let request):
            return handleRequestingNativeDockMenu(request, at: mouse, now: now)
        case .visible(let request):
            return handleVisibleNativeDockMenu(request, at: mouse, now: now)
        case .dismissed(let targetKey):
            return holdDismissedNativeDockMenu(targetKey: targetKey, at: mouse)
        case .failed(let request):
            return holdFailedNativeDockMenu(request, at: mouse)
        case .cancelling(let cancellation):
            return handleCancellingNativeDockMenu(cancellation, at: mouse, now: now)
        }
    }

    private func handleRequestingNativeDockMenu(
        _ request: NativeDockMenuRequest,
        at mouse: CGPoint,
        now: Date
    ) -> Bool {
        let targetIsHovered = targetIsStillHovered(
            request.target.key,
            at: mouse,
            allowsAnchorFallback: false
        )
        if request.awaitingDefinitePreflight {
            guard targetIsHovered else {
                beginNativeDockMenuPreflightQuarantine(
                    request,
                    replacement: nil,
                    targetExited: true
                )
                return true
            }
            guard now >= request.nextVisibilityProbeAt else { return true }
            switch currentNativeDockMenuVisibility(
                for: request,
                forceAccessibilityRefresh: true
            ) {
            case .visible(let windowIDs):
                promoteNativeDockMenuRequest(request, visibleWindowIDs: windowIDs)
            case .absent:
                var readyRequest = request
                readyRequest.awaitingDefinitePreflight = false
                readyRequest.visibilityDeadline = now.addingTimeInterval(nativeDockMenuAppearanceTimeout)
                readyRequest.unknownVisibilityObservations = 0
                readyRequest.nextVisibilityProbeAt = .distantPast
                if restoreReadableFallbackForRepeatedAttempt(readyRequest) {
                    return true
                }
                nativeDockMenuState = .requesting(readyRequest)
                performNativeDockMenuAction(readyRequest)
            case .unknown:
                var waitingRequest = request
                waitForNativeDockMenuPreflight(&waitingRequest, now: now)
            }
            return true
        }
        let visibility = currentNativeDockMenuVisibility(for: request)
        if case .visible(let windowIDs) = visibility,
           targetIsHovered || DockContextMenuController.popupContains(mouse, windowIDs: windowIDs) {
            promoteNativeDockMenuRequest(request, visibleWindowIDs: windowIDs)
            return true
        }
        guard targetIsHovered else {
            guard now >= request.visibilityDeadline else { return true }
            beginNativeDockMenuCancellation(
                from: .requesting(request),
                targetKey: request.target.key,
                replacement: nil,
                fallbackRequest: request,
                shouldShowReadableFallback: false,
                clickRestoreContext: nil,
                resumesHover: true
            )
            return true
        }
        guard now >= request.visibilityDeadline else { return true }
        beginNativeDockMenuCancellation(
            from: .requesting(request),
            targetKey: request.target.key,
            replacement: nil,
            fallbackRequest: request,
            clickRestoreContext: nil,
            resumesHover: false
        )
        return true
    }

    private func promoteNativeDockMenuRequest(
        _ request: NativeDockMenuRequest,
        visibleWindowIDs: Set<CGWindowID>
    ) {
        var visibleRequest = request
        visibleRequest.awaitingDefinitePreflight = false
        visibleRequest.certifiedPopupWindowIDs = visibleWindowIDs
        visibleRequest.hoverSessionGeneration = nativeDockMenuHoverSessionGeneration
        visibleRequest.missingVisibilityObservations = 0
        visibleRequest.unknownVisibilityObservations = 0
        visibleRequest.nextVisibilityProbeAt = .distantPast
        nativeDockMenuState = .visible(visibleRequest)
        alignNativeDockMenuAttempt(
            generation: request.generation,
            target: request.target
        )
        nativeDockMenuPointerOutsideSource = false
    }

    private func handleVisibleNativeDockMenu(
        _ request: NativeDockMenuRequest,
        at mouse: CGPoint,
        now: Date
    ) -> Bool {
        guard now >= request.nextVisibilityProbeAt else { return true }
        switch currentNativeDockMenuVisibility(for: request) {
        case .visible(let windowIDs):
            var updatedRequest = request
            updatedRequest.certifiedPopupWindowIDs = windowIDs
            updatedRequest.missingVisibilityObservations = 0
            updatedRequest.unknownVisibilityObservations = 0
            updatedRequest.nextVisibilityProbeAt = now
            nativeDockMenuState = .visible(updatedRequest)
        case .absent:
            observeMissingNativeDockMenu(request, now: now)
        case .unknown:
            observeUnknownNativeDockMenuVisibility(request, now: now)
        }
        return true
    }

    private func currentNativeDockMenuVisibility(
        for request: NativeDockMenuRequest,
        forceAccessibilityRefresh: Bool = false
    ) -> NativeDockMenuVisibility {
        DockContextMenuController.menuVisibility(
            anchoredTo: request.target.anchor,
            forceRefresh: true,
            forceAccessibilityRefresh: forceAccessibilityRefresh ||
                request.missingVisibilityObservations > 0
        )
    }

    private func observeMissingNativeDockMenu(_ request: NativeDockMenuRequest, now: Date) {
        var updatedRequest = request
        updatedRequest.missingVisibilityObservations += 1
        updatedRequest.unknownVisibilityObservations = 0
        updatedRequest.nextVisibilityProbeAt = now.addingTimeInterval(
            nativeDockMenuAbsenceRecheckInterval
        )
        guard updatedRequest.missingVisibilityObservations >= 2 else {
            nativeDockMenuState = .visible(updatedRequest)
            return
        }

        finishVisibleNativeDockMenuSession(updatedRequest)
    }

    private func observeUnknownNativeDockMenuVisibility(
        _ request: NativeDockMenuRequest,
        now: Date
    ) {
        var updatedRequest = request
        updatedRequest.unknownVisibilityObservations += 1
        updatedRequest.missingVisibilityObservations = 0
        let backoff = NativeDockMenuLifecyclePolicy.visibilityBackoff(
            unknownObservations: updatedRequest.unknownVisibilityObservations,
            baseInterval: fastTickInterval
        )
        updatedRequest.nextVisibilityProbeAt = now.addingTimeInterval(backoff)
        nativeDockMenuState = .visible(updatedRequest)
    }

    private func finishVisibleNativeDockMenuSession(_ request: NativeDockMenuRequest) {
        suppression.clearDockContextMenu()
        guard NativeDockMenuLifecyclePolicy.shouldLatchDismissal(
            sourceHoverSession: request.hoverSessionGeneration,
            currentHoverSession: nativeDockMenuHoverSessionGeneration
        ) else {
            nativeDockMenuState = nil
            scheduleWakeTick()
            return
        }
        latchDismissedNativeDockMenu(
            targetKey: request.target.key,
            anchor: request.target.anchor,
            hoverSessionGeneration: request.hoverSessionGeneration
        )
    }

    private func latchDismissedNativeDockMenu(
        targetKey: String,
        anchor: CGRect,
        hoverSessionGeneration: Int
    ) {
        dismissedNativeDockMenuAnchor = anchor
        dismissedNativeDockMenuHoverSessionGeneration = hoverSessionGeneration
        nativeDockMenuState = .dismissed(targetKey: targetKey)
        nativeDockMenuPointerOutsideSource = false
    }

    private func activeFailedNativeDockMenuGeneration(for targetKey: String) -> Int? {
        guard case .failed(let activeRequest) = nativeDockMenuState,
              activeRequest.target.key == targetKey else {
            return nil
        }
        return activeRequest.generation
    }

    private func handleCancellingNativeDockMenu(
        _ cancellation: NativeDockMenuCancellation,
        at mouse: CGPoint,
        now: Date
    ) -> Bool {
        var updatedCancellation = cancellation
        guard now >= updatedCancellation.nextVisibilityProbeAt else { return true }
        let visibility = cancellationVisibility(updatedCancellation)
        let actionSettled = cancellation.actionStartedAt == nil ||
            updatedCancellation.actionCompletedAt != nil
        let absenceWindowOpen = NativeDockMenuLifecyclePolicy.absenceIsEligible(
            actionGeneration: cancellation.actionGeneration,
            actionCompleted: actionSettled,
            now: now,
            safeAfter: updatedCancellation.safeRestoreAfter
        )
        switch visibility {
        case .visible(let visibleWindowIDs):
            updatedCancellation.certifiedPopupWindowIDs = visibleWindowIDs
            updatedCancellation.missingVisibilityObservations = 0
            updatedCancellation.unknownVisibilityObservations = 0
            updatedCancellation.nextVisibilityProbeAt = now
            updatedCancellation.didObserveCertifiedMenu = true
            if let fallbackRequest = updatedCancellation.fallbackRequest,
               canPromoteFallbackCancellation(
                fallbackRequest,
                visibleWindowIDs: visibleWindowIDs,
                mouse: mouse
               ) {
                promoteFallbackCancellation(
                    fallbackRequest,
                    visibleWindowIDs: visibleWindowIDs
                )
                return true
            }
            DockContextMenuController.dismissMenus(intersecting: visibleWindowIDs)
        case .absent:
            if absenceWindowOpen {
                updatedCancellation.unknownVisibilityObservations = 0
                updatedCancellation.missingVisibilityObservations += 1
                updatedCancellation.nextVisibilityProbeAt = now.addingTimeInterval(
                    nativeDockMenuAbsenceRecheckInterval
                )
            } else {
                updatedCancellation.missingVisibilityObservations = 0
                if !actionSettled, now >= updatedCancellation.forcedFallbackDeadline {
                    updatedCancellation.unknownVisibilityObservations += 1
                    let backoff = NativeDockMenuLifecyclePolicy.visibilityBackoff(
                        unknownObservations: updatedCancellation.unknownVisibilityObservations,
                        baseInterval: fastTickInterval
                    )
                    updatedCancellation.nextVisibilityProbeAt = now.addingTimeInterval(backoff)
                } else {
                    updatedCancellation.unknownVisibilityObservations = 0
                    updatedCancellation.nextVisibilityProbeAt = now
                }
            }
        case .unknown:
            updatedCancellation.missingVisibilityObservations = 0
            updatedCancellation.unknownVisibilityObservations += 1
            let backoff = NativeDockMenuLifecyclePolicy.visibilityBackoff(
                unknownObservations: updatedCancellation.unknownVisibilityObservations,
                baseInterval: fastTickInterval
            )
            updatedCancellation.nextVisibilityProbeAt = now.addingTimeInterval(backoff)
        }

        guard absenceWindowOpen,
              updatedCancellation.missingVisibilityObservations >= 2 else {
            nativeDockMenuState = .cancelling(updatedCancellation)
            return true
        }
        finishNativeDockMenuCancellation(updatedCancellation, menuClosed: true)
        return true
    }

    private func cancellationVisibility(
        _ cancellation: NativeDockMenuCancellation
    ) -> NativeDockMenuVisibility {
        DockContextMenuController.menuVisibility(
            anchoredTo: cancellation.targetAnchor,
            forceRefresh: true,
            forceAccessibilityRefresh: cancellation.missingVisibilityObservations > 0
        )
    }

    private func canPromoteFallbackCancellation(
        _ request: NativeDockMenuRequest,
        visibleWindowIDs: Set<CGWindowID>,
        mouse: CGPoint
    ) -> Bool {
        targetIsStillHovered(
            request.target.key,
            at: mouse,
            allowsAnchorFallback: false
        ) || DockContextMenuController.popupContains(mouse, windowIDs: visibleWindowIDs)
    }

    private func promoteFallbackCancellation(
        _ request: NativeDockMenuRequest,
        visibleWindowIDs: Set<CGWindowID>
    ) {
        var visibleRequest = request
        visibleRequest.certifiedPopupWindowIDs = visibleWindowIDs
        visibleRequest.missingVisibilityObservations = 0
        visibleRequest.unknownVisibilityObservations = 0
        visibleRequest.nextVisibilityProbeAt = .distantPast
        visibleRequest.hoverSessionGeneration = nativeDockMenuHoverSessionGeneration
        nativeDockMenuState = .visible(visibleRequest)
        alignNativeDockMenuAttempt(
            generation: request.generation,
            target: request.target
        )
        nativeDockMenuPointerOutsideSource = false
    }

    private func finishNativeDockMenuCancellation(
        _ cancellation: NativeDockMenuCancellation,
        menuClosed: Bool
    ) {
        guard menuClosed else {
            finishCancelledNativeDockMenuLatch(cancellation)
            return
        }

        suppression.clearDockContextMenu()
        restoreSuppressedDockClickIfCurrent(cancellation.clickRestoreContext)
        if let replacement = cancellation.replacement {
            if cancellation.actionStartedAt != nil,
               !cancellation.didObserveCertifiedMenu {
                beginNativeDockMenuLateDismissal(
                    cancellation: cancellation,
                    deferredPresentation: replacement,
                    keepsDismissedLatch: false
                )
                return
            }
            resumePreviewPresentation(replacement)
            return
        }
        if cancellation.didObserveCertifiedMenu {
            finishCancelledNativeDockMenuLatch(cancellation)
            return
        }
        if let fallbackRequest = cancellation.fallbackRequest,
           cancellation.shouldShowReadableFallback {
            guard NativeDockMenuLifecyclePolicy.shouldLatchDismissal(
                sourceHoverSession: cancellation.hoverSessionGeneration,
                currentHoverSession: nativeDockMenuHoverSessionGeneration
            ) else {
                if cancellation.actionStartedAt != nil {
                    beginNativeDockMenuLateDismissal(
                        cancellation: cancellation,
                        deferredPresentation: NativeDockMenuReplacement(
                            previews: fallbackRequest.previews,
                            app: fallbackRequest.app,
                            target: fallbackRequest.target,
                            anchor: fallbackRequest.anchor
                        ),
                        keepsDismissedLatch: false
                    )
                } else {
                    nativeDockMenuState = nil
                    scheduleWakeTick()
                }
                return
            }
            if cancellation.actionStartedAt != nil {
                beginNativeDockMenuLateFallbackWatch(
                    cancellation: cancellation,
                    request: fallbackRequest
                )
            }
            resumeReadableFallback(fallbackRequest)
            return
        }
        if cancellation.actionStartedAt != nil {
            beginNativeDockMenuLateDismissal(
                cancellation: cancellation,
                deferredPresentation: nil,
                keepsDismissedLatch: !cancellation.resumesHover
            )
            return
        }
        if cancellation.resumesHover {
            nativeDockMenuState = nil
            scheduleWakeTick()
        } else {
            finishCancelledNativeDockMenuLatch(cancellation)
        }
    }

    private func finishCancelledNativeDockMenuLatch(_ cancellation: NativeDockMenuCancellation) {
        guard NativeDockMenuLifecyclePolicy.shouldLatchDismissal(
            sourceHoverSession: cancellation.hoverSessionGeneration,
            currentHoverSession: nativeDockMenuHoverSessionGeneration
        ) else {
            nativeDockMenuState = nil
            scheduleWakeTick()
            return
        }
        latchDismissedNativeDockMenu(
            targetKey: cancellation.targetKey,
            anchor: cancellation.targetAnchor,
            hoverSessionGeneration: cancellation.hoverSessionGeneration
        )
    }

    private func beginNativeDockMenuLateFallbackWatch(
        cancellation: NativeDockMenuCancellation,
        request: NativeDockMenuRequest
    ) {
        let now = Date()
        let safeAfter = now.addingTimeInterval(nativeDockMenuAppearanceTimeout + fastTickInterval)
        nativeDockMenuLateCleanup = NativeDockMenuLateCleanup(
            certifiedPopupWindowIDs: cancellation.certifiedPopupWindowIDs,
            mode: .watchLateFallback,
            contextClickTargetKey: nil,
            contextClickAnchor: nil,
            sourceAnchor: request.target.anchor,
            safeAfter: safeAfter,
            absoluteDeadline: safeAfter.addingTimeInterval(1),
            fallbackWatchRequest: request,
            actionGeneration: cancellation.actionGeneration,
            actionCompletedAt: cancellation.actionCompletedAt,
            hoverSessionGeneration: nativeDockMenuHoverSessionGeneration
        )
        nativeDockMenuPointerOutsideSource = false
    }

    private func beginNativeDockMenuLateDismissal(
        cancellation: NativeDockMenuCancellation,
        deferredPresentation: NativeDockMenuReplacement?,
        keepsDismissedLatch: Bool
    ) {
        let now = Date()
        let safeAfter = now.addingTimeInterval(nativeDockMenuAppearanceTimeout + fastTickInterval)
        nativeDockMenuLateCleanup = NativeDockMenuLateCleanup(
            certifiedPopupWindowIDs: cancellation.certifiedPopupWindowIDs,
            mode: .dismissLateMenu,
            contextClickTargetKey: nil,
            contextClickAnchor: nil,
            sourceAnchor: cancellation.targetAnchor,
            safeAfter: safeAfter,
            absoluteDeadline: safeAfter.addingTimeInterval(1),
            deferredPresentation: deferredPresentation,
            actionGeneration: cancellation.actionGeneration,
            actionCompletedAt: cancellation.actionCompletedAt,
            hoverSessionGeneration: cancellation.hoverSessionGeneration
        )
        if keepsDismissedLatch {
            finishCancelledNativeDockMenuLatch(cancellation)
        } else {
            nativeDockMenuState = nil
        }
        nativeDockMenuPointerOutsideSource = false
    }

    private func restoreSuppressedDockClickIfCurrent(_ context: DockClickRestoreContext?) {
        guard let context,
              dockClickActionGeneration == context.actionGeneration,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == context.frontmostPIDAtAction else {
            return
        }
        restoreSuppressedDockClick(for: context.app)
    }

    private func resumePreviewPresentation(_ replacement: NativeDockMenuReplacement) {
        nativeDockMenuState = nil
        let mouse = currentMouseLocationForTick()
        guard let target = currentTarget(at: mouse), target.key == replacement.target.key else {
            scheduleWakeTick()
            return
        }
        lastTarget = target
        presentPreviews(
            replacement.previews,
            app: replacement.app,
            target: target,
            anchoredTo: replacement.anchor
        )
    }

    private func resumeReadableFallback(_ request: NativeDockMenuRequest) {
        var failedRequest = request
        failedRequest.actionStartedAt = nil
        failedRequest.certifiedPopupWindowIDs.removeAll()
        nativeDockMenuState = .failed(failedRequest)
        let mouse = currentMouseLocationForTick()
        guard let target = currentTarget(at: mouse), target.key == request.target.key else {
            scheduleWakeTick()
            return
        }

        failedRequest.target = target
        nativeDockMenuState = .failed(failedRequest)
        switch previewController?.show(
            previews: failedRequest.previews,
            app: failedRequest.app,
            anchoredTo: failedRequest.anchor
        ) {
        case .shown:
            retireLateFallbackPromotionIfNeeded(
                replacement: NativeDockMenuReplacement(
                    previews: failedRequest.previews,
                    app: failedRequest.app,
                    target: target,
                    anchor: failedRequest.anchor
                )
            )
            return
        case .requiresNativeDockMenu, nil:
            break
        }
        nativeDockMenuState = .failed(failedRequest)
        logNativeDockMenuFailure(failedRequest)
        previewController?.showReadableFallback(
            previews: failedRequest.previews,
            app: failedRequest.app,
            anchoredTo: failedRequest.anchor
        )
    }

    private func cancelNativeDockMenuBeforeClickRestore(
        targetKey: String,
        clickRestoreContext: DockClickRestoreContext?
    ) -> Bool {
        guard let state = nativeDockMenuState,
              state.targetKey == targetKey,
              state.blocksPreviewInterception(for: targetKey) else {
            return false
        }

        beginNativeDockMenuCancellation(
            from: state,
            targetKey: targetKey,
            replacement: nil,
            clickRestoreContext: clickRestoreContext,
            resumesHover: false
        )
        return true
    }

    private func beginNativeDockMenuCancellation(
        from state: NativeDockMenuState,
        targetKey: String,
        replacement: NativeDockMenuReplacement?,
        fallbackRequest: NativeDockMenuRequest? = nil,
        shouldShowReadableFallback: Bool = true,
        clickRestoreContext: DockClickRestoreContext?,
        resumesHover: Bool
    ) {
        nativeDockMenuGeneration &+= 1
        previewRequestGeneration &+= 1
        let now = Date()
        let safeRestoreAfter = nativeDockMenuSafeAfter(
            actionStartedAt: state.actionStartedAt,
            actionCompletedAt: state.actionCompletedAt,
            now: now
        )
        let absoluteDeadline = max(safeRestoreAfter, now).addingTimeInterval(1)
        let forcedFallbackDeadline = absoluteDeadline.addingTimeInterval(
            nativeDockMenuAppearanceTimeout + fastTickInterval
        )
        let cancellationHoverSession = state.hoverSessionGeneration ??
            nativeDockMenuHoverSessionGeneration
        if resumesHover, cancellationHoverSession == nativeDockMenuHoverSessionGeneration {
            nativeDockMenuHoverSessionGeneration &+= 1
            nativeDockMenuPointerOutsideSource = true
        }
        nativeDockMenuState = .cancelling(NativeDockMenuCancellation(
            targetKey: targetKey,
            targetAnchor: state.targetAnchor,
            replacement: replacement,
            fallbackRequest: fallbackRequest,
            clickRestoreContext: clickRestoreContext,
            resumesHover: resumesHover,
            shouldShowReadableFallback: shouldShowReadableFallback,
            certifiedPopupWindowIDs: state.certifiedPopupWindowIDs,
            actionStartedAt: state.actionStartedAt,
            safeRestoreAfter: safeRestoreAfter,
            forcedFallbackDeadline: forcedFallbackDeadline,
            actionGeneration: state.actionGeneration,
            actionCompletedAt: state.actionCompletedAt,
            didObserveCertifiedMenu: !state.certifiedPopupWindowIDs.isEmpty,
            hoverSessionGeneration: cancellationHoverSession
        ))
        previewController?.hide()
        labelController?.hide()
        suppression.suppressDockContextMenu(for: 3)
        DockContextMenuController.dismissMenus(intersecting: state.certifiedPopupWindowIDs)
    }

    private func nativeDockMenuSafeAfter(
        actionStartedAt: Date?,
        actionCompletedAt: Date?,
        now: Date
    ) -> Date {
        let quietInterval = nativeDockMenuAppearanceTimeout + fastTickInterval
        return NativeDockMenuLifecyclePolicy.safeAfter(
            actionStartedAt: actionStartedAt,
            actionCompletedAt: actionCompletedAt,
            quietInterval: quietInterval,
            now: now
        )
    }

    private func cancelNativeDockMenuForHoverResetIfNeeded() -> Bool {
        guard let state = nativeDockMenuState else { return false }
        switch state {
        case .requesting(let request) where request.awaitingDefinitePreflight:
            beginNativeDockMenuPreflightQuarantine(
                request,
                replacement: nil,
                targetExited: true
            )
            clearHoverTrackingWhileNativeMenuCancels()
            return true
        case .requesting, .visible:
            beginNativeDockMenuCancellation(
                from: state,
                targetKey: state.targetKey,
                replacement: nil,
                clickRestoreContext: nil,
                resumesHover: true
            )
            clearHoverTrackingWhileNativeMenuCancels()
            return true
        case .dismissed, .failed, .cancelling:
            return false
        }
    }

    private func clearHoverTrackingWhileNativeMenuCancels() {
        clearHoverExitGrace()
        clearPendingTarget()
        clearCachedHoverTarget()
        lastTargetKey = nil
        lastTarget = nil
        lastAnchor = nil
        suppression.clearClickPreviewHold()
    }

    private func holdDismissedNativeDockMenu(targetKey: String, at mouse: CGPoint) -> Bool {
        guard let sourceHoverSession = dismissedNativeDockMenuHoverSessionGeneration,
              NativeDockMenuLifecyclePolicy.shouldLatchDismissal(
                sourceHoverSession: sourceHoverSession,
                currentHoverSession: nativeDockMenuHoverSessionGeneration
              ) else {
            resetNativeDockMenuState()
            return false
        }
        guard targetIsStillHovered(targetKey, at: mouse) else {
            resetNativeDockMenuState()
            return false
        }
        return true
    }

    private func holdFailedNativeDockMenu(_ request: NativeDockMenuRequest, at mouse: CGPoint) -> Bool {
        guard nativeDockMenuAttemptMatchesCurrentHover(targetKey: request.target.key),
              targetIsStillHovered(request.target.key, at: mouse) else {
            resetNativeDockMenuState()
            return false
        }
        return false
    }

    private func logNativeDockMenuFailure(_ request: NativeDockMenuRequest) {
        let errorDescription = request.lastActionError.map { String(describing: $0) } ?? "no AX result"
        NSLog(
            "prevDock: native Dock menu did not become visible for %@ (%@); using readable fallback",
            request.target.key,
            errorDescription
        )
    }

    private func targetIsStillHovered(
        _ targetKey: String,
        at mouse: CGPoint,
        allowsAnchorFallback: Bool = true
    ) -> Bool {
        if let target = freshDockTargetUnderPointer(mouse) {
            guard target.key == targetKey else { return false }
            lastTarget = target
            return true
        }
        guard allowsAnchorFallback,
              let lastTarget,
              lastTarget.key == targetKey,
              lastTarget.anchor.insetBy(dx: -hoverTargetCachePadding, dy: -hoverTargetCachePadding).contains(mouse),
              DockGeometryCache.shared.isInDockInteractionStrip(mouse, refreshIfStale: false) else {
            return false
        }
        return true
    }

    private func currentTarget(at mouse: CGPoint) -> DockHoverTarget? {
        if let target = freshDockTargetUnderPointer(mouse) {
            return target
        }
        guard let lastTarget, lastTarget.anchor.contains(mouse) else { return nil }
        return resolveCurrentDockTarget(matching: lastTarget.key)
    }

    private func resetNativeDockMenuState(
        cleanupPolicy: NativeDockMenuCleanupPolicy = .dismissLateMenu
    ) {
        guard let state = nativeDockMenuState else {
            dismissedNativeDockMenuAnchor = nil
            dismissedNativeDockMenuHoverSessionGeneration = nil
            nativeDockMenuPointerOutsideSource = false
            return
        }
        if case .requesting(let request) = state,
           request.awaitingDefinitePreflight {
            beginNativeDockMenuPreflightQuarantine(
                request,
                replacement: nil,
                targetExited: true
            )
            return
        }
        preserveNativeDockMenuLateCleanup(from: state, policy: cleanupPolicy)
        nativeDockMenuState = nil
        dismissedNativeDockMenuAnchor = nil
        dismissedNativeDockMenuHoverSessionGeneration = nil
        nativeDockMenuPointerOutsideSource = false
        nativeDockMenuGeneration &+= 1
        suppression.clearDockContextMenu()
    }

    private func warmPreviewCacheIfNeeded(for target: DockHoverTarget, now: Date) {
        guard let app = target.app else { return }
        let switchDelay = PrevDockSettings.previewSwitchDelay
        if switchDelay > 0 {
            let warmupDelay = min(switchDelay, fastTickInterval)
            guard pendingTarget?.key == target.key,
                  now.timeIntervalSince(pendingTargetStartedAt) >= warmupDelay else {
                return
            }
        }
        guard WindowInventory.cachedWindows(
            for: app,
            refreshedWithin: previewWarmupInterval
        ) == nil else {
            return
        }
        let pid = app.processIdentifier
        guard now.timeIntervalSince(lastWarmupByPID[pid, default: .distantPast]) > previewWarmupInterval else {
            return
        }

        lastWarmupByPID[pid] = now
        if lastWarmupByPID.count > 32 {
            lastWarmupByPID = lastWarmupByPID.filter {
                now.timeIntervalSince($0.value) <= previewWarmupInterval
            }
        }
        WindowInventory.warmPreviewCache(for: app)
    }

    private var isMouseButtonPressed: Bool {
        NSEvent.pressedMouseButtons & 0b111 != 0
    }

    private func installMouseEventMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            DispatchQueue.main.async {
                self?.handleMouseDown(event)
            }
        }) {
            eventMonitors.append(global)
        }

        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handleMouseDown(event)
            return event
        }) {
            eventMonitors.append(local)
        }
    }

    private func installMouseDownEventTap(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastEventTapInstallAttempt >= 5 else { return }
        lastEventTapInstallAttempt = now
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.leftMouseUp.rawValue) |
            CGEventMask(1 << CGEventType.leftMouseDragged.rawValue) |
            CGEventMask(1 << CGEventType.rightMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.otherMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.rightMouseUp.rawValue) |
            CGEventMask(1 << CGEventType.otherMouseUp.rawValue) |
            CGEventMask(1 << CGEventType.rightMouseDragged.rawValue) |
            CGEventMask(1 << CGEventType.otherMouseDragged.rawValue) |
            CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.mouseDownEventCallback,
            userInfo: refcon
        ) else {
            NSLog("prevDock: failed to install Dock mouse-down event tap")
            return
        }

        mouseDownEventTap = tap
        mouseDownEventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let mouseDownEventTapSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), mouseDownEventTapSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func uninstallMouseDownEventTap() {
        if let tap = mouseDownEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = mouseDownEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        mouseDownEventTap = nil
        mouseDownEventTapSource = nil
    }

    private func repairMouseDownEventTapIfNeeded() {
        guard let tap = mouseDownEventTap else {
            installMouseDownEventTap()
            return
        }
        guard !CFMachPortIsValid(tap) || !CGEvent.tapIsEnabled(tap: tap) else { return }
        uninstallMouseDownEventTap()
        installMouseDownEventTap()
    }

    private static let mouseDownEventCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<DockHoverMonitor>.fromOpaque(refcon).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = monitor.mouseDownEventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .mouseMoved {
            let mouse = DockCursorTracker.shared.updateFromEventTap(quartzPoint: event.location)
            monitor.recordNativeDockMenuMouseMoved(at: mouse)
            monitor.wakeForMouseMoved()
            return Unmanaged.passUnretained(event)
        }

        if let kind = MouseDownKind(cgMouseDraggedEventType: type) {
            DockCursorTracker.shared.updateFromEventTap(quartzPoint: event.location)
            return monitor.shouldSuppressMouseDragFromEventTap(kind: kind) ? nil : Unmanaged.passUnretained(event)
        }

        if let kind = MouseDownKind(cgMouseUpEventType: type) {
            return monitor.shouldSuppressMouseUpFromEventTap(kind: kind) ? nil : Unmanaged.passUnretained(event)
        }

        guard let kind = MouseDownKind(cgEventType: type) else {
            return Unmanaged.passUnretained(event)
        }

        let mouse = DockCursorTracker.shared.updateFromEventTap(quartzPoint: event.location)
        let suppress = monitor.handleMouseDownFromEventTap(
            kind: kind,
            isContextClick: kind.isContextClick(eventFlags: event.flags),
            allowsPreviewInterception: kind.allowsPreviewInterception(eventFlags: event.flags),
            mouse: mouse,
            eventTimestamp: TimeInterval(event.timestamp) / 1_000_000_000
        )
        return suppress ? nil : Unmanaged.passUnretained(event)
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
        dockClickActionGeneration &+= 1
        clearCachedHoverTarget()
        if cancelNativeDockMenuForHoverResetIfNeeded() {
            return
        }
        hideAndResetHover()
    }

    private func handleSettingsChange(key: String?) {
        clearPendingTarget()
        suppression.clearClickPreviewHold()
        let presentationKeys: Set<String> = [
            PrevDockSettings.previewOverflowModeKey,
            PrevDockSettings.previewContentSizeKey,
            PrevDockSettings.previewWindowHeightKey,
            PrevDockSettings.previewCloseButtonEnabledKey,
            PrevDockSettings.previewDesktopGroupingEnabledKey
        ]
        if let key, !presentationKeys.contains(key) { return }
        guard previewController?.isVisible == true || nativeDockMenuState != nil,
              let target = lastTarget,
              let app = target.app else {
            return
        }

        let previews = WindowInventory.cachedWindows(for: app)
        guard !previews.isEmpty else { return }
        presentPreviews(
            previews,
            app: app,
            target: target,
            anchoredTo: lastAnchor ?? target.anchor
        )
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard let kind = MouseDownKind(eventType: event.type) else { return }
        _ = handleMouseDown(
            kind: kind,
            isContextClick: kind.isContextClick(modifierFlags: event.modifierFlags),
            allowsPreviewInterception: kind.allowsPreviewInterception(modifierFlags: event.modifierFlags),
            mouse: mouseLocation(for: event),
            fallbackMouse: DockCursorTracker.shared.currentMouseLocation(),
            eventTimestamp: event.timestamp,
            canSuppressDefault: false
        )
    }

    private func handleMouseDownFromEventTap(
        kind: MouseDownKind,
        isContextClick: Bool,
        allowsPreviewInterception: Bool,
        mouse: CGPoint,
        eventTimestamp: TimeInterval
    ) -> Bool {
        if Thread.isMainThread {
            return handleMouseDown(
                kind: kind,
                isContextClick: isContextClick,
                allowsPreviewInterception: allowsPreviewInterception,
                mouse: mouse,
                fallbackMouse: mouse,
                eventTimestamp: eventTimestamp,
                canSuppressDefault: true
            )
        }

        var suppress = false
        DispatchQueue.main.sync {
            suppress = handleMouseDown(
                kind: kind,
                isContextClick: isContextClick,
                allowsPreviewInterception: allowsPreviewInterception,
                mouse: mouse,
                fallbackMouse: mouse,
                eventTimestamp: eventTimestamp,
                canSuppressDefault: true
            )
        }
        return suppress
    }

    @discardableResult
    private func handleMouseDown(
        kind: MouseDownKind,
        isContextClick: Bool,
        allowsPreviewInterception: Bool,
        mouse: CGPoint,
        fallbackMouse: CGPoint,
        eventTimestamp: TimeInterval,
        canSuppressDefault: Bool
    ) -> Bool {
        defer {
            scheduleNextTickIfNeeded()
        }

        dockClickActionGeneration &+= 1
        suppression.prepareForMouseDown(kind: kind)
        let dockTarget = dockTargetUnderMouseDown(
            eventMouse: mouse,
            trackedMouse: fallbackMouse,
            allowsLastTargetFallback: isContextClick
        )
        let overPreview = previewContainsMouseDown(eventMouse: mouse, trackedMouse: fallbackMouse)

        if overPreview, dockTarget == nil {
            return false
        }

        if isContextClick {
            if let dockTarget {
                guard shouldHandleDockContextClick(
                    target: dockTarget,
                    eventMouse: mouse,
                    trackedMouse: fallbackMouse,
                    eventTimestamp: eventTimestamp
                ) else {
                    return false
                }
                hideAndResetHover(
                    cleanupPolicy: .protectUserContextMenu,
                    contextClickTarget: dockTarget
                )
                lastTarget = dockTarget
                suppression.suppressDockContextMenu(for: 120)
            }
            return false
        }

        if kind == .left {
            guard allowsPreviewInterception else { return false }
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

    private func shouldHandleDockContextClick(
        target: DockHoverTarget,
        eventMouse: CGPoint,
        trackedMouse: CGPoint,
        eventTimestamp: TimeInterval
    ) -> Bool {
        let observedAt = ProcessInfo.processInfo.systemUptime
        let timestamp = eventTimestamp.isFinite && eventTimestamp > 0 ?
            eventTimestamp : observedAt
        let location = target.anchor.insetBy(dx: -hoverTargetCachePadding, dy: -hoverTargetCachePadding)
            .contains(eventMouse) ? eventMouse : trackedMouse
        if let previous = lastDockContextClick,
           previous.targetKey == target.key,
           (abs(timestamp - previous.eventTimestamp) <= dockContextClickDeduplicationInterval ||
            observedAt - previous.observedAt <= dockContextClickDeduplicationInterval) {
            let dx = location.x - previous.location.x
            let dy = location.y - previous.location.y
            if dx * dx + dy * dy <= dockContextClickDeduplicationRadius * dockContextClickDeduplicationRadius {
                return false
            }
        }
        lastDockContextClick = DockContextClickFingerprint(
            targetKey: target.key,
            location: location,
            eventTimestamp: timestamp,
            observedAt: observedAt
        )
        return true
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
        guard nativeDockMenuState?.blocksPreviewInterception(for: target.key) != true else {
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
        guard let previews = WindowInventory.cachedWindows(
            for: app,
            refreshedWithin: 1.25
        ), previews.count >= 2 else {
            suppressHover(for: 0.35, untilDockExit: true)
            return false
        }

        if shouldDismissDockContextMenu && canSuppressDefault {
            DockContextMenuController.dismissIfVisible()
        }
        showImmediatelyForDockAppClick(
            target,
            app: app,
            previews: previews,
            actionGeneration: dockClickActionGeneration
        )
        holdSuppressedMouseUp(kind: .left)
        return true
    }

    private func showImmediatelyForDockAppClick(
        _ target: DockHoverTarget,
        app: NSRunningApplication,
        previews: [WindowPreview],
        actionGeneration: Int
    ) {
        clearPendingTarget()
        labelController?.hide()
        if lastTargetKey != target.key {
            previewRequestGeneration &+= 1
            resetNativeDockMenuState()
        }
        lastTargetKey = target.key
        lastTarget = target
        lastAnchor = target.anchor
        holdClickPreview()

        let now = Date()
        presentPreviews(previews, app: app, target: target, anchoredTo: target.anchor)
        lastMetadataRefresh = now
        lastLiveThumbnailRefresh = now

        let expectedTargetKey = target.key
        let expectedPreviewRequestGeneration = previewRequestGeneration
        let actionStartedAt = Date()
        let frontmostPIDAtAction = NSWorkspace.shared.frontmostApplication?.processIdentifier
        WindowInventory.refreshWindows(
            for: app,
            thumbnailPolicy: .refreshStale
        ) { [weak self, weak app] previews in
            guard let self, let app else { return }
            guard self.previewRequestGeneration == expectedPreviewRequestGeneration else { return }
            guard previews.count >= 2 else {
                let shouldRestoreClick = self.dockClickActionGeneration == actionGeneration &&
                    Date().timeIntervalSince(actionStartedAt) <= 0.75 &&
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostPIDAtAction
                let clickRestoreContext = shouldRestoreClick ? DockClickRestoreContext(
                    app: app,
                    actionGeneration: actionGeneration,
                    frontmostPIDAtAction: frontmostPIDAtAction
                ) : nil
                if self.cancelNativeDockMenuBeforeClickRestore(
                    targetKey: expectedTargetKey,
                    clickRestoreContext: clickRestoreContext
                ) {
                    return
                }
                if self.lastTargetKey == expectedTargetKey {
                    self.hideAndResetHover()
                }
                if shouldRestoreClick {
                    self.restoreSuppressedDockClick(for: app)
                }
                return
            }
            guard self.lastTargetKey == expectedTargetKey else { return }
            self.presentPreviews(previews, app: app, target: target, anchoredTo: target.anchor)
        } thumbnail: { [weak self, weak app] windowID, image in
            guard let self,
                  app != nil,
                  self.lastTargetKey == expectedTargetKey,
                  self.previewRequestGeneration == expectedPreviewRequestGeneration else {
                return
            }
            self.previewController?.updateThumbnail(windowID: windowID, image: image)
        }
    }

    private func restoreSuppressedDockClick(for app: NSRunningApplication) {
        guard !app.isTerminated else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let axResult = AXUIElementSetAttributeValue(
            appElement,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        let activated = app.activate(options: [.activateAllWindows])
        if axResult != .success, !activated {
            NSLog("prevDock: could not restore a suppressed Dock click")
        }
    }

    private func dockTargetUnderMouseDown(
        eventMouse: CGPoint,
        trackedMouse: CGPoint,
        allowsLastTargetFallback: Bool
    ) -> DockHoverTarget? {
        if let target = freshDockTargetUnderPointer(eventMouse) {
            return target
        }
        if eventMouse != trackedMouse, let target = freshDockTargetUnderPointer(trackedMouse) {
            return target
        }
        let points = eventMouse == trackedMouse ? [eventMouse] : [eventMouse, trackedMouse]
        if let pendingTarget,
           Date().timeIntervalSince(pendingTargetStartedAt) <= pendingTargetClickFallbackLifetime,
           points.contains(where: { point in
            pendingTarget.anchor.contains(point) &&
                DockGeometryCache.shared.isInDockInteractionStrip(point, refreshIfStale: false)
           }) {
            return pendingTarget
        }
        guard allowsLastTargetFallback,
              let lastTarget,
              lastTargetKey == lastTarget.key,
              previewController?.isVisible == true || labelController?.isVisible == true else {
            return nil
        }
        let fallbackFrame = lastTarget.anchor.insetBy(
            dx: -hoverTargetCachePadding,
            dy: -hoverTargetCachePadding
        )
        let isValidFallback = points.contains { point in
            fallbackFrame.contains(point) &&
                DockGeometryCache.shared.isInDockInteractionStrip(point, refreshIfStale: false)
        }
        return isValidFallback ? lastTarget : nil
    }

    private func previewContainsMouseDown(eventMouse: CGPoint, trackedMouse: CGPoint) -> Bool {
        if previewController?.contains(eventMouse) == true {
            return true
        }
        guard eventMouse != trackedMouse else { return false }
        return previewController?.contains(trackedMouse) == true
    }

    private func mouseLocation(for event: NSEvent) -> CGPoint {
        guard let window = event.window else {
            return event.locationInWindow
        }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func suppressHover(for interval: TimeInterval, untilDockExit: Bool) {
        suppression.suppressHover(for: interval, untilDockExit: untilDockExit)
        hideAndResetHover()
    }

    private func shouldSuppressHover(at mouse: CGPoint) -> Bool {
        if suppression.shouldSuppressDockContextMenu(visibility: {
            DockContextMenuController.visibility()
        }) {
            return true
        }
        if suppression.shouldSuppressHoverByTime() {
            return true
        }

        return suppression.shouldSuppressUntilDockExit(
            isStillInDockOrPreview: dockTargetUnderPointer(mouse) != nil || previewController?.contains(mouse) == true
        )
    }

    private func holdClickPreview() {
        suppression.holdClickPreview(for: 0.35)
    }

    private func shouldHoldClickPreview() -> Bool {
        guard previewController?.isVisible == true,
              lastTargetKey != nil else {
            return false
        }
        return suppression.shouldHoldClickPreview()
    }

    private func holdSuppressedMouseUp(kind: MouseDownKind) {
        suppression.holdSuppressedMouseUp(kind: kind)
    }

    private func shouldSuppressMouseDragFromEventTap(kind: MouseDownKind) -> Bool {
        if Thread.isMainThread {
            return suppression.shouldSuppressMouseDrag(kind: kind)
        }
        var suppress = false
        DispatchQueue.main.sync {
            suppress = suppression.shouldSuppressMouseDrag(kind: kind)
        }
        return suppress
    }

    private func shouldSuppressMouseUpFromEventTap(kind: MouseDownKind) -> Bool {
        if Thread.isMainThread {
            return shouldSuppressMouseUp(kind: kind)
        }

        var suppress = false
        DispatchQueue.main.sync {
            suppress = shouldSuppressMouseUp(kind: kind)
        }
        return suppress
    }

    private func shouldSuppressMouseUp(kind: MouseDownKind) -> Bool {
        return suppression.consumeSuppressedMouseUpIfNeeded(kind: kind)
    }

    private func hideAndResetHover(
        cleanupPolicy: NativeDockMenuCleanupPolicy = .dismissLateMenu,
        contextClickTarget: DockHoverTarget? = nil
    ) {
        previewRequestGeneration &+= 1
        resetNativeDockMenuState(cleanupPolicy: cleanupPolicy)
        if cleanupPolicy == .protectUserContextMenu, let contextClickTarget {
            convertLateCleanupForUserContextMenu(target: contextClickTarget)
        }
        previewController?.hide()
        labelController?.hide()
        clearHoverExitGrace()
        clearPendingTarget()
        clearCachedHoverTarget()
        lastTargetKey = nil
        lastTarget = nil
        lastAnchor = nil
        suppression.clearClickPreviewHold()
    }

    private func targetAfterSwitchDelay(_ target: DockHoverTarget, now: Date) -> DockHoverTarget? {
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

        guard now.timeIntervalSince(pendingTargetStartedAt) >= delay else {
            return nil
        }

        clearPendingTarget()
        return target
    }

    private func clearPendingTarget() {
        pendingTarget = nil
        pendingTargetStartedAt = .distantPast
    }

    private func shouldDelayPreviewHide(now: Date) -> Bool {
        guard previewController?.isVisible == true,
              lastTargetKey != nil else {
            clearHoverExitGrace()
            return false
        }

        guard let startedAt = hoverExitStartedAt else {
            hoverExitStartedAt = now
            return true
        }

        return now.timeIntervalSince(startedAt) < previewHideGraceInterval
    }

    private func clearHoverExitGrace() {
        hoverExitStartedAt = nil
    }

    private func currentMouseLocationForTick() -> CGPoint {
        DockCursorTracker.shared.currentMouseLocation(preferEventTap: true)
    }

    private func dockTargetUnderPointer(_ mouse: CGPoint) -> DockHoverTarget? {
        guard previewController?.contains(mouse) != true else {
            return nil
        }

        guard DockGeometryCache.shared.isInDockInteractionStrip(mouse) else {
            clearCachedHoverTarget()
            return nil
        }

        if let cachedHoverTarget,
           ProcessInfo.processInfo.systemUptime - cachedHoverTargetResolvedAt < hoverTargetCacheInterval,
           cachedHoverTarget.anchor
            .insetBy(dx: -hoverTargetCachePadding, dy: -hoverTargetCachePadding)
            .contains(mouse) {
            DockGeometryCache.shared.noteResolvedDockItem(anchor: cachedHoverTarget.anchor)
            return cachedHoverTarget
        }
        if hasCachedHoverResolution,
           cachedHoverTarget == nil,
           ProcessInfo.processInfo.systemUptime - cachedHoverTargetResolvedAt < negativeHoverTargetCacheInterval,
           squaredDistance(from: mouse, to: cachedHoverResolutionPoint) <=
            negativeHoverTargetCacheRadius * negativeHoverTargetCacheRadius {
            return nil
        }

        let target = DockHoverTargetResolver.target(at: mouse)
        if let target {
            DockGeometryCache.shared.noteResolvedDockItem(anchor: target.anchor)
        }
        cachedHoverTarget = target
        cachedHoverTargetResolvedAt = ProcessInfo.processInfo.systemUptime
        cachedHoverResolutionPoint = mouse
        hasCachedHoverResolution = true
        return target
    }

    private func freshDockTargetUnderPointer(_ mouse: CGPoint) -> DockHoverTarget? {
        guard previewController?.contains(mouse) != true,
              DockGeometryCache.shared.isInDockInteractionStrip(mouse) else {
            return nil
        }
        let target = DockHoverTargetResolver.target(at: mouse)
        if let target {
            DockGeometryCache.shared.noteResolvedDockItem(anchor: target.anchor)
        }
        cachedHoverTarget = target
        cachedHoverTargetResolvedAt = ProcessInfo.processInfo.systemUptime
        cachedHoverResolutionPoint = mouse
        hasCachedHoverResolution = true
        return target
    }

    private func clearCachedHoverTarget() {
        cachedHoverTarget = nil
        cachedHoverTargetResolvedAt = 0
        cachedHoverResolutionPoint = .zero
        hasCachedHoverResolution = false
    }

    private func squaredDistance(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private func recordNativeDockMenuMouseMoved(at mouse: CGPoint) {
        if Thread.isMainThread {
            updateNativeDockMenuHoverSession(at: mouse)
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.updateNativeDockMenuHoverSession(at: mouse)
        }
    }

    private func updateNativeDockMenuHoverSession(at mouse: CGPoint) {
        guard let source = nativeDockMenuHoverSessionSource() else {
            nativeDockMenuPointerOutsideSource = false
            nativeDockMenuContainmentRefreshKey = nil
            return
        }
        let targetFrame = source.anchor.insetBy(
            dx: -hoverTargetCachePadding,
            dy: -hoverTargetCachePadding
        )
        let inDockStrip = DockGeometryCache.shared.isInDockInteractionStrip(
            mouse,
            refreshIfStale: false
        )
        let overTarget = targetFrame.contains(mouse) && inDockStrip
        let overOtherDockTarget = DockGeometryCache.shared.isInDifferentDockItem(
            mouse,
            excluding: source.anchor,
            refreshIfStale: false
        )
        let overPreview = previewController?.contains(mouse) == true
        let overKnownMenu = DockContextMenuController.popupContains(
            mouse,
            windowIDs: source.menuWindowIDs,
            padding: DockPopupMenuSessionClassifier.connectionDistance
        )
        let overPendingMenuRegion = source.awaitingFirstMenu &&
            !inDockStrip && NativeDockMenuLifecyclePolicy.isInsidePendingMenuCorridor(
                mouse,
                anchor: source.anchor
            )
        var overMenu = !overOtherDockTarget && (overKnownMenu || overPendingMenuRegion)
        if overTarget || overMenu || overPreview {
            nativeDockMenuContainmentRefreshKey = nil
        }
        if NativeDockMenuLifecyclePolicy.shouldRefreshConnectedPopup(
            hasKnownMenu: !source.menuWindowIDs.isEmpty,
            cachedContainsPoint: overKnownMenu,
            overTarget: overTarget || overPreview,
            overOtherDockTarget: overOtherDockTarget,
            awaitingFirstMenu: source.awaitingFirstMenu,
            wasOutside: nativeDockMenuPointerOutsideSource
        ) {
            let refreshKey = NativeDockMenuContainmentRefreshKey(
                anchor: source.anchor,
                knownWindowIDs: source.menuWindowIDs
            )
            guard nativeDockMenuContainmentRefreshKey != refreshKey else { return }
            nativeDockMenuContainmentRefreshKey = refreshKey
            switch DockContextMenuController.refreshedConnectedContainment(
                of: mouse,
                anchoredTo: source.anchor,
                intersecting: source.menuWindowIDs,
                padding: DockPopupMenuSessionClassifier.connectionDistance
            ) {
            case .contains(let connectedWindowIDs):
                mergeNativeDockMenuHoverWindowIDs(connectedWindowIDs)
                nativeDockMenuContainmentRefreshKey = nil
                overMenu = true
            case .outside:
                break
            case .unknown:
                return
            }
        }
        let isOutside = overOtherDockTarget || (!overTarget && !overMenu && !overPreview)
        if isOutside, !nativeDockMenuPointerOutsideSource {
            nativeDockMenuHoverSessionGeneration &+= 1
        }
        nativeDockMenuPointerOutsideSource = isOutside
    }

    private func mergeNativeDockMenuHoverWindowIDs(_ windowIDs: Set<CGWindowID>) {
        guard !windowIDs.isEmpty else { return }
        if var cleanup = nativeDockMenuLateCleanup {
            cleanup.certifiedPopupWindowIDs.formUnion(windowIDs)
            if case .protectContextMenu(let phase) = cleanup.mode {
                cleanup.contextPopupWindowIDs.formUnion(windowIDs)
                if case .protecting(let protectedWindowIDs) = phase {
                    cleanup.mode = .protectContextMenu(
                        .protecting(windowIDs: protectedWindowIDs.union(windowIDs))
                    )
                }
            } else {
                cleanup.visiblePopupWindowIDs.formUnion(windowIDs)
            }
            nativeDockMenuLateCleanup = cleanup
            return
        }
        switch nativeDockMenuState {
        case .visible(var request):
            request.certifiedPopupWindowIDs.formUnion(windowIDs)
            nativeDockMenuState = .visible(request)
        case .cancelling(var cancellation):
            cancellation.certifiedPopupWindowIDs.formUnion(windowIDs)
            nativeDockMenuState = .cancelling(cancellation)
        case .requesting, .dismissed, .failed, nil:
            break
        }
    }

    private func nativeDockMenuHoverSessionSource() -> (
        anchor: CGRect,
        menuWindowIDs: Set<CGWindowID>,
        awaitingFirstMenu: Bool
    )? {
        if let cleanup = nativeDockMenuLateCleanup {
            guard let anchor = cleanup.contextClickAnchor ?? cleanup.sourceAnchor else { return nil }
            let menuWindowIDs: Set<CGWindowID>
            if case .protectContextMenu = cleanup.mode {
                menuWindowIDs = cleanup.contextPopupWindowIDs
            } else {
                menuWindowIDs = cleanup.visiblePopupWindowIDs
            }
            let awaitingFirstMenu: Bool
            if case .protectContextMenu = cleanup.mode {
                awaitingFirstMenu = !cleanup.didObserveContextMenu
            } else {
                awaitingFirstMenu = false
            }
            return (anchor, menuWindowIDs, awaitingFirstMenu)
        }
        switch nativeDockMenuState {
        case .visible(let request):
            return (request.target.anchor, request.certifiedPopupWindowIDs, false)
        case .cancelling(let cancellation):
            return (cancellation.targetAnchor, cancellation.certifiedPopupWindowIDs, false)
        case .dismissed:
            guard let anchor = dismissedNativeDockMenuAnchor else { return nil }
            return (anchor, [], false)
        case .requesting, .failed, nil:
            guard let attempt = nativeDockMenuAttemptLatch,
                  attempt.hoverSessionGeneration == nativeDockMenuHoverSessionGeneration else {
                return nil
            }
            let anchor = lastTarget?.key == attempt.targetKey ?
                lastTarget?.anchor ?? attempt.anchor : attempt.anchor
            return (anchor, [], false)
        }
    }

    private func wakeForMouseMoved() {
        if Thread.isMainThread {
            scheduleWakeTick()
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.scheduleWakeTick()
        }
    }

    private func scheduleWakeTick() {
        guard !wakeTickScheduled else { return }
        wakeTickScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.wakeTickScheduled = false
            self.tick()
        }
    }

    private func scheduleNextTickIfNeeded() {
        guard let interval = nextTickInterval() else { return }
        scheduleTick(after: interval)
    }

    private func scheduleTick(after interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: max(interval, 0.01), repeats: false) { [weak self] _ in
            self?.tick()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func nextTickInterval() -> TimeInterval? {
        if nativeDockMenuState?.needsFastVisibilityChecks == true {
            return visibilityPollingInterval(
                nextProbeAt: nativeDockMenuState?.nextVisibilityProbeAt
            )
        }
        if let cleanup = nativeDockMenuLateCleanup {
            return visibilityPollingInterval(nextProbeAt: cleanup.nextVisibilityProbeAt)
        }
        guard mouseDownEventTap != nil else {
            return watchdogTickInterval
        }

        if let hoverExitStartedAt {
            return max(0.01, previewHideGraceInterval - Date().timeIntervalSince(hoverExitStartedAt))
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

        return watchdogTickInterval
    }

    private func visibilityPollingInterval(nextProbeAt: Date?) -> TimeInterval {
        guard let nextProbeAt else { return fastTickInterval }
        let delay = nextProbeAt.timeIntervalSinceNow
        guard delay > fastTickInterval else { return fastTickInterval }
        return min(watchdogTickInterval, delay)
    }
}

private struct NativeDockMenuAttemptLatch {
    let targetKey: String
    var anchor: CGRect
    var hoverSessionGeneration: Int
    let actionGeneration: Int
}

private struct NativeDockMenuContainmentRefreshKey: Equatable {
    let anchor: CGRect
    let knownWindowIDs: Set<CGWindowID>
}

private struct NativeDockMenuRequest {
    var target: DockHoverTarget
    var app: NSRunningApplication
    var previews: [WindowPreview]
    var anchor: CGRect
    let generation: Int
    var visibilityDeadline: Date
    var awaitingDefinitePreflight = true
    var certifiedPopupWindowIDs = Set<CGWindowID>()
    var didRetryResolvedItem = false
    var missingVisibilityObservations = 0
    var unknownVisibilityObservations = 0
    var nextVisibilityProbeAt = Date.distantPast
    var lastActionError: AXError?
    var actionStartedAt: Date?
    var actionCompletedAt: Date?
    var hoverSessionGeneration: Int

    mutating func updateFallback(
        previews: [WindowPreview],
        app: NSRunningApplication,
        anchor: CGRect
    ) {
        self.previews = previews
        self.app = app
        self.anchor = anchor
    }
}

private struct NativeDockMenuCancellation {
    let targetKey: String
    let targetAnchor: CGRect
    var replacement: NativeDockMenuReplacement?
    var fallbackRequest: NativeDockMenuRequest?
    let clickRestoreContext: DockClickRestoreContext?
    let resumesHover: Bool
    let shouldShowReadableFallback: Bool
    var certifiedPopupWindowIDs: Set<CGWindowID>
    let actionStartedAt: Date?
    var safeRestoreAfter: Date
    let forcedFallbackDeadline: Date
    let actionGeneration: Int?
    var actionCompletedAt: Date?
    var missingVisibilityObservations = 0
    var unknownVisibilityObservations = 0
    var nextVisibilityProbeAt = Date.distantPast
    var didObserveCertifiedMenu = false
    let hoverSessionGeneration: Int
}

private struct NativeDockMenuLateCleanup {
    var certifiedPopupWindowIDs: Set<CGWindowID>
    var mode: NativeDockMenuLateCleanupMode
    var contextClickTargetKey: String?
    var contextClickAnchor: CGRect?
    var sourceAnchor: CGRect?
    var safeAfter: Date
    var absoluteDeadline: Date
    var missingVisibilityObservations = 0
    var unknownVisibilityObservations = 0
    var nextVisibilityProbeAt = Date.distantPast
    var visiblePopupWindowIDs = Set<CGWindowID>()
    var contextPopupWindowIDs = Set<CGWindowID>()
    var deferredPresentation: NativeDockMenuReplacement?
    var fallbackWatchRequest: NativeDockMenuRequest?
    var actionGeneration: Int?
    var actionCompletedAt: Date?
    var didObserveContextMenu = false
    var didPromoteLateMenu = false
    var hoverSessionGeneration: Int
    var defersProtectedPresentation = false
    var tracksSecondarySource = false
}

private enum NativeDockMenuLateCleanupMode {
    case dismissLateMenu
    case watchLateFallback
    case protectContextMenu(NativeDockMenuContextProtectionPhase)

    var defersPresentation: Bool {
        if case .dismissLateMenu = self { return true }
        return false
    }

    var blocksPresentation: Bool {
        if case .watchLateFallback = self { return false }
        return true
    }

}

private enum NativeDockMenuContextProtectionPhase {
    case awaitingFirstMenu(deadline: Date)
    case protecting(windowIDs: Set<CGWindowID>)
    case dismissingLateMenu(allowsFirstUserMenu: Bool)
}

private enum NativeDockMenuCleanupPolicy: Equatable {
    case dismissLateMenu
    case protectUserContextMenu
}

private struct NativeDockMenuReplacement {
    let previews: [WindowPreview]
    let app: NSRunningApplication
    let target: DockHoverTarget
    let anchor: CGRect
}

private struct DockClickRestoreContext {
    let app: NSRunningApplication
    let actionGeneration: Int
    let frontmostPIDAtAction: pid_t?
}

private struct DockContextClickFingerprint {
    let targetKey: String
    let location: CGPoint
    let eventTimestamp: TimeInterval
    let observedAt: TimeInterval
}

private enum NativeDockMenuState {
    case requesting(NativeDockMenuRequest)
    case visible(NativeDockMenuRequest)
    case dismissed(targetKey: String)
    case failed(NativeDockMenuRequest)
    case cancelling(NativeDockMenuCancellation)

    var targetKey: String {
        switch self {
        case .requesting(let request), .visible(let request), .failed(let request):
            return request.target.key
        case .dismissed(let targetKey):
            return targetKey
        case .cancelling(let cancellation):
            return cancellation.targetKey
        }
    }

    var actionStartedAt: Date? {
        switch self {
        case .requesting(let request), .visible(let request), .failed(let request):
            return request.actionStartedAt
        case .cancelling(let cancellation):
            return cancellation.actionStartedAt
        case .dismissed:
            return nil
        }
    }

    var targetAnchor: CGRect {
        switch self {
        case .requesting(let request), .visible(let request), .failed(let request):
            return request.target.anchor
        case .cancelling(let cancellation):
            return cancellation.targetAnchor
        case .dismissed:
            return .zero
        }
    }

    var hoverSessionGeneration: Int? {
        switch self {
        case .requesting(let request), .visible(let request), .failed(let request):
            return request.hoverSessionGeneration
        case .cancelling(let cancellation):
            return cancellation.hoverSessionGeneration
        case .dismissed:
            return nil
        }
    }

    var actionCompletedAt: Date? {
        switch self {
        case .requesting(let request), .visible(let request), .failed(let request):
            return request.actionCompletedAt
        case .cancelling(let cancellation):
            return cancellation.actionCompletedAt
        case .dismissed:
            return nil
        }
    }

    var actionGeneration: Int? {
        switch self {
        case .requesting(let request), .visible(let request), .failed(let request):
            return NativeDockMenuLifecyclePolicy.trackedActionGeneration(
                generation: request.generation,
                actionStarted: request.actionStartedAt != nil
            )
        case .cancelling(let cancellation):
            return cancellation.actionGeneration
        case .dismissed:
            return nil
        }
    }

    var certifiedPopupWindowIDs: Set<CGWindowID> {
        switch self {
        case .requesting(let request), .visible(let request), .failed(let request):
            return request.certifiedPopupWindowIDs
        case .cancelling(let cancellation):
            return cancellation.certifiedPopupWindowIDs
        case .dismissed:
            return []
        }
    }

    var needsFastVisibilityChecks: Bool {
        switch self {
        case .requesting, .visible, .cancelling:
            return true
        case .dismissed, .failed:
            return false
        }
    }

    var nextVisibilityProbeAt: Date? {
        switch self {
        case .visible(let request):
            return request.nextVisibilityProbeAt
        case .cancelling(let cancellation):
            return cancellation.nextVisibilityProbeAt
        case .requesting(let request):
            return request.nextVisibilityProbeAt
        case .dismissed, .failed:
            return nil
        }
    }

    func blocksPreviewInterception(for targetKey: String) -> Bool {
        guard self.targetKey == targetKey else { return false }
        switch self {
        case .requesting, .visible, .dismissed, .cancelling:
            return true
        case .failed:
            return false
        }
    }
}

private struct DockHoverSuppressionState {
    private var suppressHoverUntil = Date.distantPast
    private var suppressDockContextMenuUntil = Date.distantPast
    private var dockContextMenuCheckAfter = Date.distantPast
    private var missingDockContextMenuObservations = 0
    private var suppressUntilDockExit = false
    private var clickPreviewHoldUntil = Date.distantPast
    private var suppressedMouseUpKind: MouseDownKind?

    var isSuppressingDockContextMenu: Bool {
        Date() < suppressDockContextMenuUntil
    }

    mutating func suppressDockContextMenu(for interval: TimeInterval) {
        let now = Date()
        suppressDockContextMenuUntil = now.addingTimeInterval(interval)
        dockContextMenuCheckAfter = now.addingTimeInterval(0.3)
        missingDockContextMenuObservations = 0
    }

    mutating func clearDockContextMenu() {
        suppressDockContextMenuUntil = .distantPast
        dockContextMenuCheckAfter = .distantPast
        missingDockContextMenuObservations = 0
    }

    mutating func shouldSuppressDockContextMenu(visibility: () -> Bool?) -> Bool {
        let now = Date()
        guard now < suppressDockContextMenuUntil else {
            clearDockContextMenu()
            return false
        }
        guard now >= dockContextMenuCheckAfter else { return true }
        if visibility() == true {
            missingDockContextMenuObservations = 0
            dockContextMenuCheckAfter = now.addingTimeInterval(0.25)
            return true
        }
        missingDockContextMenuObservations += 1
        guard missingDockContextMenuObservations >= 2 else {
            dockContextMenuCheckAfter = now.addingTimeInterval(0.3)
            return true
        }
        clearDockContextMenu()
        return false
    }

    var dockContextMenuCheckInterval: TimeInterval? {
        let now = Date()
        guard now < suppressDockContextMenuUntil,
              now < dockContextMenuCheckAfter else {
            return nil
        }
        return max(0.01, dockContextMenuCheckAfter.timeIntervalSince(now))
    }

    mutating func suppressHover(for interval: TimeInterval, untilDockExit: Bool) {
        suppressHoverUntil = max(suppressHoverUntil, Date().addingTimeInterval(interval))
        suppressUntilDockExit = suppressUntilDockExit || untilDockExit
    }

    func shouldSuppressHoverByTime() -> Bool {
        Date() < suppressHoverUntil
    }

    mutating func shouldSuppressUntilDockExit(isStillInDockOrPreview: Bool) -> Bool {
        guard suppressUntilDockExit else { return false }
        guard !isStillInDockOrPreview else { return true }
        suppressUntilDockExit = false
        return false
    }

    mutating func holdClickPreview(for interval: TimeInterval) {
        clickPreviewHoldUntil = Date().addingTimeInterval(interval)
    }

    mutating func clearClickPreviewHold() {
        clickPreviewHoldUntil = .distantPast
    }

    func shouldHoldClickPreview() -> Bool {
        Date() < clickPreviewHoldUntil
    }

    var hasShortTimedState: Bool {
        let now = Date()
        return now < suppressHoverUntil ||
            now < clickPreviewHoldUntil
    }

    mutating func prepareForMouseDown(kind: MouseDownKind) {
        guard suppressedMouseUpKind == kind else { return }
        resetSuppressedMouseUp()
    }

    mutating func holdSuppressedMouseUp(kind: MouseDownKind) {
        suppressedMouseUpKind = kind
    }

    func shouldSuppressMouseDrag(kind: MouseDownKind) -> Bool {
        suppressedMouseUpKind == kind
    }

    mutating func consumeSuppressedMouseUpIfNeeded(kind: MouseDownKind) -> Bool {
        guard suppressedMouseUpKind == kind else { return false }
        resetSuppressedMouseUp()
        return true
    }

    mutating func resetSuppressedMouseUp() {
        suppressedMouseUpKind = nil
    }
}

private enum DockContextMenuController {
    private static var cachedPopupWindowIDs: Set<CGWindowID>?
    private static var cachedPopupFrames = [CGWindowID: CGRect]()
    private static var hasCachedSnapshot = false
    private static var lastVisibilityCheck: TimeInterval = 0
    private static let visibilityCacheLifetime: TimeInterval = 0.15
    private static var cachedAccessibilityMenuProbe = DockAccessibilityMenuProbe.absent
    private static var cachedAccessibilityMenuFrame: CGRect?
    private static var lastAccessibilityMenuCheck: TimeInterval = 0
    private static let accessibilityMenuCacheLifetime: TimeInterval = 0.12
    private static let accessibilityProbeBudget: TimeInterval = 0.04
    private static let accessibilityCallTimeout: Float = 0.01

    static func dismissIfVisible() {
        guard let popupWindowIDs = popupWindowIDs(forceRefresh: true) else { return }
        dismissMenus(intersecting: popupWindowIDs)
    }

    static func dismissMenus(intersecting windowIDs: Set<CGWindowID>) {
        guard let currentWindowIDs = popupWindowIDs(forceRefresh: true) else { return }
        let currentCandidates = currentWindowIDs.intersection(windowIDs)
        guard !certifiedMenuWindowIDs(
            among: currentCandidates,
            forceAccessibilityRefresh: true
        ).isEmpty else {
            return
        }

        if cancelMenu(inBundleIdentifier: "com.apple.dock.helper") {
            return
        }
        _ = cancelMenu(inBundleIdentifier: "com.apple.dock")
    }

    static func visibility(forceRefresh: Bool = false) -> Bool? {
        guard let popupWindowIDs = popupWindowIDs(forceRefresh: forceRefresh) else { return nil }
        guard !popupWindowIDs.isEmpty else { return false }
        switch accessibilityMenuProbe(forceRefresh: forceRefresh) {
        case .visible(let menuFrame):
            return popupWindowIDs.contains {
                cachedPopupFrames[$0]?.intersects(menuFrame) == true
            } ? true : nil
        case .absent:
            return false
        case .unknown:
            return nil
        }
    }

    static func verifiedMenuWindowIDs(
        forceRefresh: Bool = false,
        forceAccessibilityRefresh: Bool = false
    ) -> Set<CGWindowID>? {
        guard let popupWindowIDs = popupWindowIDs(forceRefresh: forceRefresh) else { return nil }
        switch accessibilityMenuProbe(forceRefresh: forceAccessibilityRefresh) {
        case .visible(let menuFrame):
            return popupWindowIDs.filter {
                cachedPopupFrames[$0]?.intersects(menuFrame) == true
            }
        case .absent:
            return []
        case .unknown:
            return nil
        }
    }

    static func certifiedMenuWindowIDs(
        among candidateWindowIDs: Set<CGWindowID>,
        forceAccessibilityRefresh: Bool = false
    ) -> Set<CGWindowID> {
        guard !candidateWindowIDs.isEmpty else {
            return []
        }
        guard case .visible(let menuFrame) = accessibilityMenuProbe(
            forceRefresh: forceAccessibilityRefresh
        ) else {
            return []
        }
        return candidateWindowIDs.filter {
            cachedPopupFrames[$0]?.intersects(menuFrame) == true
        }
    }

    static func menuVisibility(
        anchoredTo anchor: CGRect,
        forceRefresh: Bool = false,
        forceAccessibilityRefresh: Bool = false
    ) -> NativeDockMenuVisibility {
        guard popupWindowIDs(forceRefresh: forceRefresh) != nil else {
            return DockPopupMenuSessionClassifier.visibility(
                popupFrames: nil,
                accessibility: .unknown,
                anchoredTo: anchor
            )
        }
        return DockPopupMenuSessionClassifier.visibility(
            popupFrames: cachedPopupFrames,
            accessibility: accessibilityMenuProbe(forceRefresh: forceAccessibilityRefresh),
            anchoredTo: anchor
        )
    }

    static func popupContains(
        _ point: CGPoint,
        windowIDs: Set<CGWindowID>,
        padding: CGFloat = 0
    ) -> Bool {
        windowIDs.contains {
            cachedPopupFrames[$0]?.insetBy(dx: -padding, dy: -padding).contains(point) == true
        }
    }

    static func refreshedConnectedContainment(
        of point: CGPoint,
        anchoredTo anchor: CGRect,
        intersecting knownWindowIDs: Set<CGWindowID>,
        padding: CGFloat
    ) -> DockConnectedPopupContainment {
        guard popupWindowIDs(forceRefresh: true) != nil else { return .unknown }
        return DockPopupMenuSessionClassifier.connectedContainment(
            of: point,
            popupFrames: cachedPopupFrames,
            anchoredTo: anchor,
            intersecting: knownWindowIDs,
            padding: padding
        )
    }

    static func popupWindowIDs(forceRefresh: Bool = false) -> Set<CGWindowID>? {
        let now = ProcessInfo.processInfo.systemUptime
        if !forceRefresh,
           hasCachedSnapshot,
           now - lastVisibilityCheck < visibilityCacheLifetime {
            return cachedPopupWindowIDs
        }
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            cachedPopupWindowIDs = nil
            cachedPopupFrames.removeAll()
            hasCachedSnapshot = true
            lastVisibilityCheck = now
            return nil
        }

        var popupWindowIDs = Set<CGWindowID>()
        var popupFrames = [CGWindowID: CGRect]()
        for window in windows {
            let owner = window[kCGWindowOwnerName as String] as? String
            guard owner == "DockHelper" || owner == "Dock" else {
                continue
            }
            guard (window[kCGWindowLayer as String] as? Int ?? 0) >= NSWindow.Level.popUpMenu.rawValue else {
                continue
            }
            guard let number = window[kCGWindowNumber as String] as? NSNumber else { continue }
            guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width.isFinite,
                  frame.height.isFinite,
                  frame.width > 0,
                  frame.height > 0 else {
                continue
            }
            let windowID = CGWindowID(number.uint32Value)
            popupWindowIDs.insert(windowID)
            popupFrames[windowID] = AccessibilityHelpers.appKitFrame(fromQuartzWindowBounds: frame)
        }
        cachedPopupWindowIDs = popupWindowIDs
        cachedPopupFrames = popupFrames
        if cachedPopupWindowIDs?.isEmpty == true {
            cachedAccessibilityMenuProbe = .absent
            cachedAccessibilityMenuFrame = nil
            lastAccessibilityMenuCheck = 0
        }
        hasCachedSnapshot = true
        lastVisibilityCheck = now
        return cachedPopupWindowIDs
    }

    private static func accessibilityMenuProbe(
        forceRefresh: Bool = false
    ) -> DockAccessibilityMenuProbe {
        let now = ProcessInfo.processInfo.systemUptime
        if !forceRefresh,
           now - lastAccessibilityMenuCheck < accessibilityMenuCacheLifetime {
            return cachedAccessibilityMenuProbe
        }

        let deadline = now + accessibilityProbeBudget
        cachedAccessibilityMenuFrame = nil
        var sawUnknown = false
        for bundleIdentifier in ["com.apple.dock.helper", "com.apple.dock"] {
            switch probeMenu(inBundleIdentifier: bundleIdentifier, deadline: deadline) {
            case .visible(let frame):
                cachedAccessibilityMenuFrame = frame
                cachedAccessibilityMenuProbe = .visible(frame)
                lastAccessibilityMenuCheck = ProcessInfo.processInfo.systemUptime
                return cachedAccessibilityMenuProbe
            case .absent:
                break
            case .unknown:
                sawUnknown = true
            }
        }
        cachedAccessibilityMenuProbe = sawUnknown ? .unknown : .absent
        lastAccessibilityMenuCheck = ProcessInfo.processInfo.systemUptime
        return cachedAccessibilityMenuProbe
    }

    private static func probeMenu(
        inBundleIdentifier bundleIdentifier: String,
        deadline: TimeInterval
    ) -> DockAccessibilityMenuProbe {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return .unknown }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return .absent
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var rawFocusedElement: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &rawFocusedElement
        )
        if focusedError == .success,
           let rawFocusedElement,
           CFGetTypeID(rawFocusedElement) == AXUIElementGetTypeID() {
            let focusedProbe = probeMenuInAncestorChain(
                rawFocusedElement as! AXUIElement,
                deadline: deadline
            )
            if !NativeDockMenuLifecyclePolicy.focusedProbeRequiresTreeFallback(focusedProbe) {
                return focusedProbe
            }
        } else if !isDefiniteMissingAttribute(focusedError) {
            return .unknown
        }
        return probeMenu(
            in: appElement,
            depth: 0,
            deadline: deadline
        )
    }

    private static func probeMenuInAncestorChain(
        _ element: AXUIElement,
        deadline: TimeInterval
    ) -> DockAccessibilityMenuProbe {
        var current: AXUIElement? = element
        var depth = 0
        while let element = current {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return .unknown }
            guard depth < 8 else { return .unknown }
            _ = AXUIElementSetMessagingTimeout(element, accessibilityCallTimeout)
            switch menuFrameProbe(for: element) {
            case .visible(let frame):
                return .visible(frame)
            case .unknown:
                return .unknown
            case .absent:
                break
            }
            var rawParent: CFTypeRef?
            let parentError = AXUIElementCopyAttributeValue(
                element,
                kAXParentAttribute as CFString,
                &rawParent
            )
            if parentError == .success,
               let rawParent,
               CFGetTypeID(rawParent) == AXUIElementGetTypeID() {
                current = (rawParent as! AXUIElement)
            } else if isDefiniteMissingAttribute(parentError) {
                current = nil
            } else {
                return .unknown
            }
            depth += 1
        }
        return .absent
    }

    private static func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        _ = AXUIElementSetMessagingTimeout(element, accessibilityCallTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func visibleMenuInAncestorChain(
        _ element: AXUIElement,
        deadline: TimeInterval
    ) -> AXUIElement? {
        var current: AXUIElement? = element
        var depth = 0
        while let element = current,
              depth < 6,
              ProcessInfo.processInfo.systemUptime < deadline {
            _ = AXUIElementSetMessagingTimeout(element, accessibilityCallTimeout)
            if isVisibleMenuElement(element) {
                return element
            }
            current = AccessibilityHelpers.parent(element)
            depth += 1
        }
        return nil
    }

    private static func probeMenu(
        in element: AXUIElement,
        depth: Int,
        deadline: TimeInterval
    ) -> DockAccessibilityMenuProbe {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return .unknown }
        _ = AXUIElementSetMessagingTimeout(element, accessibilityCallTimeout)
        switch menuFrameProbe(for: element) {
        case .visible(let frame):
            return .visible(frame)
        case .unknown:
            return .unknown
        case .absent:
            break
        }

        var rawChildren: CFTypeRef?
        let childrenError = AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &rawChildren
        )
        guard childrenError == .success else {
            return isDefiniteMissingAttribute(childrenError) ? .absent : .unknown
        }
        let children = rawChildren as? [AXUIElement] ?? []
        guard !children.isEmpty else { return .absent }
        guard depth < 8 else { return .unknown }
        var sawUnknown = false
        for child in children {
            switch probeMenu(in: child, depth: depth + 1, deadline: deadline) {
            case .visible(let frame):
                return .visible(frame)
            case .absent:
                break
            case .unknown:
                sawUnknown = true
            }
        }
        return sawUnknown ? .unknown : .absent
    }

    private static func menuFrameProbe(for element: AXUIElement) -> DockAccessibilityMenuProbe {
        var rawRole: CFTypeRef?
        let roleError = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &rawRole
        )
        guard roleError == .success else {
            return isDefiniteMissingAttribute(roleError) ? .absent : .unknown
        }
        guard rawRole as? String == kAXMenuRole as String else { return .absent }
        guard let frame = visibleMenuFrame(for: element) else { return .unknown }
        return .visible(frame)
    }

    private static func isDefiniteMissingAttribute(_ error: AXError) -> Bool {
        error == .attributeUnsupported || error == .noValue
    }

    private static func isVisibleMenuElement(_ element: AXUIElement) -> Bool {
        guard let menuFrame = visibleMenuFrame(for: element) else { return false }
        cachedAccessibilityMenuFrame = menuFrame
        return true
    }

    private static func visibleMenuFrame(for element: AXUIElement) -> CGRect? {
        guard AccessibilityHelpers.stringAttribute(element, kAXRoleAttribute as CFString) == kAXMenuRole as String,
              let size = AccessibilityHelpers.sizeAttribute(element, kAXSizeAttribute as CFString),
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        if !cachedPopupFrames.isEmpty {
            guard let position = AccessibilityHelpers.pointAttribute(element, kAXPositionAttribute as CFString),
                  position.x.isFinite,
                  position.y.isFinite else {
                return nil
            }
            let menuFrame = AccessibilityHelpers.appKitRect(fromAccessibilityPosition: position, size: size)
            return cachedPopupFrames.values.contains { $0.intersects(menuFrame) } ? menuFrame : nil
        }
        guard let position = AccessibilityHelpers.pointAttribute(element, kAXPositionAttribute as CFString),
              position.x.isFinite,
              position.y.isFinite else {
            return nil
        }
        return AccessibilityHelpers.appKitRect(fromAccessibilityPosition: position, size: size)
    }

    private static func cancelMenu(inBundleIdentifier bundleIdentifier: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return false
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let deadline = ProcessInfo.processInfo.systemUptime + accessibilityProbeBudget
        if let focusedElement = elementAttribute(appElement, kAXFocusedUIElementAttribute as CFString),
           let menu = visibleMenuInAncestorChain(focusedElement, deadline: deadline) {
            return AXUIElementPerformAction(menu, kAXCancelAction as CFString) == .success
        }
        return cancelMenu(in: appElement)
    }

    private static func cancelMenu(in element: AXUIElement, depth: Int = 0) -> Bool {
        guard depth < 4 else { return false }
        _ = AXUIElementSetMessagingTimeout(element, accessibilityCallTimeout)
        if isVisibleMenuElement(element) {
            return AXUIElementPerformAction(element, kAXCancelAction as CFString) == .success
        }

        for child in AccessibilityHelpers.elementArrayAttribute(element, kAXChildrenAttribute as CFString) {
            if cancelMenu(in: child, depth: depth + 1) {
                return true
            }
        }
        return false
    }
}

private enum MouseDownKind {
    case left
    case right
    case other

    init?(eventType: NSEvent.EventType) {
        switch eventType {
        case .leftMouseDown:
            self = .left
        case .rightMouseDown:
            self = .right
        case .otherMouseDown:
            self = .other
        default:
            return nil
        }
    }

    init?(cgEventType: CGEventType) {
        switch cgEventType {
        case .leftMouseDown:
            self = .left
        case .rightMouseDown:
            self = .right
        case .otherMouseDown:
            self = .other
        default:
            return nil
        }
    }

    init?(cgMouseUpEventType: CGEventType) {
        switch cgMouseUpEventType {
        case .leftMouseUp:
            self = .left
        case .rightMouseUp:
            self = .right
        case .otherMouseUp:
            self = .other
        default:
            return nil
        }
    }

    init?(cgMouseDraggedEventType: CGEventType) {
        switch cgMouseDraggedEventType {
        case .leftMouseDragged:
            self = .left
        case .rightMouseDragged:
            self = .right
        case .otherMouseDragged:
            self = .other
        default:
            return nil
        }
    }

    func isContextClick(modifierFlags: NSEvent.ModifierFlags) -> Bool {
        self == .right || (self == .left && modifierFlags.contains(.control))
    }

    func isContextClick(eventFlags: CGEventFlags) -> Bool {
        self == .right || (self == .left && eventFlags.contains(.maskControl))
    }

    func allowsPreviewInterception(modifierFlags: NSEvent.ModifierFlags) -> Bool {
        guard self == .left else { return false }
        let modifiers: NSEvent.ModifierFlags = [.command, .option, .shift, .control, .function]
        return modifierFlags.intersection(modifiers).isEmpty
    }

    func allowsPreviewInterception(eventFlags: CGEventFlags) -> Bool {
        guard self == .left else { return false }
        let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl, .maskSecondaryFn]
        return eventFlags.intersection(modifiers).isEmpty
    }
}

struct DockHoverTarget {
    let app: NSRunningApplication?
    let title: String
    let url: URL?
    let anchor: CGRect
    let showsInactiveLabel: Bool
    let dockItemElement: AXUIElement

    var key: String {
        if let app {
            return "app:\(app.processIdentifier)"
        }
        if let url {
            return "dock:\(url.isFileURL ? url.path : url.absoluteString)"
        }
        return "dock:\(title)"
    }
}
