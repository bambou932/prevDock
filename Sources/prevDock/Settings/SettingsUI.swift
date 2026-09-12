import AppKit

enum SettingsUI {
    static func title(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .semibold) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = .labelColor
        return label
    }

    static func detail(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func footnote(_ text: String) -> NSTextField {
        let label = detail(text)
        label.font = .systemFont(ofSize: 11)
        return label
    }

    static func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
        view.contentTintColor = color
        view.imageScaling = .scaleProportionallyDown
        view.widthAnchor.constraint(equalToConstant: size).isActive = true
        view.heightAnchor.constraint(equalToConstant: size).isActive = true
        view.setAccessibilityElement(false)
        return view
    }

    static func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    static func horizontal(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    static func row(_ title: String, detail: String? = nil, control: NSView) -> NSView {
        row(title, detailLabel: detail.map(Self.detail), control: control)
    }

    static func row(_ text: String, detailLabel: NSTextField?, control: NSView) -> NSView {
        let label = title(text, weight: .regular)
        let labels = vertical([label] + (detailLabel.map { [$0] } ?? []), spacing: 4)
        let row = horizontal([labels, NSView(), control], spacing: 16)
        row.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel?.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        label.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor).isActive = true
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return row
    }

    static func group(_ title: String, rows: [NSView]) -> NSView {
        let card = SettingsCardView()
        let stack = vertical([], spacing: 0)
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let inset = NSView()
                let line = NSBox()
                line.boxType = .separator
                inset.addSubview(line)
                stack.addArrangedSubview(inset)
                line.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    inset.widthAnchor.constraint(equalTo: stack.widthAnchor),
                    inset.heightAnchor.constraint(equalToConstant: 1),
                    line.leadingAnchor.constraint(equalTo: inset.leadingAnchor, constant: 16),
                    line.trailingAnchor.constraint(equalTo: inset.trailingAnchor, constant: -16),
                    line.centerYAnchor.constraint(equalTo: inset.centerYAnchor)
                ])
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        card.addSubview(stack)
        pin(stack, to: card)
        return section(title, content: card)
    }

    static func section(_ title: String, content: NSView) -> NSView {
        let label = Self.title(title, size: 12)
        label.textColor = .secondaryLabelColor
        let stack = vertical([label, content], spacing: 9)
        content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    static func pin(_ view: NSView, to parent: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            view.topAnchor.constraint(equalTo: parent.topAnchor),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
    }
}

private final class SettingsCardView: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.controlBackgroundColor.withAlphaComponent(0.72).setFill()
        shape.fill()
        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
    }
}
