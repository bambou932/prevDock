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
        isLiveRefreshActive && currentWindowID != nil
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
        if preview.isFullscreen {
            hide()
            return
        }

        guard !preview.isMinimized,
              preview.bounds.width >= 80,
              preview.bounds.height >= 60 else {
            hide()
            return
        }

        let frame = LivePreviewCadence.appKitFrame(fromWindowBounds: preview.bounds)
        guard frame.width >= 80,
              frame.height >= 60,
              ScreenGeometry.screen(containing: frame) != nil else {
            hide()
            return
        }

        let windowChanged = currentWindowID != preview.windowID
        let geometryChanged = currentPreview?.bounds != preview.bounds
        let needsOrdering = currentWindowID != preview.windowID ||
            !panel.isVisible ||
            dimmingPanels.contains { !$0.isVisible }
        if windowChanged || geometryChanged {
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
        isLiveRefreshCaptureInFlight = false
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
                guard let self else {
                    return
                }
                self.isLiveRefreshCaptureInFlight = false
                guard self.isLiveRefreshActive,
                      self.liveRefreshGeneration == generation,
                      self.currentWindowID == preview.windowID,
                      let currentPreview = self.currentPreview else {
                    return
                }
                guard PermissionManager.status.screenRecordingGranted else {
                    self.liveRefreshFailureCount += 1
                    self.clearVisiblePeek()
                    self.scheduleNextLiveRefresh(for: currentPreview)
                    return
                }
                switch result {
                case .captured(let image):
                    self.liveRefreshFailureCount = 0
                    self.show(
                        image: image,
                        frame: LivePreviewCadence.appKitFrame(fromWindowBounds: currentPreview.bounds),
                        windowID: currentPreview.windowID,
                        orderFront: false
                    )
                    self.liveImageUpdateHandler?(currentPreview.windowID, image)
                case .cached(let image):
                    self.liveRefreshFailureCount += 1
                    if !self.panel.isVisible {
                        self.show(
                            image: image,
                            frame: LivePreviewCadence.appKitFrame(fromWindowBounds: currentPreview.bounds),
                            windowID: currentPreview.windowID,
                            orderFront: true
                        )
                    }
                case .unavailable:
                    self.liveRefreshFailureCount += 1
                }
                self.scheduleNextLiveRefresh(for: currentPreview)
            }
        }
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
