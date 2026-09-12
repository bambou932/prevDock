import Cocoa
import QuartzCore

enum PreviewPresentationResult: Equatable {
    case shown
    case hidden
    case suppressed
}

final class PreviewPanelController {
    typealias FocusPerformer = (CGWindowID, NSRunningApplication, @escaping (Bool) -> Void) -> WindowFocusRequest
    typealias ClosePerformer = (CGWindowID, NSRunningApplication, Bool, @escaping (Bool) -> Void) -> Void

    var onFocusTransitionStarted: (() -> Void)?
    var onFocusTransitionFinished: ((Bool) -> Void)?
    // Pending focus and suppression after a successful focus have different lifetimes.
    private(set) var isFocusTransitionActive = false
    private let focusPerformer: FocusPerformer
    private let closePerformer: ClosePerformer
    private var focusRequest: WindowFocusRequest?
    private var focusTransitionGeneration: UInt64 = 0
    private var focusTransitionFrame: NSRect?
    private var isPresentationBlocked = false
    private let surface = PreviewPanelSurface()
    private var panel: NSPanel { surface.panel }
    private var contentView: NSView { surface.contentView }
    private var stackView: NSStackView { surface.stackView }
    private var cardsByWindowID = [CGWindowID: PreviewCardView]()
    private var currentPreviews = [WindowPreview]()
    private var currentApp: NSRunningApplication?
    private var currentImageHeight: CGFloat = 140
    private var currentOverflowMode = PrevDockSettings.defaultPreviewOverflowMode
    private var currentDesktopGroupingEnabled = PrevDockSettings.defaultPreviewDesktopGroupingEnabled
    private var currentCloseButtonEnabled = PrevDockSettings.previewCloseButtonEnabled
    private var currentContentSize = PrevDockSettings.previewContentSize
    private var currentAutoLayoutPlan: PreviewLayoutPlan?
    private var currentCompactListPlan: PreviewCompactListPlan?
    private let layout = PreviewPanelLayout()
    private var currentAutoDesktopGroups: [PreviewDesktopGroup]?
    private var currentSize = NSSize(width: 160, height: 48)
    private var currentAnchor = CGRect.zero
    private var currentAvailablePanelSize = NSSize.zero
    private var initialHoverSuppressionPoint: CGPoint?
    private var removalAnimationGeneration = 0
    private var layoutAnimationGeneration = 0
    private var pendingAutoHoverTransferWindowID: CGWindowID?
    private var presentationGeneration = 0

    private var contentBuilder: PreviewPanelContentBuilder {
        PreviewPanelContentBuilder(
            stackView: stackView,
            layout: layout,
            initialHoverSuppressionPoint: initialHoverSuppressionPoint,
            cardFactory: makeCard(for:imageHeight:compactSize:)
        )
    }

    var isVisible: Bool {
        panel.isVisible
    }

    var needsBackgroundThumbnails: Bool {
        panel.isVisible && currentCompactListPlan == nil
    }

    var visibleApp: NSRunningApplication? {
        panel.isVisible ? currentApp : nil
    }

    init(
        focusPerformer: @escaping FocusPerformer = { windowID, app, completion in
            WindowInventory.focusWindow(windowID: windowID, app: app, completion: completion)
        },
        closePerformer: @escaping ClosePerformer = WindowInventory.closeWindow
    ) {
        self.focusPerformer = focusPerformer
        self.closePerformer = closePerformer
        WindowPeekController.shared.setLiveImageUpdateHandler { [weak self] windowID, image in
            self?.updateThumbnail(windowID: windowID, image: image, animated: false)
        }
    }

    deinit {
        focusRequest?.cancel()
    }

    // Only fresh user intent may admit a new shelf; metadata cannot reopen a selected preview.
    func resumePresentationForInteraction() {
        focusTransitionGeneration &+= 1
        focusRequest?.cancel()
        focusRequest = nil
        focusTransitionFrame = nil
        isFocusTransitionActive = false
        isPresentationBlocked = false
    }

    @discardableResult
    func show(
        previews: [WindowPreview],
        app: NSRunningApplication,
        anchoredTo anchor: CGRect
    ) -> PreviewPresentationResult {
        guard !previews.isEmpty else {
            guard !isPresentationBlocked || currentApp?.processIdentifier == app.processIdentifier else {
                return .suppressed
            }
            clearEmptyPresentation()
            return .hidden
        }
        guard !isPresentationBlocked else { return .suppressed }
        if !panel.isVisible || currentApp?.processIdentifier != app.processIdentifier {
            presentationGeneration &+= 1
        }
        panel.title = "prevDock.preview.\(app.processIdentifier).\(presentationGeneration)"
        let visiblePreviews = stabilizedPreviews(previews, app: app)
        let preferredImageHeight = PreviewMetrics.imageHeight(anchoredTo: anchor)
        let overflowMode = PrevDockSettings.previewOverflowMode
        let usesAutoFit = overflowMode == .scroll && PrevDockSettings.previewAutoFitEnabled
        let desktopGroupingEnabled = PrevDockSettings.previewDesktopGroupingEnabled
        let autoLayoutPlan: PreviewLayoutPlan?
        let autoDesktopGroups: [PreviewDesktopGroup]?
        let imageHeight: CGFloat
        if usesAutoFit {
            switch self.layout.autoLayoutDecision(
                previews: visiblePreviews,
                anchoredTo: anchor,
                preferredImageHeight: preferredImageHeight,
                desktopGroupingEnabled: desktopGroupingEnabled
            ) {
            case .thumbnails(let plan, let groups):
                autoLayoutPlan = plan
                autoDesktopGroups = groups
                imageHeight = plan.imageHeight
            case .compactList:
                showCompactList(previews: visiblePreviews, app: app, anchoredTo: anchor)
                return .shown
            }
        } else {
            autoLayoutPlan = nil
            autoDesktopGroups = nil
            imageHeight = preferredImageHeight
        }
        if canUpdatePreviewContentInPlace(
            previews: visiblePreviews,
            app: app,
            anchoredTo: anchor,
            imageHeight: imageHeight,
            overflowMode: overflowMode,
            desktopGroupingEnabled: desktopGroupingEnabled,
            autoLayoutPlan: autoLayoutPlan,
            autoDesktopGroups: autoDesktopGroups
        ) {
            updatePreviewContentInPlace(
                previews: visiblePreviews,
                app: app,
                anchoredTo: anchor,
                imageHeight: imageHeight,
                overflowMode: overflowMode,
                desktopGroupingEnabled: desktopGroupingEnabled,
                autoLayoutPlan: autoLayoutPlan,
                autoDesktopGroups: autoDesktopGroups
            )
            return .shown
        }

        if shouldAnimateRemoval(
            to: visiblePreviews,
            app: app,
            overflowMode: overflowMode,
            desktopGroupingEnabled: desktopGroupingEnabled,
            imageHeight: imageHeight,
            autoLayoutPlan: autoLayoutPlan,
            autoDesktopGroups: autoDesktopGroups
        ) {
            let removedIDs = Set(currentPreviews.map(\.windowID)).subtracting(visiblePreviews.map(\.windowID))
            animateRemoval(
                windowIDs: removedIDs,
                nextPreviews: visiblePreviews,
                app: app,
                anchor: anchor,
                imageHeight: imageHeight,
                overflowMode: overflowMode,
                desktopGroupingEnabled: desktopGroupingEnabled,
                autoLayoutPlan: autoLayoutPlan,
                autoDesktopGroups: autoDesktopGroups
            )
            return .shown
        }

        render(
            previews: visiblePreviews,
            app: app,
            anchoredTo: anchor,
            imageHeight: imageHeight,
            overflowMode: overflowMode,
            desktopGroupingEnabled: desktopGroupingEnabled,
            autoLayoutPlan: autoLayoutPlan,
            autoDesktopGroups: autoDesktopGroups
        )
        return .shown
    }

    private func showCompactList(previews: [WindowPreview], app: NSRunningApplication, anchoredTo anchor: CGRect) {
        let plan = self.layout.compactListPlan(itemCount: previews.count, anchoredTo: anchor)
        let sameApp = panel.isVisible && currentApp?.processIdentifier == app.processIdentifier
        if sameApp, currentCompactListPlan == plan,
           currentDesktopGroupingEnabled == PrevDockSettings.previewDesktopGroupingEnabled,
           currentCloseButtonEnabled == PrevDockSettings.previewCloseButtonEnabled,
           currentContentSize == PrevDockSettings.previewContentSize,
           currentPreviews.map(\.windowID) == previews.map(\.windowID) {
            currentPreviews = previews
            currentAnchor = anchor
            previews.forEach { cardsByWindowID[$0.windowID]?.updatePreview($0) }
            reposition(near: anchor.origin)
            return
        }
        renderCompactList(previews: previews, app: app, anchoredTo: anchor, plan: plan, sameApp: sameApp)
    }

    private func renderCompactList(
        previews: [WindowPreview],
        app: NSRunningApplication,
        anchoredTo anchor: CGRect,
        plan: PreviewCompactListPlan,
        sameApp: Bool
    ) {
        let scrollPosition = sameApp ? PreviewPresentationLayout.scrollPosition(in: stackView) : nil
        let hoverWindowID = prepareAutoHoverTransfer(previews: previews, enabled: sameApp)
        invalidateLayoutAnimation()
        invalidateRemovalAnimation()
        let mouse = DockCursorTracker.shared.currentMouseLocation(preferEventTap: true)
        initialHoverSuppressionPoint = contains(mouse) ? nil : mouse
        clearStack()
        cardsByWindowID.removeAll()
        updateCurrentPresentation(
            previews: previews, app: app, anchor: anchor, imageHeight: 0,
            overflowMode: .scroll,
            desktopGroupingEnabled: PrevDockSettings.previewDesktopGroupingEnabled,
            autoLayoutPlan: nil, autoDesktopGroups: nil
        )
        currentCompactListPlan = plan
        stackView.spacing = 0
        self.contentBuilder.installCompactListRows(previews: previews, plan: plan)
        currentSize = plan.panelSize
        let frame = self.layout.positionedFrame(width: currentSize.width, height: currentSize.height, anchoredTo: anchor)
        presentRenderedContent(frame: frame, animated: false) {
            PreviewPresentationLayout.restoreScrollPosition(scrollPosition, in: self.stackView)
            self.finishAutoHoverTransfer(windowID: hoverWindowID)
        }
    }

    private func stabilizedPreviews(_ previews: [WindowPreview], app: NSRunningApplication) -> [WindowPreview] {
        guard panel.isVisible,
              currentApp?.processIdentifier == app.processIdentifier else {
            return previews
        }

        let currentOrder = Dictionary(uniqueKeysWithValues: currentPreviews.enumerated().map { ($0.element.windowID, $0.offset) })
        return previews.sorted { lhs, rhs in
            switch (currentOrder[lhs.windowID], currentOrder[rhs.windowID]) {
            case let (lhsIndex?, rhsIndex?):
                return lhsIndex < rhsIndex
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return stablePreviewOrder(lhs, rhs)
            }
        }
    }

    private func stablePreviewOrder(_ lhs: WindowPreview, _ rhs: WindowPreview) -> Bool {
        let lhsDesktopOrder = lhs.desktop?.sortOrder ?? Int.max
        let rhsDesktopOrder = rhs.desktop?.sortOrder ?? Int.max
        if lhsDesktopOrder != rhsDesktopOrder {
            return lhsDesktopOrder < rhsDesktopOrder
        }
        return lhs.windowID < rhs.windowID
    }

    func updateThumbnail(windowID: CGWindowID, image: NSImage, animated: Bool = true) {
        if let index = currentPreviews.firstIndex(where: { $0.windowID == windowID }) {
            currentPreviews[index] = currentPreviews[index].replacingImage(with: image)
        }
        cardsByWindowID[windowID]?.updateImage(image, animated: animated)
    }

    func markThumbnailUnavailable(windowID: CGWindowID) {
        cardsByWindowID[windowID]?.markThumbnailUnavailable()
    }

    func reposition(near mouse: CGPoint) {
        guard panel.isVisible else { return }
        panel.setFrame(self.layout.positionedFrame(width: currentSize.width, height: currentSize.height, anchoredTo: currentAnchor), display: true)
    }

    func hide() {
        cardsByWindowID.values.forEach { $0.deactivateForPanelHide() }
        if panel.isVisible {
            presentationGeneration &+= 1
        }
        invalidateRemovalAnimation()
        invalidateLayoutAnimation()
        cancelPendingAutoHoverTransfer()
        WindowPeekController.shared.hide()
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func clearEmptyPresentation() {
        hide()
        clearStack()
        cardsByWindowID.removeAll()
        currentPreviews.removeAll()
        currentApp = nil
        currentAutoLayoutPlan = nil
        currentCompactListPlan = nil
        currentAutoDesktopGroups = nil
        layout.clearCache()
        currentAvailablePanelSize = .zero
        currentAnchor = .zero
        initialHoverSuppressionPoint = nil
        panel.title = "prevDock.preview.idle"
    }

    @discardableResult
    func refreshForSettingsChange() -> PreviewPresentationResult? {
        guard panel.isVisible, let currentApp else { return nil }
        return show(
            previews: currentPreviews,
            app: currentApp,
            anchoredTo: currentAnchor
        )
    }

    func contains(_ point: CGPoint) -> Bool {
        panel.isVisible && panel.frame.insetBy(dx: -8, dy: -8).contains(point)
    }

    func synchronizeHoverEffects(at point: CGPoint) {
        guard panel.isVisible, !isPresentationBlocked else { return }
        let allowsActivation = NSEvent.pressedMouseButtons == 0
        cardsByWindowID.values.forEach { $0.synchronizeHover(at: point, allowsActivation: allowsActivation) }
        deactivateStaleDesktopGroupHovers(at: point, in: contentView)
    }

    private func render(
        previews: [WindowPreview],
        app: NSRunningApplication,
        anchoredTo anchor: CGRect,
        imageHeight: CGFloat,
        overflowMode: PreviewOverflowMode,
        desktopGroupingEnabled: Bool,
        autoLayoutPlan: PreviewLayoutPlan? = nil,
        autoDesktopGroups: [PreviewDesktopGroup]? = nil,
        preservesAutoHover: Bool = false
    ) {
        guard !previews.isEmpty else {
            clearEmptyPresentation()
            return
        }
        let scrollPosition = panel.isVisible && currentApp?.processIdentifier == app.processIdentifier ?
            PreviewPresentationLayout.scrollPosition(in: stackView) : nil
        let preservesVisibleAutoHover = rebuildsVisibleAutoPresentation(
            app: app,
            autoLayoutPlan: autoLayoutPlan
        )
        let animatesAutoFrame = preservesVisibleAutoHover && currentAutoLayoutPlan != autoLayoutPlan
        let hoverTransferWindowID = prepareAutoHoverTransfer(
            previews: previews,
            enabled: preservesVisibleAutoHover || preservesAutoHover
        )
        invalidateLayoutAnimation()
        invalidateRemovalAnimation()
        let mouse = DockCursorTracker.shared.currentMouseLocation(preferEventTap: true)
        initialHoverSuppressionPoint = contains(mouse) ? nil : mouse
        clearStack()
        stackView.spacing = PreviewMetrics.rowSpacing
        cardsByWindowID.removeAll()
        updateCurrentPresentation(
            previews: previews,
            app: app,
            anchor: anchor,
            imageHeight: imageHeight,
            overflowMode: overflowMode,
            desktopGroupingEnabled: desktopGroupingEnabled,
            autoLayoutPlan: autoLayoutPlan,
            autoDesktopGroups: autoDesktopGroups
        )
        self.contentBuilder.addPreviewContent(
            previews: previews,
            app: app,
            anchoredTo: anchor,
            imageHeight: imageHeight,
            overflowMode: overflowMode,
            desktopGroupingEnabled: desktopGroupingEnabled,
            autoLayoutPlan: autoLayoutPlan,
            autoDesktopGroups: autoDesktopGroups
        )
        currentSize = self.layout.measuredSize(
            previews: previews,
            app: app,
            anchoredTo: anchor,
            imageHeight: imageHeight,
            overflowMode: overflowMode,
            desktopGroupingEnabled: desktopGroupingEnabled,
            autoLayoutPlan: autoLayoutPlan
        )
        let nextFrame = self.layout.positionedFrame(width: currentSize.width, height: currentSize.height, anchoredTo: anchor)
        presentRenderedContent(frame: nextFrame, animated: animatesAutoFrame && frameNeedsUpdate(panel.frame, nextFrame)) {
            PreviewPresentationLayout.restoreScrollPosition(scrollPosition, in: self.stackView)
            self.finishAutoHoverTransfer(windowID: hoverTransferWindowID)
        }
    }

    private func rebuildsVisibleAutoPresentation(
        app: NSRunningApplication,
        autoLayoutPlan: PreviewLayoutPlan?
    ) -> Bool {
        panel.isVisible &&
            currentApp?.processIdentifier == app.processIdentifier &&
            currentAutoLayoutPlan != nil &&
            autoLayoutPlan != nil
    }

    private func presentRenderedContent(
        frame: NSRect,
        animated: Bool,
        completion: @escaping () -> Void
    ) {
        guard animated, panel.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(frame, display: true)
            contentView.layoutSubtreeIfNeeded()
            panel.orderFrontRegardless()
            completion()
            return
        }

        layoutAnimationGeneration &+= 1
        let generation = layoutAnimationGeneration
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            guard let self,
                  self.layoutAnimationGeneration == generation else {
                return
            }
            self.contentView.layoutSubtreeIfNeeded()
            completion()
        }
    }

    private func invalidateLayoutAnimation() {
        layoutAnimationGeneration &+= 1
    }

    private func prepareAutoHoverTransfer(
        previews: [WindowPreview],
        enabled: Bool
    ) -> CGWindowID? {
        guard enabled else {
            cancelPendingAutoHoverTransfer()
            return nil
        }

        let nextWindowIDs = Set(previews.map(\.windowID))
        if let pendingWindowID = pendingAutoHoverTransferWindowID,
           !nextWindowIDs.contains(pendingWindowID) {
            WindowPeekController.shared.hide(windowID: pendingWindowID)
            pendingAutoHoverTransferWindowID = nil
        }
        let hoveredWindowID = cardsByWindowID.first { windowID, card in
            nextWindowIDs.contains(windowID) && card.isHoverActive
        }?.key
        if let hoveredWindowID,
           let pendingWindowID = pendingAutoHoverTransferWindowID,
           pendingWindowID != hoveredWindowID {
            WindowPeekController.shared.hide(windowID: pendingWindowID)
        }
        guard let windowID = hoveredWindowID ?? pendingAutoHoverTransferWindowID else { return nil }
        cardsByWindowID[windowID]?.preservePeekForReflow()
        pendingAutoHoverTransferWindowID = windowID
        return windowID
    }

    private func finishAutoHoverTransfer(windowID: CGWindowID?) {
        guard let windowID,
              pendingAutoHoverTransferWindowID == windowID else {
            return
        }
        pendingAutoHoverTransferWindowID = nil
        if cardsByWindowID.contains(where: { $0.key != windowID && $0.value.isHoverActive }) {
            WindowPeekController.shared.hide(windowID: windowID)
            return
        }
        let mouse = DockCursorTracker.shared.currentMouseLocation(preferEventTap: true)
        guard cardsByWindowID[windowID]?.restoreHoverIfNeeded(at: mouse) == true else {
            WindowPeekController.shared.hide(windowID: windowID)
            return
        }
    }

    private func cancelPendingAutoHoverTransfer() {
        guard let windowID = pendingAutoHoverTransferWindowID else { return }
        pendingAutoHoverTransferWindowID = nil
        WindowPeekController.shared.hide(windowID: windowID)
    }

    private func canUpdatePreviewContentInPlace(
        previews: [WindowPreview],
        app: NSRunningApplication,
        anchoredTo anchor: CGRect,
        imageHeight: CGFloat,
        overflowMode: PreviewOverflowMode,
        desktopGroupingEnabled: Bool,
        autoLayoutPlan: PreviewLayoutPlan?,
        autoDesktopGroups: [PreviewDesktopGroup]?
    ) -> Bool {
        guard currentApp?.processIdentifier == app.processIdentifier,
              sizesMatch(currentAvailablePanelSize, self.layout.availablePanelSize(anchoredTo: anchor)),
              currentOverflowMode == overflowMode,
              currentDesktopGroupingEnabled == desktopGroupingEnabled,
              currentCloseButtonEnabled == PrevDockSettings.previewCloseButtonEnabled,
              currentContentSize == PrevDockSettings.previewContentSize,
              currentCompactListPlan == nil,
              currentAutoLayoutPlan == autoLayoutPlan,
              autoDesktopGroupSnapshotsMatch(currentAutoDesktopGroups, autoDesktopGroups),
              abs(currentImageHeight - imageHeight) < 0.5,
              currentPreviews.map(\.windowID) == previews.map(\.windowID),
              previews.allSatisfy({ cardsByWindowID[$0.windowID]?.canReuseForPresentation == true }) else {
            return false
        }

        return hasSamePreviewSizing(previews, imageHeight: imageHeight) &&
            hasSameDesktopPresentation(previews)
    }

    private func updatePreviewContentInPlace(
        previews: [WindowPreview],
        app: NSRunningApplication,
        anchoredTo anchor: CGRect,
        imageHeight: CGFloat,
        overflowMode: PreviewOverflowMode,
        desktopGroupingEnabled: Bool,
        autoLayoutPlan: PreviewLayoutPlan?,
        autoDesktopGroups: [PreviewDesktopGroup]?
    ) {
        if !panel.isVisible {
            let mouse = DockCursorTracker.shared.currentMouseLocation(preferEventTap: true)
            initialHoverSuppressionPoint = contains(mouse) ? nil : mouse
            cardsByWindowID.values.forEach {
                $0.prepareForPanelPresentation(
                    initialHoverSuppressionPoint: initialHoverSuppressionPoint
                )
            }
        }
        updateCurrentPresentation(
            previews: previews,
            app: app,
            anchor: anchor,
            imageHeight: imageHeight,
            overflowMode: overflowMode,
            desktopGroupingEnabled: desktopGroupingEnabled,
            autoLayoutPlan: autoLayoutPlan,
            autoDesktopGroups: autoDesktopGroups
        )
        previews.forEach { cardsByWindowID[$0.windowID]?.updatePreview($0) }
        currentSize = self.layout.measuredSize(
            previews: previews,
            app: app,
            anchoredTo: anchor,
            imageHeight: imageHeight,
            overflowMode: overflowMode,
            desktopGroupingEnabled: desktopGroupingEnabled,
            autoLayoutPlan: autoLayoutPlan
        )
        let nextFrame = self.layout.positionedFrame(width: currentSize.width, height: currentSize.height, anchoredTo: anchor)
        if frameNeedsUpdate(panel.frame, nextFrame) {
            panel.setFrame(nextFrame, display: false)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func hasSamePreviewSizing(_ previews: [WindowPreview], imageHeight: CGFloat) -> Bool {
        zip(currentPreviews, previews).allSatisfy { current, next in
            sizesMatch(
                PreviewCardView.cardSize(for: current, imageHeight: imageHeight),
                PreviewCardView.cardSize(for: next, imageHeight: imageHeight)
            )
        }
    }

    private func hasSameDesktopPresentation(_ previews: [WindowPreview]) -> Bool {
        zip(currentPreviews, previews).allSatisfy { current, next in
            current.desktop?.id == next.desktop?.id &&
                current.desktop?.title == next.desktop?.title &&
                current.desktop?.isCurrent == next.desktop?.isCurrent
        }
    }

    private func autoDesktopGroupSnapshotsMatch(
        _ current: [PreviewDesktopGroup]?,
        _ next: [PreviewDesktopGroup]?
    ) -> Bool {
        switch (current, next) {
        case (nil, nil):
            return true
        case let (current?, next?):
            guard current.count == next.count else { return false }
            return zip(current, next).allSatisfy { currentGroup, nextGroup in
                currentGroup.key == nextGroup.key &&
                    currentGroup.title == nextGroup.title &&
                    currentGroup.isCurrent == nextGroup.isCurrent &&
                    currentGroup.previews.map(\.windowID) == nextGroup.previews.map(\.windowID)
            }
        default:
            return false
        }
    }

    private func autoDesktopGroupPresentationsMatch(
        _ current: [PreviewDesktopGroup]?,
        _ next: [PreviewDesktopGroup]?,
        excluding excludedWindowIDs: Set<CGWindowID>
    ) -> Bool {
        switch (current, next) {
        case (nil, nil):
            return true
        case let (current?, next?):
            let currentGroups = current.filter {
                $0.previews.contains { !excludedWindowIDs.contains($0.windowID) }
            }
            let nextGroups = next.filter {
                $0.previews.contains { !excludedWindowIDs.contains($0.windowID) }
            }
            guard currentGroups.count == nextGroups.count else { return false }
            return zip(currentGroups, nextGroups).allSatisfy { currentGroup, nextGroup in
                currentGroup.key == nextGroup.key &&
                    currentGroup.title == nextGroup.title &&
                    currentGroup.isCurrent == nextGroup.isCurrent &&
                    currentGroup.previews
                        .map(\.windowID)
                        .filter { !excludedWindowIDs.contains($0) } ==
                    nextGroup.previews
                        .map(\.windowID)
                        .filter { !excludedWindowIDs.contains($0) }
            }
        default:
            return false
        }
    }

    private func survivingPreviewSizesMatch(
        _ nextPreviews: [WindowPreview],
        imageHeight: CGFloat
    ) -> Bool {
        let currentByWindowID = Dictionary(uniqueKeysWithValues: currentPreviews.map { ($0.windowID, $0) })
        return nextPreviews.allSatisfy { next in
            guard let current = currentByWindowID[next.windowID] else { return false }
            return sizesMatch(
                PreviewCardView.cardSize(for: current, imageHeight: currentImageHeight),
                PreviewCardView.cardSize(for: next, imageHeight: imageHeight)
            )
        }
    }

    private func sizesMatch(_ lhs: NSSize, _ rhs: NSSize) -> Bool {
        abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
    }

    private func frameNeedsUpdate(_ current: NSRect, _ next: NSRect) -> Bool {
        abs(current.minX - next.minX) > 0.5 ||
            abs(current.minY - next.minY) > 0.5 ||
            abs(current.width - next.width) > 0.5 ||
            abs(current.height - next.height) > 0.5
    }

    private func deactivateStaleDesktopGroupHovers(at point: CGPoint, in view: NSView) {
        if let groupView = view as? DesktopGroupView {
            groupView.deactivateHoverIfNeeded(outside: point)
        }
        view.subviews.forEach { deactivateStaleDesktopGroupHovers(at: point, in: $0) }
    }

    private func updateCurrentPresentation(
        previews: [WindowPreview],
        app: NSRunningApplication,
        anchor: CGRect,
        imageHeight: CGFloat,
        overflowMode: PreviewOverflowMode,
        desktopGroupingEnabled: Bool,
        autoLayoutPlan: PreviewLayoutPlan?,
        autoDesktopGroups: [PreviewDesktopGroup]?
    ) {
        currentPreviews = previews
        currentApp = app
        currentAnchor = anchor
        currentAvailablePanelSize = self.layout.availablePanelSize(anchoredTo: anchor)
        currentImageHeight = imageHeight
        currentOverflowMode = overflowMode
        currentDesktopGroupingEnabled = desktopGroupingEnabled
        currentCloseButtonEnabled = PrevDockSettings.previewCloseButtonEnabled
        currentContentSize = PrevDockSettings.previewContentSize
        currentCompactListPlan = nil
        currentAutoLayoutPlan = autoLayoutPlan
        currentAutoDesktopGroups = autoDesktopGroups
    }

    private func removePreview(windowID: CGWindowID, appPID: pid_t) {
        guard !isPresentationBlocked,
              let app = currentApp,
              app.processIdentifier == appPID,
              currentPreviews.contains(where: { $0.windowID == windowID }) else {
            return
        }
        let nextPreviews = currentPreviews.filter { $0.windowID != windowID }
        guard !nextPreviews.isEmpty else {
            clearEmptyPresentation()
            return
        }
        if currentAutoLayoutPlan != nil || currentCompactListPlan != nil {
            _ = show(previews: nextPreviews, app: app, anchoredTo: currentAnchor)
            return
        }
        animateRemoval(
            windowIDs: [windowID],
            nextPreviews: nextPreviews,
            app: app,
            anchor: currentAnchor,
            imageHeight: currentImageHeight,
            overflowMode: currentOverflowMode,
            desktopGroupingEnabled: currentDesktopGroupingEnabled,
            autoLayoutPlan: nil,
            autoDesktopGroups: nil
        )
    }

    private func clearStack() {
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func shouldAnimateRemoval(
        to previews: [WindowPreview],
        app: NSRunningApplication,
        overflowMode: PreviewOverflowMode,
        desktopGroupingEnabled: Bool,
        imageHeight: CGFloat,
        autoLayoutPlan: PreviewLayoutPlan?,
        autoDesktopGroups: [PreviewDesktopGroup]?
    ) -> Bool {
        guard panel.isVisible,
              currentApp?.processIdentifier == app.processIdentifier,
              currentOverflowMode == overflowMode,
              currentDesktopGroupingEnabled == desktopGroupingEnabled else {
            return false
        }
        let currentIDs = Set(currentPreviews.map(\.windowID))
        let nextIDs = Set(previews.map(\.windowID))
        let removedIDs = currentIDs.subtracting(nextIDs)
        guard !removedIDs.isEmpty,
              !removedIDs.isDisjoint(with: Set(cardsByWindowID.keys)) else {
            return false
        }
        guard currentCompactListPlan == nil else { return false }
        if currentAutoLayoutPlan != nil || autoLayoutPlan != nil {
            guard let currentAutoLayoutPlan,
                  let autoLayoutPlan,
                  abs(currentImageHeight - imageHeight) < 0.5,
                  currentAutoLayoutPlan.shapeSignature(excluding: removedIDs) == autoLayoutPlan.shapeSignature(),
                  autoDesktopGroupPresentationsMatch(
                    currentAutoDesktopGroups,
                    autoDesktopGroups,
                    excluding: removedIDs
                  ),
                  survivingPreviewSizesMatch(previews, imageHeight: imageHeight) else {
                return false
            }
        }
        return true
    }

    private func animateRemoval(
        windowIDs: Set<CGWindowID>,
        nextPreviews: [WindowPreview],
        app: NSRunningApplication,
        anchor: CGRect,
        imageHeight: CGFloat,
        overflowMode: PreviewOverflowMode,
        desktopGroupingEnabled: Bool,
        autoLayoutPlan: PreviewLayoutPlan?,
        autoDesktopGroups: [PreviewDesktopGroup]?
    ) {
        guard !nextPreviews.isEmpty else {
            clearEmptyPresentation()
            return
        }
        removalAnimationGeneration += 1
        let generation = removalAnimationGeneration
        let duration = 0.16
        let existingCards = windowIDs.compactMap { cardsByWindowID[$0] }
        guard !existingCards.isEmpty else {
            render(
                previews: nextPreviews,
                app: app,
                anchoredTo: anchor,
                imageHeight: imageHeight,
                overflowMode: overflowMode,
                desktopGroupingEnabled: desktopGroupingEnabled,
                autoLayoutPlan: autoLayoutPlan,
                autoDesktopGroups: autoDesktopGroups
            )
            return
        }

        updateCurrentPresentation(
            previews: nextPreviews,
            app: app,
            anchor: anchor,
            imageHeight: imageHeight,
            overflowMode: overflowMode,
            desktopGroupingEnabled: desktopGroupingEnabled,
            autoLayoutPlan: autoLayoutPlan,
            autoDesktopGroups: autoDesktopGroups
        )
        existingCards.forEach { $0.collapseForRemoval(duration: duration) }
        windowIDs.forEach { cardsByWindowID.removeValue(forKey: $0) }

        currentSize = self.layout.measuredSize(
            previews: nextPreviews,
            app: app,
            anchoredTo: anchor,
            imageHeight: imageHeight,
            overflowMode: overflowMode,
            desktopGroupingEnabled: desktopGroupingEnabled,
            autoLayoutPlan: autoLayoutPlan
        )
        let nextFrame = self.layout.positionedFrame(width: currentSize.width, height: currentSize.height, anchoredTo: anchor)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(nextFrame, display: true)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) { [weak self] in
            guard let self,
                  self.panel.isVisible,
                  self.removalAnimationGeneration == generation else {
                return
            }
            guard let currentApp = self.currentApp else { return }
            self.render(
                previews: self.currentPreviews,
                app: currentApp,
                anchoredTo: self.currentAnchor,
                imageHeight: self.currentImageHeight,
                overflowMode: self.currentOverflowMode,
                desktopGroupingEnabled: self.currentDesktopGroupingEnabled,
                autoLayoutPlan: self.currentAutoLayoutPlan,
                autoDesktopGroups: self.currentAutoDesktopGroups,
                preservesAutoHover: self.currentAutoLayoutPlan != nil
            )
        }
    }

    private func invalidateRemovalAnimation() {
        removalAnimationGeneration += 1
    }

    private func beginFocusTransition(preview: WindowPreview, completion: @escaping (Bool) -> Void) {
        guard !isPresentationBlocked, panel.isVisible,
              currentApp?.processIdentifier == preview.app.processIdentifier,
              currentPreviews.contains(where: { $0.windowID == preview.windowID }) else {
            completion(false)
            return
        }
        focusRequest?.cancel()
        focusRequest = nil
        focusTransitionGeneration &+= 1
        let generation = focusTransitionGeneration
        isPresentationBlocked = true
        isFocusTransitionActive = true
        focusTransitionFrame = panel.frame
        cardsByWindowID.values.forEach { $0.suspendForFocusTransition() }
        hide()
        onFocusTransitionStarted?()
        guard focusTransitionGeneration == generation, isFocusTransitionActive else { return }
        let request = focusPerformer(preview.windowID, preview.app) { [weak self] success in
            self?.finishFocusTransition(success: success, generation: generation, completion: completion)
        }
        if focusTransitionGeneration == generation, isFocusTransitionActive || isPresentationBlocked {
            focusRequest = request
        } else {
            request.cancel()
        }
    }

    private func finishFocusTransition(
        success: Bool,
        generation: UInt64,
        completion: @escaping (Bool) -> Void
    ) {
        guard focusTransitionGeneration == generation, isFocusTransitionActive else { return }
        isFocusTransitionActive = false
        if !success {
            focusRequest?.cancel()
            focusRequest = nil
            restorePresentationAfterFocusFailure()
        }
        focusTransitionFrame = nil
        completion(success)
        onFocusTransitionFinished?(success)
    }

    private func restorePresentationAfterFocusFailure() {
        isPresentationBlocked = false
        guard let frame = focusTransitionFrame, currentApp?.isTerminated == false,
              !currentPreviews.isEmpty, !cardsByWindowID.isEmpty else { return }
        let mouse = DockCursorTracker.shared.currentMouseLocation(preferEventTap: true)
        cardsByWindowID.values.forEach { $0.prepareForPanelPresentation(initialHoverSuppressionPoint: mouse) }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    private func makeCard(
        for preview: WindowPreview,
        imageHeight: CGFloat,
        compactSize: NSSize? = nil
    ) -> PreviewCardView {
        let card = PreviewCardView(
            preview: preview,
            imageHeight: imageHeight,
            compactSize: compactSize,
            initialHoverSuppressionPoint: initialHoverSuppressionPoint,
            onFocus: { [weak self] preview, completion in
                guard let self else {
                    completion(false)
                    return
                }
                self.beginFocusTransition(preview: preview, completion: completion)
            },
            onClose: { [weak self] preview, completion in
                guard let self else {
                    completion(false)
                    return
                }
                let appPID = preview.app.processIdentifier
                self.closePerformer(preview.windowID, preview.app, preview.isFullscreen) { [weak self] success in
                    DispatchQueue.main.async {
                        guard success else {
                            completion(false)
                            return
                        }
                        self?.removePreview(windowID: preview.windowID, appPID: appPID)
                        completion(true)
                    }
                }
            }
        )
        cardsByWindowID[preview.windowID] = card
        return card
    }

}
