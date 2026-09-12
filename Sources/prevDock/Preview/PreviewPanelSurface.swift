import Cocoa

final class PreviewPanelSurface {
    let panel: NSPanel
    let contentView = NSView()
    private let backdropView = NSVisualEffectView()
    let stackView = NSStackView()

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 190),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configurePanel()
        configureContainer()
        installBackdrop()
        installStack()
        installConstraints()
        panel.contentView = contentView
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.title = "prevDock.preview.idle"
    }

    private func configureContainer() {
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 12
        contentView.layer?.borderWidth = 1
        contentView.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        contentView.layer?.masksToBounds = true
    }

    private func installBackdrop() {
        backdropView.material = .underPageBackground
        backdropView.blendingMode = .behindWindow
        backdropView.state = .active
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(backdropView)
    }

    private func installStack() {
        stackView.orientation = .vertical
        stackView.spacing = PreviewMetrics.rowSpacing
        stackView.alignment = .centerX
        stackView.distribution = .gravityAreas
        stackView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stackView)
    }

    private func installConstraints() {
        NSLayoutConstraint.activate([
            backdropView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            backdropView.topAnchor.constraint(equalTo: contentView.topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: PreviewMetrics.panelPadding),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -PreviewMetrics.panelPadding),
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: PreviewMetrics.panelPadding),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -PreviewMetrics.panelPadding)
        ])
    }
}
