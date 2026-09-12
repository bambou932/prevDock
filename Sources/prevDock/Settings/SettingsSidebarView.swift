import AppKit

final class SettingsSidebarView: NSVisualEffectView, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((SettingsPane) -> Void)?
    private let table = NSTableView()
    private var selecting = false

    init() {
        super.init(frame: .zero)
        material = .sidebar
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        configureTable()
        installContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func select(_ pane: SettingsPane) {
        guard table.selectedRow != pane.rawValue else { return }
        selecting = true
        table.selectRowIndexes(IndexSet(integer: pane.rawValue), byExtendingSelection: false)
        selecting = false
    }

    func focusSelection() { window?.makeFirstResponder(table) }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("settings-pane"))
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .sourceList
        table.rowHeight = 36
        table.intercellSpacing = NSSize(width: 0, height: 3)
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Settings categories")
    }

    private func installContent() {
        let name = SettingsUI.vertical([SettingsUI.title("prevDock", size: 17), SettingsUI.detail("Settings")], spacing: 2)
        let header = SettingsUI.horizontal([
            SettingsUI.symbol("macwindow.on.rectangle", size: 30, color: .controlAccentColor), name
        ], spacing: 10)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = table
        scroll.hasVerticalScroller = false
        addSubview(header)
        addSubview(scroll)
        header.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 55),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 26),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20)
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { SettingsPane.allCases.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let pane = SettingsPane(rawValue: row) else { return nil }
        let cell = NSTableCellView()
        let icon = SettingsUI.symbol(pane.symbol, size: 19, color: .labelColor)
        let label = SettingsUI.title(pane.title, size: 13, weight: .medium)
        cell.toolTip = "\(pane.title) (⌘\(row + 1))"
        cell.imageView = icon
        cell.textField = label
        cell.addSubview(icon)
        cell.addSubview(label)
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 9),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selecting, let pane = SettingsPane(rawValue: table.selectedRow) else { return }
        onSelect?(pane)
    }
}
