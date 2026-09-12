import Cocoa

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
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 28)
        ])
    }
}

final class ThumbnailUnavailableView: NSView {
    private let appIcon: NSImage?

    init(appIcon: NSImage?) {
        self.appIcon = appIcon
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 160, height: 58)
    }

    private func build() {
        let iconView = NSImageView()
        iconView.image = appIcon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.alphaValue = 0.68
        let label = NSTextField(labelWithString: "Preview unavailable")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.62)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(iconView)
        addSubview(label)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        translatesAutoresizingMaskIntoConstraints = false
        let preferredIconWidth = iconView.widthAnchor.constraint(equalToConstant: 32)
        preferredIconWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 58),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor),
            preferredIconWidth,
            iconView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            iconView.heightAnchor.constraint(equalTo: iconView.widthAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor)
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
