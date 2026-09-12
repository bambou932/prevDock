import Cocoa
import QuartzCore

final class WindowPeekController {
    static let shared = WindowPeekController()

    private static let peekLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
    private static let dimmingLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 2)

    private let panel: NSPanel
    private let imageView = WindowPeekImageView()
    private var dimmingPanels = [NSPanel]()
    private var liveRefreshWorkItem: DispatchWorkItem?
    private var currentWindowID: CGWindowID?
    private var currentPreview: WindowPreview?
    private var isLiveRefreshActive = false
    private var isLiveRefreshCaptureInFlight = false
    private var liveRefreshGeneration = 0
    private var liveRefreshFailureCount = 0
    private var liveImageUpdateHandler: ((CGWindowID, NSImage) -> Void)?

    var isShowingLivePreview: Bool {
        isLiveRefreshActive && currentWindowID != nil && panel.isVisible
    }

    private init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = Self.peekLevel
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let container = NSView()

        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        panel.contentView = container
    }

    func setLiveImageUpdateHandler(_ handler: @escaping (CGWindowID, NSImage) -> Void) {
        liveImageUpdateHandler = handler
    }

    func show(preview: WindowPreview) {
        guard !preview.isFullscreen,
              PermissionManager.status.screenRecordingGranted,
              let frame = presentationFrame(for: preview) else {
            hide()
            return
        }
        if preview.isMinimized {
            showSnapshot(preview, frame: frame)
            return
        }
        showLivePreview(preview, frame: frame)
    }

    func updateSnapshot(preview: WindowPreview) {
        guard preview.isMinimized,
              currentWindowID == preview.windowID,
              currentPreview?.isMinimized == true else { return }
        show(preview: preview)
    }

    private func presentationFrame(for preview: WindowPreview) -> NSRect? {
        let bounds = preview.bounds
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width >= 80, bounds.height >= 60 else { return nil }
        let frame = LivePreviewCadence.appKitFrame(fromWindowBounds: preview.bounds)
        guard ScreenGeometry.screen(containing: frame) != nil else { return nil }
        return frame
    }

    private func showSnapshot(_ preview: WindowPreview, frame: NSRect) {
        let needsOrdering = needsOrdering(for: preview.windowID)
        if isLiveRefreshActive || currentPreview?.isMinimized != true || currentWindowID != preview.windowID {
            stopLiveRefresh()
        }
        currentWindowID = preview.windowID
        currentPreview = preview
        guard let image = preview.image else {
            clearVisiblePeek()
            return
        }
        show(image: image, frame: frame, windowID: preview.windowID, orderFront: needsOrdering)
    }

    private func showLivePreview(_ preview: WindowPreview, frame: NSRect) {
        let windowChanged = currentWindowID != preview.windowID
        let geometryChanged = currentPreview?.bounds != preview.bounds
        let needsOrdering = needsOrdering(for: preview.windowID)
        if windowChanged || geometryChanged || currentPreview?.isMinimized == true {
            stopLiveRefresh()
            if windowChanged, preview.image == nil {
                clearVisiblePeek()
            }
        }
        currentWindowID = preview.windowID
        currentPreview = preview
        if let image = preview.image {
            show(image: image, frame: frame, windowID: preview.windowID, orderFront: needsOrdering)
        }

        startLiveRefreshIfNeeded()
    }

    private func needsOrdering(for windowID: CGWindowID) -> Bool {
        currentWindowID != windowID || !panel.isVisible || dimmingPanels.contains { !$0.isVisible }
    }

    func hide(windowID: CGWindowID? = nil) {
        if let windowID, currentWindowID != windowID {
            return
        }
        stopLiveRefresh()
        currentWindowID = nil
        currentPreview = nil
        performWithoutAnimation {
            imageView.clear()
            hideDimmingPanels()
            panel.orderOut(nil)
        }
    }

    private func startLiveRefreshIfNeeded() {
        guard !isLiveRefreshActive else { return }
        isLiveRefreshActive = true
        refreshCurrentPreview()
    }

    private func stopLiveRefresh() {
        isLiveRefreshActive = false
        // A capture cannot be interrupted; its completion starts the latest hover target.
        liveRefreshFailureCount = 0
        liveRefreshGeneration += 1
        liveRefreshWorkItem?.cancel()
        liveRefreshWorkItem = nil
    }

    private func refreshCurrentPreview() {
        guard isLiveRefreshActive,
              !isLiveRefreshCaptureInFlight,
              let preview = currentPreview,
              currentWindowID == preview.windowID else {
            return
        }

        let generation = liveRefreshGeneration
        isLiveRefreshCaptureInFlight = true
        WindowInventory.captureFreshThumbnail(for: preview) { [weak self] result in
            DispatchQueue.main.async {
                self?.completeLiveRefresh(result, windowID: preview.windowID, generation: generation)
            }
        }
    }

    private func completeLiveRefresh(_ result: FreshThumbnailCaptureResult, windowID: CGWindowID, generation: Int) {
        isLiveRefreshCaptureInFlight = false
        guard isLiveRefreshActive else { return }
        guard liveRefreshGeneration == generation, currentWindowID == windowID else {
            refreshCurrentPreview()
            return
        }
        guard let preview = currentPreview else { return }
        guard PermissionManager.status.screenRecordingGranted else {
            liveRefreshFailureCount += 1
            clearVisiblePeek()
            scheduleNextLiveRefresh(for: preview)
            return
        }
        applyLiveRefresh(result, to: preview)
        scheduleNextLiveRefresh(for: preview)
    }

    private func applyLiveRefresh(_ result: FreshThumbnailCaptureResult, to preview: WindowPreview) {
        switch result {
        case .captured(let image):
            liveRefreshFailureCount = 0
            showLiveImage(image, for: preview, orderFront: false)
            liveImageUpdateHandler?(preview.windowID, image)
        case .cached(let image):
            liveRefreshFailureCount += 1
            if !panel.isVisible {
                showLiveImage(image, for: preview, orderFront: true)
            }
        case .unavailable:
            liveRefreshFailureCount += 1
        }
    }

    private func showLiveImage(_ image: NSImage, for preview: WindowPreview, orderFront: Bool) {
        show(
            image: image,
            frame: LivePreviewCadence.appKitFrame(fromWindowBounds: preview.bounds),
            windowID: preview.windowID,
            orderFront: orderFront
        )
    }

    private func scheduleNextLiveRefresh(for preview: WindowPreview) {
        liveRefreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.refreshCurrentPreview()
        }
        liveRefreshWorkItem = item
        let baseInterval = LivePreviewCadence.interval(forWindowBounds: preview.bounds)
        let backoffMultiplier = pow(2, Double(min(liveRefreshFailureCount, 5)))
        let interval = min(1, baseInterval * backoffMultiplier)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + interval,
            execute: item
        )
    }

    private func show(image: NSImage, frame: NSRect, windowID: CGWindowID, orderFront: Bool) {
        performWithoutAnimation {
            imageView.update(image: image, windowID: windowID)
            syncDimmingPanels(orderFront: orderFront)
            if frameNeedsUpdate(panel.frame, frame) {
                panel.setFrame(frame, display: false, animate: false)
            }
            if orderFront || !panel.isVisible {
                panel.orderFrontRegardless()
            }
        }
    }

    private func syncDimmingPanels(orderFront: Bool) {
        let screens = NSScreen.screens
        var shouldOrderFront = orderFront
        if dimmingPanels.count != screens.count {
            dimmingPanels.forEach { $0.orderOut(nil) }
            dimmingPanels = screens.map { _ in makeDimmingPanel() }
            shouldOrderFront = true
        }

        for (screen, dimmingPanel) in zip(screens, dimmingPanels) {
            if frameNeedsUpdate(dimmingPanel.frame, screen.frame) {
                dimmingPanel.setFrame(screen.frame, display: false, animate: false)
            }
            if shouldOrderFront || !dimmingPanel.isVisible {
                dimmingPanel.orderFrontRegardless()
            }
        }
    }

    private func frameNeedsUpdate(_ current: NSRect, _ next: NSRect) -> Bool {
        abs(current.minX - next.minX) > 0.5 ||
            abs(current.minY - next.minY) > 0.5 ||
            abs(current.width - next.width) > 0.5 ||
            abs(current.height - next.height) > 0.5
    }

    private func hideDimmingPanels() {
        dimmingPanels.forEach { $0.orderOut(nil) }
    }

    private func clearVisiblePeek() {
        performWithoutAnimation {
            imageView.clear()
            hideDimmingPanels()
            panel.orderOut(nil)
        }
    }

    private func makeDimmingPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = Self.dimmingLevel
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let dimmingView = NSView()
        dimmingView.wantsLayer = true
        dimmingView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        panel.contentView = dimmingView
        return panel
    }

    private func performWithoutAnimation(_ updates: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            updates()
        }
        CATransaction.commit()
    }

}

private final class WindowPeekImageView: NSView {
    private static let outlineWidth: CGFloat = 2
    private static let outlineColor = PrevDockColors.highlight(alpha: 0.9)

    private var image: NSImage?

    override var isFlipped: Bool {
        true
    }

    func update(image: NSImage, windowID: CGWindowID) {
        self.image = image
        needsDisplay = true
    }

    func clear() {
        image = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let image else { return }

        image.draw(
            in: bounds,
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        drawOutline()
    }

    private func drawOutline() {
        let rect = bounds.insetBy(dx: Self.outlineWidth / 2, dy: Self.outlineWidth / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        path.lineWidth = Self.outlineWidth
        Self.outlineColor.setStroke()
        path.stroke()
    }
}
