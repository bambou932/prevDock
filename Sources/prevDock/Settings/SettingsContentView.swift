import AppKit

final class SettingsContentView: NSView {
    private static let sidebarWidth: CGFloat = 196
    var onMinimumContentWidthChanged: ((CGFloat) -> Void)?
    private let sidebar = SettingsSidebarView()
    private let detail = NSView()
    private let updateController: UpdateController
    private let permissionView = PermissionSettingsView()
    private let previewStage = SettingsPreviewStage()
    private var pages = [SettingsPane: SettingsPageView]()
    private var settingsObserver: NSObjectProtocol?
    private(set) var selectedPane = SettingsPane.general
    private let delaySlider = NSSlider()
    private let delayStepper = NSStepper()
    private let delayValue = NSTextField(labelWithString: "")
    private let titleSlider = NSSlider()
    private let titleValue = NSTextField(labelWithString: "")
    private let heightSlider = NSSlider()
    private let heightValue = NSTextField(labelWithString: "")
    private let autoFitSwitch = NSSwitch()
    private let autoFitDetail = SettingsUI.detail("")
    private let closeSwitch = NSSwitch()
    private let loginSwitch = NSSwitch()
    private let groupingSwitch = NSSwitch()
    private let clickSwitch = NSSwitch()
    private let dockLabelSwitch = NSSwitch()
    private let updateSwitch = NSSwitch()
    private let updateButton = NSButton(title: "Check for Updates…", target: nil, action: nil)
    private let versionLabel = NSTextField(labelWithString: "")
    private var layoutButtons = [PreviewOverflowMode: SettingsLayoutOptionButton]()

    init(updateController: UpdateController) {
        self.updateController = updateController
        super.init(frame: .zero)
        configureControls()
        configureShell()
        previewStage.onMinimumWidthChanged = { [weak self] in self?.accommodatePreviewWidth($0) }
        observeChanges()
        selectPane(.general)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }

    func selectPane(_ pane: SettingsPane) {
        selectedPane = pane
        if pane != .appearance { previewStage.setPageActive(false) }
        sidebar.select(pane)
        permissionView.setPageActive(pane == .permissions)
        let page = pages[pane] ?? makePage(pane)
        pages[pane] = page
        if page.superview !== detail {
            if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: detail) {
                sidebar.focusSelection()
            }
            detail.subviews.forEach { $0.removeFromSuperview() }
            detail.addSubview(page)
            SettingsUI.pin(page, to: detail)
        }
        if pane == .appearance { previewStage.setPageActive(true) }
        window?.title = "\(pane.title) — prevDock"
        refreshForPresentation()
        window?.recalculateKeyViewLoop()
    }

    func refreshForPresentation() {
        updateControls()
        loginSwitch.state = LaunchAtLoginController.isEnabled ? .on : .off
        updateUpdateControls()
        if selectedPane == .permissions { permissionView.refreshForPresentation() }
        if selectedPane == .appearance { previewStage.refresh() }
    }

    private func settingsDidChange() {
        updateControls()
        if selectedPane == .appearance { previewStage.refresh() }
    }

    private func accommodatePreviewWidth(_ width: CGFloat) {
        guard width.isFinite, width > 0 else { return }
        pages[.appearance]?.accommodateContentWidth(width)
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        onMinimumContentWidthChanged?(Self.sidebarWidth + SettingsPageView.horizontalInsets + scrollerWidth + width)
    }

    func focusPermissionAction() {
        selectPane(.permissions)
        layoutSubtreeIfNeeded()
        permissionView.focusFirstRelevantAction()
    }

    private func configureShell() {
        addSubview(sidebar)
        addSubview(detail)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        detail.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
            detail.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor),
            detail.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        sidebar.onSelect = { [weak self] in self?.selectPane($0) }
    }

    private func observeChanges() {
        updateController.stateDidChange = { [weak self] in self?.updateUpdateControls() }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: PrevDockSettings.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.settingsDidChange() }
    }

    private func makePage(_ pane: SettingsPane) -> SettingsPageView {
        let page = SettingsPageView(pane: pane)
        switch pane {
        case .general: populateGeneral(page)
        case .appearance: populateAppearance(page)
        case .layout: populateLayout(page)
        case .permissions: page.addSection(permissionView)
        case .updates: populateUpdates(page)
        }
        return page
    }

    private func populateGeneral(_ page: SettingsPageView) {
        page.addSection(SettingsUI.group("Startup", rows: [
            SettingsUI.row("Open at login", detail: "Have prevDock ready when you sign in.", control: loginSwitch)
        ]))
        page.addSection(SettingsUI.group("Dock interaction", rows: [
            SettingsUI.row("Click to show previews", detail: "For apps with multiple windows, show previews before activating the app.", control: clickSwitch),
            SettingsUI.row("Hide native Dock labels", detail: "Hide the app names that macOS shows above Dock icons.", control: dockLabelSwitch)
        ]))
        page.addSection(SettingsUI.group("Timing", rows: [makeDelayRow()]))
        page.addSection(SettingsUI.footnote("Hold Shift while clicking an app in the Dock to use the normal macOS action."))
    }

    private func populateAppearance(_ page: SettingsPageView) {
        page.addSection(previewStage)
        page.addSection(SettingsUI.group("Preview size", rows: [
            makeSizeRow("Title size", slider: titleSlider, value: titleValue),
            makeSizeRow("Window height", slider: heightSlider, value: heightValue)
        ]))
        page.addSection(SettingsUI.group("Window controls", rows: [
            SettingsUI.row("Show close button", detail: "Close a window directly from its preview.", control: closeSwitch)
        ]))
    }

    private func populateLayout(_ page: SettingsPageView) {
        let choices = PreviewOverflowMode.allCases.map { mode in
            let button = SettingsLayoutOptionButton(mode: mode)
            button.target = self
            button.action = #selector(layoutChanged(_:))
            layoutButtons[mode] = button
            return button
        }
        let choiceRow = SettingsUI.horizontal(choices, spacing: 12)
        choiceRow.distribution = .fillEqually
        page.addSection(SettingsUI.section("Arrange windows", content: choiceRow))
        page.addSection(SettingsUI.group("Fitting & grouping", rows: [
            SettingsUI.row("Fit automatically", detailLabel: autoFitDetail, control: autoFitSwitch),
            SettingsUI.row("Group windows by Desktop", detail: "Keep windows from the same Desktop together.", control: groupingSwitch)
        ]))
        page.addSection(SettingsUI.footnote("Automatic fitting keeps thumbnails in one row. When they become too small to read, prevDock switches to a scrollable list of window titles."))
    }

    private func populateUpdates(_ page: SettingsPageView) {
        let product = SettingsUI.vertical([
            SettingsUI.symbol("macwindow.on.rectangle", size: 38, color: .controlAccentColor),
            SettingsUI.title("prevDock", size: 24), versionLabel
        ], spacing: 10)
        product.alignment = .centerX
        product.edgeInsets = NSEdgeInsets(top: 24, left: 0, bottom: 28, right: 0)
        page.addSection(product)
        page.addSection(SettingsUI.group("Software updates", rows: [
            SettingsUI.row("Automatically install updates", detail: "Check for, download, and install new versions.", control: updateSwitch),
            SettingsUI.row("Check for a new version", control: updateButton)
        ]))
        page.addSection(SettingsUI.footnote("prevDock is an early preview. Updates include improvements to window previews and compatibility with macOS."))
    }

    private func makeDelayRow() -> NSView {
        let caption = SettingsUI.vertical([
            SettingsUI.title("Switch delay"),
            SettingsUI.detail("Wait before switching previews between Dock apps.")
        ], spacing: 3)
        let controls = SettingsUI.horizontal([delaySlider, delayStepper, delayValue], spacing: 10)
        let labels = SettingsUI.horizontal([SettingsUI.detail("Instant"), NSView(), SettingsUI.detail("2 seconds")], spacing: 0)
        let stack = SettingsUI.vertical([caption, controls, labels], spacing: 10)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        NSLayoutConstraint.activate([
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            labels.widthAnchor.constraint(equalTo: delaySlider.widthAnchor)
        ])
        return stack
    }

    private func makeSizeRow(_ title: String, slider: NSSlider, value: NSTextField) -> NSView {
        let control = SettingsUI.vertical([slider, value], spacing: 2)
        control.alignment = .centerX
        slider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        return SettingsUI.row(title, control: control)
    }

    private func configureControls() {
        configureSwitch(loginSwitch, title: "Open at login", action: #selector(loginChanged(_:)))
        configureSwitch(clickSwitch, title: "Click to show previews", action: #selector(clickChanged(_:)))
        configureSwitch(dockLabelSwitch, title: "Hide native Dock labels", action: #selector(dockLabelChanged(_:)))
        configureSwitch(autoFitSwitch, title: "Fit automatically", action: #selector(autoFitChanged(_:)))
        configureSwitch(groupingSwitch, title: "Group windows by Desktop", action: #selector(groupingChanged(_:)))
        configureSwitch(closeSwitch, title: "Show close button", action: #selector(closeChanged(_:)))
        configureSwitch(updateSwitch, title: "Automatically install updates", action: #selector(updatesChanged(_:)))
        configureSliders()
        configureUpdateControls()
    }

    private func configureSwitch(_ control: NSSwitch, title: String, action: Selector) {
        control.target = self
        control.action = action
        control.controlSize = .small
        control.setAccessibilityLabel(title)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func configureSliders() {
        configureSlider(titleSlider, title: "Preview title size", maximum: 4, action: #selector(titleChanged(_:)))
        configureSlider(heightSlider, title: "Preview window height", maximum: 4, action: #selector(heightChanged(_:)))
        configureSlider(delaySlider, title: "Preview switch delay", maximum: 2, action: #selector(delayChanged(_:)))
        delaySlider.allowsTickMarkValuesOnly = false
        delaySlider.isContinuous = true
        delayStepper.minValue = 0
        delayStepper.maxValue = 2
        delayStepper.increment = 0.05
        delayStepper.target = self
        delayStepper.action = #selector(delayChanged(_:))
        delayStepper.setAccessibilityLabel("Preview switch delay")
        delayValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        delayValue.alignment = .right
        delayValue.widthAnchor.constraint(equalToConstant: 62).isActive = true
        [titleValue, heightValue].forEach {
            $0.font = .systemFont(ofSize: 11)
            $0.textColor = .secondaryLabelColor
        }
    }

    private func configureSlider(_ slider: NSSlider, title: String, maximum: Double, action: Selector) {
        slider.minValue = 0
        slider.maxValue = maximum
        slider.numberOfTickMarks = 5
        slider.allowsTickMarkValuesOnly = true
        slider.target = self
        slider.action = action
        slider.setAccessibilityLabel(title)
    }

    private func configureUpdateControls() {
        updateButton.bezelStyle = .rounded
        updateButton.target = self
        updateButton.action = #selector(checkForUpdates(_:))
        updateButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
    }

    private func updateControls() {
        updateDelayControls()
        updateSizeControls()
        updateLayoutControls()
        clickSwitch.state = PrevDockSettings.dockAppClickPreviewEnabled ? .on : .off
        dockLabelSwitch.state = PrevDockSettings.nativeDockLabelSuppressionEnabled ? .on : .off
        closeSwitch.state = PrevDockSettings.previewCloseButtonEnabled ? .on : .off
        groupingSwitch.state = PrevDockSettings.previewDesktopGroupingEnabled ? .on : .off
    }

    private func updateDelayControls() {
        let delay = PrevDockSettings.previewSwitchDelay
        delaySlider.doubleValue = delay
        delayStepper.doubleValue = delay
        delayValue.stringValue = PrevDockSettings.formattedDelay(delay)
        delaySlider.setAccessibilityValueDescription(delayValue.stringValue)
        delayStepper.setAccessibilityValueDescription(delayValue.stringValue)
    }

    private func updateSizeControls() {
        let titleSize = PrevDockSettings.previewContentSize
        let height = PrevDockSettings.previewWindowHeight
        titleSlider.doubleValue = Double(PreviewContentSize.allCases.firstIndex(of: titleSize) ?? 2)
        heightSlider.doubleValue = Double(PreviewWindowHeight.allCases.firstIndex(of: height) ?? 2)
        titleValue.stringValue = titleSize.title
        heightValue.stringValue = height.title
        titleSlider.setAccessibilityValueDescription(titleSize.title)
        heightSlider.setAccessibilityValueDescription(height.title)
    }

    private func updateLayoutControls() {
        let mode = PrevDockSettings.previewOverflowMode
        layoutButtons.forEach { $1.state = $0 == mode ? .on : .off }
        autoFitSwitch.state = PrevDockSettings.previewAutoFitEnabled ? .on : .off
        autoFitSwitch.isEnabled = mode == .scroll
        autoFitDetail.stringValue = mode == .scroll ?
            "Adapt thumbnail sizes to the number of open windows." : "Available with Single Row. Your preference is kept when you switch back."
    }

    private func updateUpdateControls() {
        updateSwitch.state = updateController.automaticallyInstallsUpdates ? .on : .off
        updateButton.isEnabled = updateController.canCheckForUpdates
        versionLabel.stringValue = "Version \(updateController.currentVersionText)"
    }

    @objc private func delayChanged(_ sender: Any) {
        let stepped = (sender as? NSStepper) === delayStepper
        let value = stepped ? delayStepper.doubleValue : (delaySlider.doubleValue / 0.1).rounded() * 0.1
        let range = PrevDockSettings.previewSwitchDelayRange
        PrevDockSettings.previewSwitchDelay = (min(max(value, range.lowerBound), range.upperBound) * 100).rounded() / 100
        updateDelayControls()
    }

    @objc private func titleChanged(_ sender: NSSlider) {
        let index = Int(sender.doubleValue.rounded())
        guard PreviewContentSize.allCases.indices.contains(index) else { return }
        PrevDockSettings.previewContentSize = PreviewContentSize.allCases[index]
    }

    @objc private func heightChanged(_ sender: NSSlider) {
        let index = Int(sender.doubleValue.rounded())
        guard PreviewWindowHeight.allCases.indices.contains(index) else { return }
        PrevDockSettings.previewWindowHeight = PreviewWindowHeight.allCases[index]
    }

    @objc private func layoutChanged(_ sender: SettingsLayoutOptionButton) {
        PrevDockSettings.previewOverflowMode = sender.mode
    }

    @objc private func autoFitChanged(_ sender: NSSwitch) { PrevDockSettings.previewAutoFitEnabled = sender.state == .on }
    @objc private func groupingChanged(_ sender: NSSwitch) { PrevDockSettings.previewDesktopGroupingEnabled = sender.state == .on }
    @objc private func closeChanged(_ sender: NSSwitch) { PrevDockSettings.previewCloseButtonEnabled = sender.state == .on }
    @objc private func clickChanged(_ sender: NSSwitch) { PrevDockSettings.dockAppClickPreviewEnabled = sender.state == .on }
    @objc private func dockLabelChanged(_ sender: NSSwitch) { PrevDockSettings.nativeDockLabelSuppressionEnabled = sender.state == .on }

    @objc private func loginChanged(_ sender: NSSwitch) {
        do { try LaunchAtLoginController.setEnabled(sender.state == .on) }
        catch { showLoginError(error) }
        loginSwitch.state = LaunchAtLoginController.isEnabled ? .on : .off
    }

    private func showLoginError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not update login item"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }

    @objc private func updatesChanged(_ sender: NSSwitch) {
        updateController.automaticallyInstallsUpdates = sender.state == .on
        updateUpdateControls()
    }

    @objc private func checkForUpdates(_ sender: NSButton) {
        updateController.checkForUpdates(sender)
        updateUpdateControls()
    }
}
