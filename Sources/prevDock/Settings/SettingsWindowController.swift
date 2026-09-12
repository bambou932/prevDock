import Cocoa

final class SettingsWindowController: NSWindowController {
    private let settingsContentView: SettingsContentView
    private var pendingMinimumWidth: CGFloat?
    private var widthUpdateScheduled = false
    var isVisible: Bool { window?.isVisible == true }
    var selectedPane: SettingsPane { settingsContentView.selectedPane }

    init(updateController: UpdateController) {
        settingsContentView = SettingsContentView(updateController: updateController)
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "General — prevDock"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentMinSize = NSSize(width: 820, height: 580)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.contentView = settingsContentView
        window.center()
        super.init(window: window)
        window.onSelectPane = { [weak self] in self?.selectPane($0) }
        settingsContentView.onMinimumContentWidthChanged = { [weak self] in self?.scheduleMinimumWidth($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func showSettings() { present(focusingPermissions: false) }
    func showPermissionSettings() { present(focusingPermissions: true) }
    func selectPane(_ pane: SettingsPane) { settingsContentView.selectPane(pane) }

    private func scheduleMinimumWidth(_ width: CGFloat) {
        pendingMinimumWidth = max(820, ceil(width))
        guard !widthUpdateScheduled else { return }
        widthUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in self?.applyMinimumWidth() }
    }

    private func applyMinimumWidth() {
        widthUpdateScheduled = false
        guard let window, let width = pendingMinimumWidth else { return }
        pendingMinimumWidth = nil
        window.contentMinSize.width = width
        let size = window.contentRect(forFrameRect: window.frame).size
        guard size.width < width else { return }
        window.setContentSize(NSSize(width: width, height: size.height))
    }

    private func present(focusingPermissions: Bool) {
        guard let window else { return }
        if focusingPermissions { selectPane(.permissions) }
        settingsContentView.refreshForPresentation()
        if window.isMiniaturized { window.deminiaturize(nil) }
        showWindow(nil)
        focusWindow(window)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, window.isVisible else { return }
            self.focusWindow(window)
            if focusingPermissions { self.settingsContentView.focusPermissionAction() }
        }
    }

    private func focusWindow(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private final class SettingsWindow: NSWindow {
    var onSelectPane: ((SettingsPane) -> Void)?
    private lazy var keyboardMenu = makeKeyboardMenu()

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, attachedSheet == nil else {
            return super.performKeyEquivalent(with: event)
        }
        return keyboardMenu.performKeyEquivalent(with: event) || super.performKeyEquivalent(with: event)
    }

    private func makeKeyboardMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Close", action: #selector(performClose(_:)), keyEquivalent: "w").target = self
        menu.addItem(withTitle: "Settings", action: #selector(makeKeyAndOrderFront(_:)), keyEquivalent: ",").target = self
        for pane in SettingsPane.allCases {
            let item = menu.addItem(
                withTitle: pane.title, action: #selector(selectPaneFromKeyboard(_:)),
                keyEquivalent: String(pane.rawValue + 1)
            )
            item.tag = pane.rawValue
            item.target = self
        }
        return menu
    }

    @objc private func selectPaneFromKeyboard(_ sender: NSMenuItem) {
        guard let pane = SettingsPane(rawValue: sender.tag) else { return }
        onSelectPane?(pane)
    }
}
