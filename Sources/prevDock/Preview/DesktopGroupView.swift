import Cocoa

final class DesktopGroupView: NSView {
    private let contentStack = NSStackView()
    private let titleBadge: DesktopGroupTitleBadgeView?
    private let fixedSize: NSSize
    private let drawsBackground: Bool
    private var isHovered = false
    private var initialHoverGate: PreviewInitialHoverGate

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
        initialHoverGate = PreviewInitialHoverGate(suppressionPoint: initialHoverSuppressionPoint)
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
        let rect = bounds.intersection(visibleRect)
        guard !rect.isEmpty else { return }
        addTrackingArea(NSTrackingArea(
            rect: rect,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved],
            owner: self
        ))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
    }

    override func mouseEntered(with event: NSEvent) {
        guard drawsBackground else { return }
        let mouse = DockCursorTracker.shared.currentMouseLocation(preferEventTap: true)
        guard contains(screenPoint: mouse), !initialHoverGate.blocksHoverActivation(at: mouse) else { return }
        setHovered(true)
    }

    override func mouseMoved(with event: NSEvent) {
        guard drawsBackground else { return }
        let mouse = DockCursorTracker.shared.currentMouseLocation(preferEventTap: true)
        guard contains(screenPoint: mouse), !initialHoverGate.blocksHoverActivation(at: mouse) else { return }
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
        // Unclipped AppKit views can report a visibleRect larger than their own bounds.
        return bounds.intersection(visibleRect).contains(convert(windowPoint, from: nil))
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
