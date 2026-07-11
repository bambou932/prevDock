import Cocoa
import QuartzCore

enum PreviewPresentationResult: Equatable {
    case shown
    case requiresNativeDockMenu
}

final class PreviewPanelController {
    private let panel: NSPanel
    private let contentView = NSView()
    private let backdropView = NSVisualEffectView()
    private let stackView = NSStackView()
    private var cardsByWindowID = [CGWindowID: PreviewCardView]()
    private var currentPreviews = [WindowPreview]()
    private var currentApp: NSRunningApplication?
    private var currentImageHeight: CGFloat = 140
    private var currentOverflowMode = PrevDockSettings.defaultPreviewOverflowMode
    private var currentDesktopGroupingEnabled = PrevDockSettings.defaultPreviewDesktopGroupingEnabled
    private var currentAutoLayoutPlan: PreviewLayoutPlan?
    private var currentAutoDesktopGroups: [PreviewDesktopGroup]?
    private var currentSize = NSSize(width: 160, height: 48)
    private var currentAnchor = CGRect.zero
    private var initialHoverSuppressionPoint: CGPoint?
    private var removalAnimationGeneration = 0
    private var layoutAnimationGeneration = 0
    private var pendingAutoHoverTransferWindowID: CGWindowID?
    private var presentationGeneration = 0

    var isVisible: Bool {
        panel.isVisible
    }

    var visibleApp: NSRunningApplication? {
        panel.isVisible ? currentApp : nil
    }

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 190),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 12
        contentView.layer?.borderWidth = 1
        contentView.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        contentView.layer?.masksToBounds = true

        backdropView.material = .underPageBackground
        backdropView.blendingMode = .behindWindow
        backdropView.state = .active
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(backdropView)

        stackView.orientation = .vertical
        stackView.spacing = PreviewMetrics.rowSpacing
        stackView.alignment = .centerX
        stackView.distribution = .gravityAreas
        stackView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            backdropView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            backdropView.topAnchor.constraint(equalTo: contentView.topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: PreviewMetrics.panelPadding),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -PreviewMetrics.panelPadding),
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: PreviewMetrics.panelPadding),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -PreviewMetrics.panelPadding)
        ])

        panel.contentView = contentView
        WindowPeekController.shared.setLiveImageUpdateHandler { [weak self] windowID, image in
            self?.updateThumbnail(windowID: windowID, image: image, animated: false)
        }
    }

    @discardableResult
    func show(
        previews: [WindowPreview],
        app: NSRunningApplication,
        anchoredTo anchor: CGRect
    ) -> PreviewPresentationResult {
        if !panel.isVisible || currentApp?.processIdentifier != app.processIdentifier {
            presentationGeneration &+= 1
        }
        let visiblePreviews = stabilizedPreviews(previews, app: app)
        let preferredImageHeight = PreviewMetrics.imageHeight(anchoredTo: anchor)
        let overflowMode = PrevDockSettings.previewOverflowMode
        let desktopGroupingEnabled = PrevDockSettings.previewDesktopGroupingEnabled
        let autoLayoutPlan: PreviewLayoutPlan?
        let autoDesktopGroups: [PreviewDesktopGroup]?
        let imageHeight: CGFloat
        if overflowMode == .auto, !visiblePreviews.isEmpty {
            switch autoLayoutDecision(
                previews: visiblePreviews,
                anchoredTo: anchor,
                preferredImageHeight: preferredImageHeight,
                desktopGroupingEnabled: desktopGroupingEnabled
            ) {
            case .thumbnails(let plan, let groups):
                autoLayoutPlan = plan
                autoDesktopGroups = groups
                imageHeight = plan.imageHeight
            case .nativeDockMenu:
                return .requiresNativeDockMenu
            }
        } else {
            autoLayoutPlan = nil
            autoDesktopGroups = nil
            imageHeight = preferredImageHeight
        }
        if canUpdatePreviewContentInPlace(
            previews: visiblePreviews,
            app: app,
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

    func presentationRequirement(
        previews: [WindowPreview],
        app: NSRunningApplication,
        anchoredTo anchor: CGRect
    ) -> PreviewPresentationResult {
        let visiblePreviews = stabilizedPreviews(previews, app: app)
        guard PrevDockSettings.previewOverflowMode == .auto, !visiblePreviews.isEmpty else {
            return .shown
        }
        switch autoLayoutDecision(
            previews: visiblePreviews,
            anchoredTo: anchor,
            preferredImageHeight: PreviewMetrics.imageHeight(anchoredTo: anchor),
            desktopGroupingEnabled: PrevDockSettings.previewDesktopGroupingEnabled
        ) {
        case .thumbnails:
            return .shown
        case .nativeDockMenu:
            return .requiresNativeDockMenu
        }
    }

    func showReadableFallback(
        previews: [WindowPreview],
        app: NSRunningApplication,
        anchoredTo anchor: CGRect
    ) {
        render(
            previews: stabilizedPreviews(previews, app: app),
            app: app,
            anchoredTo: anchor,
            imageHeight: PreviewMetrics.minimumReadableImageHeight,
            overflowMode: .wrap,
            desktopGroupingEnabled: PrevDockSettings.previewDesktopGroupingEnabled
        )
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
        guard PermissionManager.status.screenRecordingGranted else { return }
        if let index = currentPreviews.firstIndex(where: { $0.windowID == windowID }) {
            currentPreviews[index] = currentPreviews[index].replacingImage(with: image)
        }
        cardsByWindowID[windowID]?.updateImage(image, animated: animated)
    }

    func reposition(near mouse: CGPoint) {
        guard panel.isVisible else { return }
        panel.setFrame(positionedFrame(width: currentSize.width, height: currentSize.height, anchoredTo: currentAnchor), display: true)
    }

    func hide() {
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

    func deactivateStaleHoverEffects(at point: CGPoint) {
        guard panel.isVisible else { return }
        cardsByWindowID.values.forEach { $0.deactivateHoverIfNeeded(outside: point) }
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
        let preservesVisibleAutoHover = rebuildsVisibleAutoPresentation(
            app: app,
            overflowMode: overflowMode
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
        addPreviewContent(
            previews: previews,
            app: app,
            anchoredTo: anchor,
            imageHeight: imageHeight,
            overflowMode: overflowMode,
            desktopGroupingEnabled: desktopGroupingEnabled,
            autoLayoutPlan: autoLayoutPlan,
            autoDesktopGroups: autoDesktopGroups
        )
        currentSize = measuredSize(
            previews: previews,
            app: app,
            anchoredTo: anchor,
            imageHeight: imageHeight,
            overflowMode: overflowMode,
            desktopGroupingEnabled: desktopGroupingEnabled,
            autoLayoutPlan: autoLayoutPlan
        )
        let nextFrame = positionedFrame(width: currentSize.width, height: currentSize.height, anchoredTo: anchor)
        presentRenderedContent(frame: nextFrame, animated: animatesAutoFrame && frameNeedsUpdate(panel.frame, nextFrame)) {
            self.finishAutoHoverTransfer(windowID: hoverTransferWindowID)
        }
    }

    private func rebuildsVisibleAutoPresentation(
        app: NSRunningApplication,
        overflowMode: PreviewOverflowMode
    ) -> Bool {
        panel.isVisible &&
            currentApp?.processIdentifier == app.processIdentifier &&
            currentOverflowMode == .auto &&
            overflowMode == .auto
    }

    private func presentRenderedContent(
        frame: NSRect,
        animated: Bool,
        completion: @escaping () -> Void
    ) {
        contentView.layoutSubtreeIfNeeded()
        guard animated, panel.isVisible else {
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
        imageHeight: CGFloat,
        overflowMode: PreviewOverflowMode,
        desktopGroupingEnabled: Bool,
        autoLayoutPlan: PreviewLayoutPlan?,
        autoDesktopGroups: [PreviewDesktopGroup]?
    ) -> Bool {
        guard panel.isVisible,
              currentApp?.processIdentifier == app.processIdentifier,
              currentOverflowMode == overflowMode,
              currentDesktopGroupingEnabled == desktopGroupingEnabled,
              currentAutoLayoutPlan == autoLayoutPlan,
              autoDesktopGroupSnapshotsMatch(currentAutoDesktopGroups, autoDesktopGroups),
              abs(currentImageHeight - imageHeight) < 0.5,
              currentPreviews.map(\.windowID) == previews.map(\.windowID),
              previews.allSatisfy({ cardsByWindowID[$0.windowID] != nil }) else {
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
        currentSize = measuredSize(
            previews: previews,
            app: app,
            anchoredTo: anchor,
            imageHeight: imageHeight,
            overflowMode: overflowMode,
            desktopGroupingEnabled: desktopGroupingEnabled,
            autoLayoutPlan: autoLayoutPlan
        )
        let nextFrame = positionedFrame(width: currentSize.width, height: currentSize.height, anchoredTo: anchor)
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
        currentImageHeight = imageHeight
        currentOverflowMode = overflowMode
        currentDesktopGroupingEnabled = desktopGroupingEnabled
        currentAutoLayoutPlan = autoLayoutPlan
        currentAutoDesktopGroups = autoDesktopGroups
    }

    private func addPreviewContent(
        previews: [WindowPreview],
        app: NSRunningApplication,
        anchoredTo anchor: CGRect,
        imageHeight: CGFloat,
        overflowMode: PreviewOverflowMode,
        desktopGroupingEnabled: Bool,
        autoLayoutPlan: PreviewLayoutPlan?,
        autoDesktopGroups: [PreviewDesktopGroup]?
    ) {
        if previews.isEmpty {
            stackView.addArrangedSubview(EmptyPreviewView(appName: app.localizedName ?? "Application"))
        } else if let autoLayoutPlan {
            addAutoPreviewContent(
                plan: autoLayoutPlan,
                previews: previews,
                groups: autoDesktopGroups
            )
        } else if let groups = desktopGroups(for: previews, enabled: desktopGroupingEnabled, anchoredTo: anchor) {
            stackView.spacing = PreviewMetrics.desktopGroupSpacing
            addGroupedPreviewContent(groups: groups, anchoredTo: anchor, imageHeight: imageHeight, overflowMode: overflowMode)
        } else if overflowMode == .scroll {
            if needsHorizontalScroll(for: previews, anchoredTo: anchor, imageHeight: imageHeight) {
                addScrollableRow(previews: previews, anchoredTo: anchor, imageHeight: imageHeight)
            } else {
                addPreviewRow(previews: previews, imageHeight: imageHeight)
            }
        } else {
            addWrappedPreviewRows(previews: previews, anchoredTo: anchor, imageHeight: imageHeight)
        }
    }

    private func addAutoPreviewContent(
        plan: PreviewLayoutPlan,
        previews: [WindowPreview],
        groups: [PreviewDesktopGroup]?
    ) {
        let previewsByID = Dictionary(uniqueKeysWithValues: previews.map { ($0.windowID, $0) })
        switch plan.arrangement {
        case .rows:
            let snapshot = PreviewPresentationLayout.installAutoRows(
                plan: plan,
                availableItemIDs: Set(previewsByID.keys),
                in: stackView
            ) { [self] windowID in
                guard let preview = previewsByID[windowID] else {
                    assertionFailure("Auto preview layout referenced a missing window")
                    return nil
                }
                return makeCard(for: preview, imageHeight: plan.imageHeight)
            }
            assert(snapshot?.itemIDs == plan.itemIDs, "Auto preview hierarchy did not match its plan")
        case .groupRows:
            stackView.spacing = PreviewMetrics.desktopGroupSpacing
            guard let groups else {
                assertionFailure("Grouped Auto plan is missing its immutable group snapshot")
                return
            }
            let groupsByID = Dictionary(uniqueKeysWithValues: groups.map { (layoutGroupID(for: $0.key), $0) })
            let snapshot = PreviewPresentationLayout.installAutoGroupRows(
                plan: plan,
                availableItemIDs: Set(previewsByID.keys),
                in: stackView
            ) { [self] row in
                var layoutRow = PreviewDesktopGroupLayoutRow()
                for groupPlan in row.groups {
                    guard let group = groupsByID[groupPlan.id] else {
                        assertionFailure("Auto preview group metadata changed during rendering")
                        return nil
                    }
                    let previewRows = groupPlan.itemRows.map {
                        resolvedPreviews(for: $0.itemIDs, in: previewsByID)
                    }
                    layoutRow.add(PreviewDesktopGroupLayout(
                        title: group.title,
                        isCurrent: group.isCurrent,
                        rows: previewRows,
                        rowHeight: groupPlan.itemRows.first?.size.height ?? 0,
                        size: groupPlan.size
                    ))
                }
                return makeDesktopGroupLayoutRow(layoutRow, imageHeight: plan.imageHeight)
            }
            assert(snapshot?.itemIDs == plan.itemIDs, "Grouped Auto hierarchy did not match its plan")
        }
    }

    private func resolvedPreviews(
        for windowIDs: [UInt32],
        in previewsByID: [CGWindowID: WindowPreview]
    ) -> [WindowPreview] {
        windowIDs.compactMap { windowID in
            guard let preview = previewsByID[windowID] else {
                assertionFailure("Auto preview layout referenced a missing window")
                return nil
            }
            return preview
        }
    }

    private func addPreviewRow(previews: [WindowPreview], imageHeight: CGFloat) {
        let row = makePreviewRow(previews: previews, imageHeight: imageHeight)
        let size = NSSize(
            width: rowContentWidth(for: previews, imageHeight: imageHeight),
            height: rowHeight(for: previews, imageHeight: imageHeight)
        )
        PreviewPresentationLayout.installLegacyRows(
            mode: .scroll,
            rowViews: [row],
            contentSize: size,
            viewportSize: size,
            needsScroll: false,
            spacing: PreviewMetrics.rowSpacing,
            in: stackView
        )
    }

    private func addWrappedPreviewRows(previews: [WindowPreview], anchoredTo anchor: CGRect, imageHeight: CGFloat) {
        let layout = previewRowsLayout(for: previews, anchoredTo: anchor, imageHeight: imageHeight)
        let rowViews = layout.rows.map {
            makeCenteredPreviewRow(previews: $0, imageHeight: imageHeight, width: layout.contentSize.width)
        }
        PreviewPresentationLayout.installLegacyRows(
            mode: .wrap,
            rowViews: rowViews,
            contentSize: layout.contentSize,
            viewportSize: layout.viewportSize,
            needsScroll: layout.needsVerticalScroll,
            spacing: PreviewMetrics.rowSpacing,
            in: stackView
        )
    }

    private func addGroupedPreviewContent(
        groups: [PreviewDesktopGroup],
        anchoredTo anchor: CGRect,
        imageHeight: CGFloat,
        overflowMode: PreviewOverflowMode
    ) {
        if overflowMode == .scroll {
            addGroupedScrollableRow(groups: groups, anchoredTo: anchor, imageHeight: imageHeight)
            return
        }

        addWrappedGroups(groups, anchoredTo: anchor, imageHeight: imageHeight)
    }

    private func addGroupedScrollableRow(groups: [PreviewDesktopGroup], anchoredTo anchor: CGRect, imageHeight: CGFloat) {
        let groupSizes = groups.map { groupedSingleRowSize(for: $0, anchoredTo: anchor, imageHeight: imageHeight) }
        let contentWidth = groupedContentWidth(groupSizes)
        let viewportWidth = min(contentWidth, maxContentWidth(anchoredTo: anchor))
        let contentHeight = groupSizes.map(\.height).max() ?? 0
        let scrollViewHeight = contentHeight + groupedScrollBarHeight(contentWidth: contentWidth, anchoredTo: anchor)
        let groupStack = makeHorizontalStack(views: [], spacing: PreviewMetrics.desktopGroupSpacing)
        groupStack.alignment = .top
        for (index, group) in groups.enumerated() {
            groupStack.addArrangedSubview(makeDesktopGroupView(
                group: group,
                rows: [group.previews],
                size: groupSizes[index],
                imageHeight: imageHeight
            ))
        }
        PreviewPresentationLayout.installHorizontalScrollContainer(
            rowView: groupStack,
            contentSize: NSSize(width: contentWidth, height: contentHeight),
            viewportSize: NSSize(width: viewportWidth, height: scrollViewHeight),
            showsScroller: PreviewLegacyOverflowPolicy.needsHorizontalScroll(
                contentWidth: contentWidth,
                availableWidth: viewportWidth
            ),
            in: stackView
        )
    }

    private func addWrappedGroups(_ groups: [PreviewDesktopGroup], anchoredTo anchor: CGRect, imageHeight: CGFloat) {
        let wrapLayout = groupedWrapLayout(for: groups, anchoredTo: anchor, imageHeight: imageHeight)
        let rowViews = wrapLayout.rows.map {
            makeCenteredDesktopGroupLayoutRow($0, imageHeight: imageHeight, width: wrapLayout.contentSize.width)
        }
        PreviewPresentationLayout.installLegacyRows(
            mode: .wrap,
            rowViews: rowViews,
            contentSize: wrapLayout.contentSize,
            viewportSize: wrapLayout.viewportSize,
            needsScroll: wrapLayout.needsVerticalScroll,
            spacing: PreviewMetrics.desktopGroupSpacing,
            in: stackView
        )
    }

    private func makeDesktopGroupView(
        group: PreviewDesktopGroup,
        rows: [[WindowPreview]],
        size: NSSize,
        imageHeight: CGFloat
    ) -> DesktopGroupView {
        let groupContentWidth = max(0, size.width - PreviewMetrics.desktopGroupPadding * 2)
        let groupRowHeight = rowHeight(for: group.previews, imageHeight: imageHeight)
        let groupView = DesktopGroupView(
            title: group.title,
            isCurrent: group.isCurrent,
            size: size,
            initialHoverSuppressionPoint: initialHoverSuppressionPoint
        )
        rows.forEach {
            groupView.addContentRow(makeDesktopGroupContentRow(
                previews: $0,
                imageHeight: imageHeight,
                width: groupContentWidth,
                height: groupRowHeight
            ))
        }
        return groupView
    }

    private func makeCenteredPreviewRow(previews: [WindowPreview], imageHeight: CGFloat, width: CGFloat) -> NSView {
        makeCenteredRow(
            makePreviewRow(previews: previews, imageHeight: imageHeight),
            width: width,
            height: rowHeight(for: previews, imageHeight: imageHeight)
        )
    }

    private func makeCenteredDesktopGroupLayoutRow(
        _ row: PreviewDesktopGroupLayoutRow,
        imageHeight: CGFloat,
        width: CGFloat
    ) -> NSView {
        makeCenteredRow(
            makeDesktopGroupLayoutRow(row, imageHeight: imageHeight),
            width: width,
            height: row.height
        )
    }

    private func makeCenteredRow(_ row: NSView, width: CGFloat, height: CGFloat) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width),
            container.heightAnchor.constraint(equalToConstant: height),
            row.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func makeDesktopGroupLayoutRow(
        _ row: PreviewDesktopGroupLayoutRow,
        imageHeight: CGFloat
    ) -> NSStackView {
        let rowStack = makeHorizontalStack(views: [], spacing: PreviewMetrics.desktopGroupSpacing)
        rowStack.alignment = .top
        row.layouts.forEach { layout in
            let groupView = DesktopGroupView(
                title: layout.title,
                isCurrent: layout.isCurrent,
                size: layout.size,
                initialHoverSuppressionPoint: initialHoverSuppressionPoint
            )
            let groupContentWidth = max(0, layout.size.width - PreviewMetrics.desktopGroupPadding * 2)
            layout.rows.forEach { row in
                groupView.addContentRow(makeDesktopGroupContentRow(
                    previews: row,
                    imageHeight: imageHeight,
                    width: groupContentWidth,
                    height: layout.rowHeight
                ))
            }
            rowStack.addArrangedSubview(groupView)
        }
        return rowStack
    }

    private func makeDesktopGroupContentRow(
        previews: [WindowPreview],
        imageHeight: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> NSView {
        makeCenteredRow(
            makePreviewRow(previews: previews, imageHeight: imageHeight),
            width: width,
            height: height
        )
    }

    private func removePreview(windowID: CGWindowID, appPID: pid_t) {
        guard let app = currentApp,
              app.processIdentifier == appPID,
              currentPreviews.contains(where: { $0.windowID == windowID }) else {
            return
        }
        let nextPreviews = currentPreviews.filter { $0.windowID != windowID }
        if currentOverflowMode == .auto {
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
        if overflowMode == .auto {
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

        currentSize = measuredSize(
            previews: nextPreviews,
            app: app,
            anchoredTo: anchor,
            imageHeight: imageHeight,
            overflowMode: overflowMode,
            desktopGroupingEnabled: desktopGroupingEnabled,
            autoLayoutPlan: autoLayoutPlan
        )
        let nextFrame = positionedFrame(width: currentSize.width, height: currentSize.height, anchoredTo: anchor)
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
                preservesAutoHover: self.currentOverflowMode == .auto
            )
        }
    }

    private func invalidateRemovalAnimation() {
        removalAnimationGeneration += 1
    }

    private func autoLayoutDecision(
        previews: [WindowPreview],
        anchoredTo anchor: CGRect,
        preferredImageHeight: CGFloat,
        desktopGroupingEnabled: Bool
    ) -> AutoPreviewLayoutDecision {
        let screen = ScreenGeometry.screen(containing: anchor) ?? NSScreen.main
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let availablePanelSize = PreviewPanelAvailableSpace.size(
            visibleFrame: visibleFrame,
            screenFrame: screenFrame,
            dockAnchor: anchor,
            dockEdge: autoLayoutDockEdge(for: anchor, in: screenFrame)
        )
        let metrics = autoLayoutMetrics()
        let groups = desktopGroups(
            for: previews,
            enabled: desktopGroupingEnabled,
            anchoredTo: anchor
        )
        let content = autoLayoutContent(
            previews: previews,
            groups: groups,
            availablePanelSize: availablePanelSize,
            metrics: metrics
        )
        let decision = PreviewLayoutPlanner.plan(PreviewLayoutInput(
            content: content,
            preferredImageHeight: preferredImageHeight,
            minimumImageHeight: PreviewMetrics.minimumReadableImageHeight,
            availablePanelSize: availablePanelSize,
            backingScale: max(1, screen?.backingScaleFactor ?? 1),
            metrics: metrics
        ))
        switch decision {
        case .thumbnails(let plan):
            return .thumbnails(plan: plan, groups: groups)
        case .nativeDockMenu:
            return .nativeDockMenu
        }
    }

    private func autoLayoutDockEdge(for anchor: CGRect, in frame: CGRect) -> PreviewPanelDockEdge {
        switch dockEdge(for: anchor, in: frame) {
        case .bottom:
            return .bottom
        case .top:
            return .top
        case .left:
            return .left
        case .right:
            return .right
        }
    }

    private func autoLayoutContent(
        previews: [WindowPreview],
        groups: [PreviewDesktopGroup]?,
        availablePanelSize: NSSize,
        metrics: PreviewLayoutMetrics
    ) -> PreviewLayoutContent {
        guard let groups else {
            return .ungrouped(previews.map { layoutItem(for: $0) })
        }

        let maximumHeaderWidth = max(
            0,
            availablePanelSize.width - metrics.panelPadding * 2 - metrics.groupPadding * 2
        )
        return .grouped(groups.map { group in
            PreviewLayoutGroup(
                id: layoutGroupID(for: group.key),
                items: group.previews.map { layoutItem(for: $0) },
                headerSize: autoGroupHeaderSize(title: group.title, maximumWidth: maximumHeaderWidth)
            )
        })
    }

    private func layoutItem(for preview: WindowPreview) -> PreviewLayoutItem {
        PreviewLayoutItem(
            id: preview.windowID,
            aspectRatio: PreviewCardView.layoutAspectRatio(for: preview)
        )
    }

    private func layoutGroupID(for key: PreviewDesktopGroupKey) -> PreviewLayoutGroupID {
        switch key {
        case .desktop(let id):
            return .desktop(id)
        case .unknown:
            return .unassigned
        }
    }

    private func autoGroupHeaderSize(title: String, maximumWidth: CGFloat) -> NSSize {
        let font = PreviewMetrics.desktopGroupLabelFont
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        let naturalWidth = textWidth +
            PreviewMetrics.desktopGroupLabelHorizontalPadding +
            PreviewMetrics.desktopGroupLabelTextSlack
        return NSSize(
            width: min(naturalWidth, maximumWidth),
            height: PreviewMetrics.desktopGroupLabelHeight
        )
    }

    private func autoLayoutMetrics() -> PreviewLayoutMetrics {
        PreviewLayoutMetrics(
            panelPadding: PreviewMetrics.panelPadding,
            cardHorizontalPadding: PreviewMetrics.cardContentPadding,
            cardVerticalPadding: PreviewMetrics.cardContentPadding,
            cardVerticalChrome: PreviewMetrics.cardVerticalChrome,
            itemSpacing: PreviewMetrics.rowSpacing,
            rowSpacing: PreviewMetrics.rowSpacing,
            groupPadding: PreviewMetrics.desktopGroupPadding,
            groupSpacing: PreviewMetrics.desktopGroupSpacing,
            groupHeaderSpacing: PreviewMetrics.desktopGroupHeaderSpacing,
            minimumCardWidth: PreviewMetrics.minimumCardWidth,
            maximumImageWidth: PreviewMetrics.maxImageWidth,
            minimumAspectRatio: PreviewMetrics.minAspectRatio,
            maximumAspectRatio: PreviewMetrics.maxAspectRatio
        )
    }

    private func layoutRows(for previews: [WindowPreview], anchoredTo anchor: CGRect, imageHeight: CGFloat) -> [[WindowPreview]] {
        layoutRows(for: previews, availableWidth: maxContentWidth(anchoredTo: anchor), imageHeight: imageHeight)
    }

    private func previewRowsLayout(for previews: [WindowPreview], anchoredTo anchor: CGRect, imageHeight: CGFloat) -> PreviewRowsLayout {
        let maxHeight = maxPreviewStackHeight(imageHeight: imageHeight)
        let rows = layoutRows(for: previews, anchoredTo: anchor, imageHeight: imageHeight)
        let contentSize = previewRowsContentSize(rows, imageHeight: imageHeight)
        guard PreviewLegacyOverflowPolicy.needsWrappedVerticalScroll(
            rowCount: rows.count,
            maximumVisibleRows: PreviewMetrics.maxVisiblePreviewRows
        ) else {
            return PreviewRowsLayout(rows: rows, contentSize: contentSize)
        }

        let scrollRows = layoutRows(
            for: previews,
            availableWidth: verticalScrollContentWidth(anchoredTo: anchor),
            imageHeight: imageHeight
        )
        let scrollContentSize = previewRowsContentSize(scrollRows, imageHeight: imageHeight)
        return PreviewRowsLayout(
            rows: scrollRows,
            contentSize: scrollContentSize,
            viewportSize: verticalScrollViewportSize(contentSize: scrollContentSize, maxHeight: maxHeight),
            needsVerticalScroll: true
        )
    }

    private func layoutRows(for previews: [WindowPreview], availableWidth: CGFloat, imageHeight: CGFloat) -> [[WindowPreview]] {
        let widths = previews.map { PreviewCardView.cardSize(for: $0, imageHeight: imageHeight).width }
        let maxItemsPerRow = adaptiveMaxItemsPerRow(itemWidths: widths, availableWidth: availableWidth)
        return layoutRows(
            for: previews,
            widths: widths,
            availableWidth: availableWidth,
            maxItemsPerRow: maxItemsPerRow
        )
    }

    private func layoutRows(
        for previews: [WindowPreview],
        widths: [CGFloat],
        availableWidth: CGFloat,
        maxItemsPerRow: Int
    ) -> [[WindowPreview]] {
        var rows = [[WindowPreview]]()
        var row = [WindowPreview]()
        var rowWidth: CGFloat = 0
        let maxItemsPerRow = max(1, maxItemsPerRow)

        for (preview, width) in zip(previews, widths) {
            let nextWidth = row.isEmpty ? width : rowWidth + PreviewMetrics.rowSpacing + width
            if !row.isEmpty && (row.count >= maxItemsPerRow || nextWidth > availableWidth) {
                rows.append(row)
                row = [preview]
                rowWidth = width
            } else {
                row.append(preview)
                rowWidth = nextWidth
            }
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }

    private func adaptiveMaxItemsPerRow(itemWidths: [CGFloat], availableWidth: CGFloat) -> Int {
        guard let minimumWidth = itemWidths.min(), minimumWidth > 0 else { return 1 }
        let fitCount = Int(floor((availableWidth + PreviewMetrics.rowSpacing) / (minimumWidth + PreviewMetrics.rowSpacing)))
        return max(1, fitCount)
    }

    private func measuredSize(
        previews: [WindowPreview],
        app: NSRunningApplication,
        anchoredTo anchor: CGRect,
        imageHeight: CGFloat,
        overflowMode: PreviewOverflowMode,
        desktopGroupingEnabled: Bool,
        autoLayoutPlan: PreviewLayoutPlan?
    ) -> NSSize {
        if let autoLayoutPlan {
            return PreviewPresentationLayout.measuredPanelSize(for: autoLayoutPlan)
        }
        let panelChrome = PreviewMetrics.panelPadding * 2
        if previews.isEmpty {
            let emptySize = EmptyPreviewView(appName: app.localizedName ?? "Application").intrinsicContentSize
            return NSSize(
                width: min(emptySize.width + panelChrome, maxPanelWidth(anchoredTo: anchor)),
                height: emptySize.height + panelChrome
            )
        }
        if let groups = desktopGroups(for: previews, enabled: desktopGroupingEnabled, anchoredTo: anchor) {
            return groupedMeasuredSize(groups: groups, anchoredTo: anchor, imageHeight: imageHeight, overflowMode: overflowMode)
        }
        if overflowMode == .scroll {
            let scrollerHeight = needsHorizontalScroll(for: previews, anchoredTo: anchor, imageHeight: imageHeight) ?
                PreviewMetrics.scrollBarHeight : 0
            return NSSize(
                width: min(rowContentWidth(for: previews, imageHeight: imageHeight) + panelChrome, maxPanelWidth(anchoredTo: anchor)),
                height: rowHeight(for: previews, imageHeight: imageHeight) + scrollerHeight + panelChrome
            )
        }
        let layout = previewRowsLayout(for: previews, anchoredTo: anchor, imageHeight: imageHeight)
        let width = min(layout.viewportSize.width + panelChrome, maxPanelWidth(anchoredTo: anchor))
        let height = layout.viewportSize.height + panelChrome
        return NSSize(width: width, height: height)
    }

    private func desktopGroups(for previews: [WindowPreview], enabled: Bool, anchoredTo anchor: CGRect) -> [PreviewDesktopGroup]? {
        guard enabled else { return nil }
        guard previews.contains(where: { $0.desktop != nil }) else { return nil }
        let focusedDesktopID = focusedDesktopID(anchoredTo: anchor)
        guard shouldGroupDesktopPreviews(previews, focusedDesktopID: focusedDesktopID) else { return nil }
        var previewsByKey = [PreviewDesktopGroupKey: [WindowPreview]]()
        var identitiesByKey = [PreviewDesktopGroupKey: PreviewDesktopGroupIdentity]()

        for preview in previews {
            let identity = desktopGroupIdentity(for: preview.desktop, focusedDesktopID: focusedDesktopID)
            previewsByKey[identity.key, default: []].append(preview)
            identitiesByKey[identity.key] = identity
        }

        let knownKeys = Set(identitiesByKey.keys.filter { $0 != .unknown })
        guard !knownKeys.isEmpty else { return nil }
        return sortedDesktopGroupIdentities(Array(identitiesByKey.values)).compactMap { identity in
            guard let previews = previewsByKey[identity.key] else { return nil }
            return PreviewDesktopGroup(identity: identity, previews: previews)
        }
    }

    private func desktopGroupIdentity(for desktop: WindowDesktop?, focusedDesktopID: UInt64?) -> PreviewDesktopGroupIdentity {
        guard let desktop else { return .unknown }
        return PreviewDesktopGroupIdentity(
            key: .desktop(desktop.id),
            title: desktop.title,
            isCurrent: isFocusedDesktop(desktop, focusedDesktopID: focusedDesktopID),
            sortOrder: desktop.sortOrder
        )
    }

    private func shouldGroupDesktopPreviews(_ previews: [WindowPreview], focusedDesktopID: UInt64?) -> Bool {
        guard let focusedDesktopID else {
            return !previews.allSatisfy { $0.desktop?.isCurrent == true }
        }
        return !previews.allSatisfy { $0.desktop?.id == focusedDesktopID }
    }

    private func isFocusedDesktop(_ desktop: WindowDesktop, focusedDesktopID: UInt64?) -> Bool {
        guard let focusedDesktopID else { return desktop.isCurrent }
        return desktop.id == focusedDesktopID
    }

    private func focusedDesktopID(anchoredTo anchor: CGRect) -> UInt64? {
        SkyLightCapture.currentDesktopID(displayIdentifier: displayIdentifier(anchoredTo: anchor))
    }

    private func displayIdentifier(anchoredTo anchor: CGRect) -> String? {
        let screen = ScreenGeometry.screen(containing: anchor) ?? NSScreen.main
        guard let displayID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID.uint32Value)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private func sortedDesktopGroupIdentities(_ identities: [PreviewDesktopGroupIdentity]) -> [PreviewDesktopGroupIdentity] {
        identities.sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            if lhs.key == .unknown { return false }
            if rhs.key == .unknown { return true }
            return lhs.sortOrder < rhs.sortOrder
        }
    }

    private func groupedMeasuredSize(
        groups: [PreviewDesktopGroup],
        anchoredTo anchor: CGRect,
        imageHeight: CGFloat,
        overflowMode: PreviewOverflowMode
    ) -> NSSize {
        let panelChrome = PreviewMetrics.panelPadding * 2
        let contentSize = groupedContentSize(
            groups: groups,
            anchoredTo: anchor,
            imageHeight: imageHeight,
            overflowMode: overflowMode
        )
        return NSSize(
            width: min(contentSize.width + panelChrome, maxPanelWidth(anchoredTo: anchor)),
            height: contentSize.height + panelChrome
        )
    }

    private func groupedContentSize(
        groups: [PreviewDesktopGroup],
        anchoredTo anchor: CGRect,
        imageHeight: CGFloat,
        overflowMode: PreviewOverflowMode
    ) -> NSSize {
        if overflowMode == .scroll {
            return groupedScrollContentSize(groups: groups, anchoredTo: anchor, imageHeight: imageHeight)
        }
        return groupedWrapContentSize(groups: groups, anchoredTo: anchor, imageHeight: imageHeight)
    }

    private func groupedScrollContentSize(
        groups: [PreviewDesktopGroup],
        anchoredTo anchor: CGRect,
        imageHeight: CGFloat
    ) -> NSSize {
        let groupSizes = groups.map { groupedSingleRowSize(for: $0, anchoredTo: anchor, imageHeight: imageHeight) }
        let contentWidth = groupedContentWidth(groupSizes)
        let contentHeight = groupSizes.map(\.height).max() ?? 0
        return NSSize(
            width: min(contentWidth, maxContentWidth(anchoredTo: anchor)),
            height: contentHeight + groupedScrollBarHeight(contentWidth: contentWidth, anchoredTo: anchor)
        )
    }

    private func groupedWrapContentSize(groups: [PreviewDesktopGroup], anchoredTo anchor: CGRect, imageHeight: CGFloat) -> NSSize {
        groupedWrapLayout(for: groups, anchoredTo: anchor, imageHeight: imageHeight).size
    }

    private func groupedWrapLayout(
        for groups: [PreviewDesktopGroup],
        anchoredTo anchor: CGRect,
        imageHeight: CGFloat
    ) -> PreviewDesktopGroupWrapLayout {
        let layout = groupedWrapLayout(
            for: groups,
            availableWidth: maxContentWidth(anchoredTo: anchor),
            imageHeight: imageHeight
        )
        guard layout.needsScrollbar else { return layout }
        let scrollLayout = groupedWrapLayout(
            for: groups,
            availableWidth: verticalScrollContentWidth(anchoredTo: anchor),
            imageHeight: imageHeight
        )
        return scrollLayout.constrainedToVerticalScroll(
            viewportSize: verticalScrollViewportSize(
                contentSize: scrollLayout.contentSize,
                maxHeight: scrollLayout.visibleHeight
            )
        )
    }

    private func groupedWrapLayout(
        for groups: [PreviewDesktopGroup],
        availableWidth: CGFloat,
        imageHeight: CGFloat
    ) -> PreviewDesktopGroupWrapLayout {
        let layouts = groupedLayouts(for: groups, availableWidth: availableWidth, imageHeight: imageHeight)
        return wrapGroupedLayouts(layouts, availableWidth: availableWidth)
    }

    private func groupedLayouts(
        for groups: [PreviewDesktopGroup],
        availableWidth: CGFloat,
        imageHeight: CGFloat
    ) -> [PreviewDesktopGroupLayout] {
        let maxGroupWidth = maxGroupedContentWidth(availableWidth: availableWidth)
        return groups.map { group in
            let rows = layoutRows(for: group.previews, availableWidth: maxGroupWidth, imageHeight: imageHeight)
            let groupRowHeight = rowHeight(for: group.previews, imageHeight: imageHeight)
            let rowWidths = rows.map { rowContentWidth(for: $0, imageHeight: imageHeight) }
            return PreviewDesktopGroupLayout(
                title: group.title,
                isCurrent: group.isCurrent,
                rows: rows,
                rowHeight: groupRowHeight,
                size: groupedSize(
                    rowWidths: rowWidths,
                    rowHeight: groupRowHeight,
                    rowCount: rows.count,
                    title: group.title,
                    isCurrent: group.isCurrent,
                    maxTitleWidth: maxGroupWidth
                )
            )
        }
    }

    private func wrapGroupedLayouts(
        _ layouts: [PreviewDesktopGroupLayout],
        availableWidth: CGFloat
    ) -> PreviewDesktopGroupWrapLayout {
        var rows = [PreviewDesktopGroupLayoutRow]()
        var row = PreviewDesktopGroupLayoutRow()

        for layout in layouts {
            if row.shouldWrap(adding: layout, availableWidth: availableWidth) {
                rows.append(row)
                row = PreviewDesktopGroupLayoutRow()
            }
            row.add(layout)
        }

        if !row.isEmpty {
            rows.append(row)
        }
        return PreviewDesktopGroupWrapLayout(rows: rows)
    }

    private func groupedSingleRowSize(for group: PreviewDesktopGroup, anchoredTo anchor: CGRect, imageHeight: CGFloat) -> NSSize {
        groupedSize(
            rowWidths: [rowContentWidth(for: group.previews, imageHeight: imageHeight)],
            rowHeight: rowHeight(for: group.previews, imageHeight: imageHeight),
            title: group.title,
            isCurrent: group.isCurrent,
            maxTitleWidth: maxGroupedContentWidth(anchoredTo: anchor)
        )
    }

    private func groupedSize(
        rowWidths: [CGFloat],
        rowHeight: CGFloat,
        rowCount: Int = 1,
        title: String?,
        isCurrent: Bool,
        maxTitleWidth: CGFloat
    ) -> NSSize {
        DesktopGroupView.fittingSize(
            rowWidths: rowWidths,
            rowHeight: rowHeight,
            rowCount: rowCount,
            title: title,
            isCurrent: isCurrent,
            maxTitleWidth: maxTitleWidth
        )
    }

    private func groupedContentWidth(_ sizes: [NSSize]) -> CGFloat {
        sizes.map(\.width).reduce(0, +) + CGFloat(max(0, sizes.count - 1)) * PreviewMetrics.desktopGroupSpacing
    }

    private func groupedScrollBarHeight(contentWidth: CGFloat, anchoredTo anchor: CGRect) -> CGFloat {
        PreviewLegacyOverflowPolicy.needsHorizontalScroll(
            contentWidth: contentWidth,
            availableWidth: maxContentWidth(anchoredTo: anchor)
        ) ? PreviewMetrics.scrollBarHeight : 0
    }

    private func maxGroupedContentWidth(anchoredTo anchor: CGRect) -> CGFloat {
        maxGroupedContentWidth(availableWidth: maxContentWidth(anchoredTo: anchor))
    }

    private func maxGroupedContentWidth(availableWidth: CGFloat) -> CGFloat {
        max(160, availableWidth - PreviewMetrics.desktopGroupPadding * 2)
    }

    private func addScrollableRow(previews: [WindowPreview], anchoredTo anchor: CGRect, imageHeight: CGFloat) {
        let contentWidth = rowContentWidth(for: previews, imageHeight: imageHeight)
        let rowHeight = rowHeight(for: previews, imageHeight: imageHeight)
        let contentSize = NSSize(width: contentWidth, height: rowHeight)
        let viewportSize = NSSize(
            width: min(contentWidth, maxContentWidth(anchoredTo: anchor)),
            height: rowHeight + PreviewMetrics.scrollBarHeight
        )
        let row = makePreviewRow(previews: previews, imageHeight: imageHeight)
        let scrollView = PreviewPresentationLayout.installLegacyRows(
            mode: .scroll,
            rowViews: [row],
            contentSize: contentSize,
            viewportSize: viewportSize,
            needsScroll: true,
            spacing: PreviewMetrics.rowSpacing,
            in: stackView
        )
        assert(scrollView != nil, "Scrollable preview row was not installed")
    }

    private func makePreviewRow() -> NSStackView {
        PreviewLayoutViews.makePreviewRow()
    }

    private func makePreviewRow(previews: [WindowPreview], imageHeight: CGFloat) -> NSStackView {
        let rowStack = makePreviewRow()
        previews.forEach { rowStack.addArrangedSubview(makeCard(for: $0, imageHeight: imageHeight)) }
        return rowStack
    }

    private func makeHorizontalStack(views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = spacing
        return stack
    }

    private func makeVerticalStack(views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = spacing
        stack.alignment = .centerX
        stack.distribution = .gravityAreas
        return stack
    }

    private func makeCard(for preview: WindowPreview, imageHeight: CGFloat) -> PreviewCardView {
        let cardPresentationGeneration = presentationGeneration
        let card = PreviewCardView(
            preview: preview,
            imageHeight: imageHeight,
            initialHoverSuppressionPoint: initialHoverSuppressionPoint,
            onFocus: { [weak self] preview, completion in
                WindowInventory.focusWindow(
                    windowID: preview.windowID,
                    app: preview.app
                ) { success in
                    guard success else {
                        completion(false)
                        return
                    }
                    let isStillPresented = self?.currentApp?.processIdentifier ==
                        preview.app.processIdentifier &&
                        self?.currentPreviews.contains(where: { $0.windowID == preview.windowID }) == true &&
                        self?.presentationGeneration == cardPresentationGeneration
                    if isStillPresented {
                        self?.hide()
                    }
                    completion(true)
                }
            },
            onClose: { [weak self] preview, completion in
                let appPID = preview.app.processIdentifier
                WindowInventory.closeWindow(
                    windowID: preview.windowID,
                    app: preview.app,
                    isFullscreen: preview.isFullscreen
                ) { success in
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

    private func rowContentWidth(for previews: [WindowPreview], imageHeight: CGFloat) -> CGFloat {
        previews.map { PreviewCardView.cardSize(for: $0, imageHeight: imageHeight).width }.reduce(0, +) +
            CGFloat(max(0, previews.count - 1)) * PreviewMetrics.rowSpacing
    }

    private func rowHeight(for previews: [WindowPreview], imageHeight: CGFloat) -> CGFloat {
        previews.map { PreviewCardView.cardSize(for: $0, imageHeight: imageHeight).height }.max() ?? 0
    }

    private func needsHorizontalScroll(for previews: [WindowPreview], anchoredTo anchor: CGRect, imageHeight: CGFloat) -> Bool {
        PreviewLegacyOverflowPolicy.needsHorizontalScroll(
            contentWidth: rowContentWidth(for: previews, imageHeight: imageHeight),
            availableWidth: maxContentWidth(anchoredTo: anchor)
        )
    }

    private func previewRowsContentSize(_ rows: [[WindowPreview]], imageHeight: CGFloat) -> NSSize {
        let heights = rows.map { rowHeight(for: $0, imageHeight: imageHeight) }
        return NSSize(
            width: rows.map { rowContentWidth(for: $0, imageHeight: imageHeight) }.max() ?? 0,
            height: stackedHeight(heights, spacing: PreviewMetrics.rowSpacing)
        )
    }

    private func stackedHeight(_ heights: [CGFloat], spacing: CGFloat) -> CGFloat {
        heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * spacing
    }

    private func maxPreviewStackHeight(imageHeight: CGFloat) -> CGFloat {
        let rowHeight = PreviewCardView.cardSize(for: .placeholder, imageHeight: imageHeight).height
        let rowCount = PreviewMetrics.maxVisiblePreviewRows
        return CGFloat(rowCount) * rowHeight + CGFloat(max(0, rowCount - 1)) * PreviewMetrics.rowSpacing
    }

    private func verticalScrollViewportSize(contentSize: NSSize, maxHeight: CGFloat) -> NSSize {
        NSSize(
            width: contentSize.width + PreviewMetrics.scrollBarHeight,
            height: min(contentSize.height, maxHeight)
        )
    }

    private func verticalScrollContentWidth(anchoredTo anchor: CGRect) -> CGFloat {
        max(160, maxContentWidth(anchoredTo: anchor) - PreviewMetrics.scrollBarHeight)
    }

    private func maxPanelWidth(anchoredTo anchor: CGRect) -> CGFloat {
        let screen = ScreenGeometry.screen(containing: anchor) ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return max(260, frame.width - 20)
    }

    private func maxContentWidth(anchoredTo anchor: CGRect) -> CGFloat {
        max(220, maxPanelWidth(anchoredTo: anchor) - PreviewMetrics.panelPadding * 2)
    }

    private func positionedFrame(width: CGFloat, height: CGFloat, anchoredTo anchor: CGRect) -> NSRect {
        let screen = ScreenGeometry.screen(containing: anchor) ?? NSScreen.main
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = screen?.visibleFrame ?? screenFrame
        let edge = dockEdge(for: anchor, in: screenFrame)
        let dockGap: CGFloat = 4

        switch edge {
        case .bottom:
            return frameAboveOrBelowDock(width: width, height: height, anchor: anchor, frame: frame, gap: dockGap, aboveDock: true)
        case .top:
            return frameAboveOrBelowDock(width: width, height: height, anchor: anchor, frame: frame, gap: dockGap, aboveDock: false)
        case .left:
            return frameBesideDock(width: width, height: height, anchor: anchor, frame: frame, gap: dockGap, onLeftDock: true)
        case .right:
            return frameBesideDock(width: width, height: height, anchor: anchor, frame: frame, gap: dockGap, onLeftDock: false)
        }
    }

    private func frameAboveOrBelowDock(
        width: CGFloat,
        height: CGFloat,
        anchor: CGRect,
        frame: CGRect,
        gap: CGFloat,
        aboveDock: Bool
    ) -> NSRect {
        let x = clamp(anchor.midX - width / 2, min: frame.minX + 10, max: frame.maxX - width - 10)
        let proposedY = aboveDock ? anchor.maxY + gap : anchor.minY - height - gap
        let y = clamp(proposedY, min: frame.minY + 10, max: frame.maxY - height - 10)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func frameBesideDock(
        width: CGFloat,
        height: CGFloat,
        anchor: CGRect,
        frame: CGRect,
        gap: CGFloat,
        onLeftDock: Bool
    ) -> NSRect {
        let proposedX = onLeftDock ? anchor.maxX + gap : anchor.minX - width - gap
        let x = clamp(proposedX, min: frame.minX + 10, max: frame.maxX - width - 10)
        let y = clamp(anchor.midY - height / 2, min: frame.minY + 10, max: frame.maxY - height - 10)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func dockEdge(for anchor: CGRect, in frame: CGRect) -> PreviewDockEdge {
        let distances: [(PreviewDockEdge, CGFloat)] = [
            (.bottom, abs(anchor.minY - frame.minY)),
            (.top, abs(frame.maxY - anchor.maxY)),
            (.left, abs(anchor.minX - frame.minX)),
            (.right, abs(frame.maxX - anchor.maxX))
        ]
        return distances.min { $0.1 < $1.1 }?.0 ?? .bottom
    }

    private func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.max(min, Swift.min(max, value))
    }
}

private enum AutoPreviewLayoutDecision {
    case thumbnails(plan: PreviewLayoutPlan, groups: [PreviewDesktopGroup]?)
    case nativeDockMenu
}

private struct PreviewDesktopGroup {
    let key: PreviewDesktopGroupKey
    let title: String
    let isCurrent: Bool
    let sortOrder: Int
    let previews: [WindowPreview]

    init(identity: PreviewDesktopGroupIdentity, previews: [WindowPreview]) {
        key = identity.key
        title = identity.title
        isCurrent = identity.isCurrent
        sortOrder = identity.sortOrder
        self.previews = previews
    }
}

private struct PreviewRowsLayout {
    let rows: [[WindowPreview]]
    let contentSize: NSSize
    let viewportSize: NSSize
    let needsVerticalScroll: Bool

    init(
        rows: [[WindowPreview]],
        contentSize: NSSize,
        viewportSize: NSSize? = nil,
        needsVerticalScroll: Bool = false
    ) {
        self.rows = rows
        self.contentSize = contentSize
        self.viewportSize = viewportSize ?? contentSize
        self.needsVerticalScroll = needsVerticalScroll
    }
}

private struct PreviewDesktopGroupLayout {
    let title: String?
    let isCurrent: Bool
    let rows: [[WindowPreview]]
    let rowHeight: CGFloat
    let size: NSSize

    var previewRowCount: Int {
        rows.count
    }

    func visibleHeight(maxPreviewRows: Int) -> CGFloat {
        let rowCount = min(rows.count, maxPreviewRows)
        guard rowCount > 0 else { return 0 }
        let titleHeight = title == nil ? 0 : PreviewMetrics.desktopGroupLabelHeight + PreviewMetrics.desktopGroupHeaderSpacing
        let rowsHeight = CGFloat(rowCount) * rowHeight + CGFloat(max(0, rowCount - 1)) * PreviewMetrics.rowSpacing
        return titleHeight + rowsHeight + PreviewMetrics.desktopGroupPadding * 2
    }
}

private struct PreviewDesktopGroupWrapLayout {
    let rows: [PreviewDesktopGroupLayoutRow]
    let contentSize: NSSize
    let viewportSize: NSSize
    let needsVerticalScroll: Bool

    init(
        rows: [PreviewDesktopGroupLayoutRow],
        contentSize: NSSize? = nil,
        viewportSize: NSSize? = nil,
        needsVerticalScroll: Bool = false
    ) {
        let contentSize = contentSize ?? Self.contentSize(for: rows)
        self.rows = rows
        self.contentSize = contentSize
        self.viewportSize = viewportSize ?? contentSize
        self.needsVerticalScroll = needsVerticalScroll
    }

    var size: NSSize {
        viewportSize
    }

    var visibleHeight: CGFloat {
        Self.visibleContentHeight(for: rows)
    }

    var needsScrollbar: Bool {
        contentSize.height > visibleHeight
    }

    func constrainedToVerticalScroll(viewportSize: NSSize) -> PreviewDesktopGroupWrapLayout {
        PreviewDesktopGroupWrapLayout(
            rows: rows,
            contentSize: contentSize,
            viewportSize: viewportSize,
            needsVerticalScroll: true
        )
    }

    private static func contentSize(for rows: [PreviewDesktopGroupLayoutRow]) -> NSSize {
        let height = rows.map(\.height).reduce(0, +) +
            CGFloat(max(0, rows.count - 1)) * PreviewMetrics.desktopGroupSpacing
        return NSSize(width: rows.map(\.width).max() ?? 0, height: height)
    }

    private static func visibleContentHeight(for rows: [PreviewDesktopGroupLayoutRow]) -> CGFloat {
        var remainingRows = PreviewMetrics.maxVisiblePreviewRows
        var visibleRowCount = 0
        var height: CGFloat = 0

        for row in rows {
            guard remainingRows > 0 else { break }
            let rowPreviewCount = row.previewRowCount
            let rowHeight = rowPreviewCount <= remainingRows ? row.height : row.visibleHeight(maxPreviewRows: remainingRows)
            height += rowHeight
            remainingRows -= min(rowPreviewCount, remainingRows)
            visibleRowCount += 1
        }

        return height + CGFloat(max(0, visibleRowCount - 1)) * PreviewMetrics.desktopGroupSpacing
    }
}

private struct PreviewDesktopGroupLayoutRow {
    private(set) var layouts = [PreviewDesktopGroupLayout]()
    private(set) var width: CGFloat = 0
    private(set) var height: CGFloat = 0

    var isEmpty: Bool {
        layouts.isEmpty
    }

    var previewRowCount: Int {
        layouts.map(\.previewRowCount).max() ?? 0
    }

    func visibleHeight(maxPreviewRows: Int) -> CGFloat {
        layouts.map { $0.visibleHeight(maxPreviewRows: maxPreviewRows) }.max() ?? 0
    }

    func shouldWrap(adding layout: PreviewDesktopGroupLayout, availableWidth: CGFloat) -> Bool {
        !isEmpty && width(adding: layout) > availableWidth
    }

    mutating func add(_ layout: PreviewDesktopGroupLayout) {
        width = width(adding: layout)
        height = max(height, layout.size.height)
        layouts.append(layout)
    }

    private func width(adding layout: PreviewDesktopGroupLayout) -> CGFloat {
        isEmpty ? layout.size.width : width + PreviewMetrics.desktopGroupSpacing + layout.size.width
    }
}

private struct PreviewDesktopGroupIdentity {
    let key: PreviewDesktopGroupKey
    let title: String
    let isCurrent: Bool
    let sortOrder: Int

    static let unknown = PreviewDesktopGroupIdentity(
        key: .unknown,
        title: "Other",
        isCurrent: false,
        sortOrder: Int.max
    )
}

private enum PreviewDesktopGroupKey: Hashable {
    case desktop(UInt64)
    case unknown
}

private enum PreviewDockEdge {
    case bottom
    case top
    case left
    case right
}
