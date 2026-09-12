import AppKit

@main
private enum SettingsUIFixture {
    static func main() {
        SettingsFixturePreferences.prepare()
        let application = NSApplication.shared
        let delegate = SettingsFixtureAppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

private enum SettingsFixturePreferences {
    private static let domain = "io.github.bambou932.prevDock.tests.settings-ui"

    static func prepare() {
        precondition(Bundle.main.bundleIdentifier == domain, "Run the packaged SettingsUIFixture.app")
        clear()
        PrevDockSettings.registerDefaults()
    }

    static func clear() {
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
    }
}

private final class SettingsFixtureAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let updater = UpdateController()
    private lazy var settings = SettingsWindowController(updateController: updater)

    func applicationDidFinishLaunching(_ notification: Notification) {
        ScreenGeometry.fixtureFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        NSApp.mainMenu = makeMainMenu()
        settings.showSettings()
    }

    func applicationWillTerminate(_ notification: Notification) {
        SettingsFixturePreferences.clear()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { settings.showSettings() }
        return true
    }

    private func makeMainMenu() -> NSMenu {
        let menu = NSMenu()
        let application = NSMenu(title: "prevDock Settings Fixture")
        application.addItem(item("Settings…", action: #selector(showSettings), key: ","))
        application.addItem(.separator())
        application.addItem(item("Quit Settings Fixture", action: #selector(quit), key: "q"))
        append(application, to: menu)
        append(makeFixtureMenu(), to: menu)
        return menu
    }

    private func makeFixtureMenu() -> NSMenu {
        let menu = NSMenu(title: "Fixture")
        let description = NSMenuItem(title: "UI only · simulated OS services", action: nil, keyEquivalent: "")
        description.isEnabled = false
        menu.addItem(description)
        menu.addItem(.separator())
        for (index, title) in ["System Appearance", "Light Appearance", "Dark Appearance"].enumerated() {
            let appearance = item(title, action: #selector(changeAppearance(_:)))
            appearance.tag = index
            menu.addItem(appearance)
        }
        menu.addItem(.separator())
        menu.addItem(item("Accessibility Granted", action: #selector(toggleAccessibility)))
        menu.addItem(item("Screen Recording Granted", action: #selector(toggleScreenRecording)))
        menu.addItem(item("Finish Simulated Update Check", action: #selector(finishUpdateCheck)))
        return menu
    }

    private func append(_ submenu: NSMenu, to menu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(changeAppearance(_:)):
            let selected = NSApp.appearance?.name == .aqua ? 1 : NSApp.appearance?.name == .darkAqua ? 2 : 0
            item.state = item.tag == selected ? .on : .off
        case #selector(toggleAccessibility):
            item.state = PermissionManager.status.accessibilityGranted ? .on : .off
        case #selector(toggleScreenRecording):
            item.state = PermissionManager.status.screenRecordingGranted ? .on : .off
        case #selector(finishUpdateCheck):
            return !updater.canCheckForUpdates
        default:
            break
        }
        return true
    }

    @objc private func showSettings() {
        settings.showSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func changeAppearance(_ sender: NSMenuItem) {
        switch sender.tag {
        case 1: NSApp.appearance = NSAppearance(named: .aqua)
        case 2: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    @objc private func toggleAccessibility() {
        PermissionManager.publish(
            accessibility: !PermissionManager.status.accessibilityGranted,
            recording: PermissionManager.status.screenRecordingGranted
        )
    }

    @objc private func toggleScreenRecording() {
        PermissionManager.publish(
            accessibility: PermissionManager.status.accessibilityGranted,
            recording: !PermissionManager.status.screenRecordingGranted
        )
    }

    @objc private func finishUpdateCheck() {
        updater.canCheckForUpdates = true
        updater.stateDidChange?()
    }
}
