import Cocoa

final class DockLabelPanelController {
    private let panel: NSPanel
    private let labelView = DockItemLabelView()
    private var currentKey: String?
    private var currentAnchor = CGRect.zero

    var isVisible: Bool {
        panel.isVisible
    }

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 30),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = labelView
    }

    func show(title: String, anchoredTo anchor: CGRect) {
        guard !title.isEmpty else {
            hide()
            return
        }

        currentAnchor = anchor
        labelView.title = title
        let frame = positionedFrame(size: labelView.intrinsicContentSize, anchoredTo: anchor)
        let key = "\(title)|\(Int(frame.minX))|\(Int(frame.minY))|\(Int(frame.width))|\(Int(frame.height))"
        guard key != currentKey || !panel.isVisible else { return }

        currentKey = key
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        currentKey = nil
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    func reposition() {
        guard panel.isVisible else { return }
        panel.setFrame(positionedFrame(size: labelView.intrinsicContentSize, anchoredTo: currentAnchor), display: true)
    }

    private func positionedFrame(size: NSSize, anchoredTo anchor: CGRect) -> NSRect {
        let screen = ScreenGeometry.screen(containing: anchor) ?? NSScreen.main
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = screen?.visibleFrame ?? screenFrame
        let gap: CGFloat = 7
        let edge = dockEdge(for: anchor, in: screenFrame)

        switch edge {
        case .bottom:
            return NSRect(
                x: clamp(anchor.midX - size.width / 2, min: frame.minX + 8, max: frame.maxX - size.width - 8),
                y: min(anchor.maxY + gap, frame.maxY - size.height - 8),
                width: size.width,
                height: size.height
            )
        case .top:
            return NSRect(
                x: clamp(anchor.midX - size.width / 2, min: frame.minX + 8, max: frame.maxX - size.width - 8),
                y: max(anchor.minY - size.height - gap, frame.minY + 8),
                width: size.width,
                height: size.height
            )
        case .left:
            return NSRect(
                x: min(anchor.maxX + gap, frame.maxX - size.width - 8),
                y: clamp(anchor.midY - size.height / 2, min: frame.minY + 8, max: frame.maxY - size.height - 8),
                width: size.width,
                height: size.height
            )
        case .right:
            return NSRect(
                x: max(anchor.minX - size.width - gap, frame.minX + 8),
                y: clamp(anchor.midY - size.height / 2, min: frame.minY + 8, max: frame.maxY - size.height - 8),
                width: size.width,
                height: size.height
            )
        }
    }

    private func dockEdge(for anchor: CGRect, in frame: CGRect) -> DockEdge {
        let distances: [(DockEdge, CGFloat)] = [
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

private final class DockItemLabelView: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")

    var title: String = "" {
        didSet {
            label.stringValue = title
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let labelSize = label.intrinsicContentSize
        return NSSize(
            width: ceil(min(max(labelSize.width + 28, 46), 260)),
            height: 31
        )
    }

    private func build() {
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.42).cgColor

        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5)
        ])
    }
}

private enum DockEdge {
    case bottom
    case top
    case left
    case right
}
