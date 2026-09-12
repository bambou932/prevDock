import Cocoa

final class StatusItemController: NSObject {
    private static let iconHeight: CGFloat = 18
    private var statusItem: NSStatusItem?
    private var permissionItem: NSMenuItem?
    private let updateController: () -> UpdateController?
    private let showSettings: () -> Void
    private let showPermissions: () -> Void
    private let toggleHoverDebug: () -> Void

    init(
        updateController: @escaping () -> UpdateController?,
        showSettings: @escaping () -> Void,
        showPermissions: @escaping () -> Void,
        toggleHoverDebug: @escaping () -> Void
    ) {
        self.updateController = updateController
        self.showSettings = showSettings
        self.showPermissions = showPermissions
        self.toggleHoverDebug = toggleHoverDebug
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton(item.button)
        item.menu = makeMenu()
        statusItem = item
    }

    func updatePermissions(_ status: PermissionManager.Status) {
        permissionItem?.title = status.allGranted ? "Permissions..." : "Permissions Required..."
    }

    private func configureButton(_ button: NSStatusBarButton?) {
        guard let button else { return }
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        if let image = bundledIcon() ?? fallbackIcon() {
            button.image = image
        } else {
            button.title = "pD"
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "prevDock is running", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(actionItem("Settings...", action: #selector(openSettings), key: ","))
        let update = NSMenuItem(title: "Update Now...", action: #selector(UpdateController.checkForUpdates(_:)), keyEquivalent: "")
        update.target = updateController()
        menu.addItem(update)
        menu.addItem(actionItem("Toggle Hover Debug", action: #selector(toggleDebug), key: "d"))
        let permission = actionItem("", action: #selector(openPermissions), key: "p")
        permissionItem = permission
        updatePermissions(PermissionManager.status)
        menu.addItem(permission)
        menu.addItem(actionItem("Quit prevDock", action: #selector(quit), key: "q"))
        return menu
    }

    private func actionItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func bundledIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "prevDock_menubar_Icon", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        return prepareIcon(image)
    }

    private func fallbackIcon() -> NSImage? {
        guard let image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "prevDock") else { return nil }
        return prepareIcon(image)
    }

    private func prepareIcon(_ image: NSImage) -> NSImage {
        image.isTemplate = true
        guard image.size.height > 0 else { return image }
        let ratio = image.size.width / image.size.height
        image.size = NSSize(width: Self.iconHeight * ratio, height: Self.iconHeight)
        return image
    }

    @objc private func openSettings() { showSettings() }
    @objc private func openPermissions() { showPermissions() }
    @objc private func toggleDebug() { toggleHoverDebug() }
    @objc private func quit() { NSApp.terminate(nil) }
}
