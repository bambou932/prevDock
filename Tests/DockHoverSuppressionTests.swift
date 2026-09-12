import Cocoa

@main
enum DockHoverSuppressionTests {
    static func main() {
        testElapsedTimeAndDockExit()
        testDockExitDuringTimedSuppression()
        testContextMenuObservations()
        testClickPairing()
        testModifiedClicks()
        testDelayedEventFallback()
        testEventIdentityAndFallback()
        testBoundedEventHistory()
        testFocusNavigation()
        print("Dock hover suppression tests passed")
    }

    static func testElapsedTimeAndDockExit() {
        var uptime: TimeInterval = 100
        var state = DockHoverSuppressionState(clock: { uptime })
        check(!state.hasShortTimedState, "initial state must be idle")
        state.suppressHover(for: 0.5, untilDockExit: true)
        state.holdClickPreview(for: 0.8)
        uptime += 0.2
        state.suppressHover(for: 0.1, untilDockExit: false)
        uptime += 0.2
        check(state.shouldSuppressHoverByTime(), "a shorter request must not shorten suppression")
        uptime += 0.2
        check(!state.shouldSuppressHoverByTime(), "elapsed hover delay must expire")
        check(state.shouldHoldClickPreview(), "click preview keeps its independent deadline")
        check(state.shouldSuppressUntilDockExit(isStillInDockOrPreview: true), "Dock exit latch survives delay")
        check(!state.shouldSuppressUntilDockExit(isStillInDockOrPreview: false), "leaving Dock clears latch")
        check(!state.shouldSuppressUntilDockExit(isStillInDockOrPreview: true), "returning must not restore latch")
        uptime += 0.3
        check(!state.hasShortTimedState, "all short states must expire with elapsed time")
        state.holdClickPreview(for: 10)
        state.clearClickPreviewHold()
        check(!state.shouldHoldClickPreview(), "explicit dismissal must cancel a hold")
        state.suppressHover(for: 10, untilDockExit: true)
        state.holdSuppressedMouseUp(kind: .left)
        state.clearHoverSuppression()
        check(!state.shouldSuppressHoverByTime(), "an explicit preview click overrides prior native-click delay")
        check(!state.shouldSuppressUntilDockExit(isStillInDockOrPreview: true), "an explicit preview click clears the old Dock exit latch")
        check(state.consumeSuppressedMouseUpIfNeeded(kind: .left), "resetting hover suppression preserves click pairing")
    }

    static func testFocusNavigation() {
        for keyCode: Int64 in [48, 50] {
            check(DockFocusNavigation.cancelsPendingFocus(keyCode: keyCode, flags: .maskCommand), "new app/window navigation must supersede queued focus")
            check(DockFocusNavigation.cancelsPendingFocus(keyCode: keyCode, flags: [.maskCommand, .maskShift]), "reverse navigation must also supersede queued focus")
            check(!DockFocusNavigation.cancelsPendingFocus(keyCode: keyCode, flags: []), "ordinary tab or text input must preserve the selected focus")
        }
        for keyCode: Int64 in 123...126 {
            check(DockFocusNavigation.cancelsPendingFocus(keyCode: keyCode, flags: .maskControl), "explicit Space navigation must supersede queued focus")
            check(!DockFocusNavigation.cancelsPendingFocus(keyCode: keyCode, flags: []), "ordinary arrows must not cancel focus")
        }
        check(!DockFocusNavigation.cancelsPendingFocus(keyCode: 0, flags: .maskCommand), "unrelated app shortcuts must not cancel focus")
    }

    static func testDockExitDuringTimedSuppression() {
        var uptime: TimeInterval = 100
        var state = DockHoverSuppressionState(clock: { uptime })
        state.suppressHover(for: 0.35, untilDockExit: true)
        check(state.shouldSuppressHover(isStillInDockOrPreview: true), "remaining in Dock keeps suppression")
        uptime += 0.1
        check(state.shouldSuppressHover(isStillInDockOrPreview: false), "early Dock exit must keep only the remaining timed guard")
        uptime += 0.1
        check(state.shouldSuppressHover(isStillInDockOrPreview: true), "quick return still respects the short guard")
        uptime += 0.2
        check(!state.shouldSuppressHover(isStillInDockOrPreview: true), "Dock exit during the timer must allow a new hover after the guard expires")
        var probes = 0
        func observePointer() -> Bool { probes += 1; return true }
        check(!state.shouldSuppressHover(isStillInDockOrPreview: observePointer()), "idle suppression must remain inactive")
        check(probes == 0, "an unlatched timer must not require Dock accessibility probes")
        state.suppressHover(for: 0.35, untilDockExit: true)
        uptime += 0.4
        check(state.shouldSuppressHover(isStillInDockOrPreview: true), "a pointer that never left Dock must remain suppressed after the timer")
        check(!state.shouldSuppressHover(isStillInDockOrPreview: false), "leaving after the timer must also clear suppression")
    }

    static func testContextMenuObservations() {
        var uptime: TimeInterval = 100
        var state = DockHoverSuppressionState(clock: { uptime })
        var observations = 0
        state.suppressDockContextMenu(for: 120)
        check(state.shouldSuppressDockContextMenu { observations += 1; return false }, "opening menu needs grace")
        check(observations == 0, "must not probe before initial grace")
        check(abs((state.dockContextMenuCheckInterval ?? 0) - 0.3) < 0.001, "initial check delay")
        uptime += 0.31
        check(state.shouldSuppressDockContextMenu { nil }, "one unknown observation must not dismiss")
        uptime += 0.31
        check(state.shouldSuppressDockContextMenu { true }, "visible menu resets missing observations")
        uptime += 0.26
        check(state.shouldSuppressDockContextMenu { false }, "first missing observation gets grace")
        uptime += 0.31
        check(!state.shouldSuppressDockContextMenu { nil }, "two missing observations must recover hover")
        check(!state.isSuppressingDockContextMenu && state.dockContextMenuCheckInterval == nil, "cleared menu is idle")
        state.suppressDockContextMenu(for: 1)
        uptime += 1.01
        check(!state.shouldSuppressDockContextMenu { true }, "hard deadline recovers even with stale visibility")
    }

    static func testClickPairing() {
        var state = DockHoverSuppressionState()
        state.holdSuppressedMouseUp(kind: .left)
        check(state.shouldSuppressMouseDrag(kind: .left), "intercepted click owns matching drag")
        check(!state.consumeSuppressedMouseUpIfNeeded(kind: .right), "unrelated button release passes through")
        state.prepareForMouseDown(kind: .right)
        check(state.consumeSuppressedMouseUpIfNeeded(kind: .left), "unrelated button must preserve matching release")
        check(!state.consumeSuppressedMouseUpIfNeeded(kind: .left), "release can be consumed only once")
        state.holdSuppressedMouseUp(kind: .left)
        state.prepareForMouseDown(kind: .left)
        check(!state.shouldSuppressMouseDrag(kind: .left), "new click clears stale interception")
    }

    static func testModifiedClicks() {
        check(MouseDownKind.left.allowsPreviewInterception(eventFlags: []), "plain primary click may open previews")
        for flag: CGEventFlags in [.maskCommand, .maskAlternate, .maskShift, .maskControl, .maskSecondaryFn] {
            check(!MouseDownKind.left.allowsPreviewInterception(eventFlags: flag), "Dock modified clicks must remain native")
        }
        check(MouseDownKind.left.isContextClick(eventFlags: .maskControl), "control-click is a context click")
        check(MouseDownKind.right.isContextClick(eventFlags: []), "secondary click is a context click")
        check(!MouseDownKind.other.allowsPreviewInterception(eventFlags: []), "other buttons pass through")
    }

    static func testDelayedEventFallback() {
        var events = DockMouseDownDeduplicator()
        events.record(kind: .right, timestamp: 100)
        events.record(kind: .left, timestamp: 200)
        check(events.wasHandled(kind: .right, timestamp: 100), "a delayed context-menu fallback must be ignored after a newer preview click")
        check(events.wasHandled(kind: .left, timestamp: 200), "a preview click must not be processed again by AppKit")
        check(!events.wasHandled(kind: .left, timestamp: 300), "a new click missed by the event tap must still reach fallback handling")
    }

    static func testEventIdentityAndFallback() {
        var events = DockMouseDownDeduplicator()
        events.record(kind: .left, timestamp: 500)
        check(!events.wasHandled(kind: .right, timestamp: 500), "different mouse buttons must not collide")
        check(!events.wasHandled(kind: .left, timestamp: 501), "nearby events must not be deduplicated by a timing window")
        check(!events.wasHandled(kind: .left, timestamp: nil), "events without a CGEvent identity retain fallback behavior")
        events.record(kind: .left, timestamp: 0)
        check(!events.wasHandled(kind: .left, timestamp: 0), "unidentified synthetic events cannot share a deduplication key")
    }

    static func testBoundedEventHistory() {
        var events = DockMouseDownDeduplicator(capacity: 2)
        events.record(kind: .left, timestamp: 100)
        events.record(kind: .right, timestamp: 200)
        events.record(kind: .right, timestamp: 200)
        check(events.wasHandled(kind: .left, timestamp: 100), "duplicate tap delivery must not evict other event identities")
        events.record(kind: .other, timestamp: 300)
        check(!events.wasHandled(kind: .left, timestamp: 100), "old event storage must remain bounded")
        check(events.wasHandled(kind: .right, timestamp: 200), "bounded storage retains recent context clicks")
        check(events.wasHandled(kind: .other, timestamp: 300), "bounded storage retains the latest click")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
