import Cocoa
import QuartzCore

private extension PreviewWindowHeight {
    var scale: CGFloat {
        switch self {
        case .extraSmall:
            return 0.80
        case .small:
            return 0.90
        case .regular:
            return 1.00
        case .large:
            return 1.15
        case .extraLarge:
            return 1.30
        }
    }
}

enum PreviewMetrics {
    static let maxImageWidth: CGFloat = 520
    static let minimumReadableImageHeight: CGFloat = 96
    static let minAspectRatio: CGFloat = 0.30
    static let maxAspectRatio: CGFloat = 3.15
    static let panelPadding: CGFloat = 6
    static let cardContentPadding: CGFloat = 6
    static let rowSpacing: CGFloat = 0
    static let maxVisiblePreviewRows = 3
    static let emptyHorizontalPadding: CGFloat = 4
    static let emptyVerticalPadding: CGFloat = 4
    static let emptyTitleSpacing: CGFloat = 1
    static let peekDelay: TimeInterval = 0
    static let cardHoverExitGrace: TimeInterval = 0.045
    static let scrollBarHeight: CGFloat = ceil(NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy))
    static let desktopGroupLabelHorizontalPadding: CGFloat = 14
    static let desktopGroupLabelTextSlack: CGFloat = 12
    static let desktopGroupHeaderSpacing: CGFloat = 4
    static let desktopGroupPadding: CGFloat = 5
    static let desktopGroupSpacing: CGFloat = 8

    static var minimumCardWidth: CGFloat {
        PreviewCardChromeLayout.minimumCardWidth(
            contentStyle: contentStyle,
            contentPadding: cardContentPadding
        )
    }

    static var desktopGroupLabelHeight: CGFloat {
        desktopGroupLabelHeight(for: PrevDockSettings.previewContentSize)
    }

    static var desktopGroupLabelFont: NSFont {
        desktopGroupLabelFont(for: PrevDockSettings.previewContentSize)
    }

    static var cardVerticalChrome: CGFloat {
        contentStyle.cardVerticalChrome
    }

    static var titleFontSize: CGFloat {
        contentStyle.titleFontSize
    }

    static var statusFontSize: CGFloat {
        contentStyle.statusFontSize
    }

    static var appIconSize: CGFloat {
        contentStyle.appIconSize
    }

    static func imageHeight(
        anchoredTo anchor: CGRect,
        windowHeight: PreviewWindowHeight = PrevDockSettings.previewWindowHeight
    ) -> CGFloat {
        let screen = ScreenGeometry.screen(containing: anchor) ?? NSScreen.main
        let screenHeight = screen?.frame.height ?? 1080
        let baseHeight = clamp(screenHeight * 0.15, min: 128, max: 260)
        let scaledHeight = baseHeight * windowHeight.scale
        return clamp(scaledHeight, min: minimumReadableImageHeight, max: 338)
    }

    static func cardVerticalChrome(for contentSize: PreviewContentSize) -> CGFloat {
        contentSize.style.cardVerticalChrome
    }

    static func desktopGroupLabelHeight(for contentSize: PreviewContentSize) -> CGFloat {
        max(18, ceil(contentSize.style.titleFontSize + 6))
    }

    static func desktopGroupLabelFont(for contentSize: PreviewContentSize) -> NSFont {
        .systemFont(ofSize: contentSize.style.titleFontSize, weight: .medium)
    }

    private static var contentStyle: PreviewContentStyle {
        PrevDockSettings.previewContentSize.style
    }

    private static func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.max(min, Swift.min(max, value))
    }
}

enum PreviewLayoutViews {
    static func makePreviewRow(views: [NSView] = []) -> NSStackView {
        PreviewPresentationLayout.makePreviewRow(views: views, spacing: PreviewMetrics.rowSpacing)
    }
}

private struct InitialHoverActivationGate {
    private let suppressionPoint: CGPoint?
    private var isSuppressionActive: Bool

    init(suppressionPoint: CGPoint?) {
        self.suppressionPoint = suppressionPoint
        isSuppressionActive = suppressionPoint != nil
    }

    mutating func blocksHoverActivation() -> Bool {
        guard isSuppressionActive, let suppressionPoint else { return false }
        let mouse = DockCursorTracker.shared.currentMouseLocation(preferEventTap: true)
        if mouse.distanceSquared(to: suppressionPoint) <= 4 {
            return true
        }
        isSuppressionActive = false
        return false
    }
}

private extension CGPoint {
    func distanceSquared(to point: CGPoint) -> CGFloat {
        let dx = x - point.x
        let dy = y - point.y
        return dx * dx + dy * dy
    }
}

private struct PreviewHighlightCornerRadiusKey: Equatable {
    let pixelWidth: Int
    let pixelHeight: Int
    let displayWidth: Int
    let displayHeight: Int
}

private enum PreviewHighlightCornerRadius {
    private static let alphaThreshold: UInt8 = 32
    private static let maxSampleDimension = 768

    static func estimate(from image: CGImage, displayedSize: NSSize, padding: CGFloat, fallback: CGFloat) -> CGFloat {
        guard displayedSize.width > 0,
              displayedSize.height > 0,
              let sample = alphaSample(from: image) else {
            return fallback
        }

        let leftRadius = estimatedRadius(in: sample, fromLeft: true)
        let rightRadius = estimatedRadius(in: sample, fromLeft: false)
        let sampleRadius = max(leftRadius, rightRadius)
        guard sampleRadius > 1 else { return fallback }

        let displayScale = displayedSize.width / CGFloat(sample.width)
        let maxRadius = min(displayedSize.width, displayedSize.height) * 0.18 + padding
        let radius = CGFloat(sampleRadius) * displayScale + padding
        return clamp(radius, min: fallback, max: max(fallback, maxRadius))
    }

    private static func estimatedRadius(in sample: PreviewAlphaSample, fromLeft: Bool) -> Int {
        let scanWidth = min(max(1, sample.width / 3), 96)
        let scanHeight = min(max(1, sample.height / 3), 96)
        var maxTransparentRun = 0

        for yOffset in 0..<scanHeight {
            var transparentRun = 0
            for xOffset in 0..<scanWidth {
                let x = fromLeft ? xOffset : sample.width - 1 - xOffset
                if sample.alpha[yOffset * sample.width + x] > alphaThreshold {
                    break
                }
                transparentRun += 1
            }
            maxTransparentRun = max(maxTransparentRun, transparentRun)
        }
        return maxTransparentRun
    }

    private static func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.max(min, Swift.min(max, value))
    }

    private static func alphaSample(from image: CGImage) -> PreviewAlphaSample? {
        let size = sampleSize(for: image)
        let bytesPerRow = size.width * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * size.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        let didDraw = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: size.width,
                      height: size.height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo
                  ) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            return true
        }
        guard didDraw else { return nil }

        var alpha = [UInt8](repeating: 0, count: size.width * size.height)
        for index in 0..<alpha.count {
            alpha[index] = rgba[index * 4 + 3]
        }
        return PreviewAlphaSample(width: size.width, height: size.height, alpha: alpha)
    }

    private static func sampleSize(for image: CGImage) -> (width: Int, height: Int) {
        let maxDimension = max(image.width, image.height)
        guard maxDimension > maxSampleDimension else {
            return (max(1, image.width), max(1, image.height))
        }

        let scale = CGFloat(maxSampleDimension) / CGFloat(maxDimension)
        return (
            max(1, Int((CGFloat(image.width) * scale).rounded())),
            max(1, Int((CGFloat(image.height) * scale).rounded()))
        )
    }
}

private struct PreviewAlphaSample {
    let width: Int
    let height: Int
    let alpha: [UInt8]
}

private final class PreviewCardHoverCoordinator {
    static let shared = PreviewCardHoverCoordinator()

    private weak var activeCard: PreviewCardView?

    func activate(_ card: PreviewCardView) {
        guard activeCard !== card else { return }
        let previousCard = activeCard
        activeCard = card
        previousCard?.deactivateHoverForPeerSwitch()
    }

    func deactivate(_ card: PreviewCardView) {
        if activeCard === card {
            activeCard = nil
        }
    }
}

final class PreviewCardView: NSView {
    private static let contentPadding = PreviewMetrics.cardContentPadding
    private static let highlightBorderWidth: CGFloat = 2
    private static let fallbackHighlightCornerRadius: CGFloat = 10

    enum InteractionMode {
        case live
        case sample
    }

    private var preview: WindowPreview
    private let cardSize: NSSize
    private let thumbnailSize: NSSize
    private let showsCloseButton: Bool
    private let keepsSampleCloseButtonVisible: Bool
    private let contentStyle: PreviewContentStyle
    private let interactionMode: InteractionMode
    private let onFocus: (WindowPreview, @escaping (Bool) -> Void) -> Void
    private let onClose: (WindowPreview, @escaping (Bool) -> Void) -> Void
    private let imageView = NSImageView()
    private let appIconView = NSImageView()
    private let closeButton = PreviewCloseButton()
    private var titleLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var widthConstraint: NSLayoutConstraint?
    private var peekWorkItem: DispatchWorkItem?
    private var hoverExitWorkItem: DispatchWorkItem?
    private var actionFeedbackWorkItem: DispatchWorkItem?
    private var actionFeedbackGeneration = 0
    private var isClosing = false
    private var isHovered = false
    private var preservesPeekOnDeinit = false
    private var initialHoverGate: InitialHoverActivationGate
    private var highlightCornerRadius: CGFloat = 10
    private var highlightCornerRadiusKey: PreviewHighlightCornerRadiusKey?

    init(
        preview: WindowPreview,
        imageHeight: CGFloat,
        interactionMode: InteractionMode = .live,
        contentSizeOverride: PreviewContentSize? = nil,
        showsCloseButtonOverride: Bool? = nil,
        initialHoverSuppressionPoint: CGPoint? = nil,
        onFocus: @escaping (WindowPreview, @escaping (Bool) -> Void) -> Void = { _, completion in
            completion(false)
        },
        onClose: @escaping (WindowPreview, @escaping (Bool) -> Void) -> Void = { _, completion in completion(false) }
    ) {
        let thumbnailSize = Self.thumbnailSize(for: preview, imageHeight: imageHeight)
        let contentStyle = contentSizeOverride?.style ?? PrevDockSettings.previewContentSize.style
        self.preview = preview
        self.thumbnailSize = thumbnailSize
        self.showsCloseButton = showsCloseButtonOverride ?? (interactionMode == .live && PrevDockSettings.previewCloseButtonEnabled)
        keepsSampleCloseButtonVisible = interactionMode == .sample && self.showsCloseButton
        self.contentStyle = contentStyle
        self.interactionMode = interactionMode
        self.onFocus = onFocus
        self.onClose = onClose
        self.cardSize = Self.cardSize(thumbnailSize: thumbnailSize, contentStyle: contentStyle)
        self.initialHoverGate = InitialHoverActivationGate(suppressionPoint: initialHoverSuppressionPoint)
        super.init(frame: NSRect(origin: .zero, size: cardSize))
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        peekWorkItem?.cancel()
        hoverExitWorkItem?.cancel()
        actionFeedbackWorkItem?.cancel()
        if isInteractive, !preservesPeekOnDeinit {
            WindowPeekController.shared.hide(windowID: preview.windowID)
        }
    }

    override var intrinsicContentSize: NSSize {
        cardSize
    }

    static func cardSize(for preview: WindowPreview, imageHeight: CGFloat) -> NSSize {
        cardSize(
            thumbnailSize: thumbnailSize(for: preview, imageHeight: imageHeight),
            contentStyle: PrevDockSettings.previewContentSize.style
        )
    }

    static func cardSize(for preview: WindowPreview, imageHeight: CGFloat, contentSize: PreviewContentSize) -> NSSize {
        cardSize(thumbnailSize: thumbnailSize(for: preview, imageHeight: imageHeight), contentStyle: contentSize.style)
    }

    static func layoutAspectRatio(for preview: WindowPreview) -> CGFloat {
        let boundsWidth = max(preview.bounds.width, 1)
        let boundsHeight = max(preview.bounds.height, 1)
        let imageSize = preview.image?.size ?? .zero
        let sourceWidth = boundsWidth > 1 ? boundsWidth : max(imageSize.width, 1)
        let sourceHeight = boundsHeight > 1 ? boundsHeight : max(imageSize.height, 1)
        return min(
            PreviewMetrics.maxAspectRatio,
            max(PreviewMetrics.minAspectRatio, sourceWidth / sourceHeight)
        )
    }

    private static func thumbnailSize(for preview: WindowPreview, imageHeight: CGFloat) -> NSSize {
        let aspect = layoutAspectRatio(for: preview)
        let imageWidth = min(PreviewMetrics.maxImageWidth, imageHeight * aspect)
        return NSSize(width: imageWidth, height: imageHeight)
    }

    private static func cardSize(thumbnailSize: NSSize, contentStyle: PreviewContentStyle) -> NSSize {
        return NSSize(
            width: max(
                thumbnailSize.width + contentPadding * 2,
                PreviewCardChromeLayout.minimumCardWidth(
                    contentStyle: contentStyle,
                    contentPadding: contentPadding
                )
            ),
            height: thumbnailSize.height + contentStyle.cardVerticalChrome + contentPadding * 2
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractive, !isClosing else { return }
        beginAction(status: "Opening")
        peekWorkItem?.cancel()
        WindowPeekController.shared.hide()
        onFocus(preview) { [weak self] success in
            guard let self else { return }
            guard !success else { return }
            self.isClosing = false
            self.showActionFailure("Open failed")
        }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        guard isInteractive else { return }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard isInteractive, !initialHoverGate.blocksHoverActivation() else { return }
        activateHover()
        updateCloseButtonHover(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard isInteractive, !initialHoverGate.blocksHoverActivation() else { return }
        activateHover()
        updateCloseButtonHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard isInteractive else { return }
        scheduleHoverDeactivation()
    }

    func updateImage(_ image: NSImage, animated: Bool = true) {
        preview = preview.replacingImage(with: image)
        if let currentImage = imageView.image, currentImage === image {
            updateImageBackground()
            return
        }
        if animated {
            addImageUpdateTransitionIfNeeded()
        }
        imageView.image = image
        updateImageBackground()
        updateHighlightCornerRadius(for: image)
        imageView.subviews.forEach { $0.removeFromSuperview() }
    }

    func updatePreview(_ preview: WindowPreview) {
        self.preview = preview
        titleLabel?.stringValue = preview.title
        if !isClosing, actionFeedbackWorkItem == nil {
            setStatus(preview.isMinimized ? "Minimized" : "")
        }
        if let image = preview.image {
            updateImage(image)
        } else {
            updateImageBackground()
        }
        if isHovered, !isClosing {
            WindowPeekController.shared.show(preview: preview)
        }
    }

    func deactivateHoverIfNeeded(outside screenPoint: CGPoint) {
        guard isHovered else { return }
        guard contains(screenPoint: screenPoint) else {
            scheduleHoverDeactivation()
            return
        }
    }

    var isHoverActive: Bool {
        isHovered
    }

    func preservePeekForReflow() {
        guard isInteractive else { return }
        preservesPeekOnDeinit = true
        peekWorkItem?.cancel()
        hoverExitWorkItem?.cancel()
        PreviewCardHoverCoordinator.shared.deactivate(self)
    }

    @discardableResult
    func restoreHoverIfNeeded(at screenPoint: CGPoint) -> Bool {
        guard isInteractive,
              !isClosing,
              contains(screenPoint: screenPoint) else {
            return false
        }
        activateHover()
        updateCloseButtonHover(at: screenPoint)
        return true
    }

    @objc private func closeWindow(_ sender: NSButton) {
        guard isInteractive, !isClosing else { return }
        beginAction(status: "Closing")
        peekWorkItem?.cancel()
        WindowPeekController.shared.hide()
        sender.isEnabled = false
        onClose(preview) { [weak self] success in
            guard let self, !success else { return }
            self.isClosing = false
            self.closeButton.isEnabled = true
            self.showActionFailure("Close failed")
        }
    }

    private func beginAction(status: String) {
        isClosing = true
        actionFeedbackGeneration += 1
        actionFeedbackWorkItem?.cancel()
        actionFeedbackWorkItem = nil
        setStatus(status)
    }

    private func showActionFailure(_ message: String) {
        setStatus(message)
        actionFeedbackGeneration += 1
        let generation = actionFeedbackGeneration
        actionFeedbackWorkItem?.cancel()
        let windowID = preview.windowID
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.preview.windowID == windowID,
                  self.actionFeedbackGeneration == generation,
                  !self.isClosing else {
                return
            }
            self.actionFeedbackWorkItem = nil
            self.setStatus(self.preview.isMinimized ? "Minimized" : "")
        }
        actionFeedbackWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    private func setStatus(_ status: String) {
        guard let statusLabel, statusLabel.stringValue != status else { return }
        statusLabel.stringValue = status
        statusLabel.toolTip = status.isEmpty ? nil : status
        NSAccessibility.post(element: statusLabel, notification: .valueChanged)
    }

    func collapseForRemoval(duration: TimeInterval) {
        isClosing = true
        actionFeedbackGeneration += 1
        peekWorkItem?.cancel()
        hoverExitWorkItem?.cancel()
        actionFeedbackWorkItem?.cancel()
        WindowPeekController.shared.hide(windowID: preview.windowID)
        PreviewCardHoverCoordinator.shared.deactivate(self)
        setCloseButtonVisible(false)
        isHovered = false
        updateHighlightAppearance()
        superview?.layoutSubtreeIfNeeded()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            widthConstraint?.animator().constant = 0
            animator().alphaValue = 0
            superview?.layoutSubtreeIfNeeded()
        }
    }

    private func schedulePeek() {
        guard isInteractive else { return }
        peekWorkItem?.cancel()
        guard PreviewMetrics.peekDelay > 0 else {
            WindowPeekController.shared.show(preview: preview)
            return
        }

        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.window?.isVisible == true,
                  self.bounds.contains(self.convert(self.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)) else {
                return
            }
            WindowPeekController.shared.show(preview: self.preview)
        }
        peekWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + PreviewMetrics.peekDelay, execute: item)
    }

    private func activateHover() {
        guard isInteractive, !isClosing else { return }
        hoverExitWorkItem?.cancel()
        hoverExitWorkItem = nil
        let wasHovered = isHovered
        isHovered = true
        updateHighlightAppearance()
        setCloseButtonVisible(true)
        if !wasHovered {
            schedulePeek()
        }
        PreviewCardHoverCoordinator.shared.activate(self)
    }

    private func deactivateHover(hidePeek: Bool = true) {
        guard isInteractive, !isClosing else { return }
        hoverExitWorkItem?.cancel()
        hoverExitWorkItem = nil
        isHovered = false
        updateHighlightAppearance()
        setCloseButtonVisible(false)
        peekWorkItem?.cancel()
        PreviewCardHoverCoordinator.shared.deactivate(self)
        if hidePeek {
            WindowPeekController.shared.hide(windowID: preview.windowID)
        }
    }

    fileprivate func deactivateHoverForPeerSwitch() {
        deactivateHover(hidePeek: false)
    }

    private func scheduleHoverDeactivation() {
        hoverExitWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverExitWorkItem = nil
            guard !self.containsCurrentMouse() else { return }
            self.deactivateHover()
        }
        hoverExitWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + PreviewMetrics.cardHoverExitGrace, execute: item)
    }

    private func build() {
        configureCardLayer()
        configureImageView()
        configureAppIconView()
        if showsCloseButton {
            configureCloseButton()
        }
        let titleLabel = makeTitleLabel()
        let statusLabel = makeStatusLabel()
        self.titleLabel = titleLabel
        self.statusLabel = statusLabel
        addSubviews(titleLabel: titleLabel, statusLabel: statusLabel)
        installConstraints(titleLabel: titleLabel, statusLabel: statusLabel)
        if keepsSampleCloseButtonVisible {
            setCloseButtonVisible(true)
        }
    }

    private var isInteractive: Bool {
        interactionMode == .live
    }

    private func contains(screenPoint: CGPoint) -> Bool {
        guard let window else { return false }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        return bounds.contains(convert(windowPoint, from: nil))
    }

    private func containsCurrentMouse() -> Bool {
        contains(screenPoint: DockCursorTracker.shared.currentMouseLocation(preferEventTap: true))
    }

    private func configureCardLayer() {
        wantsLayer = true
        layer?.cornerRadius = highlightCornerRadius
        layer?.masksToBounds = false
        updateHighlightCornerRadius(for: preview.image)
        updateHighlightAppearance()
    }

    private func updateHighlightAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.borderWidth = isHovered ? Self.highlightBorderWidth : 0
        layer?.borderColor = isHovered ? PrevDockColors.highlight(alpha: 0.95).cgColor : NSColor.clear.cgColor
        layer?.backgroundColor = isHovered ? PrevDockColors.highlight(alpha: 0.16).cgColor : NSColor.clear.cgColor
        CATransaction.commit()
    }

    private func addImageUpdateTransitionIfNeeded() {
        guard imageView.image != nil else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.08
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        imageView.layer?.add(transition, forKey: "previewThumbnailImageUpdate")
    }

    private func updateHighlightCornerRadius(for image: NSImage?) {
        guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            highlightCornerRadiusKey = nil
            highlightCornerRadius = Self.fallbackHighlightCornerRadius
            layer?.cornerRadius = highlightCornerRadius
            return
        }

        let key = PreviewHighlightCornerRadiusKey(
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height,
            displayWidth: Int(thumbnailSize.width.rounded(.toNearestOrAwayFromZero)),
            displayHeight: Int(thumbnailSize.height.rounded(.toNearestOrAwayFromZero))
        )
        guard highlightCornerRadiusKey != key else { return }

        highlightCornerRadiusKey = key
        highlightCornerRadius = PreviewHighlightCornerRadius.estimate(
            from: cgImage,
            displayedSize: thumbnailSize,
            padding: Self.contentPadding,
            fallback: Self.fallbackHighlightCornerRadius
        )
        layer?.cornerRadius = highlightCornerRadius
    }

    private func configureImageView() {
        imageView.image = preview.image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.masksToBounds = true
        updateImageBackground()
        if preview.image == nil {
            let loadingView = ThumbnailLoadingView()
            let loadingSize = PreviewLoadingPlaceholderLayout.fittedSize(in: thumbnailSize)
            imageView.addSubview(loadingView)
            NSLayoutConstraint.activate([
                loadingView.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
                loadingView.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
                loadingView.widthAnchor.constraint(equalToConstant: loadingSize.width),
                loadingView.heightAnchor.constraint(equalToConstant: loadingSize.height)
            ])
        }
    }

    private func updateImageBackground() {
        guard imageView.image == nil else {
            imageView.layer?.backgroundColor = nil
            return
        }
        imageView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
    }

    private func configureAppIconView() {
        appIconView.image = preview.app.icon
        appIconView.imageScaling = .scaleProportionallyUpOrDown
        appIconView.wantsLayer = true
        appIconView.layer?.cornerRadius = max(3, contentStyle.appIconSize * 0.2)
        appIconView.layer?.masksToBounds = true
    }

    private func configureCloseButton() {
        closeButton.toolTip = "Close"
        closeButton.target = self
        closeButton.action = #selector(closeWindow(_:))
        closeButton.isHidden = true
        closeButton.alphaValue = 0
    }

    private func setCloseButtonVisible(_ visible: Bool) {
        guard showsCloseButton else { return }
        if !visible {
            closeButton.setPointerInside(false)
        }
        closeButton.isHidden = !visible
        closeButton.alphaValue = visible ? 1 : 0
    }

    private func updateCloseButtonHover(with event: NSEvent) {
        guard showsCloseButton, !closeButton.isHidden else { return }
        let buttonPoint = closeButton.convert(event.locationInWindow, from: nil)
        closeButton.setPointerInside(closeButton.bounds.contains(buttonPoint))
    }

    private func updateCloseButtonHover(at screenPoint: CGPoint) {
        guard let window,
              showsCloseButton,
              !closeButton.isHidden else {
            return
        }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let buttonPoint = closeButton.convert(windowPoint, from: nil)
        closeButton.setPointerInside(closeButton.bounds.contains(buttonPoint))
    }

    private func makeTitleLabel() -> NSTextField {
        let label = NSTextField(labelWithString: preview.title)
        label.font = .systemFont(ofSize: contentStyle.titleFontSize, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func makeStatusLabel() -> NSTextField {
        let status = NSTextField(labelWithString: preview.isMinimized ? "Minimized" : "")
        status.font = .systemFont(ofSize: contentStyle.statusFontSize, weight: .medium)
        status.textColor = NSColor.white.withAlphaComponent(0.7)
        status.alignment = .right
        status.lineBreakMode = .byTruncatingTail
        status.maximumNumberOfLines = 1
        return status
    }

    private func addSubviews(titleLabel: NSTextField, statusLabel: NSTextField) {
        addSubview(imageView)
        addSubview(appIconView)
        addSubview(titleLabel)
        addSubview(statusLabel)
        if showsCloseButton {
            addSubview(closeButton)
        }
        imageView.translatesAutoresizingMaskIntoConstraints = false
        appIconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
    }

    private func installConstraints(titleLabel: NSTextField, statusLabel: NSTextField) {
        let widthConstraint = widthAnchor.constraint(equalToConstant: cardSize.width)
        self.widthConstraint = widthConstraint
        var constraints = PreviewCardChromeLayout.horizontalConstraints(
            container: self,
            imageView: imageView,
            appIconView: appIconView,
            titleLabel: titleLabel,
            statusLabel: statusLabel,
            thumbnailWidth: thumbnailSize.width,
            contentStyle: contentStyle,
            contentPadding: Self.contentPadding
        ) + [
            widthConstraint,
            heightAnchor.constraint(equalToConstant: cardSize.height),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: Self.contentPadding),
            imageView.heightAnchor.constraint(equalToConstant: thumbnailSize.height),
            appIconView.centerYAnchor.constraint(equalTo: imageView.bottomAnchor, constant: contentStyle.cardVerticalChrome / 2),
            appIconView.heightAnchor.constraint(equalToConstant: contentStyle.appIconSize),
            titleLabel.centerYAnchor.constraint(equalTo: imageView.bottomAnchor, constant: contentStyle.cardVerticalChrome / 2),
            statusLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor)
        ]
        if showsCloseButton {
            closeButton.translatesAutoresizingMaskIntoConstraints = false
            constraints.append(contentsOf: [
                closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.contentPadding + 1),
                closeButton.topAnchor.constraint(equalTo: topAnchor, constant: Self.contentPadding + 1),
                closeButton.widthAnchor.constraint(equalToConstant: PreviewCloseButton.side),
                closeButton.heightAnchor.constraint(equalToConstant: PreviewCloseButton.side)
            ])
        }
        NSLayoutConstraint.activate(constraints)
    }
}

private final class PreviewCloseButton: NSButton {
    static let side: CGFloat = 30
    private static let diameter: CGFloat = 26
    private var hoverTrackingArea: NSTrackingArea?
    private var isPointerInside = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureButton()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.side, height: Self.side)
    }

    override var isOpaque: Bool {
        false
    }

    override var isHighlighted: Bool {
        didSet {
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setPointerInside(true)
    }

    override func mouseMoved(with event: NSEvent) {
        setPointerInside(true)
    }

    override func mouseExited(with event: NSEvent) {
        setPointerInside(false)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawCircularBackground()
        drawXMark()
    }

    private func configureButton() {
        setButtonType(.momentaryChange)
        isBordered = false
        isTransparent = true
        title = ""
        focusRingType = .none
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityLabel("Close")
        translatesAutoresizingMaskIntoConstraints = false
    }

    private var circleRect: NSRect {
        let maxDiameter = max(0, floor(min(bounds.width, bounds.height)) - 1)
        let diameter = min(maxDiameter, Self.diameter)
        return NSRect(
            x: bounds.midX - diameter / 2,
            y: bounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
    }

    private func drawCircularBackground() {
        let alpha: CGFloat = isHighlighted || isPointerInside ? 0.86 : 0.76
        NSColor.black.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: circleRect).fill()
    }

    private func drawXMark() {
        let rect = circleRect
        let inset = max(7, rect.width * 0.31)
        let path = NSBezierPath()
        path.lineWidth = 2.2
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: rect.minX + inset, y: rect.minY + inset))
        path.line(to: NSPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        path.move(to: NSPoint(x: rect.maxX - inset, y: rect.minY + inset))
        path.line(to: NSPoint(x: rect.minX + inset, y: rect.maxY - inset))
        NSColor.white.setStroke()
        path.stroke()
    }

    fileprivate func setPointerInside(_ inside: Bool) {
        guard isPointerInside != inside else { return }
        isPointerInside = inside
        needsDisplay = true
    }
}

final class DesktopGroupView: NSView {
    private let contentStack = NSStackView()
    private let titleBadge: DesktopGroupTitleBadgeView?
    private let fixedSize: NSSize
    private let drawsBackground: Bool
    private var isHovered = false
    private var initialHoverGate: InitialHoverActivationGate

    init(
        title: String?,
        isCurrent: Bool,
        size: NSSize,
        initialHoverSuppressionPoint: CGPoint? = nil,
        drawsBackground: Bool = true
    ) {
        let maxTitleWidth = max(0, size.width - PreviewMetrics.desktopGroupPadding * 2)
        titleBadge = title.map { DesktopGroupTitleBadgeView(title: $0, isCurrent: isCurrent, maxWidth: maxTitleWidth) }
        fixedSize = size
        self.drawsBackground = drawsBackground
        initialHoverGate = InitialHoverActivationGate(suppressionPoint: initialHoverSuppressionPoint)
        super.init(frame: NSRect(origin: .zero, size: size))
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        fixedSize
    }

    static func fittingSize(
        rowWidths: [CGFloat],
        rowHeight: CGFloat,
        rowCount: Int = 1,
        title: String?,
        isCurrent: Bool,
        maxTitleWidth: CGFloat? = nil,
        contentSize: PreviewContentSize? = nil
    ) -> NSSize {
        let labelFont = contentSize.map(PreviewMetrics.desktopGroupLabelFont(for:)) ?? PreviewMetrics.desktopGroupLabelFont
        let labelHeight = contentSize.map(PreviewMetrics.desktopGroupLabelHeight(for:)) ?? PreviewMetrics.desktopGroupLabelHeight
        let titleWidth = title.map {
            DesktopGroupTitleBadgeView.preferredWidth(
                for: $0,
                isCurrent: isCurrent,
                maxWidth: maxTitleWidth ?? CGFloat.greatestFiniteMagnitude,
                font: labelFont
            )
        } ?? 0
        let titleHeight = title == nil ? 0 : labelHeight + PreviewMetrics.desktopGroupHeaderSpacing
        let contentWidth = max(rowWidths.max() ?? 0, titleWidth)
        let rowsHeight = CGFloat(rowCount) * rowHeight + CGFloat(max(0, rowCount - 1)) * PreviewMetrics.rowSpacing
        return NSSize(
            width: contentWidth + PreviewMetrics.desktopGroupPadding * 2,
            height: titleHeight + rowsHeight + PreviewMetrics.desktopGroupPadding * 2
        )
    }

    func addContentRow(_ row: NSView) {
        if let previousRow = contentStack.arrangedSubviews.last, previousRow !== titleBadge {
            contentStack.setCustomSpacing(PreviewMetrics.rowSpacing, after: previousRow)
        }
        contentStack.addArrangedSubview(row)
    }

    func deactivateHoverIfNeeded(outside screenPoint: CGPoint) {
        guard isHovered else { return }
        guard contains(screenPoint: screenPoint) else {
            setHovered(false)
            return
        }
    }

    override func updateTrackingAreas() {
        guard drawsBackground else { return }
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self
        ))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
    }

    override func mouseEntered(with event: NSEvent) {
        guard drawsBackground else { return }
        guard !initialHoverGate.blocksHoverActivation() else { return }
        setHovered(true)
    }

    override func mouseMoved(with event: NSEvent) {
        guard drawsBackground else { return }
        guard !initialHoverGate.blocksHoverActivation() else { return }
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard drawsBackground else { return }
        setHovered(false)
    }

    private func build() {
        configureLayer()
        configureStack()
        installStack()
    }

    private func contains(screenPoint: CGPoint) -> Bool {
        guard let window else { return false }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        return bounds.contains(convert(windowPoint, from: nil))
    }

    private func configureLayer() {
        wantsLayer = drawsBackground
        if drawsBackground {
            layer?.cornerRadius = 9
            layer?.borderWidth = 1
            updateLayerColors()
        }
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: fixedSize.width),
            heightAnchor.constraint(equalToConstant: fixedSize.height)
        ])
    }

    private func configureStack() {
        contentStack.orientation = .vertical
        contentStack.spacing = PreviewMetrics.desktopGroupHeaderSpacing
        contentStack.alignment = .centerX
        contentStack.distribution = .gravityAreas
        if let titleBadge {
            contentStack.addArrangedSubview(titleBadge)
        }
    }

    private func installStack() {
        addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: PreviewMetrics.desktopGroupPadding),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -PreviewMetrics.desktopGroupPadding),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: PreviewMetrics.desktopGroupPadding),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -PreviewMetrics.desktopGroupPadding)
        ])
    }

    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        updateLayerColors()
    }

    private func updateLayerColors() {
        guard drawsBackground else { return }
        let borderColor = isHovered ? PrevDockColors.highlight(alpha: 0.95) : .separatorColor
        layer?.borderWidth = isHovered ? 2 : 1
        layer?.borderColor = layerColor(borderColor)
        layer?.backgroundColor = layerColor(.windowBackgroundColor)
    }

    private func layerColor(_ color: NSColor) -> CGColor {
        var resolvedColor = color
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolvedColor = color.usingColorSpace(.deviceRGB) ?? color
        }
        return resolvedColor.cgColor
    }
}

private final class DesktopGroupTitleBadgeView: NSView {
    private let titleLabel: NSTextField
    private let isCurrent: Bool
    private let labelWidth: CGFloat

    init(title: String, isCurrent: Bool, maxWidth: CGFloat) {
        titleLabel = NSTextField(labelWithString: title)
        self.isCurrent = isCurrent
        labelWidth = Self.preferredWidth(for: title, isCurrent: isCurrent, maxWidth: maxWidth)
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: labelWidth, height: PreviewMetrics.desktopGroupLabelHeight)
    }

    static func preferredWidth(
        for title: String,
        isCurrent: Bool,
        maxWidth: CGFloat,
        font: NSFont = PreviewMetrics.desktopGroupLabelFont
    ) -> CGFloat {
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        let horizontalPadding = PreviewMetrics.desktopGroupLabelHorizontalPadding
        let naturalWidth = textWidth + horizontalPadding + PreviewMetrics.desktopGroupLabelTextSlack
        return min(naturalWidth, maxWidth)
    }

    private func build() {
        configureLayer()
        configureTitle()
        installTitle()
    }

    private func configureLayer() {
        wantsLayer = true
        layer?.cornerRadius = PreviewMetrics.desktopGroupLabelHeight / 2
        layer?.borderWidth = 1
        updateColors()
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: labelWidth),
            heightAnchor.constraint(equalToConstant: PreviewMetrics.desktopGroupLabelHeight)
        ])
    }

    private func configureTitle() {
        titleLabel.font = PreviewMetrics.desktopGroupLabelFont
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.textColor = textColor
    }

    private func installTitle() {
        addSubview(titleLabel)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        let inset = PreviewMetrics.desktopGroupLabelHorizontalPadding / 2
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private var backgroundColor: NSColor {
        isCurrent ? PrevDockColors.highlight(alpha: 0.56) : .clear
    }

    private var borderColor: NSColor {
        isCurrent ? PrevDockColors.highlight(alpha: 0.95) : NSColor.white.withAlphaComponent(0.42)
    }

    private var textColor: NSColor {
        .white.withAlphaComponent(isCurrent ? 0.98 : 0.78)
    }

    private func updateColors() {
        layer?.backgroundColor = backgroundColor.cgColor
        layer?.borderColor = borderColor.cgColor
        titleLabel.textColor = textColor
    }
}

final class EmptyPreviewView: NSView {
    private let titleLabel: NSTextField
    private let label: NSTextField

    init(appName: String) {
        titleLabel = NSTextField(labelWithString: appName)
        label = NSTextField(labelWithString: "No window found")
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let titleSize = titleLabel.intrinsicContentSize
        let labelSize = label.intrinsicContentSize
        return NSSize(
            width: ceil(max(titleSize.width, labelSize.width) + PreviewMetrics.emptyHorizontalPadding),
            height: ceil(titleSize.height + labelSize.height + PreviewMetrics.emptyTitleSpacing + PreviewMetrics.emptyVerticalPadding)
        )
    }

    private func build() {
        configureLabels()
        installLabels()
    }

    private func configureLabels() {
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.82)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
    }

    private func installLabels() {
        addSubview(titleLabel)
        addSubview(label)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PreviewMetrics.emptyHorizontalPadding / 2),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PreviewMetrics.emptyHorizontalPadding / 2),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: PreviewMetrics.emptyVerticalPadding / 2),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PreviewMetrics.emptyHorizontalPadding / 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PreviewMetrics.emptyHorizontalPadding / 2),
            label.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: PreviewMetrics.emptyTitleSpacing),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -PreviewMetrics.emptyVerticalPadding / 2)
        ])
    }
}

final class ThumbnailLoadingView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 140, height: 28)
    }

    private func build() {
        let label = NSTextField(labelWithString: "Loading")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.62)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 3),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -3)
        ])
    }
}

extension WindowPreview {
    static var placeholder: WindowPreview {
        WindowPreview(
            windowID: 0,
            title: "",
            bounds: .zero,
            isMinimized: false,
            isFullscreen: false,
            isFocused: false,
            desktop: nil,
            image: nil,
            app: NSRunningApplication.current
        )
    }
}
