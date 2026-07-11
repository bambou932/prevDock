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
    private var wakeTickScheduled = false
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

    init(
        previewController: PreviewPanelController,
        labelController: DockLabelPanelController
    ) {
        self.previewController = previewController
        self.labelController = labelController
    }

    func start() {
        dockClickActionGeneration &+= 1
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
        previewController?.deactivateStaleHoverEffects(at: mouse)
        let overPreview = previewController?.contains(mouse) == true
        let now = Date()

        if isMouseButtonPressed {
            if overPreview || shouldHoldClickPreview() || dockTargetUnderPointer(mouse) != nil {
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
        lastTargetKey = target.key

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
                previewController?.show(previews: cached, app: app, anchoredTo: lastAnchor ?? target.anchor)
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
        if needsMetadata {
            WindowInventory.refreshWindows(
                for: app,
                thumbnailPolicy: needsLiveThumbnails ? .refreshStale : .missingOnly
            ) { [weak self, weak app] previews in
                guard let self else { return }
                guard let app, self.lastTargetKey == expectedTargetKey else { return }
                self.previewController?.show(previews: previews, app: app, anchoredTo: self.lastAnchor ?? target.anchor)
            } thumbnail: { [weak self, weak app] windowID, image in
                guard let self, app != nil, self.lastTargetKey == expectedTargetKey else { return }
                self.previewController?.updateThumbnail(windowID: windowID, image: image)
            }
        } else if needsLiveThumbnails {
            WindowInventory.refreshThumbnails(for: app) { [weak self, weak app] windowID, image in
                guard let self, app != nil, self.lastTargetKey == expectedTargetKey else { return }
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
        WindowInventory.refreshThumbnails(for: app) { [weak self, weak app] windowID, image in
            guard let self,
                  app != nil,
                  self.lastTargetKey == expectedTargetKey,
                  self.previewController?.isVisible == true else {
                return
            }
            self.previewController?.updateThumbnail(windowID: windowID, image: image)
        }
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
            DockCursorTracker.shared.updateFromEventTap(quartzPoint: event.location)
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
            mouse: mouse
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
        guard previewController?.isVisible == true else { return }
        previewController?.refreshForSettingsChange()
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard let kind = MouseDownKind(eventType: event.type) else { return }
        _ = handleMouseDown(
            kind: kind,
            isContextClick: kind.isContextClick(modifierFlags: event.modifierFlags),
            allowsPreviewInterception: kind.allowsPreviewInterception(modifierFlags: event.modifierFlags),
            mouse: mouseLocation(for: event),
            fallbackMouse: DockCursorTracker.shared.currentMouseLocation(),
            canSuppressDefault: false
        )
    }

    private func handleMouseDownFromEventTap(
        kind: MouseDownKind,
        isContextClick: Bool,
        allowsPreviewInterception: Bool,
        mouse: CGPoint
    ) -> Bool {
        if Thread.isMainThread {
            return handleMouseDown(
                kind: kind,
                isContextClick: isContextClick,
                allowsPreviewInterception: allowsPreviewInterception,
                mouse: mouse,
                fallbackMouse: mouse,
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
        canSuppressDefault: Bool
    ) -> Bool {
        defer {
            scheduleNextTickIfNeeded()
        }

        dockClickActionGeneration &+= 1
        suppression.prepareForMouseDown(kind: kind)
        let dockTarget = dockTargetUnderMouseDown(eventMouse: mouse, trackedMouse: fallbackMouse)
        let overPreview = previewContainsMouseDown(eventMouse: mouse, trackedMouse: fallbackMouse)

        if overPreview {
            return false
        }

        if isContextClick {
            if dockTarget != nil {
                suppression.suppressDockContextMenu(for: 120)
                hideAndResetHover()
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
        lastTargetKey = target.key
        lastAnchor = target.anchor
        holdClickPreview()

        let now = Date()
        previewController?.show(previews: previews, app: app, anchoredTo: target.anchor)
        lastMetadataRefresh = now
        lastLiveThumbnailRefresh = now

        let expectedTargetKey = target.key
        let actionStartedAt = Date()
        let frontmostPIDAtAction = NSWorkspace.shared.frontmostApplication?.processIdentifier
        WindowInventory.refreshWindows(
            for: app,
            thumbnailPolicy: .refreshStale
        ) { [weak self, weak app] previews in
            guard let self, let app else { return }
            guard previews.count >= 2 else {
                let shouldRestoreClick = self.dockClickActionGeneration == actionGeneration &&
                    Date().timeIntervalSince(actionStartedAt) <= 0.75 &&
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostPIDAtAction
                if self.lastTargetKey == expectedTargetKey {
                    self.hideAndResetHover()
                }
                if shouldRestoreClick {
                    self.restoreSuppressedDockClick(for: app)
                }
                return
            }
            guard self.lastTargetKey == expectedTargetKey else { return }
            self.previewController?.show(previews: previews, app: app, anchoredTo: target.anchor)
        } thumbnail: { [weak self, weak app] windowID, image in
            guard let self, app != nil, self.lastTargetKey == expectedTargetKey else { return }
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

    private func dockTargetUnderMouseDown(eventMouse: CGPoint, trackedMouse: CGPoint) -> DockHoverTarget? {
        if let target = freshDockTargetUnderPointer(eventMouse) {
            return target
        }
        if eventMouse != trackedMouse, let target = freshDockTargetUnderPointer(trackedMouse) {
            return target
        }
        guard let pendingTarget,
              Date().timeIntervalSince(pendingTargetStartedAt) <= pendingTargetClickFallbackLifetime else {
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

    private func hideAndResetHover() {
        previewController?.hide()
        labelController?.hide()
        clearHoverExitGrace()
        clearPendingTarget()
        clearCachedHoverTarget()
        lastTargetKey = nil
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
    private static var cachedVisibility: Bool?
    private static var hasCachedVisibility = false
    private static var lastVisibilityCheck: TimeInterval = 0
    private static let visibilityCacheLifetime: TimeInterval = 0.15

    static func dismissIfVisible() {
        guard visibility(forceRefresh: true) != false else { return }

        if cancelMenu(inBundleIdentifier: "com.apple.dock.helper") {
            return
        }
        _ = cancelMenu(inBundleIdentifier: "com.apple.dock")
    }

    static func visibility(forceRefresh: Bool = false) -> Bool? {
        let now = ProcessInfo.processInfo.systemUptime
        if !forceRefresh,
           hasCachedVisibility,
           now - lastVisibilityCheck < visibilityCacheLifetime {
            return cachedVisibility
        }
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            cachedVisibility = nil
            hasCachedVisibility = true
            lastVisibilityCheck = now
            return nil
        }

        cachedVisibility = windows.contains { window in
            let owner = window[kCGWindowOwnerName as String] as? String
            guard owner == "DockHelper" || owner == "Dock" else {
                return false
            }
            return (window[kCGWindowLayer as String] as? Int ?? 0) >= NSWindow.Level.popUpMenu.rawValue
        }
        hasCachedVisibility = true
        lastVisibilityCheck = now
        return cachedVisibility
    }

    private static func cancelMenu(inBundleIdentifier bundleIdentifier: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return false
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return cancelMenu(in: appElement)
    }

    private static func cancelMenu(in element: AXUIElement, depth: Int = 0) -> Bool {
        guard depth < 4 else { return false }
        if AccessibilityHelpers.stringAttribute(element, kAXRoleAttribute as CFString) == kAXMenuRole as String {
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
