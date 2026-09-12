import AppKit
import Darwin

@main
enum SettingsWindowLayoutTests {
    private static var snapshotDirectory: URL?
    private static var testDomain = ""

    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        prepareIsolatedPreferences()
        defer { clearTestPreferences() }
        prepareSnapshots()
        captureReferenceSnapshots()
        verifyLayouts()
        verifyActualSizeExample()
        verifySettingsActions()
        print("SettingsWindowLayoutTests: passed")
    }

    private static func prepareIsolatedPreferences() {
        guard let identifier = Bundle.main.bundleIdentifier,
              identifier.hasPrefix("io.github.bambou932.prevDock.tests.settings-layout."),
              UUID(uuidString: String(identifier.split(separator: ".").last ?? "")) != nil else {
            fail("settings tests require a unique temporary test app and preferences domain")
        }
        testDomain = identifier
        clearTestPreferences()
        PrevDockSettings.registerDefaults()
    }

    private static func clearTestPreferences() {
        guard !testDomain.isEmpty else { return }
        UserDefaults.standard.removePersistentDomain(forName: testDomain)
        UserDefaults.standard.synchronize()
    }

    private static func prepareSnapshots() {
        guard CommandLine.arguments.count > 1 else { return }
        expect(CommandLine.arguments.count == 2, "usage: settings-window-layout-tests [snapshot-directory]")
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { fail("could not create snapshot directory: \(error)") }
        snapshotDirectory = directory
    }

    private static func verifyActualSizeExample() {
        let previousFrame = ScreenGeometry.fixtureFrame
        let titleSize = PrevDockSettings.previewContentSize
        let windowHeight = PrevDockSettings.previewWindowHeight
        let grouped = PrevDockSettings.previewDesktopGroupingEnabled
        let close = PrevDockSettings.previewCloseButtonEnabled
        let controller = SettingsWindowController(updateController: UpdateController())
        guard let window = controller.window else { fail("actual-size example needs its settings window") }
        window.alphaValue = 0
        window.orderFrontRegardless()
        controller.selectPane(.appearance)
        defer {
            DockSnapshotService.publish(.unavailable(.hidden))
            window.orderOut(nil)
            window.close()
            ScreenGeometry.fixtureFrame = previousFrame
            PrevDockSettings.previewContentSize = titleSize
            PrevDockSettings.previewWindowHeight = windowHeight
            PrevDockSettings.previewDesktopGroupingEnabled = grouped
            PrevDockSettings.previewCloseButtonEnabled = close
        }
        for screenHeight: CGFloat in [768, 982, 1440, 2160] {
            ScreenGeometry.fixtureFrame = CGRect(x: 0, y: 0, width: 3840, height: screenHeight)
            layout(controller)
            verifyAllSampleSizes(controller)
        }
        verifyDockComparison(controller)
        verifySnapshotActivity()
    }

    private static func sampleStage(_ controller: SettingsWindowController) -> SettingsPreviewStage {
        guard let stage = descendants(in: content(controller)).compactMap({ $0 as? SettingsPreviewStage }).first else {
            fail("Appearance requires its actual-size stage")
        }
        return stage
    }

    private static func verifyAllSampleSizes(_ controller: SettingsWindowController) {
        let stage = sampleStage(controller)
        stage.refresh()
        layout(controller)
        let frame = stage.frame
        let title: NSSlider = control(controller, label: "Preview title size")
        let height: NSSlider = control(controller, label: "Preview window height")
        let titleFrame = title.convert(title.bounds, to: stage.superview)
        for contentSize in PreviewContentSize.allCases {
            for windowHeight in PreviewWindowHeight.allCases {
                PrevDockSettings.previewContentSize = contentSize
                PrevDockSettings.previewWindowHeight = windowHeight
                for grouped in [false, true] {
                    PrevDockSettings.previewDesktopGroupingEnabled = grouped
                    PrevDockSettings.previewCloseButtonEnabled = grouped
                    stage.refresh()
                    layout(controller)
                    let cards = descendants(in: stage).compactMap { $0 as? PreviewCardView }
                    expect(cards.count == 1, "actual-size example should always use one 4:3 card")
                    let card = cards[0]
                    let expected = PreviewCardView.cardSize(for: samplePreview(), imageHeight: PreviewMetrics.imageHeight(anchoredTo: ScreenGeometry.fixtureFrame), contentSize: contentSize)
                    expect(closeSize(card.intrinsicContentSize, expected), "sample card must use exact production metrics at every title and window size")
                    let pixel = 1 / max(1, card.window?.backingScaleFactor ?? 1)
                    expect(abs(card.bounds.width - expected.width) <= pixel + 0.001 &&
                           abs(card.bounds.height - expected.height) <= pixel + 0.001,
                           "rendered sample may only differ from production metrics by native pixel alignment: \(card.bounds.size), expected \(expected)")
                    expect(stage.frame == frame, "appearance preferences must not move or resize the outer example")
                    expect(title.convert(title.bounds, to: stage.superview) == titleFrame,
                           "controls below the example must not move when sample size changes")
                    expect(stage.bounds.insetBy(dx: -0.5, dy: -0.5).contains(stage.convert(card.bounds, from: card)),
                           "the largest actual-size card must fit within the reserved stage")
                }
            }
        }
        expect(height.bounds.width >= 200, "actual-size example must preserve usable size controls")
    }

    private static func samplePreview() -> WindowPreview {
        WindowPreview(windowID: 0, title: "Documents", bounds: CGRect(x: 0, y: 0, width: 480, height: 360),
                      isMinimized: false, isFullscreen: false, isFocused: false, desktop: nil, image: nil, app: .current)
    }

    private static func closeSize(_ actual: CGSize, _ expected: CGSize) -> Bool {
        abs(actual.width - expected.width) < 0.01 && abs(actual.height - expected.height) < 0.01
    }

    private static func verifyDockComparison(_ controller: SettingsWindowController) {
        guard let window = controller.window else { fail("Dock comparison needs a window") }
        let stage = sampleStage(controller)
        for edge in DockSnapshotEdge.allCases {
            let snapshot = fixtureDock(edge: edge)
            DockSnapshotService.publish(.available(snapshot))
            layout(controller)
            window.setContentSize(window.contentMinSize)
            layout(controller)
            let stageFrame = stage.frame
            let windowFrame = window.frame
            let minimumWidth = window.contentMinSize.width
            verifyDockGeometry(stage, snapshot: snapshot)
            for grouped in [false, true] {
                PrevDockSettings.previewDesktopGroupingEnabled = grouped
                for size in PreviewWindowHeight.allCases {
                    PrevDockSettings.previewWindowHeight = size
                    PrevDockSettings.previewContentSize = size == .extraLarge ? .extraLarge : .extraSmall
                    stage.refresh()
                    layout(controller)
                    expect(stage.frame == stageFrame && window.frame == windowFrame && window.contentMinSize.width == minimumWidth,
                           "Dock comparison must reserve maximum geometry independently of selected appearance preferences")
                    verifyDockGeometry(stage, snapshot: snapshot)
                }
            }
            DockSnapshotService.publish(.unavailable(.hidden))
            layout(controller)
            let image: NSImageView = identifiedView(stage, identifier: "prevDock.settings.dockSnapshot")
            let crop: NSView = identifiedView(stage, identifier: "prevDock.settings.dockSnapshotCrop")
            expect(image.image == nil && crop.isHidden, "a hidden Dock must clear screenshot pixels")
            expect(stage.frame == stageFrame && window.contentMinSize.width == minimumWidth,
                   "hiding the Dock must retain the last reserved geometry")
        }
        DockSnapshotService.publish(.unavailable(.hidden))
    }

    private static func verifyDockGeometry(_ stage: SettingsPreviewStage, snapshot: DockSnapshot) {
        let image: NSImageView = identifiedView(stage, identifier: "prevDock.settings.dockSnapshot")
        let crop: NSView = identifiedView(stage, identifier: "prevDock.settings.dockSnapshotCrop")
        let panel: NSVisualEffectView = identifiedView(stage, identifier: "prevDock.settings.samplePreviewPanel")
        expect(image.image === snapshot.image && image.imageScaling == .scaleNone,
               "Dock comparison must draw the actual captured image without scaling")
        expect(closeSize(image.frame.size, snapshot.geometry.imageSize), "each Dock image point must occupy exactly one view point")
        let cropRect = stage.convert(crop.bounds, from: crop)
        let panelRect = stage.convert(panel.bounds, from: panel)
        expect(stage.bounds.insetBy(dx: -0.5, dy: -0.5).contains(cropRect) && stage.bounds.insetBy(dx: -0.5, dy: -0.5).contains(panelRect),
               "Dock and preview must fit when settings is resized to its minimum width")
        let imageRect = stage.convert(image.bounds, from: image)
        let finder = snapshot.geometry.finderRectInImage.offsetBy(dx: imageRect.minX, dy: imageRect.minY)
        expect(cropRect.insetBy(dx: -0.5, dy: -0.5).contains(finder), "the cropped Dock must retain the complete Finder icon")
        let expected = PreviewAnchorLayout.frame(previewSize: panel.bounds.size, anchor: snapshot.finderRect,
                                                screenFrame: snapshot.screenFrame, visibleFrame: snapshot.screenVisibleFrame)
        expect(abs((panelRect.minX - finder.minX) - (expected.minX - snapshot.finderRect.minX)) < 0.01 &&
               abs((panelRect.minY - finder.minY) - (expected.minY - snapshot.finderRect.minY)) < 0.01,
               "sample panel must retain production Finder alignment, gap, and screen clamping")
    }

    private static func identifiedView<T: NSView>(_ parent: NSView, identifier: String) -> T {
        guard let view = descendants(in: parent).first(where: { $0.accessibilityIdentifier() == identifier }) as? T else {
            fail("missing comparison view: \(identifier)")
        }
        return view
    }

    private static func fixtureDock(edge: DockSnapshotEdge) -> DockSnapshot {
        let screen = ScreenGeometry.fixtureFrame
        let dock: CGRect
        let finder: CGRect
        switch edge {
        case .bottom:
            dock = CGRect(x: 300, y: 0, width: 1200, height: 128)
            finder = CGRect(x: 312, y: 12, width: 104, height: 104)
        case .left:
            dock = CGRect(x: 0, y: 500, width: 128, height: 1200)
            finder = CGRect(x: 12, y: 1584, width: 104, height: 104)
        case .right:
            dock = CGRect(x: screen.maxX - 128, y: 500, width: 128, height: 1200)
            finder = CGRect(x: screen.maxX - 116, y: 1584, width: 104, height: 104)
        }
        let image = NSImage(size: dock.size, flipped: false) { rect in NSColor.systemBlue.setFill(); rect.fill(); return true }
        let geometry = DockSnapshotGeometry(edge: edge, imageSize: dock.size,
                                            dockRectInImage: CGRect(origin: .zero, size: dock.size),
                                            finderRectInImage: finder.offsetBy(dx: -dock.minX, dy: -dock.minY))
        return DockSnapshot(image: image, geometry: geometry, dockRect: dock, finderRect: finder,
                            screenFrame: screen, screenVisibleFrame: screen, displayID: 1,
                            displayName: "Fixture display", backingScaleFactor: 2)
    }

    private static func verifySnapshotActivity() {
        let provider = SnapshotProbe()
        let stage = SettingsPreviewStage(snapshotProvider: provider)
        let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 650),
                                    styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = stage
        defer { stage.setPageActive(false); window.orderOut(nil); window.close() }
        stage.setPageActive(true)
        expect(provider.activations.isEmpty, "detached or hidden settings must not start Dock observation")
        window.orderFrontRegardless()
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        expect(provider.activations == [true], "visible Appearance should start its provider once")
        for _ in 0..<5 { stage.refresh(); stage.layoutSubtreeIfNeeded() }
        expect(provider.activations == [true] && provider.refreshCount == 0,
               "layout and appearance refresh must never recapture Dock or restart its provider")
        provider.onChange?(.available(fixtureDock(edge: .left)))
        let image: NSImageView = identifiedView(stage, identifier: "prevDock.settings.dockSnapshot")
        expect(!descendants(in: stage).compactMap({ $0 as? NSButton }).contains(where: { $0.title.localizedCaseInsensitiveContains("refresh") }),
               "the example must update directly without a Refresh button")
        verifyAccessibleDockStatus(stage, provider: provider)
        provider.onChange?(.available(fixtureDock(edge: .left)))
        expect(image.image != nil, "close lifecycle verification requires visible Dock pixels")
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        stage.refresh()
        stage.layoutSubtreeIfNeeded()
        expect(provider.activations == [true, false] && image.image == nil,
               "willClose must stop observation and clear pixels before isVisible changes")
        stage.setPageActive(false)
        stage.setPageActive(true)
        expect(provider.activations == [true, false], "page activation must not reopen a closing window's provider")
        window.orderOut(nil)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        window.orderFrontRegardless()
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        expect(provider.activations == [true, false, true], "reopening should restart Dock observation")
        window.simulatesMiniaturized = true
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: window)
        expect(provider.activations.last == false, "minimizing settings must stop observation")
        window.simulatesMiniaturized = false
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: window)
        expect(provider.activations.last == true, "restoring settings should restart observation")
        window.orderOut(nil)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        expect(provider.activations.last == false, "ordering settings out must stop observation without closing")
        stage.setPageActive(false)
        provider.onChange?(.available(fixtureDock(edge: .bottom)))
        expect(image.image == nil, "late snapshots after leaving Appearance must not restore pixels")
    }

    private static func verifyAccessibleDockStatus(_ stage: SettingsPreviewStage, provider: SnapshotProbe) {
        let statuses: [(DockSnapshotUnavailableReason, String)] = [
            (.hidden, "Show the Dock"), (.permissions, "permissions"),
            (.unavailable, "Dock unavailable"), (.captureFailed, "automatically")
        ]
        for (reason, text) in statuses {
            provider.onChange?(.unavailable(reason))
            let labels = stage.accessibilityChildren()?.compactMap { $0 as? NSTextField } ?? []
            expect(labels.count == 1 && labels[0].stringValue.contains(text),
                   "VoiceOver must be able to read the current Dock status without exposing sample actions")
        }
    }

    private final class SnapshotWindow: NSWindow {
        var simulatesMiniaturized = false
        override var isMiniaturized: Bool { simulatesMiniaturized || super.isMiniaturized }
    }

    private final class SnapshotProbe: DockSnapshotProviding {
        var onChange: ((DockSnapshotState) -> Void)?
        var activations = [Bool]()
        var refreshCount = 0
        func setActive(_ active: Bool) { activations.append(active) }
        func refresh() { refreshCount += 1 }
    }

    private static func verifySettingsActions() {
        let updater = UpdateController()
        let controller = SettingsWindowController(updateController: updater)
        guard let window = controller.window else { fail("settings window is missing") }
        window.alphaValue = 0
        defer { window.orderOut(nil); window.close() }
        window.orderFrontRegardless()
        verifyGeneralActions(controller)
        verifyAppearanceActions(controller)
        verifyLayoutActions(controller)
        verifyPermissionActions(controller)
        verifyUpdateActions(controller, updater: updater)
        verifyPresentation(controller)
        expect(PermissionManager.requested == [.accessibility, .screenRecording],
               "permission requests should route only to the test service")
        expect(PermissionManager.opened == [.accessibility, .screenRecording],
               "permission settings actions should route to the matching test permission")
    }

    private static func verifyGeneralActions(_ controller: SettingsWindowController) {
        controller.selectPane(.general)
        verifyToggle(controller, label: "Click to show previews", key: PrevDockSettings.dockAppClickPreviewEnabledKey) {
            PrevDockSettings.dockAppClickPreviewEnabled
        }
        verifyToggle(controller, label: "Hide native Dock labels", key: PrevDockSettings.nativeDockLabelSuppressionEnabledKey) {
            PrevDockSettings.nativeDockLabelSuppressionEnabled
        }
        let login: NSSwitch = control(controller, label: "Open at login")
        for enabled in [true, false] {
            login.state = enabled ? .on : .off
            send(login)
            expect(LaunchAtLoginController.isEnabled == enabled, "login toggle should invoke the login service")
            expect(login.state == (enabled ? .on : .off), "login toggle should reflect actual service state")
        }
        expect(LaunchAtLoginController.requested == [true, false], "login actions should not be duplicated")
        verifyDelay(controller)
    }

    private static func verifyDelay(_ controller: SettingsWindowController) {
        let slider: NSSlider = control(controller, label: "Preview switch delay")
        let stepper: NSStepper = control(controller, label: "Preview switch delay")
        expect(slider.minValue == 0 && slider.maxValue == 2, "delay slider should cover 0–2 seconds")
        expect(stepper.increment == 0.05, "delay stepper should retain 50 ms increments")
        for (input, expected) in [(0.0, 0.0), (0.26, 0.3), (1.94, 1.9), (2.0, 2.0)] {
            slider.doubleValue = input
            send(slider)
            expect(abs(PrevDockSettings.previewSwitchDelay - expected) < 0.0001,
                   "delay slider should snap to tenths of a second")
            expect(stepper.doubleValue == PrevDockSettings.previewSwitchDelay,
                   "delay controls should remain synchronized")
            expect(slider.accessibilityValueDescription() == PrevDockSettings.formattedDelay(expected),
                   "delay accessibility description should include the displayed unit")
        }
        stepper.doubleValue = 0.35
        send(stepper)
        expect(PrevDockSettings.previewSwitchDelay == 0.35 && slider.doubleValue == 0.35,
               "stepper precision must not be rounded to the slider increment")
        expect(UserDefaults.standard.double(forKey: PrevDockSettings.previewSwitchDelayKey) == 0.35,
               "delay actions should persist in the isolated domain")
    }

    private static func verifyAppearanceActions(_ controller: SettingsWindowController) {
        controller.selectPane(.appearance)
        let title: NSSlider = control(controller, label: "Preview title size")
        let height: NSSlider = control(controller, label: "Preview window height")
        layout(controller)
        let stage = sampleStage(controller)
        for (index, size) in PreviewContentSize.allCases.enumerated() {
            title.doubleValue = Double(index)
            send(title)
            expect(PrevDockSettings.previewContentSize == size, "all title sizes should remain selectable")
            expect((stage.accessibilityValue() as? String)?.contains(size.title + " text and icons") == true,
                   "title actions must update the example immediately without Refresh or another layout pass")
            expect(title.accessibilityValueDescription() == size.title, "title slider should expose its selected size")
            expect(UserDefaults.standard.string(forKey: PrevDockSettings.previewContentSizeKey) == size.rawValue,
                   "title size should persist")
        }
        for (index, size) in PreviewWindowHeight.allCases.enumerated() {
            height.doubleValue = Double(index)
            send(height)
            expect(PrevDockSettings.previewWindowHeight == size, "all window heights should remain selectable")
            expect((stage.accessibilityValue() as? String)?.contains(size.title + " thumbnails") == true,
                   "height actions must update the example immediately without Refresh or another layout pass")
            expect(height.accessibilityValueDescription() == size.title, "height slider should expose its selected size")
            expect(UserDefaults.standard.string(forKey: PrevDockSettings.previewWindowHeightKey) == size.rawValue,
                   "window height should persist")
        }
        verifyToggle(controller, label: "Show close button", key: PrevDockSettings.previewCloseButtonEnabledKey) {
            PrevDockSettings.previewCloseButtonEnabled
        }
        layout(controller)
        stage.refresh()
        expect((stage.accessibilityValue() as? String)?.contains("Close buttons hidden") == true,
               "appearance example should reflect the close-button preference")
        let titleSize = PrevDockSettings.previewContentSize
        controller.selectPane(.general)
        controller.selectPane(.appearance)
        expect(PrevDockSettings.previewContentSize == titleSize, "page navigation must preserve appearance preferences")
        verifySampleKeyboardFocus(controller)
    }

    private static func verifySampleKeyboardFocus(_ controller: SettingsWindowController) {
        PrevDockSettings.previewCloseButtonEnabled = true
        layout(controller)
        guard let window = controller.window,
              let stage = descendants(in: content(controller)).compactMap({ $0 as? SettingsPreviewStage }).first else {
            fail("appearance keyboard test requires its sample stage")
        }
        let sampleButtons = descendants(in: stage).compactMap { $0 as? NSButton }
        expect(!sampleButtons.isEmpty, "keyboard regression should cover visible sample close buttons")
        expect(sampleButtons.allSatisfy(\.refusesFirstResponder),
               "decorative preview controls must refuse keyboard focus")
        window.recalculateKeyViewLoop()
        let title: NSSlider = control(controller, label: "Preview title size")
        var visited = Set<ObjectIdentifier>()
        var candidate: NSView? = title
        while let view = candidate, visited.insert(ObjectIdentifier(view)).inserted {
            expect(!view.isDescendant(of: stage), "Tab navigation must not enter decorative preview controls")
            expect(visited.count < 100, "settings key-view loop should remain bounded")
            candidate = view.nextValidKeyView
        }
        let height: NSSlider = control(controller, label: "Preview window height")
        let close: NSSwitch = control(controller, label: "Show close button")
        for control: NSControl in [title, height, close] {
            expect(!control.refusesFirstResponder && window.makeFirstResponder(control),
                   "real appearance controls must remain keyboard focusable")
        }
    }

    private static func verifyLayoutActions(_ controller: SettingsWindowController) {
        controller.selectPane(.layout)
        let autoFit: NSSwitch = control(controller, label: "Fit automatically")
        let scroll = layoutButton(controller, mode: .scroll)
        let wrap = layoutButton(controller, mode: .wrap)
        autoFit.state = .on
        send(autoFit)
        send(wrap)
        expect(PrevDockSettings.previewOverflowMode == .wrap && wrap.state == .on && scroll.state == .off,
               "layout choices should persist and remain mutually exclusive")
        expect(!autoFit.isEnabled && autoFit.state == .on && PrevDockSettings.previewAutoFitEnabled,
               "wrap should disable automatic fitting without clearing its preference")
        send(scroll)
        expect(autoFit.isEnabled && autoFit.state == .on, "single row should restore the retained auto-fit choice")
        verifyToggle(controller, label: "Fit automatically", key: PrevDockSettings.previewAutoFitEnabledKey) {
            PrevDockSettings.previewAutoFitEnabled
        }
        send(wrap)
        send(scroll)
        expect(autoFit.state == .off, "an explicit disabled auto-fit preference should also survive layout changes")
        verifyToggle(controller, label: "Group windows by Desktop", key: PrevDockSettings.previewDesktopGroupingEnabledKey) {
            PrevDockSettings.previewDesktopGroupingEnabled
        }
    }

    private static func verifyPermissionActions(_ controller: SettingsWindowController) {
        controller.selectPane(.permissions)
        PermissionManager.publish(accessibility: false, recording: false)
        for permission in PermissionManager.Permission.allCases {
            let request: NSButton = control(controller, label: "Request \(permission.title) access")
            let settings: NSButton = control(controller, label: "Open \(permission.title) settings")
            send(request)
            send(settings)
        }
        PermissionManager.publish(accessibility: true, recording: true)
    }

    private static func verifyUpdateActions(_ controller: SettingsWindowController, updater: UpdateController) {
        controller.selectPane(.updates)
        let toggle: NSSwitch = control(controller, label: "Automatically install updates")
        let check: NSButton = button(controller, title: "Check for Updates…")
        expect(check.isEnabled, "idle updater should allow a manual check")
        toggle.state = .on
        send(toggle)
        expect(updater.automaticallyInstallsUpdates, "automatic-update toggle should reach the updater")
        send(check)
        expect(updater.checkCount == 1 && !check.isEnabled, "manual update should honor the in-progress state")
        updater.canCheckForUpdates = true
        updater.stateDidChange?()
        expect(check.isEnabled, "updater callbacks should refresh controls without page reconstruction")
        updater.automaticallyInstallsUpdates = false
        updater.stateDidChange?()
        expect(toggle.state == .off, "updater state changes should synchronize the toggle")
        expect(labels(controller).contains("Version 1.2.3 (45)"), "Updates should show version and build")
    }

    private static func verifyPresentation(_ controller: SettingsWindowController) {
        controller.selectPane(.layout)
        controller.window?.orderOut(nil)
        controller.showSettings()
        layout(controller)
        expect(controller.selectedPane == .layout, "normal presentation should remember the selected pane")
        PermissionManager.publish(accessibility: false, recording: true)
        controller.showPermissionSettings()
        layout(controller)
        expect(controller.selectedPane == .permissions, "permission entry should select Permissions")
        let request: NSButton = control(controller, label: "Request Accessibility access")
        expect(controller.window?.firstResponder === request, "permission entry should focus its first relevant action")
        controller.window?.orderOut(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        expect(!controller.isVisible, "queued presentation work must not reopen a dismissed window")
        PermissionManager.publish(accessibility: true, recording: true)
        verifyKeyboardShortcuts(controller)
    }

    private static func verifyKeyboardShortcuts(_ controller: SettingsWindowController) {
        guard let window = controller.window else { fail("keyboard shortcuts require a settings window") }
        window.orderFrontRegardless()
        for pane in SettingsPane.allCases {
            sendCommand(String(pane.rawValue + 1), to: window)
            expect(controller.selectedPane == pane, "Command-number should select the corresponding settings pane")
        }
        sendCommand(",", to: window)
        expect(controller.selectedPane == .updates, "Command-comma should preserve the current settings pane")
        verifyUnmatchedShortcuts(controller, window: window)
        sendCommand("w", to: window)
        expect(!controller.isVisible, "Command-W should close the settings window")
    }

    private static func verifyUnmatchedShortcuts(_ controller: SettingsWindowController, window: NSWindow) {
        let selected = controller.selectedPane
        let shortcuts: [(String, NSEvent.ModifierFlags)] = [
            ("!", [.command, .shift]), ("1", [.command, .option]), ("w", [])
        ]
        for (key, modifiers) in shortcuts {
            let event = keyEvent(key, modifiers: modifiers, window: window)
            expect(!window.performKeyEquivalent(with: event),
                   "unsupported shortcut \(key), modifiers \(modifiers.rawValue), must not match settings shortcuts")
            expect(controller.selectedPane == selected && controller.isVisible,
                   "unmatched shortcuts must not switch panes or close settings")
        }
    }

    private static func sendCommand(_ key: String, to window: NSWindow) {
        let event = keyEvent(key, modifiers: .command, window: window)
        expect(window.performKeyEquivalent(with: event), "settings window should handle Command-\(key)")
    }

    private static func keyEvent(_ key: String, modifiers: NSEvent.ModifierFlags, window: NSWindow) -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                          timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                          characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0) else {
            fail("could not create a keyboard shortcut event")
        }
        return event
    }

    private static func verifyToggle(_ controller: SettingsWindowController, label: String, key: String, read: () -> Bool) {
        let toggle: NSSwitch = control(controller, label: label)
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(forName: PrevDockSettings.didChangeNotification, object: nil, queue: nil) {
            if $0.object as? String == key { notifications += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        for enabled in [true, false] {
            let before = read()
            toggle.state = enabled ? .on : .off
            send(toggle)
            expect(read() == enabled && UserDefaults.standard.bool(forKey: key) == enabled,
                   "\(label) should update and persist its setting")
            expect(toggle.state == (enabled ? .on : .off), "\(label) should remain synchronized")
            if before != enabled { expect(notifications > 0, "\(label) should notify live consumers") }
        }
    }

    private static func captureReferenceSnapshots() {
        guard snapshotDirectory != nil else { return }
        resetVisiblePreferences()
        ScreenGeometry.fixtureFrame = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let controller = SettingsWindowController(updateController: UpdateController())
        guard let window = controller.window else { fail("settings window is missing") }
        defer { window.orderOut(nil); window.close() }
        window.orderFrontRegardless()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for pane in SettingsPane.allCases {
                controller.selectPane(pane)
                layout(controller)
                if pane == .appearance { verifyAppearancePresentation(controller) }
                saveSnapshot(controller, pane: pane, appearance: appearance)
            }
        }
    }

    private static func verifyLayouts() {
        resetVisiblePreferences()
        let configurations: [(String, NSSize, NSRect)] = [
            ("minimum", NSSize(width: 820, height: 580), NSRect(x: 0, y: 0, width: 1512, height: 982)),
            ("default", NSSize(width: 920, height: 700), NSRect(x: -2560, y: 0, width: 2560, height: 1440)),
            ("wide", NSSize(width: 1020, height: 760), NSRect(x: 0, y: 982, width: 3840, height: 2160))
        ]
        for (_, size, screen) in configurations {
            ScreenGeometry.fixtureFrame = screen
            let controller = SettingsWindowController(updateController: UpdateController())
            guard let window = controller.window else { fail("settings window is missing") }
            window.setContentSize(size)
            window.alphaValue = snapshotDirectory == nil ? 0 : 1
            window.orderFrontRegardless()
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                for pane in SettingsPane.allCases {
                    controller.selectPane(pane)
                    layout(controller)
                    verifyPage(controller, pane: pane)

                }
            }
            window.orderOut(nil)
            window.close()
        }
    }

    private static func resetVisiblePreferences() {
        PrevDockSettings.previewContentSize = .regular
        PrevDockSettings.previewWindowHeight = .regular
        PrevDockSettings.previewCloseButtonEnabled = true
        PrevDockSettings.previewDesktopGroupingEnabled = true
        PrevDockSettings.previewOverflowMode = .scroll
        PrevDockSettings.previewAutoFitEnabled = true
        PrevDockSettings.previewSwitchDelay = 0.3
    }

    private static func verifyPage(_ controller: SettingsWindowController, pane: SettingsPane) {
        let views = descendants(in: content(controller))
        let tables = views.compactMap { $0 as? NSTableView }
        expect(tables.count == 1 && tables[0].numberOfRows == SettingsPane.allCases.count,
               "sidebar should expose all settings categories")
        expect(tables[0].selectedRow == pane.rawValue, "sidebar selection should match the detail pane")
        let pages = views.compactMap { $0 as? SettingsPageView }
        expect(pages.count == 1, "only the current page should be attached")
        guard let page = pages.first, let document = page.documentView else { fail("settings page is missing") }
        expect(page.accessibilityLabel() == pane.title + " settings", "page should expose an accessibility name")
        verifyPageControls(controller, pane: pane)
        if pane == .appearance { verifyAppearancePresentation(controller) }
        for control in descendants(in: document).compactMap({ $0 as? NSControl }) where !control.isHiddenOrHasHiddenAncestor {
            if let label = control as? NSTextField, !label.isEditable, label.stringValue.isEmpty { continue }
            let rect = document.convert(control.alignmentRect(forFrame: control.frame), from: control.superview)
            expect(rect.width > 0 && rect.height > 0, "\(pane.title): visible controls must have a usable size: \(describe(control)), \(rect)")
            expect(rect.minX >= -0.5 && rect.maxX <= document.bounds.maxX + 0.5,
                   "\(pane.title): horizontal clipping for \(describe(control)) at \(rect), document \(document.bounds)")
            expect(rect.minY >= -0.5 && rect.maxY <= document.bounds.maxY + 0.5,
                   "\(pane.title): vertical clipping for \(describe(control)) at \(rect), document \(document.bounds)")
        }
        expect(document.bounds.width <= page.contentView.bounds.width + 0.5,
               "\(pane.title): pages should not require horizontal scrolling")
    }

    private static func verifyAppearancePresentation(_ controller: SettingsWindowController) {
        guard let stage = descendants(in: content(controller)).compactMap({ $0 as? SettingsPreviewStage }).first else {
            fail("first Appearance presentation should attach its sample stage")
        }
        expect(stage.window === controller.window && !stage.isHiddenOrHasHiddenAncestor,
               "the appearance example should be attached and visible on its first presentation")
        expect(stage.bounds.width > 0 && stage.bounds.height > 0,
               "the appearance example should receive a layout size before rendering")
        let cards = descendants(in: stage).compactMap { $0 as? PreviewCardView }
        expect(!cards.isEmpty, "first Appearance presentation must contain actual preview cards")
        for card in cards {
            expect(card.frame.width > 0 && card.frame.height > 0 && card.bounds.width > 0 && card.bounds.height > 0,
                   "first Appearance preview cards must have positive frames and bounds")
            expect(card.visibleRect.width > 0 && card.visibleRect.height > 0,
                   "first Appearance preview cards must not be clipped by an unlaid-out ancestor")
            let rect = stage.convert(card.bounds, from: card)
            expect(stage.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect),
                   "first Appearance preview cards should fit inside the example stage: \(rect), stage \(stage.bounds)")
        }
    }

    private static func verifyPageControls(_ controller: SettingsWindowController, pane: SettingsPane) {
        let expectedSwitches: [SettingsPane: [String]] = [
            .general: ["Open at login", "Click to show previews", "Hide native Dock labels"],
            .appearance: ["Show close button"],
            .layout: ["Fit automatically", "Group windows by Desktop"],
            .permissions: [], .updates: ["Automatically install updates"]
        ]
        for label in expectedSwitches[pane] ?? [] {
            let _: NSSwitch = control(controller, label: label)
        }
        let sliders = descendants(in: content(controller)).compactMap { $0 as? NSSlider }
        expect(sliders.count == (pane == .appearance ? 2 : pane == .general ? 1 : 0),
               "\(pane.title): only its own slider controls should be attached")
        for slider in sliders {
            expect(slider.bounds.width >= 200, "\(pane.title): sliders should remain usable at the minimum width")
        }
        if pane == .layout {
            expect(layoutButton(controller, mode: .scroll).bounds.width > 200, "layout choices should have readable diagrams")
            expect(layoutButton(controller, mode: .wrap).bounds.width > 200, "both layout choices should remain reachable")
        }
    }

    private static func saveSnapshot(_ controller: SettingsWindowController, pane: SettingsPane, appearance: NSAppearance.Name) {
        guard let directory = snapshotDirectory else { return }
        let view = content(controller)
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fail("could not allocate settings snapshot") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fail("could not encode settings snapshot") }
        let suffix = appearance == .aqua ? "light" : "dark"
        let path = directory.appendingPathComponent("settings-\(pane.title.lowercased())-\(suffix).png")
        do { try data.write(to: path) }
        catch { fail("could not write settings snapshot: \(error)") }
    }

    private static func layout(_ controller: SettingsWindowController) {
        content(controller).layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        content(controller).layoutSubtreeIfNeeded()
    }

    private static func content(_ controller: SettingsWindowController) -> NSView {
        guard let content = controller.window?.contentView else { fail("settings content is missing") }
        return content
    }

    private static func labels(_ controller: SettingsWindowController) -> [String] {
        descendants(in: content(controller)).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    private static func control<T: NSControl>(_ controller: SettingsWindowController, label: String) -> T {
        guard let control = descendants(in: content(controller)).compactMap({ $0 as? T }).first(where: { $0.accessibilityLabel() == label }) else {
            fail("missing accessible control: \(label)")
        }
        return control
    }

    private static func button(_ controller: SettingsWindowController, title: String) -> NSButton {
        guard let button = descendants(in: content(controller)).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else {
            fail("missing button: \(title)")
        }
        return button
    }

    private static func layoutButton(_ controller: SettingsWindowController, mode: PreviewOverflowMode) -> SettingsLayoutOptionButton {
        guard let button = descendants(in: content(controller)).compactMap({ $0 as? SettingsLayoutOptionButton }).first(where: { $0.mode == mode }) else {
            fail("missing layout choice: \(mode)")
        }
        return button
    }

    private static func send(_ control: NSControl) {
        guard let action = control.action else { fail("control has no action: \(describe(control))") }
        expect(NSApp.sendAction(action, to: control.target, from: control), "native control action should reach its target")
    }

    private static func describe(_ control: NSControl) -> String {
        control.accessibilityLabel() ?? (control as? NSTextField)?.stringValue ?? String(describing: type(of: control))
    }

    private static func descendants(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(in: $0) }
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        clearTestPreferences()
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}
