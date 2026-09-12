import AppKit

final class PermissionSettingsView: NSStackView {
    private static let monitoringInterval: TimeInterval = 0.5
    private static let maximumMonitoringDuration: TimeInterval = 120
    private static let returnMonitoringDuration: TimeInterval = 3

    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let summaryImageView = NSImageView()
    private var lastStatus: PermissionManager.Status?
    private var refreshTimer: Timer?
    private var monitoringDeadline: TimeInterval = 0
    private var isPageActive = true
    private var applicationObserver: NSObjectProtocol?
    private var permissionObserver: NSObjectProtocol?
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
        installPermissionObserver()
        refreshStatus()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopMonitoring()
        removeObserver(applicationObserver)
        removeObserver(permissionObserver)
        removeObserver(windowCloseObserver)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindowClose()
    }

    func refreshForPresentation() {
        refreshStatus()
    }

    func setPageActive(_ active: Bool) {
        isPageActive = active
        guard active else {
            stopMonitoring()
            return
        }
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
        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.maximumNumberOfLines = 0
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summaryImageView.imageScaling = .scaleProportionallyDown
        summaryImageView.widthAnchor.constraint(equalToConstant: 18).isActive = true
        summaryImageView.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let stack = NSStackView(views: [summaryImageView, summaryLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 9
        return stack
    }

    private func makeFootnote() -> NSTextField {
        let label = NSTextField(
            wrappingLabelWithString: "Status updates automatically. If a Screen Recording change does not take effect, quit and reopen prevDock."
        )
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.maximumNumberOfLines = 0
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
        refreshStatus(PermissionManager.status)
    }

    private func refreshStatus(_ status: PermissionManager.Status) {
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
            NSAccessibility.post(element: summaryLabel, notification: .valueChanged)
        }
    }

    private func updateSummary(_ status: PermissionManager.Status) {
        if status.allGranted {
            summaryLabel.stringValue = "Ready — Accessibility and Screen Recording are granted."
            updateSummarySymbol(granted: true)
            return
        }

        let missing = status.missingPermissions.map(\.title).joined(separator: " and ")
        summaryLabel.stringValue = "Action needed — \(missing) \(status.missingPermissions.count == 1 ? "is" : "are") not granted."
        updateSummarySymbol(granted: false)
    }

    private func updateSummarySymbol(granted: Bool) {
        let symbol = granted ? "checkmark.circle.fill" : "info.circle.fill"
        summaryImageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        summaryImageView.contentTintColor = granted ? .systemGreen : .secondaryLabelColor
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

    private func installPermissionObserver() {
        permissionObserver = NotificationCenter.default.addObserver(
            forName: PermissionManager.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let status = notification.object as? PermissionManager.Status else { return }
            self?.refreshStatus(status)
        }
    }

    private func applicationDidBecomeActive() {
        guard isPageActive else { return }
        refreshStatus()
        guard refreshTimer != nil else { return }
        monitoringDeadline = ProcessInfo.processInfo.systemUptime + Self.returnMonitoringDuration
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
        guard isPageActive else { return }
        monitoringDeadline = ProcessInfo.processInfo.systemUptime + Self.maximumMonitoringDuration
        guard refreshTimer == nil else { return }

        let timer = Timer(timeInterval: Self.monitoringInterval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard self.isPageActive, self.window?.isVisible == true,
                  ProcessInfo.processInfo.systemUptime < self.monitoringDeadline else {
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
        monitoringDeadline = 0
    }

    private func removeObserver(_ observer: NSObjectProtocol?) {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
    }


}
