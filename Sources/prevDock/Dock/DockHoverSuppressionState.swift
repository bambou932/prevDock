import Cocoa

struct DockHoverSuppressionState {
    private let clock: () -> TimeInterval
    private var suppressHoverUntil = -TimeInterval.infinity
    private var suppressDockContextMenuUntil = -TimeInterval.infinity
    private var dockContextMenuCheckAfter = -TimeInterval.infinity
    private var missingDockContextMenuObservations = 0
    private var suppressUntilDockExit = false
    private var clickPreviewHoldUntil = -TimeInterval.infinity
    private var suppressedMouseUpKind: MouseDownKind?

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    var isSuppressingDockContextMenu: Bool {
        clock() < suppressDockContextMenuUntil
    }

    mutating func suppressDockContextMenu(for interval: TimeInterval) {
        let now = clock()
        suppressDockContextMenuUntil = (now + interval)
        dockContextMenuCheckAfter = (now + 0.3)
        missingDockContextMenuObservations = 0
    }

    mutating func clearDockContextMenu() {
        suppressDockContextMenuUntil = -TimeInterval.infinity
        dockContextMenuCheckAfter = -TimeInterval.infinity
        missingDockContextMenuObservations = 0
    }

    mutating func shouldSuppressDockContextMenu(visibility: () -> Bool?) -> Bool {
        let now = clock()
        guard now < suppressDockContextMenuUntil else {
            clearDockContextMenu()
            return false
        }
        guard now >= dockContextMenuCheckAfter else { return true }
        if visibility() == true {
            missingDockContextMenuObservations = 0
            dockContextMenuCheckAfter = (now + 0.25)
            return true
        }
        missingDockContextMenuObservations += 1
        guard missingDockContextMenuObservations >= 2 else {
            dockContextMenuCheckAfter = (now + 0.3)
            return true
        }
        clearDockContextMenu()
        return false
    }

    var dockContextMenuCheckInterval: TimeInterval? {
        let now = clock()
        guard now < suppressDockContextMenuUntil,
              now < dockContextMenuCheckAfter else {
            return nil
        }
        return max(0.01, (dockContextMenuCheckAfter - now))
    }

    mutating func suppressHover(for interval: TimeInterval, untilDockExit: Bool) {
        suppressHoverUntil = max(suppressHoverUntil, (clock() + interval))
        suppressUntilDockExit = suppressUntilDockExit || untilDockExit
    }

    func shouldSuppressHoverByTime() -> Bool {
        clock() < suppressHoverUntil
    }

    mutating func shouldSuppressHover(isStillInDockOrPreview: @autoclosure () -> Bool) -> Bool {
        // Leaving during the timed guard still completes the Dock-exit requirement.
        let awaitsDockExit = suppressUntilDockExit && shouldSuppressUntilDockExit(
            isStillInDockOrPreview: isStillInDockOrPreview()
        )
        return shouldSuppressHoverByTime() || awaitsDockExit
    }

    mutating func clearHoverSuppression() {
        suppressHoverUntil = -TimeInterval.infinity
        suppressUntilDockExit = false
    }

    mutating func shouldSuppressUntilDockExit(isStillInDockOrPreview: Bool) -> Bool {
        guard suppressUntilDockExit else { return false }
        guard !isStillInDockOrPreview else { return true }
        suppressUntilDockExit = false
        return false
    }

    mutating func holdClickPreview(for interval: TimeInterval) {
        clickPreviewHoldUntil = (clock() + interval)
    }

    mutating func clearClickPreviewHold() {
        clickPreviewHoldUntil = -TimeInterval.infinity
    }

    func shouldHoldClickPreview() -> Bool {
        clock() < clickPreviewHoldUntil
    }

    var hasShortTimedState: Bool {
        let now = clock()
        return now < suppressHoverUntil ||
            now < clickPreviewHoldUntil
    }

    mutating func prepareForMouseDown(kind: MouseDownKind) {
        guard suppressedMouseUpKind == kind else { return }
        resetSuppressedMouseUp()
    }

    mutating func holdSuppressedMouseUp(kind: MouseDownKind) {
        suppressedMouseUpKind = kind
    }

    func shouldSuppressMouseDrag(kind: MouseDownKind) -> Bool {
        suppressedMouseUpKind == kind
    }

    mutating func consumeSuppressedMouseUpIfNeeded(kind: MouseDownKind) -> Bool {
        guard suppressedMouseUpKind == kind else { return false }
        resetSuppressedMouseUp()
        return true
    }

    mutating func resetSuppressedMouseUp() {
        suppressedMouseUpKind = nil
    }
}

enum MouseDownKind {
    case left
    case right
    case other

    init?(eventType: NSEvent.EventType) {
        switch eventType {
        case .leftMouseDown:
            self = .left
        case .rightMouseDown:
            self = .right
        case .otherMouseDown:
            self = .other
        default:
            return nil
        }
    }

    init?(cgEventType: CGEventType) {
        switch cgEventType {
        case .leftMouseDown:
            self = .left
        case .rightMouseDown:
            self = .right
        case .otherMouseDown:
            self = .other
        default:
            return nil
        }
    }

    init?(cgMouseUpEventType: CGEventType) {
        switch cgMouseUpEventType {
        case .leftMouseUp:
            self = .left
        case .rightMouseUp:
            self = .right
        case .otherMouseUp:
            self = .other
        default:
            return nil
        }
    }

    init?(cgMouseDraggedEventType: CGEventType) {
        switch cgMouseDraggedEventType {
        case .leftMouseDragged:
            self = .left
        case .rightMouseDragged:
            self = .right
        case .otherMouseDragged:
            self = .other
        default:
            return nil
        }
    }

    func isContextClick(modifierFlags: NSEvent.ModifierFlags) -> Bool {
        self == .right || (self == .left && modifierFlags.contains(.control))
    }

    func isContextClick(eventFlags: CGEventFlags) -> Bool {
        self == .right || (self == .left && eventFlags.contains(.maskControl))
    }

    func allowsPreviewInterception(modifierFlags: NSEvent.ModifierFlags) -> Bool {
        guard self == .left else { return false }
        let modifiers: NSEvent.ModifierFlags = [.command, .option, .shift, .control, .function]
        return modifierFlags.intersection(modifiers).isEmpty
    }

    func allowsPreviewInterception(eventFlags: CGEventFlags) -> Bool {
        guard self == .left else { return false }
        let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl, .maskSecondaryFn]
        return eventFlags.intersection(modifiers).isEmpty
    }
}
