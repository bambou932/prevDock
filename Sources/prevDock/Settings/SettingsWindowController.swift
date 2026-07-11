import Cocoa

final class SettingsWindowController: NSWindowController {
    private let settingsContentView: SettingsContentView

    var isVisible: Bool {
        window?.isVisible == true
    }

    init(updateController: UpdateController) {
        let contentView = SettingsContentView(updateController: updateController)
        settingsContentView = contentView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 952, height: 700),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "prevDock Settings"
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.contentView = contentView
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSettings() {
        showSettings(focusingPermissions: false)
    }

    func showPermissionSettings() {
        showSettings(focusingPermissions: true)
    }

    private func showSettings(focusingPermissions: Bool) {
        guard let window else { return }
        settingsContentView.refreshForPresentation()

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        showWindow(nil)
        focusWindow(window)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.focusWindow(window)
            if focusingPermissions {
                self.settingsContentView.focusPermissionSection()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self, weak window] in
            guard let self, let window, !window.isKeyWindow else { return }
            self.focusWindow(window)
        }
    }

    private func focusWindow(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

private final class SettingsContentView: NSView {
    private static let settingsGroupWidth: CGFloat = 892
    private static let settingsSliderWidth: CGFloat = 280
    private static let optionButtonSize = NSSize(width: 424, height: 258)
    private static let closeOptionButtonSize = NSSize(width: 424, height: 238)
    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private let permissionSettingsView = PermissionSettingsView()
    private let delaySlider = NSSlider()
    private let delayStepper = NSStepper()
    private let delayValueLabel = NSTextField(labelWithString: "")
    private let contentSizeSlider = NSSlider()
    private let contentSizeValueLabel = NSTextField(labelWithString: "")
    private let windowHeightSlider = NSSlider()
    private let windowHeightValueLabel = NSTextField(labelWithString: "")
    private lazy var previewSizeStage = SettingsPreviewStageView(
        width: Self.settingsGroupWidth - 32
    )
    private var overflowButtons = [PreviewOverflowMode: SettingsPreviewOptionButton]()
    private var closeButtons = [Bool: SettingsPreviewOptionButton]()
    private let launchAtLoginSwitch = NSSwitch()
    private let previewDesktopGroupingSwitch = NSSwitch()
    private let dockAppClickPreviewSwitch = NSSwitch()
    private let nativeDockLabelSuppressionSwitch = NSSwitch()
    private let automaticUpdateSwitch = NSSwitch()
    private let updateCheckButton = NSButton(title: "Update Now...", target: nil, action: nil)
    private let updateVersionLabel = NSTextField(labelWithString: "")
    private let updateController: UpdateController

    init(updateController: UpdateController) {
        self.updateController = updateController
        super.init(frame: .zero)
        updateController.stateDidChange = { [weak self] in
            self?.updateUpdateControls()
        }
        build()
        updateControls()
    }

    override init(frame frameRect: NSRect) {
        fatalError("init(frame:) has not been implemented")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.scrollToTop()
        }
    }

    func refreshForPresentation() {
        updateControls()
        previewSizeStage.prepareForPresentation()
        permissionSettingsView.refreshForPresentation()
    }

    func focusPermissionSection() {
        layoutSubtreeIfNeeded()
        scrollToTop()
        permissionSettingsView.focusFirstRelevantAction()
    }

    private func build() {
        configureBackground()
        configureScrollView()
        configureDelayControls()
        configureContentSizeControl()
        configureWindowHeightControl()
        configureLaunchAtLoginSwitch()
        configurePreviewDesktopGroupingSwitch()
        configureDockAppClickPreviewSwitch()
        configureNativeDockLabelSuppressionSwitch()
        configureUpdateControls()
        let stack = makeVerticalStack(views: [makeSettingsGroup()], spacing: 18)
        documentView.addSubview(stack)
        addSubview(scrollView)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -24)
        ])
    }

    private func configureBackground() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    private func configureScrollView() {
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
    }

    private func configureDelayControls() {
        delaySlider.minValue = PrevDockSettings.previewSwitchDelayRange.lowerBound
        delaySlider.maxValue = PrevDockSettings.previewSwitchDelayRange.upperBound
        delaySlider.numberOfTickMarks = 5
        delaySlider.allowsTickMarkValuesOnly = false
        delaySlider.isContinuous = true
        delaySlider.target = self
        delaySlider.action = #selector(delayChanged(_:))
        delaySlider.setAccessibilityLabel("Preview switch delay")
        delaySlider.widthAnchor.constraint(equalToConstant: Self.settingsSliderWidth).isActive = true
        delayStepper.minValue = PrevDockSettings.previewSwitchDelayRange.lowerBound
        delayStepper.maxValue = PrevDockSettings.previewSwitchDelayRange.upperBound
        delayStepper.increment = 0.05
        delayStepper.target = self
        delayStepper.action = #selector(delayChanged(_:))
        delayStepper.setAccessibilityLabel("Preview switch delay")
        delayValueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        delayValueLabel.textColor = .labelColor
        delayValueLabel.alignment = .right
        delayValueLabel.widthAnchor.constraint(equalToConstant: 76).isActive = true
    }

    private func configureContentSizeControl() {
        contentSizeSlider.minValue = 0
        contentSizeSlider.maxValue = Double(PreviewContentSize.allCases.count - 1)
        contentSizeSlider.numberOfTickMarks = PreviewContentSize.allCases.count
        contentSizeSlider.allowsTickMarkValuesOnly = true
        contentSizeSlider.target = self
        contentSizeSlider.action = #selector(contentSizeChanged(_:))
        contentSizeSlider.setAccessibilityLabel("Preview title size")
        contentSizeSlider.widthAnchor.constraint(equalToConstant: Self.settingsSliderWidth).isActive = true
        contentSizeValueLabel.font = .systemFont(ofSize: 12, weight: .medium)
        contentSizeValueLabel.textColor = .secondaryLabelColor
        contentSizeValueLabel.alignment = .center
        contentSizeValueLabel.widthAnchor.constraint(equalToConstant: 88).isActive = true
    }

    private func configureWindowHeightControl() {
        windowHeightSlider.minValue = 0
        windowHeightSlider.maxValue = Double(PreviewWindowHeight.allCases.count - 1)
        windowHeightSlider.numberOfTickMarks = PreviewWindowHeight.allCases.count
        windowHeightSlider.allowsTickMarkValuesOnly = true
        windowHeightSlider.target = self
        windowHeightSlider.action = #selector(windowHeightChanged(_:))
        windowHeightSlider.setAccessibilityLabel("Preview window height")
        windowHeightSlider.widthAnchor.constraint(equalToConstant: Self.settingsSliderWidth).isActive = true
        windowHeightValueLabel.font = .systemFont(ofSize: 12, weight: .medium)
        windowHeightValueLabel.textColor = .secondaryLabelColor
        windowHeightValueLabel.alignment = .center
        windowHeightValueLabel.widthAnchor.constraint(equalToConstant: 88).isActive = true
    }

    private func makeSettingsGroup() -> SettingsGroupView {
        let group = SettingsGroupView()
        let stack = makeVerticalStack(
            views: [
                permissionSettingsView,
                separator(),
                makeDelaySection(),
                separator(),
                makeOverflowSection(),
                separator(),
                makePreviewDesktopGroupingSection(),
                separator(),
                makeContentSizeSection(),
                separator(),
                makeCloseButtonSection(),
                separator(),
                makeLaunchAtLoginSection(),
                separator(),
                makeUpdatesSection(),
                separator(),
                makeDockAppClickPreviewSection(),
                separator(),
                makeNativeDockLabelSuppressionSection()
            ],
            spacing: 14
        )
        group.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            group.widthAnchor.constraint(equalToConstant: Self.settingsGroupWidth),
            permissionSettingsView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: group.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: group.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: group.bottomAnchor, constant: -16)
        ])
        return group
    }

    private func makeDelaySection() -> NSStackView {
        let scale = SettingsSliderTickLabelsContainer(
            slider: delaySlider,
            labels: ["0s", "0.5s", "1.0s", "1.5s", "2.0s"],
            width: Self.settingsSliderWidth
        )
        let controlRow = makeSliderControlRow(
            leadingInset: scale.sideInset,
            views: [delaySlider, delayStepper, delayValueLabel],
            spacing: 10
        )
        return makeVerticalStack(views: [
            makeSectionLabel(title: "Switch delay"),
            controlRow,
            scale
        ], spacing: 8)
    }

    private func makeOverflowSection() -> NSStackView {
        let scroll = makeOverflowButton(mode: .scroll, title: "1 row + scroll")
        let wrap = makeOverflowButton(mode: .wrap, title: "Wrap into rows")
        return makeVerticalStack(views: [
            makeSectionLabel(title: "Preview layout"),
            makeHorizontalStack(views: [scroll, wrap], spacing: 12)
        ], spacing: 10)
    }

    private func makeOverflowButton(mode: PreviewOverflowMode, title: String) -> SettingsPreviewOptionButton {
        let button = SettingsPreviewOptionButton(
            title: title,
            value: mode.rawValue,
            sampleView: SettingsPreviewSamples.layoutPreview(mode: mode),
            cardSize: Self.optionButtonSize,
            allowsSampleInteraction: mode == .scroll
        )
        button.target = self
        button.action = #selector(overflowSelected(_:))
        overflowButtons[mode] = button
        return button
    }

    private func makeContentSizeSection() -> NSStackView {
        let titleSizeBlock = makeSliderBlock(
            title: "Title size",
            slider: contentSizeSlider,
            valueLabel: contentSizeValueLabel,
            scale: makeContentSizeScale()
        )
        let heightBlock = makeSliderBlock(
            title: "Window height",
            slider: windowHeightSlider,
            valueLabel: windowHeightValueLabel,
            scale: makeWindowHeightScale()
        )
        let controls = makeHorizontalStack(views: [titleSizeBlock, heightBlock], spacing: 18)
        controls.alignment = .top
        return makeVerticalStack(views: [
            makeSectionLabel(title: "Preview size"),
            controls,
            previewSizeStage
        ], spacing: 10)
    }

    private func makeContentSizeScale() -> SettingsSliderTickLabelsContainer {
        makePreviewSizeScale(slider: contentSizeSlider, labels: PreviewContentSize.allCases.map(\.title))
    }

    private func makeWindowHeightScale() -> SettingsSliderTickLabelsContainer {
        makePreviewSizeScale(slider: windowHeightSlider, labels: PreviewWindowHeight.allCases.map(\.title))
    }

    private func makePreviewSizeScale(slider: NSSlider, labels: [String]) -> SettingsSliderTickLabelsContainer {
        SettingsSliderTickLabelsContainer(slider: slider, labels: labels, width: Self.settingsSliderWidth)
    }

    private func makeSliderBlock(title: String, slider: NSSlider, valueLabel: NSTextField, scale: SettingsSliderTickLabelsContainer) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        let row = makeSliderControlRow(
            leadingInset: scale.sideInset,
            views: [slider, valueLabel],
            spacing: 10
        )
        return makeVerticalStack(views: [titleLabel, row, scale], spacing: 4)
    }

    private func makeCloseButtonSection() -> NSStackView {
        let on = makeCloseButton(enabled: true, title: "Show close button")
        let off = makeCloseButton(enabled: false, title: "Hide close button")
        return makeVerticalStack(views: [
            makeSectionLabel(title: "Window close button"),
            makeHorizontalStack(views: [on, off], spacing: 12)
        ], spacing: 10)
    }

    private func makeCloseButton(enabled: Bool, title: String) -> SettingsPreviewOptionButton {
        let button = SettingsPreviewOptionButton(
            title: title,
            value: enabled ? "on" : "off",
            sampleView: SettingsPreviewSamples.closeButtonPreview(isEnabled: enabled),
            cardSize: Self.closeOptionButtonSize
        )
        button.target = self
        button.action = #selector(closeButtonSelected(_:))
        closeButtons[enabled] = button
        return button
    }

    private func configureLaunchAtLoginSwitch() {
        configureSwitch(launchAtLoginSwitch, action: #selector(launchAtLoginChanged(_:)))
    }

    private func makeLaunchAtLoginSection() -> NSStackView {
        makeSwitchSection(
            toggle: launchAtLoginSwitch,
            title: "Open prevDock at login",
            description: "Start after sign-in."
        )
    }

    private func configurePreviewDesktopGroupingSwitch() {
        configureSwitch(previewDesktopGroupingSwitch, action: #selector(previewDesktopGroupingChanged(_:)))
    }

    private func makePreviewDesktopGroupingSection() -> NSStackView {
        makeSwitchSection(
            toggle: previewDesktopGroupingSwitch,
            title: "Group windows by Desktop",
            description: "Separate by Desktop."
        )
    }

    private func configureDockAppClickPreviewSwitch() {
        configureSwitch(dockAppClickPreviewSwitch, action: #selector(dockAppClickPreviewChanged(_:)))
    }

    private func makeDockAppClickPreviewSection() -> NSStackView {
        makeSwitchSection(
            toggle: dockAppClickPreviewSwitch,
            title: "Dock app click previews",
            description: "Show previews on a plain click. Hold Shift for native Dock drag and modifier actions."
        )
    }

    private func configureNativeDockLabelSuppressionSwitch() {
        configureSwitch(nativeDockLabelSuppressionSwitch, action: #selector(nativeDockLabelSuppressionChanged(_:)))
    }

    private func configureUpdateControls() {
        configureSwitch(automaticUpdateSwitch, action: #selector(automaticUpdateChanged(_:)))
        updateCheckButton.target = self
        updateCheckButton.action = #selector(checkForUpdates(_:))
        updateCheckButton.bezelStyle = .rounded
        updateVersionLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        updateVersionLabel.textColor = .secondaryLabelColor
        updateVersionLabel.alignment = .right
        updateVersionLabel.widthAnchor.constraint(equalToConstant: 110).isActive = true
    }

    private func makeNativeDockLabelSuppressionSection() -> NSStackView {
        makeSwitchSection(
            toggle: nativeDockLabelSuppressionSwitch,
            title: "Hide native Dock labels",
            description: "Hide macOS Dock labels."
        )
    }

    private func makeUpdatesSection() -> NSStackView {
        let labelStack = makeSectionLabel(
            title: "Updates",
            description: "Early preview release."
        )
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = makeHorizontalStack(views: [labelStack, spacer, updateVersionLabel, updateCheckButton], spacing: 12)
        row.alignment = .centerY
        let automaticRow = makeSwitchSection(
            toggle: automaticUpdateSwitch,
            title: "Automatically install updates",
            description: "Check, download, and install preview updates."
        )
        return makeVerticalStack(views: [row, automaticRow], spacing: 10)
    }

    private func configureSwitch(_ toggle: NSSwitch, action: Selector) {
        toggle.target = self
        toggle.action = action
        toggle.controlSize = .small
        toggle.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func makeSwitchSection(toggle: NSSwitch, title: String, description: String) -> NSStackView {
        toggle.setAccessibilityLabel(title)
        let labelStack = makeSectionLabel(
            title: title,
            description: description
        )
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = makeHorizontalStack(views: [labelStack, spacer, toggle], spacing: 12)
        row.alignment = .centerY
        return row
    }

    private func makeSectionLabel(title: String, description: String? = nil) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        guard let description else {
            return makeVerticalStack(views: [titleLabel], spacing: 0)
        }

        let descriptionLabel = NSTextField(labelWithString: description)
        descriptionLabel.font = .systemFont(ofSize: 12)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.lineBreakMode = .byWordWrapping
        descriptionLabel.maximumNumberOfLines = 2
        return makeVerticalStack(views: [titleLabel, descriptionLabel], spacing: 2)
    }

    private func makeVerticalStack(views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = spacing
        stack.alignment = .leading
        return stack
    }

    private func makeHorizontalStack(views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = spacing
        stack.alignment = .top
        return stack
    }

    private func makeSliderControlRow(leadingInset: CGFloat, views: [NSView], spacing: CGFloat) -> NSStackView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: leadingInset).isActive = true

        let controls = makeHorizontalStack(views: views, spacing: spacing)
        controls.alignment = .centerY

        let row = makeHorizontalStack(views: [spacer, controls], spacing: 0)
        row.alignment = .centerY
        return row
    }

    @objc private func delayChanged(_ sender: Any) {
        let value = (sender as? NSStepper) === delayStepper ? roundedDelay(delayStepper.doubleValue) : magneticDelay(delaySlider.doubleValue)
        PrevDockSettings.previewSwitchDelay = value
        updateControls()
    }

    @objc private func overflowSelected(_ sender: SettingsPreviewOptionButton) {
        guard let mode = PreviewOverflowMode(rawValue: sender.value) else { return }
        PrevDockSettings.previewOverflowMode = mode
        updateControls()
    }

    @objc private func contentSizeChanged(_ sender: NSSlider) {
        let index = Int(sender.doubleValue.rounded())
        guard PreviewContentSize.allCases.indices.contains(index) else { return }
        PrevDockSettings.previewContentSize = PreviewContentSize.allCases[index]
        updateControls()
    }

    @objc private func windowHeightChanged(_ sender: NSSlider) {
        let index = Int(sender.doubleValue.rounded())
        guard PreviewWindowHeight.allCases.indices.contains(index) else { return }
        PrevDockSettings.previewWindowHeight = PreviewWindowHeight.allCases[index]
        updateControls()
    }

    @objc private func closeButtonSelected(_ sender: SettingsPreviewOptionButton) {
        PrevDockSettings.previewCloseButtonEnabled = sender.value == "on"
        updateControls()
    }

    @objc private func launchAtLoginChanged(_ sender: NSSwitch) {
        do {
            try LaunchAtLoginController.setEnabled(sender.state == .on)
        } catch {
            showLaunchAtLoginError(error)
        }
        updateControls()
    }

    @objc private func previewDesktopGroupingChanged(_ sender: NSSwitch) {
        PrevDockSettings.previewDesktopGroupingEnabled = sender.state == .on
        updateControls()
    }

    @objc private func dockAppClickPreviewChanged(_ sender: NSSwitch) {
        PrevDockSettings.dockAppClickPreviewEnabled = sender.state == .on
        updateControls()
    }

    @objc private func nativeDockLabelSuppressionChanged(_ sender: NSSwitch) {
        PrevDockSettings.nativeDockLabelSuppressionEnabled = sender.state == .on
        updateControls()
    }

    @objc private func automaticUpdateChanged(_ sender: NSSwitch) {
        updateController.automaticallyInstallsUpdates = sender.state == .on
        updateControls()
    }

    @objc private func checkForUpdates(_ sender: NSButton) {
        updateController.checkForUpdates(sender)
        updateControls()
    }

    private func updateControls() {
        let delay = PrevDockSettings.previewSwitchDelay
        delaySlider.doubleValue = delay
        delayStepper.doubleValue = delay
        let delayDescription = PrevDockSettings.formattedDelay(delay)
        delayValueLabel.stringValue = delayDescription
        delaySlider.setAccessibilityValueDescription(delayDescription)
        delayStepper.setAccessibilityValueDescription(delayDescription)
        updateOverflowButtons()
        updateContentSizeControls()
        updateCloseButtons()
        updateLaunchAtLoginSwitch()
        updatePreviewDesktopGroupingSwitch()
        updateDockAppClickPreviewSwitch()
        updateNativeDockLabelSuppressionSwitch()
        updateUpdateControls()
    }

    private func updateOverflowButtons() {
        let selected = PrevDockSettings.previewOverflowMode
        overflowButtons.forEach { mode, button in
            button.isChosen = mode == selected
        }
    }

    private func updateContentSizeControls() {
        let selected = PrevDockSettings.previewContentSize
        let index = PreviewContentSize.allCases.firstIndex(of: selected) ?? 0
        contentSizeSlider.doubleValue = Double(index)
        contentSizeValueLabel.stringValue = selected.title
        contentSizeSlider.setAccessibilityValueDescription(selected.title)
        let height = PrevDockSettings.previewWindowHeight
        let heightIndex = PreviewWindowHeight.allCases.firstIndex(of: height) ?? 0
        windowHeightSlider.doubleValue = Double(heightIndex)
        windowHeightValueLabel.stringValue = height.title
        windowHeightSlider.setAccessibilityValueDescription(height.title)
        previewSizeStage.update()
    }

    private func showLaunchAtLoginError(_ error: Error) {
        NSSound.beep()
        let alert = NSAlert()
        alert.messageText = "Could not update login item"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func updateCloseButtons() {
        let selected = PrevDockSettings.previewCloseButtonEnabled
        closeButtons.forEach { enabled, button in
            button.isChosen = enabled == selected
        }
    }

    private func updateLaunchAtLoginSwitch() {
        launchAtLoginSwitch.state = LaunchAtLoginController.isEnabled ? .on : .off
    }

    private func updatePreviewDesktopGroupingSwitch() {
        previewDesktopGroupingSwitch.state = PrevDockSettings.previewDesktopGroupingEnabled ? .on : .off
    }

    private func updateDockAppClickPreviewSwitch() {
        dockAppClickPreviewSwitch.state = PrevDockSettings.dockAppClickPreviewEnabled ? .on : .off
    }

    private func updateNativeDockLabelSuppressionSwitch() {
        nativeDockLabelSuppressionSwitch.state = PrevDockSettings.nativeDockLabelSuppressionEnabled ? .on : .off
    }

    private func updateUpdateControls() {
        automaticUpdateSwitch.state = updateController.automaticallyInstallsUpdates ? .on : .off
        updateCheckButton.isEnabled = updateController.canCheckForUpdates
        updateVersionLabel.stringValue = updateController.currentVersionText
    }

    private func scrollToTop() {
        guard let document = scrollView.documentView else { return }
        let y = max(0, document.bounds.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func magneticDelay(_ value: TimeInterval) -> TimeInterval {
        roundedDelay((value / 0.1).rounded() * 0.1)
    }

    private func roundedDelay(_ value: TimeInterval) -> TimeInterval {
        let range = PrevDockSettings.previewSwitchDelayRange
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return (clamped * 100).rounded() / 100
    }

    private func separator() -> NSView {
        let view = NSBox()
        view.boxType = .separator
        return view
    }
}

private final class SettingsGroupView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class SettingsPreviewOptionButton: NSButton {
    private static let captionHeight: CGFloat = 30
    private static let sampleInset: CGFloat = 6
    let value: String
    private let caption: String
    private let cardSize: NSSize
    private let sampleHost = SettingsPreviewOptionSampleHostView()
    private var hovered = false

    var isChosen = false {
        didSet {
            state = isChosen ? .on : .off
            updateSampleState()
        }
    }

    override var isHighlighted: Bool {
        didSet {
            updateSampleState()
        }
    }

    init(
        title: String,
        value: String,
        sampleView: NSView,
        cardSize: NSSize,
        allowsSampleInteraction: Bool = false
    ) {
        self.value = value
        self.caption = title
        self.cardSize = cardSize
        super.init(frame: NSRect(origin: .zero, size: cardSize))
        sampleHost.allowsInteraction = allowsSampleInteraction
        configureButton()
        installSample(sampleView)
        updateSampleState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        cardSize
    }

    override var isFlipped: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard sampleHost.allowsInteraction else {
            return super.hitTest(point)
        }
        let samplePoint = sampleHost.convert(point, from: self)
        guard sampleHost.bounds.contains(samplePoint),
              let sampleTarget = sampleHost.hitTest(samplePoint) else {
            return super.hitTest(point)
        }
        return sampleTarget
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateSampleState()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateSampleState()
    }

    override func draw(_ dirtyRect: NSRect) {
        drawCaption()
        drawKeyboardFocusIfNeeded()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { needsDisplay = true }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { needsDisplay = true }
        return resigned
    }

    private func configureButton() {
        setButtonType(.radio)
        isBordered = false
        title = ""
        setAccessibilityLabel(caption)
        state = isChosen ? .on : .off
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: cardSize.width).isActive = true
        heightAnchor.constraint(equalToConstant: cardSize.height).isActive = true
    }

    private func installSample(_ sampleView: NSView) {
        addSubview(sampleHost)
        sampleHost.addSubview(sampleView)
        sampleHost.translatesAutoresizingMaskIntoConstraints = false
        sampleView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sampleHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            sampleHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            sampleHost.topAnchor.constraint(equalTo: topAnchor),
            sampleHost.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.captionHeight),
            sampleView.centerXAnchor.constraint(equalTo: sampleHost.centerXAnchor),
            sampleView.centerYAnchor.constraint(equalTo: sampleHost.centerYAnchor),
            sampleView.leadingAnchor.constraint(greaterThanOrEqualTo: sampleHost.leadingAnchor, constant: Self.sampleInset),
            sampleView.trailingAnchor.constraint(lessThanOrEqualTo: sampleHost.trailingAnchor, constant: -Self.sampleInset),
            sampleView.topAnchor.constraint(greaterThanOrEqualTo: sampleHost.topAnchor, constant: Self.sampleInset),
            sampleView.bottomAnchor.constraint(lessThanOrEqualTo: sampleHost.bottomAnchor, constant: -Self.sampleInset)
        ])
    }

    private func updateSampleState() {
        sampleHost.isChosen = isChosen
        sampleHost.isHovered = hovered
        sampleHost.isPressed = isHighlighted
        needsDisplay = true
    }

    private func drawCaption() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        caption.draw(
            in: NSRect(x: 10, y: bounds.height - Self.captionHeight + 6, width: bounds.width - 20, height: 18),
            withAttributes: attributes
        )
    }

    private func drawKeyboardFocusIfNeeded() {
        guard window?.firstResponder === self else { return }
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 2, dy: 2),
            xRadius: 10,
            yRadius: 10
        )
        path.lineWidth = 2
        NSColor.keyboardFocusIndicatorColor.setStroke()
        path.stroke()
    }
}

private final class SettingsPreviewOptionSampleHostView: NSView {
    var allowsInteraction = false
    var isChosen = false {
        didSet { needsDisplay = true }
    }
    var isHovered = false {
        didSet { needsDisplay = true }
    }
    var isPressed = false {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        allowsInteraction ? super.hitTest(point) : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        let selectedAlpha: CGFloat = isPressed ? 0.30 : 0.18
        let normalAlpha: CGFloat = isHovered ? 0.14 : 0.07
        PrevDockColors.highlight(alpha: isChosen ? selectedAlpha : normalAlpha).setFill()
        path.fill()
        path.lineWidth = isChosen ? 2 : 1
        (isChosen ? PrevDockColors.highlight : NSColor.separatorColor.withAlphaComponent(0.70)).setStroke()
        path.stroke()
    }
}

private final class SettingsSliderTickLabelsContainer: NSView {
    private static let height: CGFloat = 14
    private static let labelFont = NSFont.systemFont(ofSize: 10)
    let sideInset: CGFloat

    init(slider: NSSlider, labels: [String], width: CGFloat) {
        sideInset = Self.sideInset(for: labels)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width + sideInset * 2).isActive = true
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true

        let labelView = SettingsSliderTickLabelsView(slider: slider, labels: labels)
        addSubview(labelView)
        labelView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            labelView.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelView.trailingAnchor.constraint(equalTo: trailingAnchor),
            labelView.topAnchor.constraint(equalTo: topAnchor),
            labelView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func sideInset(for labels: [String]) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: labelFont]
        let maxLabelWidth = labels
            .map { ceil(($0 as NSString).size(withAttributes: attributes).width) }
            .max() ?? 0
        return maxLabelWidth / 2 + 2
    }
}

private final class SettingsSliderTickLabelsView: NSView {
    private weak var slider: NSSlider?
    private let labels: [String]

    init(slider: NSSlider, labels: [String]) {
        self.slider = slider
        self.labels = labels
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let slider else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: paragraph
        ]
        let tickCount = min(labels.count, slider.numberOfTickMarks)
        for index in 0..<tickCount {
            let tickRect = slider.rectOfTickMark(at: index)
            let tickPoint = convert(NSPoint(x: tickRect.midX, y: tickRect.midY), from: slider)
            let attributedLabel = labels[index] as NSString
            let labelWidth = ceil(attributedLabel.size(withAttributes: attributes).width)
            let maxLabelX = max(0, bounds.width - labelWidth)
            let labelX = min(max(tickPoint.x - labelWidth / 2, 0), maxLabelX)
            let labelRect = NSRect(x: labelX, y: 0, width: labelWidth, height: bounds.height)
            attributedLabel.draw(in: labelRect, withAttributes: attributes)
        }
    }
}

private final class SettingsPreviewStageView: NSView {
    private struct ObserverRegistration {
        let center: NotificationCenter
        let token: NSObjectProtocol
    }

    private static let previewBounds = CGRect(x: 0, y: 0, width: 1200, height: 600)
    private static let previewImage = SettingsPreviewSamples.windowImage(theme: .finder)
    private static let groupTitle = "Desktop 1"
    private static let stageInset = SettingsPreviewStageLayout.stageInset
    private static let panelPadding = PreviewMetrics.panelPadding
    private static let dockGap = SettingsPreviewStageLayout.dockGap
    private static let fallbackDockThickness: CGFloat = 72
    private static let retryDelays: [TimeInterval] = [0, 0.25, 0.75]
    private let stageWidth: CGFloat
    private let sceneView = NSView()
    private let dockClipView = NSView()
    private let dockImageView = NSImageView()
    private let placeholderLabel = NSTextField(wrappingLabelWithString: "")
    private var previewView: NSView?
    private var snapshot: DockSnapshot?
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    private var stageHeight: CGFloat = 1
    private var captureGeneration = 0
    private var retryWorkItems = [DispatchWorkItem]()
    private var refreshWorkItem: DispatchWorkItem?
    private var observers = [ObserverRegistration]()
    private var availabilityDescription: String?

    init(width: CGFloat) {
        stageWidth = width
        super.init(frame: .zero)
        configureLayout()
        configureDockImageView()
        configurePlaceholderLabel()
        configureAccessibility()
        update()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        cancelPendingWork()
        removeObservers()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: stageWidth, height: stageHeight)
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        layoutStage()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cancelPendingWork()
        removeObservers()
        guard window?.isVisible == true, window?.isMiniaturized == false else { return }
        installObservers()
        scheduleDockRefresh()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
        scheduleDockRefresh()
    }

    func update() {
        previewView?.removeFromSuperview()
        let preview = makePreviewPanel()
        preview.translatesAutoresizingMaskIntoConstraints = true
        preview.setAccessibilityHidden(true)
        sceneView.addSubview(preview, positioned: .above, relativeTo: dockClipView)
        previewView = preview
        updateStageHeight()
        updateAccessibilityValue()
        needsLayout = true
    }

    func prepareForPresentation() {
        installObservers()
        guard window?.isMiniaturized != true else { return }
        refreshDockSnapshot()
    }

    private func refreshDockSnapshot() {
        captureGeneration &+= 1
        let generation = captureGeneration
        cancelRetryWorkItems()

        guard PermissionManager.status.allGranted else {
            snapshot = nil
            dockImageView.image = nil
            update()
            showPlaceholder("Grant Accessibility and Screen Recording above to show the current Dock.")
            return
        }

        if snapshot == nil {
            showPlaceholder("Loading current Dock…")
        }
        captureSnapshot(generation: generation, attempt: 0)
    }

    private func configureLayout() {
        translatesAutoresizingMaskIntoConstraints = false
        sceneView.translatesAutoresizingMaskIntoConstraints = true
        sceneView.wantsLayer = true
        sceneView.layer?.cornerRadius = 10
        sceneView.layer?.masksToBounds = true
        sceneView.layer?.borderWidth = 1
        sceneView.setAccessibilityHidden(true)
        addSubview(sceneView)
        updateLayerColors()
        updateStageHeight()
        widthConstraint = widthAnchor.constraint(equalToConstant: stageWidth)
        heightConstraint = heightAnchor.constraint(equalToConstant: stageHeight)
        widthConstraint?.isActive = true
        heightConstraint?.isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    private func configureDockImageView() {
        dockClipView.wantsLayer = true
        dockClipView.layer?.masksToBounds = true
        dockClipView.translatesAutoresizingMaskIntoConstraints = true
        dockClipView.setAccessibilityHidden(true)
        sceneView.addSubview(dockClipView)

        dockImageView.imageAlignment = .alignBottomLeft
        dockImageView.imageScaling = .scaleNone
        dockImageView.translatesAutoresizingMaskIntoConstraints = true
        dockImageView.setAccessibilityHidden(true)
        dockClipView.addSubview(dockImageView)
    }

    private func configurePlaceholderLabel() {
        placeholderLabel.alignment = .center
        placeholderLabel.font = .systemFont(ofSize: 12)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.maximumNumberOfLines = 2
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = true
        placeholderLabel.setAccessibilityHidden(true)
        sceneView.addSubview(placeholderLabel, positioned: .above, relativeTo: dockClipView)
    }

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Preview size example")
        setAccessibilityChildren([])
    }

    private func updateAccessibilityValue() {
        let grouping = PrevDockSettings.previewDesktopGroupingEnabled ? "grouped" : "ungrouped"
        let edge = snapshot?.geometry.edge.rawValue ?? "Dock unavailable"
        let previewDescription =
            "\(PrevDockSettings.previewContentSize.title) title, " +
                "\(PrevDockSettings.previewWindowHeight.title) window, \(grouping), " +
                "\(edge); shown at actual size; non-interactive"
        guard let availabilityDescription else {
            setAccessibilityValue(previewDescription)
            return
        }
        setAccessibilityValue("\(availabilityDescription) \(previewDescription)")
    }

    private func makePreviewPanel() -> NSView {
        let content = makePreviewContent(imageHeight: currentImageHeight())
        let contentSize = measuredSize(of: content)
        let panelSize = NSSize(
            width: contentSize.width + Self.panelPadding * 2,
            height: contentSize.height + Self.panelPadding * 2
        )
        let panel = SettingsPreviewPanelSampleView(size: panelSize, material: .underPageBackground)
        let insets = NSEdgeInsets(
            top: Self.panelPadding,
            left: Self.panelPadding,
            bottom: Self.panelPadding,
            right: Self.panelPadding
        )
        panel.installContent(content, insets: insets)
        return panel
    }

    private func makePreviewContent(imageHeight: CGFloat) -> NSView {
        let card = makePreviewCard(imageHeight: imageHeight)
        guard PrevDockSettings.previewDesktopGroupingEnabled else { return card }
        let group = DesktopGroupView(
            title: Self.groupTitle,
            isCurrent: true,
            size: groupedSampleSize(for: measuredSize(of: card)),
            allowsInteraction: false
        )
        group.addContentRow(PreviewLayoutViews.makePreviewRow(views: [card]))
        return group
    }

    private func makePreviewCard(imageHeight: CGFloat) -> PreviewCardView {
        PreviewCardView(
            preview: makeFinderPreview(),
            imageHeight: imageHeight,
            interactionMode: .sample,
            showsCloseButtonOverride: PrevDockSettings.previewCloseButtonEnabled,
            thumbnailCornerRadiusOverride: SettingsPreviewSamples.thumbnailCornerRadius
        )
    }

    private func makeFinderPreview() -> WindowPreview {
        WindowPreview(
            windowID: 0,
            title: "Finder",
            bounds: Self.previewBounds,
            isMinimized: false,
            isFullscreen: false,
            isFocused: true,
            desktop: nil,
            image: Self.previewImage,
            app: SettingsPreviewSamples.finderApplication()
        )
    }

    private func measuredSize(of view: NSView) -> NSSize {
        let intrinsic = view.intrinsicContentSize
        guard intrinsic.width > 0,
              intrinsic.height > 0,
              intrinsic.width != NSView.noIntrinsicMetric,
              intrinsic.height != NSView.noIntrinsicMetric else {
            return view.fittingSize
        }
        return intrinsic
    }

    private func groupedSampleSize(
        for cardSize: NSSize,
        contentSize: PreviewContentSize? = nil
    ) -> NSSize {
        DesktopGroupView.fittingSize(
            rowWidths: [cardSize.width],
            rowHeight: cardSize.height,
            title: Self.groupTitle,
            isCurrent: true,
            contentSize: contentSize
        )
    }

    private func maximumPreviewPanelSize() -> NSSize {
        let imageHeight = PreviewMetrics.imageHeight(
            anchoredTo: dockPreviewAnchor(),
            windowHeight: .extraLarge
        )
        let cardSize = PreviewCardView.cardSize(
            for: makeFinderPreview(),
            imageHeight: imageHeight,
            contentSize: .extraLarge
        )
        let groupSize = groupedSampleSize(for: cardSize, contentSize: .extraLarge)
        return NSSize(
            width: groupSize.width + Self.panelPadding * 2,
            height: groupSize.height + Self.panelPadding * 2
        )
    }

    private func currentImageHeight() -> CGFloat {
        PreviewMetrics.imageHeight(anchoredTo: dockPreviewAnchor())
    }

    private func dockPreviewAnchor() -> CGRect {
        snapshot?.screenFrame ?? window?.screen?.frame ?? DockScreenLocator.previewAnchor() ??
            NSScreen.main?.frame ?? Self.previewBounds
    }

    private func updateStageHeight() {
        let maximumPreviewHeight = maximumPreviewPanelSize().height
        let nextHeight: CGFloat
        switch snapshot?.geometry.edge {
        case .left, .right:
            nextHeight = Self.stageInset * 2 + maximumPreviewHeight
        case .bottom, .top:
            let dockHeight = snapshot?.geometry.imageSize.height ?? Self.fallbackDockThickness
            nextHeight = Self.stageInset * 2 + maximumPreviewHeight + Self.dockGap + dockHeight
        case nil:
            nextHeight = Self.stageInset * 2 + maximumPreviewHeight + Self.dockGap + Self.fallbackDockThickness
        }
        stageHeight = ceil(nextHeight)
        heightConstraint?.constant = stageHeight
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func layoutStage() {
        guard let previewView else { return }
        let previewSize = measuredSize(of: previewView)
        guard let snapshot else {
            layoutUnavailableStage(previewSize: previewSize)
            return
        }
        let sceneSize = compactSceneSize(
            previewSize: previewSize,
            dockImageSize: snapshot.geometry.imageSize,
            edge: snapshot.geometry.edge
        )
        sceneView.frame = centeredSceneFrame(size: sceneSize)
        let result = SettingsPreviewStageLayout.calculate(
            stageBounds: sceneView.bounds,
            previewSize: previewSize,
            dockImageSize: snapshot.geometry.imageSize,
            geometry: snapshot.geometry
        )
        previewView.frame = result.previewFrame
        dockClipView.frame = result.dockVisibleRect
        dockImageView.frame = result.dockImageFrame.offsetBy(
            dx: -result.dockVisibleRect.minX,
            dy: -result.dockVisibleRect.minY
        )
        placeholderLabel.isHidden = true
    }

    private func layoutUnavailableStage(previewSize: NSSize) {
        let sceneSize = compactSceneSize(
            previewSize: previewSize,
            dockImageSize: NSSize(width: previewSize.width, height: Self.fallbackDockThickness),
            edge: .bottom
        )
        sceneView.frame = centeredSceneFrame(size: sceneSize)
        let previewX = Self.stageInset
        let previewY = Self.stageInset + Self.fallbackDockThickness + Self.dockGap
        previewView?.frame = NSRect(origin: NSPoint(x: previewX, y: previewY), size: previewSize)
        dockClipView.frame = .zero
        dockImageView.frame = .zero
        placeholderLabel.frame = NSRect(
            x: Self.stageInset,
            y: Self.stageInset,
            width: previewSize.width,
            height: Self.fallbackDockThickness
        )
    }

    private func compactSceneSize(
        previewSize: NSSize,
        dockImageSize: NSSize,
        edge: DockSnapshotEdge
    ) -> NSSize {
        let contentSize = SettingsPreviewStageLayout.sceneSize(
            previewSize: previewSize,
            dockImageSize: dockImageSize,
            edge: edge
        )
        return NSSize(
            width: ceil(contentSize.width + Self.stageInset * 2),
            height: ceil(contentSize.height + Self.stageInset * 2)
        )
    }

    private func centeredSceneFrame(size: NSSize) -> NSRect {
        let origin = NSPoint(
            x: floor((bounds.width - size.width) / 2),
            y: floor((bounds.height - size.height) / 2)
        )
        return NSRect(origin: origin, size: size)
    }

    private func captureSnapshot(generation: Int, attempt: Int) {
        guard Self.retryDelays.indices.contains(attempt) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, generation == self.captureGeneration else { return }
            DockSnapshotProvider.capture(for: self.window?.screen) { [weak self] snapshot in
                self?.handleCapture(snapshot, generation: generation, attempt: attempt)
            }
        }
        retryWorkItems.append(work)
        let delay = Self.retryDelays[attempt]
        if delay == 0 {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func handleCapture(_ snapshot: DockSnapshot?, generation: Int, attempt: Int) {
        guard generation == captureGeneration else { return }
        guard let snapshot else {
            let nextAttempt = attempt + 1
            if Self.retryDelays.indices.contains(nextAttempt) {
                captureSnapshot(generation: generation, attempt: nextAttempt)
                return
            }
            discardSnapshotIfTargetChanged()
            if self.snapshot == nil {
                showPlaceholder(
                    "Current Dock is hidden or temporarily unavailable. Show it, then reopen Settings to refresh."
                )
            }
            return
        }

        self.snapshot = snapshot
        availabilityDescription = nil
        dockImageView.image = snapshot.image
        dockImageView.isHidden = false
        placeholderLabel.isHidden = true
        cancelRetryWorkItems()
        update()
    }

    private func showPlaceholder(_ message: String) {
        availabilityDescription = message
        placeholderLabel.stringValue = message
        placeholderLabel.isHidden = false
        dockImageView.isHidden = true
        updateAccessibilityValue()
        needsLayout = true
    }

    private func discardSnapshotIfTargetChanged() {
        guard let snapshot, !snapshotMatchesCurrentTarget(snapshot) else { return }
        self.snapshot = nil
        dockImageView.image = nil
        dockClipView.frame = .zero
        availabilityDescription = nil
        update()
    }

    private func snapshotMatchesCurrentTarget(_ snapshot: DockSnapshot) -> Bool {
        guard let screen = window?.screen else { return false }
        let location = DockScreenLocator.snapshotLocation(for: screen)
        if DockSystemPreferences.isAutoHideEnabled {
            return shouldRetainAutoHiddenSnapshot(snapshot, location: location)
        }
        guard let location else {
            guard snapshotPreferencesMatch(snapshot),
                  let snapshotScreen = connectedScreen(withDisplayID: snapshot.geometryKey.displayID) else {
                return false
            }
            return snapshotScaleMatches(snapshot, scale: snapshotScreen.backingScaleFactor) &&
                screenFramesMatch(snapshot.screenFrame, snapshotScreen.frame)
        }
        return snapshot.geometryKey.edge == location.edge &&
            snapshot.geometryKey.displayID == location.displayID &&
            snapshot.geometryKey.dockWidthInCentipoints == centipoints(location.dockRect.width) &&
            snapshot.geometryKey.dockHeightInCentipoints == centipoints(location.dockRect.height) &&
            snapshotScaleMatches(snapshot, scale: location.backingScaleFactor) &&
            screenFramesMatch(snapshot.screenFrame, location.appKitScreenFrame)
    }

    private func shouldRetainAutoHiddenSnapshot(
        _ snapshot: DockSnapshot,
        location: DockSnapshotAXLocation?
    ) -> Bool {
        guard snapshotPreferencesMatch(snapshot),
              let screen = connectedScreen(withDisplayID: snapshot.geometryKey.displayID),
              snapshotScaleMatches(snapshot, scale: screen.backingScaleFactor),
              screenFramesMatch(snapshot.screenFrame, screen.frame) else {
            return false
        }
        guard let location else { return true }
        return location.edge == snapshot.geometry.edge &&
            location.displayID == snapshot.geometryKey.displayID &&
            dockMainLength(location, edge: snapshot.geometry.edge) == snapshotDockMainLength(snapshot) &&
            snapshotScaleMatches(snapshot, scale: location.backingScaleFactor) &&
            screenFramesMatch(snapshot.screenFrame, location.appKitScreenFrame)
    }

    private func snapshotPreferencesMatch(_ snapshot: DockSnapshot) -> Bool {
        guard DockSystemPreferences.orientation == snapshot.geometry.edge,
              let capturedTileSize = snapshot.tileSizePreference,
              let currentTileSize = DockSystemPreferences.tileSize else {
            return false
        }
        return abs(capturedTileSize - currentTileSize) <= 0.5
    }

    private func dockMainLength(
        _ location: DockSnapshotAXLocation,
        edge: DockSnapshotEdge
    ) -> Int {
        switch edge {
        case .bottom, .top:
            return centipoints(location.dockRect.width)
        case .left, .right:
            return centipoints(location.dockRect.height)
        }
    }

    private func snapshotDockMainLength(_ snapshot: DockSnapshot) -> Int {
        switch snapshot.geometry.edge {
        case .bottom, .top:
            return snapshot.geometryKey.dockWidthInCentipoints
        case .left, .right:
            return snapshot.geometryKey.dockHeightInCentipoints
        }
    }

    private func snapshotScaleMatches(_ snapshot: DockSnapshot, scale: CGFloat) -> Bool {
        let imageScaleX = CGFloat(snapshot.geometryKey.imagePixelWidth) /
            max(1, snapshot.geometry.imageSize.width)
        let imageScaleY = CGFloat(snapshot.geometryKey.imagePixelHeight) /
            max(1, snapshot.geometry.imageSize.height)
        return abs(imageScaleX - scale) < 0.05 && abs(imageScaleY - scale) < 0.05
    }

    private func displayID(for screen: NSScreen) -> UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    private func connectedScreen(withDisplayID displayID: UInt32) -> NSScreen? {
        NSScreen.screens.first { self.displayID(for: $0) == displayID }
    }

    private func screenFramesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        DockSnapshotScreenFrameKey(frame: lhs) == DockSnapshotScreenFrameKey(frame: rhs)
    }

    private func centipoints(_ value: CGFloat) -> Int {
        guard value.isFinite else { return 0 }
        return Int((value * 100).rounded())
    }

    private func scheduleDockRefresh() {
        guard window?.isVisible == true, window?.isMiniaturized == false else { return }
        refreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.refreshWorkItem = nil
            self?.refreshDockSnapshot()
        }
        refreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
    }

    private func installObservers() {
        guard observers.isEmpty, let window else { return }
        let center = NotificationCenter.default
        let notifications: [(Notification.Name, Any?)] = [
            (PermissionManager.didChangeNotification, nil),
            (NSApplication.didChangeScreenParametersNotification, nil),
            (NSWindow.didBecomeKeyNotification, window),
            (NSWindow.didChangeScreenNotification, window),
            (NSWindow.willCloseNotification, window),
            (NSWindow.didMiniaturizeNotification, window),
            (NSWindow.didDeminiaturizeNotification, window)
        ]
        notifications.forEach { name, object in
            let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                self?.handleObservedNotification(name)
            }
            observers.append(ObserverRegistration(center: center, token: token))
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].forEach { name in
            let token = workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleDockRefresh()
            }
            observers.append(ObserverRegistration(center: workspaceCenter, token: token))
        }
    }

    private func handleObservedNotification(_ name: Notification.Name) {
        if name == NSWindow.willCloseNotification {
            cancelPendingWork()
            removeObservers()
            return
        }
        if name == NSWindow.didMiniaturizeNotification {
            cancelPendingWork()
            return
        }
        scheduleDockRefresh()
    }

    private func removeObservers() {
        observers.forEach { $0.center.removeObserver($0.token) }
        observers = []
    }

    private func cancelPendingWork() {
        captureGeneration &+= 1
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
        cancelRetryWorkItems()
    }

    private func cancelRetryWorkItems() {
        retryWorkItems.forEach { $0.cancel() }
        retryWorkItems = []
    }

    private func updateLayerColors() {
        var background = NSColor.controlBackgroundColor
        var border = NSColor.separatorColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            background = NSColor.controlBackgroundColor.withAlphaComponent(0.46)
            border = NSColor.separatorColor.withAlphaComponent(0.55)
        }
        sceneView.layer?.backgroundColor = background.cgColor
        sceneView.layer?.borderColor = border.cgColor
    }
}

private enum SettingsSampleWindowTheme {
    case work
    case files
    case media
    case notes
    case archive
    case finder
}

private enum SettingsPreviewSamples {
    private static let windowBounds = CGRect(x: 0, y: 0, width: 1200, height: 600)
    private static let layoutImageHeight: CGFloat = 63
    private static let scrollVisibleCardCount: CGFloat = 2.5
    private static let closeImageHeight: CGFloat = 106
    private static let optionContentSize = PreviewContentSize.extraSmall
    static let thumbnailCornerRadius: CGFloat = 10

    static func layoutPreview(mode: PreviewOverflowMode) -> NSView {
        let panel = SettingsPreviewPanelSampleView(size: NSSize(width: 408, height: 210))
        let content = mode == .scroll ? scrollPreviewContent() : wrappedPreviewContent()
        panel.installContent(content, insets: NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6))
        return panel
    }

    static func closeButtonPreview(isEnabled: Bool) -> NSView {
        let card = previewCard(
            preview: preview(windowID: 31, title: "Finder", theme: .finder),
            imageHeight: closeImageHeight,
            showsCloseButton: isEnabled
        )
        let panel = SettingsPreviewPanelSampleView(size: NSSize(width: 408, height: 190))
        panel.installContent(card, insets: NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6))
        return panel
    }

    static func windowImage(theme: SettingsSampleWindowTheme) -> NSImage {
        let size = NSSize(width: windowBounds.width, height: windowBounds.height)
        return NSImage(size: size, flipped: false) { imageRect in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }

            let windowRect = imageRect
            baseColor(for: theme).setFill()
            windowRect.fill()
            drawWindowChrome(in: windowRect, theme: theme)
            drawWindowContent(in: windowRect.insetBy(dx: 34, dy: 92), theme: theme)
            return true
        }
    }

    static func finderApplication() -> NSRunningApplication {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first ??
            NSRunningApplication.current
    }

    private static func scrollPreviewContent() -> NSView {
        let previews = samplePreviews()
        let row = previewRow(previews: previews, imageHeight: layoutImageHeight)
        let rowSize = row.fittingSize
        let viewportSize = NSSize(width: scrollViewportWidth(for: previews), height: rowSize.height + PreviewMetrics.scrollBarHeight)
        let documentView = SettingsPreviewScrollDocumentView(frame: NSRect(origin: .zero, size: rowSize))
        documentView.addSubview(row)
        row.frame = NSRect(origin: .zero, size: rowSize)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.scrollerKnobStyle = .light
        scrollView.horizontalScroller?.controlSize = .small
        scrollView.documentView = documentView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalToConstant: viewportSize.width),
            scrollView.heightAnchor.constraint(equalToConstant: viewportSize.height)
        ])
        return scrollView
    }

    private static func wrappedPreviewContent() -> NSView {
        let previews = samplePreviews()
        let stack = NSStackView(views: [
            previewRow(previews: Array(previews.prefix(2)), imageHeight: layoutImageHeight),
            previewRow(previews: Array(previews.dropFirst(2)), imageHeight: layoutImageHeight)
        ])
        stack.orientation = .vertical
        stack.spacing = PreviewMetrics.rowSpacing
        stack.alignment = .centerX
        return stack
    }

    private static func samplePreviews() -> [WindowPreview] {
        [
            preview(windowID: 1, title: "Work", theme: .work),
            preview(windowID: 2, title: "Files", theme: .files),
            preview(windowID: 3, title: "Pics", theme: .media)
        ]
    }

    private static func scrollViewportWidth(for previews: [WindowPreview]) -> CGFloat {
        guard let preview = previews.first else { return 0 }
        let cardWidth = PreviewCardView.cardSize(
            for: preview,
            imageHeight: layoutImageHeight,
            contentSize: optionContentSize
        ).width
        return floor(cardWidth * scrollVisibleCardCount)
    }

    private static func preview(windowID: CGWindowID, title: String, theme: SettingsSampleWindowTheme) -> WindowPreview {
        WindowPreview(
            windowID: windowID,
            title: title,
            bounds: windowBounds,
            isMinimized: false,
            isFullscreen: false,
            isFocused: windowID == 1,
            desktop: nil,
            image: windowImage(theme: theme),
            app: finderApplication()
        )
    }

    private static func previewRow(previews: [WindowPreview], imageHeight: CGFloat) -> NSStackView {
        PreviewLayoutViews.makePreviewRow(views: previews.map {
            previewCard(preview: $0, imageHeight: imageHeight)
        })
    }

    private static func previewCard(
        preview: WindowPreview,
        imageHeight: CGFloat,
        showsCloseButton: Bool? = nil
    ) -> PreviewCardView {
        PreviewCardView(
            preview: preview,
            imageHeight: imageHeight,
            interactionMode: .sample,
            contentSizeOverride: optionContentSize,
            showsCloseButtonOverride: showsCloseButton,
            thumbnailCornerRadiusOverride: thumbnailCornerRadius
        )
    }

    private static func drawWindowChrome(in rect: NSRect, theme: SettingsSampleWindowTheme) {
        fill(NSRect(x: rect.minX, y: rect.maxY - 78, width: rect.width, height: 78), color: chromeColor(for: theme), radius: 0)
        for index in 0..<3 {
            fill(
                NSRect(x: rect.minX + 32 + CGFloat(index) * 30, y: rect.maxY - 48, width: 16, height: 16),
                color: NSColor.white.withAlphaComponent(0.26),
                radius: 8
            )
        }
        fill(NSRect(x: rect.minX + 160, y: rect.maxY - 54, width: rect.width * 0.54, height: 26), color: NSColor.white.withAlphaComponent(0.10), radius: 13)
    }

    private static func drawWindowContent(in rect: NSRect, theme: SettingsSampleWindowTheme) {
        drawFinderSidebar(in: rect)
        switch theme {
        case .work, .finder:
            drawFinderList(in: rect, highlightedRow: 1)
        case .files:
            drawFinderIconGrid(in: rect)
        case .media:
            drawFinderGallery(in: rect)
        case .notes:
            drawFinderColumns(in: rect)
        case .archive:
            drawFinderList(in: rect, highlightedRow: 4)
        }
    }

    private static func drawFinderSidebar(in rect: NSRect) {
        let sidebar = NSRect(x: rect.minX + 18, y: rect.minY + 18, width: rect.width * 0.22, height: rect.height - 36)
        fill(sidebar, color: NSColor.white.withAlphaComponent(0.08), radius: 12)
        for index in 0..<6 {
            let y = sidebar.maxY - 42 - CGFloat(index) * 38
            fill(NSRect(x: sidebar.minX + 24, y: y, width: sidebar.width * 0.58, height: 11), color: NSColor.white.withAlphaComponent(0.20), radius: 6)
        }
    }

    private static func drawFinderList(in rect: NSRect, highlightedRow: Int) {
        let content = mainContentRect(in: rect)
        for index in 0..<7 {
            let y = content.maxY - 34 - CGFloat(index) * 36
            if index == highlightedRow {
                fill(NSRect(x: content.minX, y: y - 7, width: content.width * 0.88, height: 25), color: sampleAccent(alpha: 0.24), radius: 8)
            }
            fill(NSRect(x: content.minX + 22, y: y, width: content.width * 0.36, height: 10), color: sampleAccent(alpha: 0.58), radius: 5)
            fill(NSRect(x: content.minX + content.width * 0.48, y: y, width: content.width * 0.30, height: 10), color: NSColor.white.withAlphaComponent(0.16), radius: 5)
        }
    }

    private static func drawFinderIconGrid(in rect: NSRect) {
        let content = mainContentRect(in: rect)
        for column in 0..<3 {
            for row in 0..<2 {
                let x = content.minX + CGFloat(column) * (content.width / 3)
                let y = content.maxY - 70 - CGFloat(row) * 104
                fill(NSRect(x: x + 24, y: y, width: 48, height: 38), color: sampleAccent(alpha: 0.40), radius: 8)
                fill(NSRect(x: x + 22, y: y - 24, width: 74, height: 10), color: NSColor.white.withAlphaComponent(0.16), radius: 5)
            }
        }
    }

    private static func drawFinderGallery(in rect: NSRect) {
        let content = mainContentRect(in: rect)
        fill(NSRect(x: content.minX + 22, y: content.minY + 24, width: content.width * 0.62, height: content.height - 48), color: sampleAccent(alpha: 0.26), radius: 14)
        for index in 0..<3 {
            let x = content.minX + content.width * 0.70
            let y = content.maxY - 50 - CGFloat(index) * 64
            fill(NSRect(x: x, y: y, width: content.width * 0.20, height: 42), color: NSColor.white.withAlphaComponent(0.13), radius: 8)
        }
    }

    private static func drawFinderColumns(in rect: NSRect) {
        let content = mainContentRect(in: rect)
        for column in 0..<3 {
            let x = content.minX + CGFloat(column) * (content.width / 3)
            fill(NSRect(x: x, y: content.minY + 20, width: content.width / 3 - 14, height: content.height - 40), color: NSColor.white.withAlphaComponent(0.06), radius: 9)
            for row in 0..<5 {
                let y = content.maxY - 42 - CGFloat(row) * 34
                fill(NSRect(x: x + 18, y: y, width: content.width / 3 - 52, height: 10), color: row == 1 ? sampleAccent(alpha: 0.50) : NSColor.white.withAlphaComponent(0.15), radius: 5)
            }
        }
    }

    private static func mainContentRect(in rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + rect.width * 0.27, y: rect.minY + 18, width: rect.width * 0.70, height: rect.height - 36)
    }

    private static func sampleAccent(alpha: CGFloat) -> NSColor {
        NSColor(calibratedRed: 0.33, green: 0.54, blue: 0.84, alpha: alpha)
    }

    private static func baseColor(for theme: SettingsSampleWindowTheme) -> NSColor {
        NSColor(calibratedRed: 0.14, green: 0.16, blue: 0.18, alpha: 1)
    }

    private static func chromeColor(for theme: SettingsSampleWindowTheme) -> NSColor {
        baseColor(for: theme).blended(withFraction: 0.16, of: .white) ?? baseColor(for: theme)
    }

    private static func fill(_ rect: NSRect, color: NSColor, radius: CGFloat) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
}

private final class SettingsPreviewScrollDocumentView: NSView {
    override var isFlipped: Bool {
        true
    }
}

private final class SettingsPreviewPanelSampleView: NSVisualEffectView {
    private let sampleSize: NSSize
    private let sampleMaterial: NSVisualEffectView.Material

    init(size: NSSize, material: NSVisualEffectView.Material = .hudWindow) {
        sampleSize = size
        sampleMaterial = material
        super.init(frame: NSRect(origin: .zero, size: size))
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        sampleSize
    }

    func installContent(_ view: NSView, insets: NSEdgeInsets) {
        addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: centerXAnchor),
            view.centerYAnchor.constraint(equalTo: centerYAnchor),
            view.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -insets.right),
            view.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: insets.top),
            view.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -insets.bottom)
        ])
    }

    private func configure() {
        material = sampleMaterial
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: sampleSize.width),
            heightAnchor.constraint(equalToConstant: sampleSize.height)
        ])
    }
}
