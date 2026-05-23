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
    private var lastTargetKey: String?
    private var lastMetadataRefresh = Date.distantPast
    private var lastLiveThumbnailRefresh = Date.distantPast
    private var lastAnchor: CGRect?
    private var hoverExitStartedAt: Date?
    private var pendingTarget: DockHoverTarget?
    private var pendingTargetStartedAt = Date.distantPast
    private var lastWarmupTargetKey: String?
    private var lastWarmupStartedAt = Date.distantPast
    private var suppression = DockHoverSuppressionState()
    private var wakeTickScheduled = false
    private let fastTickInterval: TimeInterval = 0.08
    private let watchdogTickInterval: TimeInterval = 1.0
    private let liveThumbnailRefreshInterval: TimeInterval = 0.45
    private let previewWarmupInterval: TimeInterval = 3.0
    private let previewHideGraceInterval: TimeInterval = 0.20

    init(
        previewController: PreviewPanelController,
        labelController: DockLabelPanelController
    ) {
        self.previewController = previewController
        self.labelController = labelController
    }

    func start() {
        timer?.invalidate()
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
        uninstallMouseDownEventTap()

        installMouseDownEventTap()
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
        warmPreviewCacheIfNeeded(for: target, now: now)

        let panelVisible = previewController?.isVisible == true
        let needsPresentation = targetChanged || !panelVisible
        let needsMetadata = needsPresentation || now.timeIntervalSince(lastMetadataRefresh) > 1.0
        let needsLiveThumbnails = panelVisible &&
            now.timeIntervalSince(lastLiveThumbnailRefresh) > liveThumbnailRefreshInterval
        guard needsPresentation || needsMetadata || needsLiveThumbnails else { return }

        if needsPresentation {
            let cached = WindowInventory.cachedWindows(for: app)
            if cached.isEmpty {
                if targetChanged {
                    previewController?.hide()
                }
            } else {
                previewController?.show(previews: cached, app: app, anchoredTo: lastAnchor ?? target.anchor)
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
            WindowInventory.refreshWindows(for: app, refreshThumbnails: needsLiveThumbnails) { [weak self, weak app] previews in
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
        guard lastWarmupTargetKey != target.key ||
            now.timeIntervalSince(lastWarmupStartedAt) > previewWarmupInterval else {
            return
        }

        lastWarmupTargetKey = target.key
        lastWarmupStartedAt = now
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

    private func installMouseDownEventTap() {
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.leftMouseUp.rawValue) |
            CGEventMask(1 << CGEventType.rightMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.otherMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.rightMouseUp.rawValue) |
            CGEventMask(1 << CGEventType.otherMouseUp.rawValue) |
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

        if let kind = MouseDownKind(cgMouseUpEventType: type) {
            return monitor.shouldSuppressMouseUpFromEventTap(kind: kind) ? nil : Unmanaged.passUnretained(event)
        }

        guard let kind = MouseDownKind(cgEventType: type) else {
            return Unmanaged.passUnretained(event)
        }

        let mouse = DockCursorTracker.shared.updateFromEventTap(quartzPoint: event.location)
        let suppress = monitor.handleMouseDownFromEventTap(kind: kind, mouse: mouse)
        return suppress ? nil : Unmanaged.passUnretained(event)
    }

    private func installSettingsObserver() {
        guard settingsObserver == nil else { return }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: PrevDockSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSettingsChange()
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
        hideAndResetHover()
    }

    private func handleSettingsChange() {
        clearPendingTarget()
        suppression.clearClickPreviewHold()
        suppression.resetSuppressedMouseUp()
        guard previewController?.isVisible == true else { return }
        previewController?.refreshForSettingsChange()
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard let kind = MouseDownKind(eventType: event.type) else { return }
        _ = handleMouseDown(
            kind: kind,
            mouse: mouseLocation(for: event),
            fallbackMouse: DockCursorTracker.shared.currentMouseLocation(),
            canSuppressDefault: false
        )
    }

    private func handleMouseDownFromEventTap(kind: MouseDownKind, mouse: CGPoint) -> Bool {
        if Thread.isMainThread {
            return handleMouseDown(kind: kind, mouse: mouse, fallbackMouse: mouse, canSuppressDefault: true)
        }

        var suppress = false
        DispatchQueue.main.sync {
            suppress = handleMouseDown(kind: kind, mouse: mouse, fallbackMouse: mouse, canSuppressDefault: true)
        }
        return suppress
    }

    @discardableResult
    private func handleMouseDown(
        kind: MouseDownKind,
        mouse: CGPoint,
        fallbackMouse: CGPoint,
        canSuppressDefault: Bool
    ) -> Bool {
        defer {
            scheduleNextTickIfNeeded()
        }

        let dockTarget = dockTargetUnderMouseDown(eventMouse: mouse, trackedMouse: fallbackMouse)
        let overPreview = previewContainsMouseDown(eventMouse: mouse, trackedMouse: fallbackMouse)

        if overPreview {
            return false
        }

        if kind.isContextClick {
            if dockTarget != nil {
                suppression.suppressDockContextMenu(for: 120)
                hideAndResetHover()
            }
            return false
        }

        if kind == .left {
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

        let previews = WindowInventory.currentWindows(for: app)
        guard previews.count >= 2 else {
            suppressHover(for: 0.35, untilDockExit: true)
            return false
        }

        if shouldDismissDockContextMenu && canSuppressDefault {
            DockContextMenuController.dismissIfVisible()
        }
        showImmediatelyForDockAppClick(target, app: app, previews: previews)
        if canSuppressDefault {
            holdSuppressedMouseUp(kind: .left)
            return true
        }
        return false
    }

    private func showImmediatelyForDockAppClick(
        _ target: DockHoverTarget,
        app: NSRunningApplication,
        previews: [WindowPreview]
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
        WindowInventory.refreshWindows(for: app, refreshThumbnails: true) { [weak self, weak app] previews in
            guard let self, let app, self.lastTargetKey == expectedTargetKey else { return }
            guard previews.count >= 2 else {
                self.hideAndResetHover()
                return
            }
            self.previewController?.show(previews: previews, app: app, anchoredTo: target.anchor)
        } thumbnail: { [weak self, weak app] windowID, image in
            guard let self, app != nil, self.lastTargetKey == expectedTargetKey else { return }
            self.previewController?.updateThumbnail(windowID: windowID, image: image)
        }
    }

    private func dockTargetUnderMouseDown(eventMouse: CGPoint, trackedMouse: CGPoint) -> DockHoverTarget? {
        if let target = dockTargetUnderPointer(eventMouse) {
            return target
        }
        if eventMouse != trackedMouse, let target = dockTargetUnderPointer(trackedMouse) {
            return target
        }
        return pendingTarget
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
        suppression.holdSuppressedMouseUp(kind: kind, for: 0.8)
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
        guard PrevDockSettings.dockAppClickPreviewEnabled else {
            resetSuppressedMouseUp()
            return false
        }

        return suppression.consumeSuppressedMouseUpIfNeeded(kind: kind)
    }

    private func resetSuppressedMouseUp() {
        suppression.resetSuppressedMouseUp()
    }

    private func hideAndResetHover() {
        previewController?.hide()
        labelController?.hide()
        clearHoverExitGrace()
        clearPendingTarget()
        lastTargetKey = nil
        lastAnchor = nil
        suppression.clearClickPreviewHold()
        suppression.resetSuppressedMouseUp()
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
            return nil
        }

        return DockHoverTargetResolver.target(at: mouse)
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

        if pendingTarget != nil ||
            previewController?.isVisible == true ||
            isMouseButtonPressed ||
            shouldHoldClickPreview() ||
            suppression.hasShortTimedState {
            return fastTickInterval
        }

        return nil
    }
}

private struct DockHoverSuppressionState {
    private var suppressHoverUntil = Date.distantPast
    private var suppressDockContextMenuUntil = Date.distantPast
    private var suppressUntilDockExit = false
    private var clickPreviewHoldUntil = Date.distantPast
    private var suppressedMouseUpUntil = Date.distantPast
    private var suppressedMouseUpKind: MouseDownKind?

    var isSuppressingDockContextMenu: Bool {
        Date() < suppressDockContextMenuUntil
    }

    mutating func suppressDockContextMenu(for interval: TimeInterval) {
        suppressDockContextMenuUntil = Date().addingTimeInterval(interval)
    }

    mutating func clearDockContextMenu() {
        suppressDockContextMenuUntil = .distantPast
    }

    mutating func suppressHover(for interval: TimeInterval, untilDockExit: Bool) {
        suppressHoverUntil = max(suppressHoverUntil, Date().addingTimeInterval(interval))
        suppressUntilDockExit = suppressUntilDockExit || untilDockExit
    }

    func shouldSuppressHoverByTime() -> Bool {
        let now = Date()
        return now < suppressDockContextMenuUntil || now < suppressHoverUntil
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
            now < clickPreviewHoldUntil ||
            now < suppressedMouseUpUntil
    }

    mutating func holdSuppressedMouseUp(kind: MouseDownKind, for interval: TimeInterval) {
        suppressedMouseUpKind = kind
        suppressedMouseUpUntil = Date().addingTimeInterval(interval)
    }

    mutating func consumeSuppressedMouseUpIfNeeded(kind: MouseDownKind) -> Bool {
        guard suppressedMouseUpKind == kind,
              Date() < suppressedMouseUpUntil else {
            resetSuppressedMouseUp()
            return false
        }
        return true
    }

    mutating func resetSuppressedMouseUp() {
        suppressedMouseUpKind = nil
        suppressedMouseUpUntil = .distantPast
    }
}

private enum DockContextMenuController {
    static func dismissIfVisible() {
        guard isVisible else { return }

        if cancelMenu(inBundleIdentifier: "com.apple.dock.helper") {
            return
        }
        _ = cancelMenu(inBundleIdentifier: "com.apple.dock")
    }

    private static var isVisible: Bool {
        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        return windows.contains { window in
            guard (window[kCGWindowOwnerName as String] as? String) == "DockHelper" else {
                return false
            }
            return (window[kCGWindowLayer as String] as? Int ?? 0) >= NSWindow.Level.popUpMenu.rawValue
        }
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

    var isContextClick: Bool {
        self == .right || self == .other
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
