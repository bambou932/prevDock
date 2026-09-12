import AppKit

final class SettingsPageView: NSScrollView {
    static let horizontalInsets: CGFloat = 64
    private let body = SettingsUI.vertical([], spacing: 22)
    private var maximumBodyWidth: NSLayoutConstraint!

    init(pane: SettingsPane) {
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        horizontalScrollElasticity = .none
        let document = SettingsFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        documentView = document
        document.addSubview(body)
        body.translatesAutoresizingMaskIntoConstraints = false
        let fluidWidth = body.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -Self.horizontalInsets)
        fluidWidth.priority = .defaultHigh
        maximumBodyWidth = body.widthAnchor.constraint(lessThanOrEqualToConstant: 660)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: contentView.widthAnchor),
            body.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            maximumBodyWidth, fluidWidth,
            body.topAnchor.constraint(equalTo: document.topAnchor, constant: 28),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -28)
        ])
        let heading = SettingsUI.vertical([
            SettingsUI.title(pane.title, size: 25), SettingsUI.detail(pane.subtitle)
        ], spacing: 7)
        addSection(heading)
        setAccessibilityLabel(pane.title + " settings")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func accommodateContentWidth(_ width: CGFloat) {
        let maximum = max(660, ceil(width))
        guard maximumBodyWidth.constant != maximum else { return }
        maximumBodyWidth.constant = maximum
        needsLayout = true
    }

    func addSection(_ view: NSView) {
        body.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    }
}

private final class SettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}
