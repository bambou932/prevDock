import ApplicationServices
import Cocoa
import CoreGraphics

final class HoverDebugPanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let textView = NSTextView()
    private var timer: Timer?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .nonactivatingPanel, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "prevDock Hover Debug"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        scrollView.autoresizingMask = [.width, .height]
        scrollView.frame = panel.contentView?.bounds ?? .zero

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .white
        textView.backgroundColor = NSColor.black.withAlphaComponent(0.86)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        panel.contentView = scrollView
    }

    func show() {
        positionPanel()
        panel.orderFrontRegardless()
        start()
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func windowWillClose(_ notification: Notification) {
        stop()
    }

    private func hide() {
        panel.orderOut(nil)
        stop()
    }

    private func start() {
        stop()
        let timer = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func positionPanel() {
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.minX + 18, y: frame.maxY - size.height - 18))
    }

    private func refresh() {
        let mouse = DockCursorTracker.shared.currentMouseLocation()
        textView.string = DockHoverDiagnostics.text(at: mouse)
    }
}
