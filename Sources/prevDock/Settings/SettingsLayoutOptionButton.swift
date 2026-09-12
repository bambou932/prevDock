import AppKit

final class SettingsLayoutOptionButton: NSButton {
    let mode: PreviewOverflowMode
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }

    init(mode: PreviewOverflowMode) {
        self.mode = mode
        super.init(frame: .zero)
        title = mode == .scroll ? "Single Row" : "Wrap into Rows"
        setButtonType(.radio)
        isBordered = false
        focusRingType = .exterior
        setAccessibilityLabel(title)
        heightAnchor.constraint(equalToConstant: 146).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        (state == .on ? NSColor.controlAccentColor.withAlphaComponent(0.10) : .controlBackgroundColor).setFill()
        shape.fill()
        (state == .on ? NSColor.controlAccentColor : NSColor.separatorColor.withAlphaComponent(0.5)).setStroke()
        shape.lineWidth = state == .on ? 2 : 0.5
        shape.stroke()
        drawDiagram()
        if state == .on { drawSelectionMark() }
        drawText(title, y: 103, font: .systemFont(ofSize: 13, weight: .medium), color: .labelColor)
        drawText(mode == .scroll ? "Scroll horizontally" : "Use multiple rows", y: 122, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
    }

    private func drawDiagram() {
        let size = NSSize(width: 42, height: 27)
        let count = mode == .scroll ? 3 : 4
        for index in 0..<count {
            let column = mode == .scroll ? index : index % 2
            let row = mode == .scroll ? 0 : index / 2
            let width: CGFloat = mode == .scroll ? 142 : 92
            let x = (bounds.width - width) / 2 + CGFloat(column) * 50
            let y: CGFloat = mode == .scroll ? 44 : 27 + CGFloat(row) * 33
            let rect = NSRect(origin: NSPoint(x: x, y: y), size: size)
            NSColor.controlAccentColor.withAlphaComponent(state == .on ? 0.75 : 0.35).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            NSColor.white.withAlphaComponent(0.55).setFill()
            NSRect(x: x + 5, y: y + 6, width: 12, height: 2).fill()
        }
    }

    private func drawSelectionMark() {
        let x = bounds.width - 28
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: 12, width: 15, height: 15)).fill()
        let check = NSBezierPath()
        check.move(to: NSPoint(x: x + 4, y: 19))
        check.line(to: NSPoint(x: x + 6.5, y: 22))
        check.line(to: NSPoint(x: x + 11, y: 17))
        check.lineWidth = 1.5
        check.lineCapStyle = .round
        NSColor.white.setStroke()
        check.stroke()
    }

    private func drawText(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        (text as NSString).draw(in: NSRect(x: 8, y: y, width: bounds.width - 16, height: 18), withAttributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph
        ])
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }
}
