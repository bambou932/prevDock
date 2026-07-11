import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let statusIconHeight: CGFloat = 18

    private var statusItem: NSStatusItem?
    private var permissionMenuItem: NSMenuItem?
    private let previewController = PreviewPanelController()
    private let labelController = DockLabelPanelController()
    private let dockMouseEventSuppressor = DockMouseEventSuppressor()
    private let hoverDebugPanelController = HoverDebugPanelController()
    private let updateController = UpdateController()
    private lazy var settingsWindowController = SettingsWindowController(updateController: updateController)
    private var hoverMonitor: DockHoverMonitor?
    private var settingsObserver: NSObjectProtocol?
    private var permissionObserver: NSObjectProtocol?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var lastPermissionStatus: PermissionManager.Status?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SingleInstanceCoordinator.claimInstance() else {
            NSApp.terminate(nil)
            return
        }
        let isFreshInstall = !PrevDockSettings.hasPersistentSettingsDomain
        PrevDockSettings.registerDefaults()
        LaunchAtLoginController.applyDefaultIfNeeded(isFreshInstall: isFreshInstall)
        lastPermissionStatus = PermissionManager.status
        configureStatusItem()
        dockMouseEventSuppressor.shouldPassThroughMouseMoved = { [weak self] point in
            self?.previewController.contains(point) == true
        }
        dockMouseEventSuppressor.updateForCurrentSettings()
        installSettingsObserver()
        installPermissionObserver()
        let monitor = DockHoverMonitor(
            previewController: previewController,
            labelController: labelController
        )
        hoverMonitor = monitor
        dockMouseEventSuppressor.onSuppressedMouseMoved = { [weak monitor] in
            monitor?.wakeForSuppressedMouseMoved()
        }
        monitor.start()

        if isFreshInstall {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.showPermissionSetupIfNeeded()
            }
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            if let image = statusIconImage() ?? fallbackStatusIconImage() {
                button.image = image
            } else {
                button.title = "pD"
            }
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "prevDock is running", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        let updateItem = NSMenuItem(
            title: "Update Now...",
            action: #selector(UpdateController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = updateController
        menu.addItem(updateItem)
        menu.addItem(NSMenuItem(title: "Toggle Hover Debug", action: #selector(toggleHoverDebug), keyEquivalent: "d"))
        let permissionItem = NSMenuItem(
            title: permissionMenuItemTitle,
            action: #selector(showPermissions),
            keyEquivalent: "p"
        )
        permissionMenuItem = permissionItem
        menu.addItem(permissionItem)
        menu.addItem(NSMenuItem(title: "Quit prevDock", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    private func statusIconImage() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "prevDock_menubar_Icon", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        return preparedStatusIcon(image)
    }

    private func fallbackStatusIconImage() -> NSImage? {
        guard let image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "prevDock") else {
            return nil
        }
        return preparedStatusIcon(image)
    }

    private func preparedStatusIcon(_ image: NSImage) -> NSImage {
        image.isTemplate = true
        guard image.size.height > 0 else { return image }

        let aspectRatio = image.size.width / image.size.height
        image.size = NSSize(width: Self.statusIconHeight * aspectRatio, height: Self.statusIconHeight)
        return image
    }

    @objc private func showSettings() {
        DispatchQueue.main.async { [weak self] in
            self?.settingsWindowController.showSettings()
        }
    }

    @objc private func showPermissions() {
        PrevDockSettings.permissionSetupShown = true
        settingsWindowController.showPermissionSettings()
    }

    @objc private func toggleHoverDebug() {
        hoverDebugPanelController.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showPermissionSetupIfNeeded() {
        guard !PermissionManager.status.allGranted,
              !PrevDockSettings.permissionSetupShown else {
            return
        }
        PrevDockSettings.permissionSetupShown = true
        guard !settingsWindowController.isVisible else { return }
        settingsWindowController.showPermissionSettings()
    }

    func applicationWillTerminate(_ notification: Notification) {
        dockMouseEventSuppressor.stop()
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        if let permissionObserver {
            NotificationCenter.default.removeObserver(permissionObserver)
        }
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
    }

    private func installSettingsObserver() {
        guard settingsObserver == nil else { return }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: PrevDockSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard notification.object as? String == PrevDockSettings.nativeDockLabelSuppressionEnabledKey else {
                return
            }
            self?.dockMouseEventSuppressor.updateForCurrentSettings()
        }
    }

    private func installPermissionObserver() {
        guard permissionObserver == nil else { return }
        permissionObserver = NotificationCenter.default.addObserver(
            forName: PermissionManager.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handlePermissionStatusChange()
        }
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handlePermissionStatusChange()
        }
    }

    private func handlePermissionStatusChange() {
        let status = PermissionManager.status
        permissionMenuItem?.title = permissionMenuItemTitle(for: status)
        guard status != lastPermissionStatus else { return }

        let previousStatus = lastPermissionStatus
        lastPermissionStatus = status
        if previousStatus?.screenRecordingGranted == true,
           !status.screenRecordingGranted {
            WindowInventory.discardCachedThumbnails()
        }
        previewController.hide()
        labelController.hide()
        DockGeometryCache.shared.refreshNow()
        hoverMonitor?.start()
        dockMouseEventSuppressor.updateForCurrentSettings()
    }

    private var permissionMenuItemTitle: String {
        permissionMenuItemTitle(for: PermissionManager.status)
    }

    private func permissionMenuItemTitle(for status: PermissionManager.Status) -> String {
        status.allGranted ? "Permissions..." : "Permissions Required..."
    }
}
