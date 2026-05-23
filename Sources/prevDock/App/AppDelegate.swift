import ApplicationServices
import Cocoa
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let statusIconHeight: CGFloat = 18

    private var statusItem: NSStatusItem?
    private let previewController = PreviewPanelController()
    private let labelController = DockLabelPanelController()
    private let dockMouseEventSuppressor = DockMouseEventSuppressor()
    private let hoverDebugPanelController = HoverDebugPanelController()
    private let updateController = UpdateController()
    private lazy var settingsWindowController = SettingsWindowController(updateController: updateController)
    private var hoverMonitor: DockHoverMonitor?
    private var settingsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SingleInstanceCoordinator.closeOtherInstances()
        let isFreshInstall = !PrevDockSettings.hasPersistentSettingsDomain
        PrevDockSettings.registerDefaults()
        LaunchAtLoginController.applyDefaultIfNeeded(isFreshInstall: isFreshInstall)
        configureStatusItem()
        dockMouseEventSuppressor.updateForCurrentSettings()
        installSettingsObserver()
        let monitor = DockHoverMonitor(
            previewController: previewController,
            labelController: labelController
        )
        hoverMonitor = monitor
        dockMouseEventSuppressor.onSuppressedMouseMoved = { [weak monitor] in
            monitor?.wakeForSuppressedMouseMoved()
        }
        monitor.start()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.requestMissingPermissionsIfNeeded(showAlert: true)
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
            title: "Check for Updates...",
            action: #selector(UpdateController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = updateController
        menu.addItem(updateItem)
        menu.addItem(NSMenuItem(title: "Toggle Hover Debug", action: #selector(toggleHoverDebug), keyEquivalent: "d"))
        menu.addItem(NSMenuItem(title: "Request Permissions", action: #selector(requestPermissionsFromMenu), keyEquivalent: "p"))
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

    @objc private func requestPermissionsFromMenu() {
        requestMissingPermissionsIfNeeded(showAlert: true)
    }

    @objc private func toggleHoverDebug() {
        hoverDebugPanelController.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func requestMissingPermissionsIfNeeded(showAlert: Bool) {
        let accessibilityGranted = AXIsProcessTrusted()
        guard !accessibilityGranted else { return }

        if showAlert {
            let alert = NSAlert()
            alert.messageText = "prevDock needs two macOS permissions"
            alert.informativeText = """
            Accessibility lets prevDock read Dock icon positions.
            macOS may ask you to restart prevDock after granting permissions.
            """
            alert.addButton(withTitle: "Request")
            alert.addButton(withTitle: "Later")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        PermissionManager.requestAccessibility()
    }

    func applicationWillTerminate(_ notification: Notification) {
        dockMouseEventSuppressor.stop()
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    private func installSettingsObserver() {
        guard settingsObserver == nil else { return }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: PrevDockSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.dockMouseEventSuppressor.updateForCurrentSettings()
        }
    }
}
