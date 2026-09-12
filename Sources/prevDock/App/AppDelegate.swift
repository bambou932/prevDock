import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let previewController = PreviewPanelController()
    private let dockMouseEventSuppressor = DockMouseEventSuppressor()
    private let hoverDebugPanelController = HoverDebugPanelController()
    private lazy var updateController = UpdateController()
    private lazy var settingsWindowController = SettingsWindowController(updateController: updateController)
    private lazy var statusItemController = StatusItemController(
        updateController: { [weak self] in self?.updateController },
        showSettings: { [weak self] in self?.showSettings() },
        showPermissions: { [weak self] in self?.showPermissions() },
        toggleHoverDebug: { [weak self] in self?.hoverDebugPanelController.toggle() }
    )
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
        statusItemController.install()
        dockMouseEventSuppressor.shouldPassThroughMouseMoved = { [weak self] point in
            self?.previewController.contains(point) == true
        }
        dockMouseEventSuppressor.updateForCurrentSettings()
        installSettingsObserver()
        installPermissionObserver()
        let monitor = DockHoverMonitor(previewController: previewController)
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

    private func showSettings() {
        DispatchQueue.main.async { [weak self] in
            self?.settingsWindowController.showSettings()
        }
    }

    private func showPermissions() {
        PrevDockSettings.permissionSetupShown = true
        settingsWindowController.showPermissionSettings()
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
        statusItemController.updatePermissions(status)
        guard status != lastPermissionStatus else { return }

        let previousStatus = lastPermissionStatus
        lastPermissionStatus = status
        if previousStatus?.screenRecordingGranted == true,
           !status.screenRecordingGranted {
            WindowInventory.discardCachedThumbnails()
        }
        previewController.hide()
        DockGeometryCache.shared.refreshNow()
        hoverMonitor?.start()
        dockMouseEventSuppressor.updateForCurrentSettings()
    }
}
