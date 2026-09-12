import AppKit
import CoreGraphics

final class DockSnapshotService: DockSnapshotProviding {
    var onChange: ((DockSnapshotState) -> Void)?
    private(set) var state = DockSnapshotState.idle
    private let contextProvider: () -> DockSnapshotContext?
    private let backend: DockSnapshotBackendProviding
    private let permissions: () -> Bool
    private let now: () -> TimeInterval
    private let schedulesTimers: Bool
    private var timer: Timer?
    private var observers = [(NotificationCenter, NSObjectProtocol)]()
    private var active = false
    private var context: DockSnapshotContext?
    private var generation: UInt64 = 0
    private var revision: UInt64 = 0
    private var completedRevision: UInt64?
    private var metadata: DockSnapshotMetadata?
    private var probeInFlight = false
    private var probeSequence: UInt64 = 0
    private var pendingProbe = false
    private var captureInFlight = false
    private var awaitingValidation: DockSnapshotPendingImage?
    private var nextCaptureAt: TimeInterval = 0
    private var loadingStartedAt: TimeInterval?

    init(
        contextProvider: @escaping () -> DockSnapshotContext?,
        backend: DockSnapshotBackendProviding = DockSnapshotBackend(),
        permissions: @escaping () -> Bool = { PermissionManager.status.allGranted },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedulesTimers: Bool = true
    ) {
        self.contextProvider = contextProvider
        self.backend = backend
        self.permissions = permissions
        self.now = now
        self.schedulesTimers = schedulesTimers
    }

    deinit {
        timer?.invalidate()
        observers.forEach { $0.0.removeObserver($0.1) }
    }

    func setActive(_ active: Bool) {
        precondition(Thread.isMainThread)
        guard self.active != active else { return }
        self.active = active
        guard active else {
            stopMonitoring()
            invalidatePixels()
            context = nil
            publish(.idle)
            return
        }
        installMonitoring()
        beginLoading()
        refresh()
    }

    func refresh() {
        precondition(Thread.isMainThread)
        guard active else { return }
        // Content refresh intent survives a later periodic probe replacing pending work.
        revision &+= 1
        poll()
    }

    func poll() {
        precondition(Thread.isMainThread)
        guard active else { return }
        expireLoading()
        guard updateContext(), permissions() else {
            invalidatePixels()
            publish(.unavailable(context == nil ? .unavailable : .permissions))
            return
        }
        requestProbe()
    }

    private func updateContext() -> Bool {
        let current = contextProvider()
        if current != context {
            context = current
            invalidatePixels()
            if current != nil { beginLoading() }
        }
        return context != nil
    }

    private func requestProbe() {
        guard let context else { return }
        guard !probeInFlight else {
            pendingProbe = true
            return
        }
        probeInFlight = true
        pendingProbe = false
        probeSequence &+= 1
        let sequence = probeSequence
        let requestGeneration = generation
        backend.probe(context: context) { [weak self] result in
            self?.finishProbe(result, context: context, generation: requestGeneration, sequence: sequence)
        }
    }

    private func finishProbe(_ result: DockSnapshotProbeResult, context requested: DockSnapshotContext, generation requestedGeneration: UInt64, sequence: UInt64) {
        probeInFlight = false
        guard active else { return }
        guard updateContext(), permissions() else {
            invalidatePixels()
            publish(.unavailable(context == nil ? .unavailable : .permissions))
            return
        }
        if requested == context, requestedGeneration == generation {
            consume(result, probeSequence: sequence)
        } else {
            pendingProbe = true
        }
        if pendingProbe { requestProbe() }
    }

    private func consume(_ result: DockSnapshotProbeResult, probeSequence: UInt64) {
        switch result {
        case .visible(let metadata): consumeVisible(metadata, probeSequence: probeSequence)
        case .hidden:
            invalidatePixels()
            publish(.unavailable(.hidden))
        case .unavailable:
            invalidatePixels()
            publish(.unavailable(.unavailable))
        }
    }

    private func consumeVisible(_ current: DockSnapshotMetadata, probeSequence: UInt64) {
        if metadata?.matchesCapture(current) != true {
            invalidatePixels()
            metadata = current
            beginLoading()
        } else {
            metadata = current
        }
        if let pending = awaitingValidation,
           pending.generation == generation, pending.metadata.matchesCapture(current),
           probeSequence > pending.validationAfterProbe {
            awaitingValidation = nil
            completedRevision = pending.revision
            loadingStartedAt = nil
            nextCaptureAt = 0
            publish(.available(pending.snapshot))
        }
        startCaptureIfNeeded()
    }

    private func startCaptureIfNeeded() {
        guard active, let metadata, !captureInFlight, awaitingValidation == nil,
              completedRevision != revision, now() >= nextCaptureAt else { return }
        captureInFlight = true
        let requestGeneration = generation
        let requestRevision = revision
        backend.capture(metadata: metadata) { [weak self] snapshot in
            self?.finishCapture(snapshot, metadata: metadata, generation: requestGeneration, revision: requestRevision)
        }
    }

    private func finishCapture(_ snapshot: DockSnapshot?, metadata requested: DockSnapshotMetadata, generation requestedGeneration: UInt64, revision requestedRevision: UInt64) {
        captureInFlight = false
        // Native failures are rate-limited even when their presentation has become obsolete.
        if snapshot == nil { nextCaptureAt = now() + 5 }
        guard active else { return }
        guard updateContext(), permissions() else {
            invalidatePixels()
            publish(.unavailable(context == nil ? .unavailable : .permissions))
            return
        }
        guard requestedGeneration == generation, metadata?.matchesCapture(requested) == true else {
            requestProbe()
            return
        }
        guard let snapshot else {
            awaitingValidation = nil
            loadingStartedAt = nil
            publish(.unavailable(.captureFailed))
            return
        }
        awaitingValidation = DockSnapshotPendingImage(snapshot: snapshot, metadata: requested,
                                                      generation: requestedGeneration, revision: requestedRevision,
                                                      validationAfterProbe: probeSequence)
        // Recheck visibility after capture. SkyLight itself is synchronous and cannot be canceled.
        requestProbe()
    }

    private func invalidatePixels() {
        generation &+= 1
        metadata = nil
        awaitingValidation = nil
        completedRevision = nil
        loadingStartedAt = nil
        pendingProbe = false
    }

    private func beginLoading() {
        loadingStartedAt = now()
        publish(.loading)
    }

    private func expireLoading() {
        guard let started = loadingStartedAt, now() - started >= 2 else { return }
        loadingStartedAt = nil
        publish(.unavailable(.captureFailed))
    }

    private func publish(_ next: DockSnapshotState) {
        if case .unavailable(let previous) = state, case .unavailable(let current) = next, previous == current { return }
        state = next
        onChange?(next)
    }

    private func installMonitoring() {
        guard schedulesTimers else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        observe(NotificationCenter.default, names: [PermissionManager.didChangeNotification,
                NSApplication.didChangeScreenParametersNotification, NSApplication.didBecomeActiveNotification])
        observe(NSWorkspace.shared.notificationCenter, names: [NSWorkspace.activeSpaceDidChangeNotification,
                NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                NSWorkspace.didWakeNotification])
    }

    private func observe(_ center: NotificationCenter, names: [Notification.Name]) {
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
            observers.append((center, token))
        }
    }

    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        observers.forEach { $0.0.removeObserver($0.1) }
        observers = []
    }
}

private struct DockSnapshotPendingImage {
    let snapshot: DockSnapshot
    let metadata: DockSnapshotMetadata
    let generation: UInt64
    let revision: UInt64
    let validationAfterProbe: UInt64
}

extension DockSnapshotContext {
    static func current(window: NSWindow?) -> DockSnapshotContext? {
        guard let window else { return nil }
        let displays = NSScreen.screens.compactMap { screen -> DockSnapshotDisplay? in
            guard let id = displayID(screen) else { return nil }
            return DockSnapshotDisplay(id: id, name: screen.localizedName, frame: screen.frame,
                                       visibleFrame: screen.visibleFrame, backingScaleFactor: screen.backingScaleFactor)
        }
        guard !displays.isEmpty else { return nil }
        return DockSnapshotContext(windowNumber: window.windowNumber, preferredDisplayID: window.screen.flatMap(displayID),
                                   displays: displays, referenceMaxY: ScreenGeometry.appKitReferenceMaxY,
                                   dockPID: NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier)
    }

    private static func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
