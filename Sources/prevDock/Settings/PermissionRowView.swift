import AppKit

final class PermissionRowView: NSStackView {
    private let permission: PermissionManager.Permission
    private let statusImageView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let requestButton = NSButton(title: "Request Access", target: nil, action: nil)
    private let settingsButton = NSButton(title: "Open Settings", target: nil, action: nil)
    private let requestHandler: (PermissionManager.Permission) -> Void
    private let settingsHandler: (PermissionManager.Permission) -> Void

    init(
        permission: PermissionManager.Permission,
        description: String,
        requestHandler: @escaping (PermissionManager.Permission) -> Void,
        settingsHandler: @escaping (PermissionManager.Permission) -> Void
    ) {
        self.permission = permission
        self.requestHandler = requestHandler
        self.settingsHandler = settingsHandler
        super.init(frame: .zero)
        configureLayout(description: description)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    func update(granted: Bool) {
        let shouldMoveKeyboardFocus = granted && window?.firstResponder === requestButton
        let symbolName = granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        let color: NSColor = granted ? .systemGreen : .systemOrange
        statusImageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        statusImageView.contentTintColor = color
        statusLabel.stringValue = granted ? "Granted" : "Needed"
        statusLabel.textColor = color
        requestButton.isHidden = granted
        settingsButton.title = granted ? "Review Settings" : "Open Settings"
        setAccessibilityValue(granted ? "Granted" : "Not granted")
        if shouldMoveKeyboardFocus {
            window?.makeFirstResponder(settingsButton)
        }
    }

    func preferredAction(granted: Bool) -> NSButton {
        granted ? settingsButton : requestButton
    }

    private func configureLayout(description: String) {
        orientation = .vertical
        alignment = .leading
        spacing = 12
        edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 0.5
        updateColors()
        configureStatusViews()
        configureButtons()
        installRows(description: description)
        setAccessibilityLabel(permission.title)
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        }
    }

    private func installRows(description: String) {
        let header = makeHeader()
        let body = makeBody(description: description)
        addArrangedSubview(header)
        addArrangedSubview(body)
        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalTo: widthAnchor, constant: -32),
            body.widthAnchor.constraint(equalTo: header.widthAnchor),
            body.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    private func makeHeader() -> NSStackView {
        let symbol = permission == .accessibility ? "accessibility" : "rectangle.on.rectangle"
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let title = NSTextField(labelWithString: permission.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        return horizontalStack([icon, title, flexibleSpacer(), makeStatusStack()], spacing: 9)
    }

    private func makeBody(description: String) -> NSStackView {
        let detail = NSTextField(wrappingLabelWithString: description)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 0
        detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let actions = horizontalStack([requestButton, settingsButton], spacing: 8)
        actions.distribution = .fill
        actions.setContentHuggingPriority(.required, for: .horizontal)
        actions.setContentCompressionResistancePriority(.required, for: .horizontal)
        let body = horizontalStack([detail, actions], spacing: 16)
        actions.trailingAnchor.constraint(equalTo: body.trailingAnchor).isActive = true
        return body
    }

    private func configureStatusViews() {
        statusImageView.imageScaling = .scaleProportionallyDown
        statusImageView.widthAnchor.constraint(equalToConstant: 14).isActive = true
        statusImageView.heightAnchor.constraint(equalToConstant: 14).isActive = true
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func makeStatusStack() -> NSStackView {
        horizontalStack([statusImageView, statusLabel], spacing: 5)
    }

    private func configureButtons() {
        requestButton.target = self
        requestButton.action = #selector(requestAccess)
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        for button in [requestButton, settingsButton] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        requestButton.setAccessibilityLabel("Request \(permission.title) access")
        settingsButton.setAccessibilityLabel("Open \(permission.title) settings")
    }

    private func horizontalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func flexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }

    @objc private func requestAccess() {
        requestHandler(permission)
    }

    @objc private func openSettings() {
        settingsHandler(permission)
    }
}
