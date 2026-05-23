import Cocoa
import CoreGraphics

final class DockMouseEventSuppressor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var rectRefreshTimer: Timer?
    var onSuppressedMouseMoved: (() -> Void)?

    var isRunning: Bool {
        eventTap != nil
    }

    func updateForCurrentSettings() {
        if PrevDockSettings.nativeDockLabelSuppressionEnabled {
            start()
        } else {
            stop()
        }
    }

    func start() {
        guard eventTap == nil else {
            DockGeometryCache.shared.refreshNow()
            return
        }

        DockGeometryCache.shared.refreshNow()
        startRectRefreshTimer()

        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventCallback,
            userInfo: refcon
        ) else {
            rectRefreshTimer?.invalidate()
            rectRefreshTimer = nil
            NSLog("prevDock: failed to install Dock mouse event suppressor")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        rectRefreshTimer?.invalidate()
        rectRefreshTimer = nil
    }

    private static let eventCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let suppressor = Unmanaged<DockMouseEventSuppressor>.fromOpaque(refcon).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = suppressor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .mouseMoved else {
            return Unmanaged.passUnretained(event)
        }

        let point = DockCursorTracker.shared.updateFromEventTap(quartzPoint: event.location)
        guard suppressor.isRunning,
              DockGeometryCache.shared.isInNativeLabelSuppressionStrip(point, refreshIfStale: false) else {
            return Unmanaged.passUnretained(event)
        }

        suppressor.notifySuppressedMouseMoved()
        return nil
    }

    private func notifySuppressedMouseMoved() {
        if Thread.isMainThread {
            onSuppressedMouseMoved?()
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.onSuppressedMouseMoved?()
        }
    }

    private func startRectRefreshTimer() {
        let timer = Timer(timeInterval: 10, repeats: true) { _ in
            DockGeometryCache.shared.refreshNow()
        }
        rectRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
