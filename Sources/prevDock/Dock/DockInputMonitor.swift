import Cocoa
import CoreGraphics

final class DockInputMonitor {
    struct MouseDown {
        let kind: MouseDownKind
        let isContextClick: Bool
        let allowsPreviewInterception: Bool
        let mouse: CGPoint
        let fallbackMouse: CGPoint
        let canSuppressDefault: Bool
    }

    struct Handlers {
        let mouseDown: (MouseDown) -> Bool
        let mouseMoved: () -> Void
        let focusNavigation: () -> Void
        let mouseDragged: (MouseDownKind) -> Bool
        let mouseUp: (MouseDownKind) -> Bool
    }

    private let handlers: Handlers
    private var eventMonitors = [Any]()
    private var globalMouseMovedMonitor: Any?
    private var mouseDownEventTap: CFMachPort?
    private var mouseDownEventTapSource: CFRunLoopSource?
    private var lastEventTapInstallAttempt: TimeInterval = 0
    private var lastMouseMovedMonitorInstallAttempt: TimeInterval = 0
    private var handledMouseDownEvents = DockMouseDownDeduplicator()

    var hasGlobalMouseMovedMonitor: Bool { globalMouseMovedMonitor != nil }

    init(handlers: Handlers) {
        self.handlers = handlers
    }

    deinit { stop() }

    func start() {
        stop()
        globalMouseMovedMonitor = nil
        lastMouseMovedMonitorInstallAttempt = 0
        installMouseDownEventTap(force: true)
        installMouseEventMonitors()
    }

    func stop() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
        globalMouseMovedMonitor = nil
        uninstallMouseDownEventTap()
    }

    func repairIfNeeded() {
        repairMouseDownEventTapIfNeeded()
        repairMouseMovedMonitorIfNeeded()
    }

    private func installMouseEventMonitors() {
        installMouseDownEventMonitors()
        installMouseMovedEventMonitors()
    }

    private func installMouseDownEventMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            DispatchQueue.main.async {
                self?.handleMouseDown(event)
            }
        }) {
            eventMonitors.append(global)
        }

        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handleMouseDown(event)
            return event
        }) {
            eventMonitors.append(local)
        }
    }

    private func installMouseMovedEventMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved]

        installGlobalMouseMovedMonitorIfNeeded(mask: mask)

        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handleMouseMoved()
            return event
        }) {
            eventMonitors.append(local)
        }
    }

    private func installGlobalMouseMovedMonitorIfNeeded(
        mask: NSEvent.EventTypeMask = [.mouseMoved]
    ) {
        guard globalMouseMovedMonitor == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMouseMovedMonitorInstallAttempt >= 1 else { return }
        lastMouseMovedMonitorInstallAttempt = now
        guard let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.handleMouseMoved()
        }) else {
            return
        }
        globalMouseMovedMonitor = monitor
        eventMonitors.append(monitor)
    }

    private func repairMouseMovedMonitorIfNeeded() {
        installGlobalMouseMovedMonitorIfNeeded()
    }

    private func installMouseDownEventTap(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastEventTapInstallAttempt >= 5 else { return }
        lastEventTapInstallAttempt = now
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.leftMouseUp.rawValue) |
            CGEventMask(1 << CGEventType.leftMouseDragged.rawValue) |
            CGEventMask(1 << CGEventType.rightMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.otherMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.rightMouseUp.rawValue) |
            CGEventMask(1 << CGEventType.otherMouseUp.rawValue) |
            CGEventMask(1 << CGEventType.rightMouseDragged.rawValue) |
            CGEventMask(1 << CGEventType.otherMouseDragged.rawValue) |
            CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.mouseDownEventCallback,
            userInfo: refcon
        ) else {
            NSLog("prevDock: failed to install Dock mouse-down event tap")
            return
        }

        mouseDownEventTap = tap
        mouseDownEventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let mouseDownEventTapSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), mouseDownEventTapSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func uninstallMouseDownEventTap() {
        if let tap = mouseDownEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = mouseDownEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        mouseDownEventTap = nil
        mouseDownEventTapSource = nil
    }

    private func repairMouseDownEventTapIfNeeded() {
        guard let tap = mouseDownEventTap else {
            installMouseDownEventTap()
            return
        }
        guard !CFMachPortIsValid(tap) || !CGEvent.tapIsEnabled(tap: tap) else { return }
        uninstallMouseDownEventTap()
        installMouseDownEventTap(force: true)
    }

    private func handleMouseDownFromEventTap(
        kind: MouseDownKind,
        isContextClick: Bool,
        allowsPreviewInterception: Bool,
        mouse: CGPoint
    ) -> Bool {
        if Thread.isMainThread {
            return handlers.mouseDown(MouseDown(
                kind: kind,
                isContextClick: isContextClick,
                allowsPreviewInterception: allowsPreviewInterception,
                mouse: mouse,
                fallbackMouse: mouse,
                canSuppressDefault: true
            ))
        }

        var suppress = false
        DispatchQueue.main.sync {
            suppress = handlers.mouseDown(MouseDown(
                kind: kind,
                isContextClick: isContextClick,
                allowsPreviewInterception: allowsPreviewInterception,
                mouse: mouse,
                fallbackMouse: mouse,
                canSuppressDefault: true
            ))
        }
        return suppress
    }

    private func mouseLocation(for event: NSEvent) -> CGPoint {
        guard let window = event.window else {
            return event.locationInWindow
        }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func handleFocusNavigation(_ event: CGEvent) {
        guard DockFocusNavigation.cancelsPendingFocus(
            keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags
        ) else { return }
        if Thread.isMainThread {
            handlers.focusNavigation()
        } else {
            DispatchQueue.main.sync { handlers.focusNavigation() }
        }
    }

    private func shouldSuppressMouseDragFromEventTap(kind: MouseDownKind) -> Bool {
        if Thread.isMainThread {
            return handlers.mouseDragged(kind)
        }
        var suppress = false
        DispatchQueue.main.sync {
            suppress = handlers.mouseDragged(kind)
        }
        return suppress
    }

    private func shouldSuppressMouseUpFromEventTap(kind: MouseDownKind) -> Bool {
        if Thread.isMainThread {
            return handlers.mouseUp(kind)
        }

        var suppress = false
        DispatchQueue.main.sync {
            suppress = handlers.mouseUp(kind)
        }
        return suppress
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard let kind = MouseDownKind(eventType: event.type) else { return }
        // AppKit can deliver the same event later, after a newer click has already opened a preview.
        guard !handledMouseDownEvents.wasHandled(kind: kind, timestamp: event.cgEvent?.timestamp) else { return }
        _ = handlers.mouseDown(MouseDown(
            kind: kind,
            isContextClick: kind.isContextClick(modifierFlags: event.modifierFlags),
            allowsPreviewInterception: kind.allowsPreviewInterception(modifierFlags: event.modifierFlags),
            mouse: mouseLocation(for: event),
            fallbackMouse: DockCursorTracker.shared.currentMouseLocation(),
            canSuppressDefault: false
        ))
    }

    private func handleMouseMoved() {
        DockCursorTracker.shared.updateFromAppKitPoint(NSEvent.mouseLocation)
        handlers.mouseMoved()
    }

    private static let mouseDownEventCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<DockInputMonitor>.fromOpaque(refcon).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = monitor.mouseDownEventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            monitor.handlers.mouseMoved()
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            monitor.handleFocusNavigation(event)
            return Unmanaged.passUnretained(event)
        }

        if let kind = MouseDownKind(cgMouseDraggedEventType: type) {
            DockCursorTracker.shared.updateFromEventTap(quartzPoint: event.location)
            return monitor.shouldSuppressMouseDragFromEventTap(kind: kind) ? nil : Unmanaged.passUnretained(event)
        }

        if let kind = MouseDownKind(cgMouseUpEventType: type) {
            return monitor.shouldSuppressMouseUpFromEventTap(kind: kind) ? nil : Unmanaged.passUnretained(event)
        }

        guard let kind = MouseDownKind(cgEventType: type) else {
            return Unmanaged.passUnretained(event)
        }

        monitor.handledMouseDownEvents.record(kind: kind, timestamp: event.timestamp)
        let mouse = DockCursorTracker.shared.updateFromEventTap(quartzPoint: event.location)
        let suppress = monitor.handleMouseDownFromEventTap(
            kind: kind,
            isContextClick: kind.isContextClick(eventFlags: event.flags),
            allowsPreviewInterception: kind.allowsPreviewInterception(eventFlags: event.flags),
            mouse: mouse
        )
        return suppress ? nil : Unmanaged.passUnretained(event)
    }
}
