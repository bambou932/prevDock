import AppKit

final class SettingsPreviewStage: NSView {
    private static let sampleBounds = NSRect(x: 0, y: 0, width: 480, height: 360)
    private static let finderApplication = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first ?? .current
    private static var thumbnails = [NSAppearance.Name: NSImage]()

    var onMinimumWidthChanged: ((CGFloat) -> Void)? {
        didSet { onMinimumWidthChanged?(requiredSize.width) }
    }

    private let scene = SettingsPreviewScene()
    private let panel = NSVisualEffectView()
    private let dockClip = NSView()
    private let dockImageView = NSImageView()
    private let caption = NSTextField(labelWithString: "Actual size · Show the Dock to compare")
    private var provider: DockSnapshotProviding?
    private var pageActive = false
    private var providerActive = false
    private var windowClosing = false
    private var observedClosedWindowHidden = false
    private var windowObservers = [NSObjectProtocol]()
    private var dockPlacement: SettingsPreviewStageLayout.DockPlacement?
    private var sampleContent: NSView?
    private var sampleConstraints = [NSLayoutConstraint]()
    private var renderedState: SampleState?
    private var previewSize = CGSize.zero
    private var maximumPreviewSize = CGSize.zero
    private var requiredSize = CGSize(width: 520, height: 348)

    init(snapshotProvider: DockSnapshotProviding? = nil) {
        provider = snapshotProvider
        super.init(frame: .zero)
        configureStage()
        configureScene()
        configureFooter()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        provider?.onChange = nil
        provider?.setActive(false)
    }

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: requiredSize.height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindow()
        updateActivity()
        refresh()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    override func viewWillDraw() {
        refreshSampleIfVisible()
        super.viewWillDraw()
    }

    override func layout() {
        refreshSampleIfVisible()
        positionScene()
        super.layout()
    }

    func setPageActive(_ active: Bool) {
        pageActive = active
        updateActivity()
        refresh()
    }

    func refresh() {
        needsDisplay = true
        refreshSampleIfVisible()
    }

    private var canObserveDock: Bool {
        pageActive && !windowClosing && window?.isVisible == true && window?.isMiniaturized == false
    }

    private func updateActivity() {
        let active = canObserveDock
        guard active != providerActive else { return }
        providerActive = active
        if active { connectProviderIfNeeded() }
        provider?.setActive(active)
        if !active { clearDockImage(status: "Show the Dock to compare") }
    }

    private func connectProviderIfNeeded() {
        if provider == nil {
            provider = DockSnapshotService(contextProvider: { [weak self] in
                guard let self, self.canObserveDock else { return nil }
                return DockSnapshotContext.current(window: self.window)
            })
        }
        provider?.onChange = { [weak self] state in self?.receiveSnapshot(state) }
    }

    private func observeWindow() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        windowClosing = false
        observedClosedWindowHidden = false
        guard let window else { return }
        observe(NSWindow.willCloseNotification, window: window) { stage in stage.windowWillClose() }
        observe(NSWindow.didMiniaturizeNotification, window: window) { stage in stage.updateActivity() }
        observe(NSWindow.didDeminiaturizeNotification, window: window) { stage in stage.windowReopened() }
        observe(NSWindow.didBecomeKeyNotification, window: window) { stage in stage.windowReopened() }
        observe(NSWindow.didChangeOcclusionStateNotification, window: window) { stage in stage.windowVisibilityChanged() }
        observe(NSWindow.didChangeScreenNotification, window: window) { stage in stage.refresh() }
    }

    private func observe(_ name: Notification.Name, window: NSWindow, action: @escaping (SettingsPreviewStage) -> Void) {
        windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
            guard let self else { return }
            action(self)
        })
    }

    private func windowWillClose() {
        windowClosing = true
        observedClosedWindowHidden = false
        updateActivity()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.windowClosing else { return }
            self.observedClosedWindowHidden = self.window?.isVisible != true
        }
    }

    private func windowVisibilityChanged() {
        if windowClosing {
            if window?.isVisible != true { observedClosedWindowHidden = true }
            else if observedClosedWindowHidden { windowClosing = false }
        }
        updateActivity()
        refresh()
    }

    private func windowReopened() {
        guard window?.isVisible == true else { return }
        windowClosing = false
        observedClosedWindowHidden = false
        updateActivity()
        refresh()
    }

    private func receiveSnapshot(_ state: DockSnapshotState) {
        guard providerActive, canObserveDock else { return }
        switch state {
        case .idle: clearDockImage(status: "Show the Dock to compare")
        case .loading: clearDockImage(status: "Reading Dock…")
        case let .available(snapshot): installSnapshot(snapshot)
        case let .unavailable(reason): clearDockImage(status: status(for: reason))
        }
        refresh()
    }

    private func installSnapshot(_ snapshot: DockSnapshot) {
        let geometry = snapshot.geometry
        let imageFrame = CGRect(
            x: snapshot.dockRect.minX - geometry.dockRectInImage.minX,
            y: snapshot.dockRect.minY - geometry.dockRectInImage.minY,
            width: geometry.imageSize.width, height: geometry.imageSize.height
        )
        guard valid(imageFrame), valid(snapshot.finderRect), valid(snapshot.screenFrame), valid(snapshot.screenVisibleFrame),
              snapshot.image.size == geometry.imageSize else {
            clearDockImage(status: "Dock unavailable")
            return
        }
        dockPlacement = .init(edge: geometry.edge, imageFrame: imageFrame, finderFrame: snapshot.finderRect,
                              screenFrame: snapshot.screenFrame, visibleFrame: snapshot.screenVisibleFrame)
        dockImageView.image = snapshot.image
        dockClip.isHidden = false
        updateCaption("Dock · \(snapshot.displayName)")
        needsLayout = true
    }

    private func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0
    }

    private func clearDockImage(status: String) {
        dockImageView.image = nil
        dockClip.isHidden = true
        updateCaption(status)
    }

    private func status(for reason: DockSnapshotUnavailableReason) -> String {
        switch reason {
        case .hidden: return "Show the Dock to compare"
        case .permissions: return "Dock comparison needs permissions"
        case .unavailable: return "Dock unavailable"
        case .captureFailed: return "Dock comparison will retry automatically"
        }
    }

    private func updateCaption(_ status: String) {
        caption.stringValue = "Actual size · \(status)"
        caption.toolTip = caption.stringValue + ". A single-window example; automatic fitting can reduce previews for many windows."
    }

    private func configureStage() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("prevDock.settings.appearanceSample")
    }

    private func configureScene() {
        addSubview(scene)
        scene.addSubview(dockClip)
        dockClip.wantsLayer = true
        dockClip.layer?.masksToBounds = true
        dockClip.isHidden = true
        dockClip.setAccessibilityIdentifier("prevDock.settings.dockSnapshotCrop")
        dockClip.addSubview(dockImageView)
        dockImageView.imageScaling = .scaleNone
        dockImageView.imageAlignment = .alignBottomLeft
        dockImageView.setAccessibilityIdentifier("prevDock.settings.dockSnapshot")
        configurePanel()
        scene.setAccessibilityElement(false)
        scene.setAccessibilityChildren([])
        setAccessibilityChildren([caption])
    }

    private func configurePanel() {
        panel.material = .popover
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 12
        panel.layer?.masksToBounds = true
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        panel.setAccessibilityIdentifier("prevDock.settings.samplePreviewPanel")
        scene.addSubview(panel)
    }

    private func configureFooter() {
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingTail
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(caption)
        caption.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            caption.centerYAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
        ])
    }

    private func refreshSampleIfVisible() {
        guard pageActive, window?.isVisible == true, !isHiddenOrHasHiddenAncestor else { return }
        let state = currentState()
        if renderedState != state {
            renderedState = state
            rebuildSample(state)
            updateAccessibilityDescription(state)
        }
        updateRequiredSize()
    }

    private func currentState() -> SampleState {
        let anchor = dockPlacement?.finderFrame ?? window?.screen?.frame ?? Self.sampleBounds
        return SampleState(
            contentSize: PrevDockSettings.previewContentSize,
            showsCloseButton: PrevDockSettings.previewCloseButtonEnabled,
            groupsByDesktop: PrevDockSettings.previewDesktopGroupingEnabled,
            appearance: effectiveAppearance.bestMatch(from: [.accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua, .darkAqua, .aqua]) ?? .aqua,
            imageHeight: PreviewMetrics.imageHeight(anchoredTo: anchor),
            maximumImageHeight: PreviewMetrics.imageHeight(anchoredTo: anchor, windowHeight: .extraLarge)
        )
    }

    private func rebuildSample(_ state: SampleState) {
        NSLayoutConstraint.deactivate(sampleConstraints)
        sampleContent?.removeFromSuperview()
        let preview = makePreview(state)
        let card = PreviewCardView(preview: preview, imageHeight: state.imageHeight, interactionMode: .sample,
                                   contentSizeOverride: state.contentSize, showsCloseButtonOverride: state.showsCloseButton)
        let content = makeContent(card, grouped: state.groupsByDesktop)
        previewSize = padded(content.intrinsicContentSize)
        maximumPreviewSize = padded(groupSize(PreviewCardView.cardSize(for: preview, imageHeight: state.maximumImageHeight, contentSize: .extraLarge), contentSize: .extraLarge))
        installContent(content)
    }

    private func makeContent(_ card: PreviewCardView, grouped: Bool) -> NSView {
        guard grouped else { return card }
        let group = DesktopGroupView(title: "Desktop 1", isCurrent: true, size: groupSize(card.intrinsicContentSize), drawsBackground: false)
        group.addContentRow(PreviewLayoutViews.makePreviewRow(views: [card]))
        return group
    }

    private func groupSize(_ cardSize: CGSize, contentSize: PreviewContentSize? = nil) -> CGSize {
        DesktopGroupView.fittingSize(rowWidths: [cardSize.width], rowHeight: cardSize.height,
                                    title: "Desktop 1", isCurrent: true, contentSize: contentSize)
    }

    private func padded(_ size: CGSize) -> CGSize {
        CGSize(width: size.width + PreviewMetrics.panelPadding * 2, height: size.height + PreviewMetrics.panelPadding * 2)
    }

    private func installContent(_ content: NSView) {
        sampleContent = content
        excludeFromKeyboardNavigation(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(content)
        let padding = PreviewMetrics.panelPadding
        sampleConstraints = [
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -padding),
            content.topAnchor.constraint(equalTo: panel.topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -padding)
        ]
        NSLayoutConstraint.activate(sampleConstraints)
        needsLayout = true
    }

    private func updateRequiredSize() {
        let size = SettingsPreviewStageLayout.requiredSize(maximumPreviewSize: maximumPreviewSize, dock: dockPlacement)
        guard size != requiredSize else { return }
        let widthChanged = size.width != requiredSize.width
        requiredSize = size
        invalidateIntrinsicContentSize()
        needsLayout = true
        if widthChanged { onMinimumWidthChanged?(size.width) }
    }

    private func positionScene() {
        scene.frame = bounds
        guard maximumPreviewSize.width > 0 else { return }
        let layout = SettingsPreviewStageLayout.calculate(stageBounds: bounds, previewSize: previewSize,
                                                          maximumPreviewSize: maximumPreviewSize, dock: dockPlacement)
        panel.frame = layout.previewFrame
        dockClip.frame = layout.dockVisibleFrame
        dockImageView.frame = layout.dockImageFrame.offsetBy(dx: -layout.dockVisibleFrame.minX, dy: -layout.dockVisibleFrame.minY)
    }

    private func excludeFromKeyboardNavigation(_ view: NSView) {
        if let control = view as? NSControl {
            control.refusesFirstResponder = true
            control.focusRingType = .none
        }
        view.subviews.forEach(excludeFromKeyboardNavigation)
    }

    private func makePreview(_ state: SampleState) -> WindowPreview {
        WindowPreview(windowID: 0, title: "Documents", bounds: Self.sampleBounds, isMinimized: false,
                      isFullscreen: false, isFocused: false, desktop: nil, image: Self.sampleImage(for: state.appearance), app: Self.finderApplication)
    }

    private func updateAccessibilityDescription(_ state: SampleState) {
        let close = state.showsCloseButton ? "Close buttons shown" : "Close buttons hidden"
        let group = state.groupsByDesktop ? "Grouped by desktop" : "Without desktop groups"
        setAccessibilityLabel("Actual-size appearance example")
        setAccessibilityValue("\(state.contentSize.title) text and icons. \(PrevDockSettings.previewWindowHeight.title) thumbnails. \(close). \(group).")
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSColor.windowBackgroundColor
        let tint = background.blended(withFraction: 0.12, of: .controlAccentColor) ?? background
        NSGradient(starting: background, ending: tint)?.draw(in: bounds, angle: -30)
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12).stroke()
    }

    private struct SampleState: Equatable {
        let contentSize: PreviewContentSize
        let showsCloseButton: Bool
        let groupsByDesktop: Bool
        let appearance: NSAppearance.Name
        let imageHeight: CGFloat
        let maximumImageHeight: CGFloat
    }
}

private final class SettingsPreviewScene: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}
private extension SettingsPreviewStage {
    static func sampleImage(for appearanceName: NSAppearance.Name) -> NSImage {
        if let image = thumbnails[appearanceName] { return image }
        let appearance = NSAppearance(named: appearanceName) ?? NSAppearance.currentDrawing()
        let image = NSImage(size: sampleBounds.size, flipped: false) { _ in
            appearance.performAsCurrentDrawingAppearance { drawFinderWindow() }
            return true
        }
        thumbnails[appearanceName] = image
        return image
    }

    static func drawFinderWindow() {
        let outline = NSBezierPath(roundedRect: sampleBounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
        outline.addClip()
        NSColor.controlBackgroundColor.setFill()
        outline.fill()
        fill(NSRect(x: 0, y: 0, width: 115, height: 360), color: .windowBackgroundColor)
        drawToolbar()
        drawSidebar()
        drawDocumentList()
    }

    static func drawToolbar() {
        fill(NSRect(x: 115, y: 315, width: 365, height: 45), color: .windowBackgroundColor)
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            fill(NSRect(x: 15 + CGFloat(index) * 17, y: 338, width: 10, height: 10), color: color, radius: 5)
        }
        drawText("‹   ›", in: NSRect(x: 132, y: 328, width: 42, height: 20), size: 16, color: .secondaryLabelColor)
        drawText("Finder", in: NSRect(x: 182, y: 330, width: 110, height: 16), size: 12, weight: .semibold)
        fill(NSRect(x: 362, y: 327, width: 98, height: 20), color: .quaternaryLabelColor, radius: 6)
    }

    static func drawSidebar() {
        drawText("Favorites", in: NSRect(x: 16, y: 303, width: 90, height: 14), size: 9, color: .secondaryLabelColor)
        let labels = ["AirDrop", "Recents", "Documents", "Downloads"]
        for (index, title) in labels.enumerated() {
            let y = CGFloat(278 - index * 29)
            if index == 2 {
                fill(NSRect(x: 8, y: y - 3, width: 99, height: 25), color: .quaternaryLabelColor, radius: 5)
            }
            fill(NSRect(x: 16, y: y + 3, width: 10, height: 9), color: .systemBlue, radius: 2)
            drawText(title, in: NSRect(x: 34, y: y, width: 72, height: 16), size: 10)
        }
    }

    static func drawDocumentList() {
        drawText("Name", in: NSRect(x: 137, y: 295, width: 160, height: 14), size: 10, color: .secondaryLabelColor)
        for (index, title) in ["Projects", "Design", "Notes", "Shared", "Archive", "Photos", "Research"].enumerated() {
            let y = CGFloat(264 - index * 34)
            if index.isMultiple(of: 2) {
                fill(NSRect(x: 126, y: y - 5, width: 343, height: 29), color: .quaternaryLabelColor, radius: 5)
            }
            drawFolder(in: NSRect(x: 139, y: y + 2, width: 20, height: 16))
            drawText(title, in: NSRect(x: 169, y: y + 1, width: 160, height: 17), size: 11)
            drawText("Folder", in: NSRect(x: 360, y: y + 1, width: 75, height: 17), size: 10, color: .secondaryLabelColor)
        }
    }

    static func drawFolder(in rect: NSRect) {
        fill(NSRect(x: rect.minX, y: rect.maxY - rect.height * 0.1, width: rect.width * 0.45, height: rect.height * 0.22), color: .systemTeal, radius: 2)
        fill(rect, color: .systemCyan, radius: 3)
    }

    static func fill(_ rect: NSRect, color: NSColor, radius: CGFloat = 0) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    static func drawText(_ text: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) {
        (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    }
}
