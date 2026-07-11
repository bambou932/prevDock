import AppKit

final class PermissionSettingsView: NSStackView {
    private static let monitoringInterval: TimeInterval = 0.5
    private static let maximumMonitoringDuration: TimeInterval = 120
    private static let returnMonitoringDuration: TimeInterval = 3

    private let summaryLabel = NSTextField(labelWithString: "")
    private var lastStatus: PermissionManager.Status?
    private var refreshTimer: Timer?
    private var monitoringDeadline = Date.distantPast
    private var applicationObserver: NSObjectProtocol?
    private var windowCloseObserver: NSObjectProtocol?

    private lazy var accessibilityRow = makePermissionRow(
        permission: .accessibility,
        description: "Lets prevDock read Dock items and act on the window you choose."
    )
    private lazy var screenRecordingRow = makePermissionRow(
        permission: .screenRecording,
        description: "Lets prevDock capture window thumbnails for previews."
    )

    init() {
        super.init(frame: .zero)
        configureLayout()
        installApplicationObserver()
        refreshStatus()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopMonitoring()
        removeObserver(applicationObserver)
        removeObserver(windowCloseObserver)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindowClose()
    }

    func refreshForPresentation() {
        refreshStatus()
    }

    func focusFirstRelevantAction() {
        let status = PermissionManager.status
        let permission = status.missingPermissions.first ?? .accessibility
        window?.makeFirstResponder(row(for: permission).preferredAction(granted: status.isGranted(permission)))
    }

    private func configureLayout() {
        orientation = .vertical
        alignment = .leading
        spacing = 12
        let header = makeHeader()
        let footnote = makeFootnote()
        addArrangedSubview(header)
        addArrangedSubview(accessibilityRow)
        addArrangedSubview(screenRecordingRow)
        addArrangedSubview(footnote)
        header.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        accessibilityRow.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        screenRecordingRow.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        footnote.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    private func makeHeader() -> NSStackView {
        let title = NSTextField(labelWithString: "Permissions")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let explanation = NSTextField(
            wrappingLabelWithString: "Both permissions are needed for complete Dock previews. “Screen Recording” is the macOS name for access used to create thumbnails."
        )
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        explanation.maximumNumberOfLines = 2

        summaryLabel.font = .systemFont(ofSize: 12, weight: .medium)
        summaryLabel.maximumNumberOfLines = 2

        let stack = verticalStack([title, explanation, summaryLabel], spacing: 3)
        explanation.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        summaryLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func makeFootnote() -> NSTextField {
        let label = NSTextField(
            wrappingLabelWithString: "Status updates automatically. If a Screen Recording change does not take effect, quit and reopen prevDock."
        )
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.maximumNumberOfLines = 2
        return label
    }

    private func makePermissionRow(
        permission: PermissionManager.Permission,
        description: String
    ) -> PermissionRowView {
        PermissionRowView(
            permission: permission,
            description: description,
            requestHandler: { [weak self] permission in
                self?.request(permission)
            },
            settingsHandler: { [weak self] permission in
                self?.openSettings(for: permission)
            }
        )
    }

    private func request(_ permission: PermissionManager.Permission) {
        startMonitoring()
        PermissionManager.request(permission)
        refreshStatus()
    }

    private func openSettings(for permission: PermissionManager.Permission) {
        startMonitoring()
        _ = PermissionManager.openSystemSettings(for: permission)
    }

    private func refreshStatus() {
        let status = PermissionManager.status
        if status != lastStatus {
            update(status)
        }
        if status.allGranted {
            stopMonitoring()
        }
    }

    private func update(_ status: PermissionManager.Status) {
        let hadPreviousStatus = lastStatus != nil
        lastStatus = status
        accessibilityRow.update(granted: status.accessibilityGranted)
        screenRecordingRow.update(granted: status.screenRecordingGranted)
        updateSummary(status)
        if hadPreviousStatus {
            NotificationCenter.default.post(
                name: PermissionManager.didChangeNotification,
                object: status
            )
            NSAccessibility.post(element: summaryLabel, notification: .valueChanged)
        }
    }

    private func updateSummary(_ status: PermissionManager.Status) {
        if status.allGranted {
            summaryLabel.stringValue = "Ready — Accessibility and Screen Recording are granted."
            summaryLabel.textColor = .systemGreen
            return
        }

        let missing = status.missingPermissions.map(\.title).joined(separator: " and ")
        summaryLabel.stringValue = "Action needed — \(missing) \(status.missingPermissions.count == 1 ? "is" : "are") not granted."
        summaryLabel.textColor = .systemOrange
    }

    private func row(for permission: PermissionManager.Permission) -> PermissionRowView {
        switch permission {
        case .accessibility:
            return accessibilityRow
        case .screenRecording:
            return screenRecordingRow
        }
    }

    private func installApplicationObserver() {
        applicationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            self?.applicationDidBecomeActive()
        }
    }

    private func applicationDidBecomeActive() {
        refreshStatus()
        guard refreshTimer != nil else { return }
        monitoringDeadline = Date().addingTimeInterval(Self.returnMonitoringDuration)
    }

    private func observeWindowClose() {
        removeObserver(windowCloseObserver)
        windowCloseObserver = nil
        guard let window else {
            stopMonitoring()
            return
        }

        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.stopMonitoring()
        }
    }

    private func startMonitoring() {
        monitoringDeadline = Date().addingTimeInterval(Self.maximumMonitoringDuration)
        guard refreshTimer == nil else { return }

        let timer = Timer(timeInterval: Self.monitoringInterval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard self.window?.isVisible == true, Date() < self.monitoringDeadline else {
                self.stopMonitoring()
                return
            }
            self.refreshStatus()
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopMonitoring() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        monitoringDeadline = .distantPast
    }

    private func removeObserver(_ observer: NSObjectProtocol?) {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
    }

    private func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }
}

private final class PermissionRowView: NSStackView {
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
        orientation = .horizontal
        alignment = .centerY
        spacing = 10
        edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        layer?.borderWidth = 1

        let labels = makeLabels(description: description)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configureStatusViews()
        configureButtons()
        addArrangedSubview(labels)
        addArrangedSubview(spacer)
        addArrangedSubview(makeStatusStack())
        addArrangedSubview(requestButton)
        addArrangedSubview(settingsButton)
        labels.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        setAccessibilityLabel(permission.title)
    }

    private func makeLabels(description: String) -> NSStackView {
        let title = NSTextField(labelWithString: permission.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let detail = NSTextField(wrappingLabelWithString: description)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    private func configureStatusViews() {
        statusImageView.imageScaling = .scaleProportionallyDown
        statusImageView.setContentHuggingPriority(.required, for: .horizontal)
        statusImageView.widthAnchor.constraint(equalToConstant: 16).isActive = true
        statusImageView.heightAnchor.constraint(equalToConstant: 16).isActive = true
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.alignment = .left
        statusLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
    }

    private func makeStatusStack() -> NSStackView {
        let stack = NSStackView(views: [statusImageView, statusLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        return stack
    }

    private func configureButtons() {
        requestButton.target = self
        requestButton.action = #selector(requestAccess)
        requestButton.bezelStyle = .rounded
        requestButton.controlSize = .small
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        settingsButton.bezelStyle = .rounded
        settingsButton.controlSize = .small
    }

    @objc private func requestAccess() {
        requestHandler(permission)
    }

    @objc private func openSettings() {
        settingsHandler(permission)
    }
}
