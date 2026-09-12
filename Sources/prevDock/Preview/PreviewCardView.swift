import Cocoa
import QuartzCore

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
    private let isCompact: Bool
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
    private var thumbnailLoadingWorkItem: DispatchWorkItem?
    private var actionFeedbackGeneration = 0
    private var isClosing = false
    private var isHovered = false
    private var isPresentationSuspended = false
    private var isThumbnailUnavailable = false
    private var preservesPeekOnDeinit = false
    private var initialHoverGate: PreviewInitialHoverGate
    private var highlightCornerRadius: CGFloat = 10
    private var highlightCornerRadiusKey: PreviewHighlightCornerRadiusKey?

    init(
        preview: WindowPreview,
        imageHeight: CGFloat,
        compactSize: NSSize? = nil,
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
        self.isCompact = compactSize != nil
        self.thumbnailSize = thumbnailSize
        self.showsCloseButton = showsCloseButtonOverride ?? (interactionMode == .live && PrevDockSettings.previewCloseButtonEnabled)
        keepsSampleCloseButtonVisible = interactionMode == .sample && self.showsCloseButton
        self.contentStyle = contentStyle
        self.interactionMode = interactionMode
        self.onFocus = onFocus
        self.onClose = onClose
        self.cardSize = compactSize ?? Self.cardSize(thumbnailSize: thumbnailSize, contentStyle: contentStyle)
        self.initialHoverGate = PreviewInitialHoverGate(suppressionPoint: initialHoverSuppressionPoint)
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
        thumbnailLoadingWorkItem?.cancel()
        if isInteractive, !preservesPeekOnDeinit {
            WindowPeekController.shared.hide(windowID: preview.windowID)
        }
    }

    override var intrinsicContentSize: NSSize {
        cardSize
    }

    var canReuseForPresentation: Bool {
        !isClosing
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
        focusWindow()
    }

    private func focusWindow() {
        guard isInteractive, !isPresentationSuspended, !isClosing else { return }
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
        let rect = bounds.intersection(visibleRect)
        guard !rect.isEmpty else { return }
        addTrackingArea(NSTrackingArea(rect: rect, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        synchronizeHover(at: DockCursorTracker.shared.currentMouseLocation(preferEventTap: true))
    }

    override func mouseMoved(with event: NSEvent) {
        synchronizeHover(at: DockCursorTracker.shared.currentMouseLocation(preferEventTap: true))
    }

    override func mouseExited(with event: NSEvent) {
        guard isInteractive else { return }
        scheduleHoverDeactivation()
    }

    func updateImage(_ image: NSImage, animated: Bool = true) {
        cancelThumbnailLoadingDeadline()
        preview = preview.replacingImage(with: image)
        isThumbnailUnavailable = false
        updateThumbnailAccessibility()
        updateSnapshotPeekIfNeeded()
        guard !isCompact else { return }
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

    private func updateSnapshotPeekIfNeeded() {
        guard preview.isMinimized, isInteractive, isHovered,
              !isPresentationSuspended, !isClosing,
              window?.isVisible == true, containsCurrentMouse() else { return }
        WindowPeekController.shared.updateSnapshot(preview: preview)
    }

    func updatePreview(_ preview: WindowPreview) {
        let shouldResetThumbnailFailure = self.preview.isMinimized != preview.isMinimized ||
            self.preview.bounds.size != preview.bounds.size
        if shouldResetThumbnailFailure {
            cancelThumbnailLoadingDeadline()
            isThumbnailUnavailable = false
        }
        self.preview = preview
        titleLabel?.stringValue = preview.title
        updateAccessibilityDescription()
        if !isClosing, actionFeedbackWorkItem == nil {
            setStatus(defaultStatus)
        }
        if let image = preview.image {
            updateImage(image)
        } else {
            showThumbnailPlaceholder()
        }
        if isHovered, !isPresentationSuspended, !isClosing {
            WindowPeekController.shared.show(preview: preview)
        }
        updateThumbnailAccessibility()
    }

    func markThumbnailUnavailable() {
        guard !isCompact, preview.image == nil, !isThumbnailUnavailable else { return }
        cancelThumbnailLoadingDeadline()
        isThumbnailUnavailable = true
        showThumbnailPlaceholder()
        updateThumbnailAccessibility()
    }

    func deactivateForPanelHide() {
        deactivateHover()
        peekWorkItem?.cancel()
        hoverExitWorkItem?.cancel()
    }

    func suspendForFocusTransition() {
        deactivateForPanelHide()
        isPresentationSuspended = true
    }

    func prepareForPanelPresentation(initialHoverSuppressionPoint: CGPoint?) {
        isPresentationSuspended = false
        peekWorkItem?.cancel()
        hoverExitWorkItem?.cancel()
        initialHoverGate = PreviewInitialHoverGate(
            suppressionPoint: initialHoverSuppressionPoint
        )
        if isHovered {
            deactivateHover()
        }
    }

    func synchronizeHover(at screenPoint: CGPoint, allowsActivation: Bool = true) {
        guard isInteractive, !isPresentationSuspended, window?.isVisible == true else { return }
        // Reflow can deliver tracking events for a row that has moved away from the pointer.
        guard contains(screenPoint: screenPoint) else {
            if isHovered { scheduleHoverDeactivation() }
            return
        }
        guard allowsActivation, !initialHoverGate.blocksHoverActivation(at: screenPoint) else { return }
        activateHover()
        updateCloseButtonHover(at: screenPoint)
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
              !isPresentationSuspended,
              !isClosing,
              contains(screenPoint: screenPoint) else {
            return false
        }
        activateHover()
        updateCloseButtonHover(at: screenPoint)
        return true
    }

    @objc private func closeWindow(_ sender: NSButton) {
        guard isInteractive, !isPresentationSuspended, !isClosing else { return }
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
        deactivateHover()
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
            self.setStatus(self.defaultStatus)
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
        guard isInteractive, !isPresentationSuspended else { return }
        peekWorkItem?.cancel()
        guard PreviewMetrics.peekDelay > 0 else {
            WindowPeekController.shared.show(preview: preview)
            return
        }

        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.window?.isVisible == true,
                  self.isHovered,
                  !self.isPresentationSuspended,
                  self.containsCurrentMouse() else {
                return
            }
            WindowPeekController.shared.show(preview: self.preview)
        }
        peekWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + PreviewMetrics.peekDelay, execute: item)
    }

    private func activateHover() {
        guard isInteractive, !isPresentationSuspended, !isClosing else { return }
        hoverExitWorkItem?.cancel()
        hoverExitWorkItem = nil
        if !isHovered {
            isHovered = true
            updateHighlightAppearance()
            setCloseButtonVisible(true)
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
        if !isCompact { configureImageView() }
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
        configureAccessibility()
        if keepsSampleCloseButtonVisible {
            setCloseButtonVisible(true)
        }
    }

    private var isInteractive: Bool {
        interactionMode == .live
    }

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("prevDock.previewCard.\(preview.windowID)")
        updateAccessibilityDescription()
        updateThumbnailAccessibility()
        configureAccessibilityActions()
    }

    private func configureAccessibilityActions() {
        guard isInteractive, showsCloseButton else { return }
        let closeAction = NSAccessibilityCustomAction(name: "Close Window") { [weak self] in
            guard let self, !self.isPresentationSuspended, !self.isClosing else { return false }
            self.closeWindow(self.closeButton)
            return true
        }
        setAccessibilityCustomActions([closeAction])
    }

    private func updateThumbnailAccessibility() {
        setAccessibilityLabel(isCompact ? toolTip : preview.title)
        let value: String
        if isCompact {
            value = defaultStatus.isEmpty ? "Ready" : defaultStatus
        } else if preview.image != nil {
            value = "Ready"
        } else if isThumbnailUnavailable {
            value = "Unavailable"
        } else {
            value = "Loading"
        }
        setAccessibilityValue(value)
    }

    private func contains(screenPoint: CGPoint) -> Bool {
        guard let window else { return false }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        // Unclipped AppKit views can report a visibleRect larger than their own bounds.
        return bounds.intersection(visibleRect).contains(convert(windowPoint, from: nil))
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
        guard !isCompact else { return }
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
            showThumbnailPlaceholder()
        }
    }

    private func showThumbnailPlaceholder() {
        guard !isCompact else { return }
        imageView.image = nil
        scheduleThumbnailLoadingDeadlineIfNeeded()
        if isThumbnailUnavailable, imageView.subviews.first is ThumbnailUnavailableView { return }
        if !isThumbnailUnavailable, imageView.subviews.first is ThumbnailLoadingView { return }
        imageView.subviews.forEach { $0.removeFromSuperview() }
        let placeholder: NSView = isThumbnailUnavailable ?
            ThumbnailUnavailableView(appIcon: preview.app.icon) : ThumbnailLoadingView()
        imageView.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: imageView.leadingAnchor, constant: 4),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: imageView.trailingAnchor, constant: -4),
            placeholder.widthAnchor.constraint(equalToConstant: min(
                placeholder.intrinsicContentSize.width,
                max(1, thumbnailSize.width - 8)
            ))
        ])
        updateImageBackground()
        updateHighlightCornerRadius(for: nil)
    }

    private func scheduleThumbnailLoadingDeadlineIfNeeded() {
        guard isInteractive, !isCompact, !isThumbnailUnavailable, thumbnailLoadingWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.markThumbnailUnavailable()
        }
        thumbnailLoadingWorkItem = item
        // Window-server capture can fail to respond; keep the card usable while retries continue.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    private func cancelThumbnailLoadingDeadline() {
        thumbnailLoadingWorkItem?.cancel()
        thumbnailLoadingWorkItem = nil
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
        let status = NSTextField(labelWithString: defaultStatus)
        status.font = .systemFont(ofSize: contentStyle.statusFontSize, weight: .medium)
        status.textColor = NSColor.white.withAlphaComponent(0.7)
        status.alignment = .right
        status.lineBreakMode = .byTruncatingTail
        status.maximumNumberOfLines = 1
        return status
    }

    private func addSubviews(titleLabel: NSTextField, statusLabel: NSTextField) {
        if !isCompact { addSubview(imageView) }
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

    private var defaultStatus: String {
        let desktop = isCompact && PrevDockSettings.previewDesktopGroupingEnabled ? preview.desktop?.title : nil
        return [desktop, preview.isMinimized ? "Minimized" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    private func updateAccessibilityDescription() {
        toolTip = [preview.title, defaultStatus].filter { !$0.isEmpty }.joined(separator: " — ")
        closeButton.setAccessibilityLabel("Close \(preview.title)")
    }

    override func accessibilityPerformPress() -> Bool {
        guard isInteractive, !isPresentationSuspended, !isClosing else { return false }
        focusWindow()
        return true
    }

    private func installCompactConstraints(titleLabel: NSTextField, statusLabel: NSTextField) {
        widthConstraint = widthAnchor.constraint(equalToConstant: cardSize.width)
        NSLayoutConstraint.activate(PreviewCardChromeLayout.compactConstraints(
            container: self,
            appIconView: appIconView,
            titleLabel: titleLabel,
            statusLabel: statusLabel,
            closeButton: showsCloseButton ? closeButton : nil,
            contentStyle: contentStyle
        ) + [widthConstraint!, heightAnchor.constraint(equalToConstant: cardSize.height)])
    }

    private func installConstraints(titleLabel: NSTextField, statusLabel: NSTextField) {
        guard !isCompact else {
            installCompactConstraints(titleLabel: titleLabel, statusLabel: statusLabel)
            return
        }
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
