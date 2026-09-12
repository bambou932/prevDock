import Cocoa

final class PreviewCloseButton: NSButton {
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
        let rect = bounds.intersection(visibleRect)
        guard !rect.isEmpty else { return }
        let area = NSTrackingArea(
            rect: rect,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        updatePointerInside()
    }

    override func mouseMoved(with event: NSEvent) {
        updatePointerInside()
    }

    private func updatePointerInside() {
        guard let window else { return }
        let mouse = DockCursorTracker.shared.currentMouseLocation(preferEventTap: true)
        let windowPoint = window.convertPoint(fromScreen: mouse)
        setPointerInside(bounds.intersection(visibleRect).contains(convert(windowPoint, from: nil)))
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

    func setPointerInside(_ inside: Bool) {
        guard isPointerInside != inside else { return }
        isPointerInside = inside
        needsDisplay = true
    }
}
