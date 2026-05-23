import ApplicationServices
import Cocoa
import CoreGraphics

final class HoverDebugPanelController {
    private let panel: NSPanel
    private let textView = NSTextView()
    private var timer: Timer?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .nonactivatingPanel, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "prevDock Hover Debug"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

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

    private func hide() {
        panel.orderOut(nil)
        timer?.invalidate()
        timer = nil
    }

    private func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer!, forMode: .common)
        refresh()
    }

    private func positionPanel() {
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.minX + 18, y: frame.maxY - size.height - 18))
    }

    private func refresh() {
        let mouse = DockCursorTracker.shared.currentMouseLocation()
        let dock = DockHoverDebugInspector.snapshot(at: mouse)
        let window = WindowUnderPointerInspector.window(at: mouse)
        textView.string = HoverDebugFormatter.text(mouse: mouse, dock: dock, window: window)
    }
}

private enum HoverDebugFormatter {
    static func text(
        mouse: CGPoint,
        dock: DockHoverDebugSnapshot,
        window: WindowUnderPointerSnapshot?
    ) -> String {
        let windowText = window.map(formatWindow) ?? "none"
        let chainText = dock.chain.isEmpty ? "none" : dock.chain.map(formatElement).joined(separator: "\n")
        let targetText = dock.target.map(formatTarget) ?? "nil"
        let targetSourceText = dock.targetSource?.rawValue ?? "nil"
        let screenText = formatScreen(containing: mouse)
        return """
        time: \(Date())
        mouse.appkit: \(formatPoint(mouse))
        mouse.nseventRaw: \(formatPoint(NSEvent.mouseLocation))
        mouse.ax/cg: \(formatPoint(dock.axPoint))
        suppressNativeDockLabels: \(PrevDockSettings.nativeDockLabelSuppressionEnabled)
        pressedButtons: \(NSEvent.pressedMouseButtons)
        axTrusted: \(AXIsProcessTrusted())

        screen:
        \(screenText)

        dock.hit.error: \(dock.hitError)
        dock.targetSource: \(targetSourceText)
        dock.resolvedTarget:
        \(targetText)

        dock.hit.chain:
        \(chainText)

        windowUnderPointer:
        \(windowText)
        """
    }

    private static func formatScreen(containing mouse: CGPoint) -> String {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else {
            return "  none"
        }

        let frame = screen.frame
        let visible = screen.visibleFrame
        return """
          frame: \(formatRect(frame))
          visibleFrame: \(formatRect(visible))
          mouseInsideVisibleFrame: \(visible.contains(mouse))
          bottomReserved: \(Int(visible.minY - frame.minY))
          topReserved: \(Int(frame.maxY - visible.maxY))
        """
    }

    private static func formatTarget(_ target: DockHoverTarget) -> String {
        """
          key: \(target.key)
          title: \(target.title)
          app: \(target.app?.localizedName ?? "nil") pid=\(target.app?.processIdentifier.description ?? "nil")
          bundleID: \(target.app?.bundleIdentifier ?? "nil")
          url: \(target.url?.path ?? "nil")
          anchor.appkit: \(formatRect(target.anchor))
          showsInactiveLabel: \(target.showsInactiveLabel)
        """
    }

    private static func formatElement(_ element: DockHitElementSnapshot) -> String {
        """
          [\(element.depth)] role=\(element.role) subrole=\(element.subrole) desc=\(element.roleDescription)
              title=\(element.title) url=\(element.url?.path ?? "nil")
              pos=\(element.position.map(formatPoint) ?? "nil") size=\(element.size.map(formatSize) ?? "nil")
        """
    }

    private static func formatWindow(_ window: WindowUnderPointerSnapshot) -> String {
        """
          owner: \(window.ownerName) pid=\(window.ownerPID)
          name: \(window.name)
          windowID: \(window.windowID) layer=\(window.layer)
          bounds.cg: \(formatRect(window.bounds))
        """
    }

    private static func formatPoint(_ point: CGPoint) -> String {
        "(\(Int(point.x)), \(Int(point.y)))"
    }

    private static func formatSize(_ size: CGSize) -> String {
        "(\(Int(size.width)) x \(Int(size.height)))"
    }

    private static func formatRect(_ rect: CGRect) -> String {
        "(x:\(Int(rect.minX)) y:\(Int(rect.minY)) w:\(Int(rect.width)) h:\(Int(rect.height)))"
    }
}

private enum DockHoverDebugInspector {
    static func snapshot(at mouse: CGPoint) -> DockHoverDebugSnapshot {
        let axPoint = AccessibilityHelpers.accessibilityPoint(fromAppKitPoint: mouse)
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return DockHoverDebugSnapshot(axPoint: axPoint, hitError: "Dock process not found", chain: [], target: nil, targetSource: nil)
        }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(dockElement, Float(axPoint.x), Float(axPoint.y), &hit)
        let resolution = DockHoverTargetResolver.resolution(at: mouse)
        guard error == .success, let hit else {
            return DockHoverDebugSnapshot(
                axPoint: axPoint,
                hitError: "\(error.rawValue)",
                chain: [],
                target: resolution?.target,
                targetSource: resolution?.source
            )
        }

        let chain = hitChain(from: hit)
        return DockHoverDebugSnapshot(
            axPoint: axPoint,
            hitError: "\(error.rawValue)",
            chain: chain,
            target: resolution?.target,
            targetSource: resolution?.source
        )
    }

    private static func hitChain(from hit: AXUIElement) -> [DockHitElementSnapshot] {
        var snapshots = [DockHitElementSnapshot]()
        var current: AXUIElement? = hit
        var depth = 0

        while let element = current, depth < 8 {
            snapshots.append(DockHitElementSnapshot(depth: depth, element: element))
            current = AccessibilityHelpers.parent(element)
            depth += 1
        }

        return snapshots
    }
}

private enum WindowUnderPointerInspector {
    static func window(at mouse: CGPoint) -> WindowUnderPointerSnapshot? {
        let point = AccessibilityHelpers.accessibilityPoint(fromAppKitPoint: mouse)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        for window in windows {
            guard let snapshot = WindowUnderPointerSnapshot(window: window),
                  snapshot.ownerName != "prevDock",
                  snapshot.bounds.contains(point) else {
                continue
            }
            return snapshot
        }

        return nil
    }
}

private struct DockHoverDebugSnapshot {
    let axPoint: CGPoint
    let hitError: String
    let chain: [DockHitElementSnapshot]
    let target: DockHoverTarget?
    let targetSource: DockHoverTargetSource?
}

private struct DockHitElementSnapshot {
    let depth: Int
    let role: String
    let subrole: String
    let roleDescription: String
    let title: String
    let url: URL?
    let position: CGPoint?
    let size: CGSize?

    init(depth: Int, element: AXUIElement) {
        self.depth = depth
        role = AccessibilityHelpers.stringAttribute(element, kAXRoleAttribute as CFString) ?? ""
        subrole = AccessibilityHelpers.stringAttribute(element, kAXSubroleAttribute as CFString) ?? ""
        roleDescription = AccessibilityHelpers.stringAttribute(element, kAXRoleDescriptionAttribute as CFString) ?? ""
        title = [
            AccessibilityHelpers.stringAttribute(element, kAXTitleAttribute as CFString),
            AccessibilityHelpers.stringAttribute(element, kAXDescriptionAttribute as CFString),
            AccessibilityHelpers.stringAttribute(element, kAXHelpAttribute as CFString)
        ].compactMap { $0 }.first ?? ""
        url = AccessibilityHelpers.urlAttribute(element, "AXURL" as CFString)
        position = AccessibilityHelpers.pointAttribute(element, kAXPositionAttribute as CFString)
        size = AccessibilityHelpers.sizeAttribute(element, kAXSizeAttribute as CFString)
    }
}

private struct WindowUnderPointerSnapshot {
    let ownerName: String
    let ownerPID: Int
    let name: String
    let windowID: Int
    let layer: Int
    let bounds: CGRect

    init?(window: [String: Any]) {
        guard let ownerName = window[kCGWindowOwnerName as String] as? String,
              let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
              let windowID = window[kCGWindowNumber as String] as? Int,
              let layer = window[kCGWindowLayer as String] as? Int,
              let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
            return nil
        }

        self.ownerName = ownerName
        self.ownerPID = ownerPID
        name = window[kCGWindowName as String] as? String ?? ""
        self.windowID = windowID
        self.layer = layer
        self.bounds = bounds
    }
}
