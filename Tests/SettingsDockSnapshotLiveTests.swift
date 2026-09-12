import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

@main
private enum SettingsDockSnapshotLiveTests {
    static let identifier = "io.github.bambou932.prevDock.tests.settings-dock-snapshot-live"

    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.count == 2, arguments[0] == "--restore-desktop" {
                try DockDesktopState.restore(from: URL(fileURLWithPath: arguments[1]))
                return
            }
            guard (1...2).contains(arguments.count), arguments.count == 1 || arguments[1] == "--inspect",
                  Bundle.main.bundleIdentifier == identifier else {
                throw LiveFailure("Run the packaged harness with <report-directory> [--inspect]")
            }
            try exercise(directory: URL(fileURLWithPath: arguments[0]), inspect: arguments.count == 2)
        } catch {
            LiveHarness.emit(["event": "failure", "message": String(describing: error)])
            exit(1)
        }
    }

    private static func exercise(directory: URL, inspect: Bool) throws {
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
            throw LiveFailure("Existing Accessibility and Screen Recording access are required; no permission prompt was requested")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stateURL = directory.appendingPathComponent("desktop-state.plist")
        let desktop = try DockDesktopState.save(to: stateURL)
        LiveHarness.installSignalHandlers()
        var testError: Error?
        var session: SnapshotLiveSession?
        do {
            try desktop.stopPrevDock()
            UserDefaults.standard.removePersistentDomain(forName: identifier)
            PrevDockSettings.registerDefaults()
            session = SnapshotLiveSession(directory: directory)
            if inspect { try session?.inspect() } else { try session?.exerciseConfigurations() }
        } catch { testError = error }
        session?.close()
        session = nil
        UserDefaults.standard.removePersistentDomain(forName: identifier)
        UserDefaults.standard.synchronize()
        try DockDesktopState.restore(from: stateURL)
        if let testError { throw testError }
        LiveHarness.emit(["event": "passed", "mode": inspect ? "inspect" : "all-configurations"])
    }
}

private final class SnapshotLiveSession {
    private let directory: URL
    private let window: NSWindow
    private let backend = CountingDockSnapshotBackend()
    private var observedState = DockSnapshotState.idle
    private var availableDeliveries = 0
    private var phase = "starting"
    private lazy var service = DockSnapshotService(contextProvider: { [weak self] in
        DockSnapshotContext.current(window: self?.window)
    }, backend: backend)
    private lazy var provider = ObservingDockSnapshotProvider(service: service) { [weak self] state in
        self?.observe(state)
    }
    private lazy var stage = SettingsPreviewStage(snapshotProvider: provider)

    init(directory: URL) {
        self.directory = directory
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.finishLaunching()
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: screen.minX + 50, y: screen.minY + 50,
                           width: min(1200, screen.width - 100), height: min(720, screen.height - 100))
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "prevDock · Real Dock Snapshot Verification"
        window.isReleasedWhenClosed = false
        window.contentView = stage
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        stage.setPageActive(false)
    }

    func close() {
        stage.setPageActive(false)
        window.orderOut(nil)
        window.close()
    }

    func inspect() throws {
        phase = "inspect"
        stage.setPageActive(true)
        LiveHarness.emit(["event": "inspect-ready", "duration_seconds": 90,
                          "window_number": window.windowNumber, "pid": ProcessInfo.processInfo.processIdentifier])
        try LiveHarness.wait(seconds: 90)
        try saveStage(named: "inspect-final")
    }

    func exerciseConfigurations() throws {
        for edge in DockSnapshotEdge.allCases {
            for autoHide in [false, true] {
                try exercise(edge: edge, autoHide: autoHide)
            }
        }
        try require(WindowPeekController.unexpectedInteractions == 0, "sample cards invoked real-window actions")
    }

    private func exercise(edge: DockSnapshotEdge, autoHide: Bool) throws {
        stage.setPageActive(false)
        phase = "\(edge.rawValue)-\(autoHide ? "autohide" : "visible")"
        try DockDesktopState.configure(edge: edge, autoHide: autoHide)
        moveAwayFromDock()
        try LiveHarness.wait(seconds: 1.2)
        stage.setPageActive(true)
        if autoHide {
            try LiveHarness.eventually("auto-hidden Dock should report hidden") {
                if case .unavailable(.hidden) = self.observedState { return true }
                return false
            }
            try require((descendant(identifier: "prevDock.settings.dockSnapshot") as? NSImageView)?.image == nil,
                        "hidden Dock retained captured pixels")
            try require(descendant(identifier: "prevDock.settings.dockSnapshotCrop")?.isHidden == true,
                        "hidden Dock left a visible image crop")
            LiveHarness.emit(record(event: "hidden", snapshot: nil))
            revealDock(edge: edge)
            try LiveHarness.wait(seconds: 1.2)
        }
        try LiveHarness.eventually("Dock snapshot and sample should become ready") {
            guard case .available(let snapshot) = self.observedState,
                  snapshot.geometry.edge == edge else { return false }
            return self.sampleIsReady
        }
        guard case .available(let snapshot) = observedState else { throw LiveFailure("available snapshot disappeared") }
        try validate(snapshot, expectedEdge: edge)
        try saveStage(named: phase)
        LiveHarness.emit(record(event: "ready", snapshot: snapshot))
        try verifyAppearanceChangesDoNotCapture()
        try verifyInactiveStageDoesNotCapture()
    }

    private func validate(_ snapshot: DockSnapshot, expectedEdge: DockSnapshotEdge) throws {
        let geometry = snapshot.geometry
        let imageBounds = CGRect(origin: .zero, size: geometry.imageSize)
        try require(geometry.edge == expectedEdge, "snapshot orientation differs from the actual Dock preference")
        try require(snapshot.image.size == geometry.imageSize, "captured image point size differs from geometry")
        try require(imageBounds.insetBy(dx: -1, dy: -1).contains(geometry.dockRectInImage), "Dock crop extends outside its image")
        try require(imageBounds.insetBy(dx: -1, dy: -1).contains(geometry.finderRectInImage), "Finder anchor extends outside its image")
        let imageOrigin = CGPoint(x: snapshot.dockRect.minX - geometry.dockRectInImage.minX,
                                  y: snapshot.dockRect.minY - geometry.dockRectInImage.minY)
        let imageFinder = geometry.finderRectInImage.offsetBy(dx: imageOrigin.x, dy: imageOrigin.y)
        try require(abs(imageFinder.minX - snapshot.finderRect.minX) < 1 &&
                    abs(imageFinder.minY - snapshot.finderRect.minY) < 1 &&
                    abs(imageFinder.width - snapshot.finderRect.width) < 1 &&
                    abs(imageFinder.height - snapshot.finderRect.height) < 1,
                    "Finder global and captured-image coordinates disagree")
        try require(snapshot.screenFrame.intersects(snapshot.finderRect), "Finder is not on the reported display")
        try require(snapshot.finderRect.width > 0 && snapshot.finderRect.height > 0, "Finder anchor is empty")
        try require(sampleIsReady, "appearance stage contains no ready sample card")
        try require(stage.window === window && !stage.isHiddenOrHasHiddenAncestor, "sample stage is detached or hidden")
        try require(backend.captureCount > 0, "no production backend capture was requested")
        stage.layoutSubtreeIfNeeded()
        guard let dockImage = descendant(identifier: "prevDock.settings.dockSnapshot") as? NSImageView else {
            throw LiveFailure("stage does not contain the Dock image view")
        }
        try require(dockImage.image === snapshot.image, "stage did not install the latest native Dock image")
        try require(dockImage.imageScaling == .scaleNone && dockImage.frame.size == snapshot.image.size,
                    "Dock image is scaled instead of displayed at its real point size")
    }

    private func verifyInactiveStageDoesNotCapture() throws {
        stage.setPageActive(false)
        try LiveHarness.wait(seconds: 0.3)
        let captures = backend.captureCount
        for height in PreviewWindowHeight.allCases {
            PrevDockSettings.previewWindowHeight = height
            stage.refresh()
        }
        try LiveHarness.wait(seconds: 1.2)
        try require(backend.captureCount == captures, "an inactive appearance stage requested capture")
        PrevDockSettings.previewWindowHeight = .regular
        LiveHarness.emit(record(event: "inactive", snapshot: nil))
    }

    private func verifyAppearanceChangesDoNotCapture() throws {
        let captures = backend.captureCount
        for height in PreviewWindowHeight.allCases {
            PrevDockSettings.previewWindowHeight = height
            stage.refresh()
        }
        try LiveHarness.wait(seconds: 1.2)
        try require(backend.captureCount == captures, "sample preference changes recaptured an unchanged Dock")
        try require(sampleIsReady, "sample preferences removed the ready preview")
        PrevDockSettings.previewWindowHeight = .regular
        stage.refresh()
        LiveHarness.emit(record(event: "appearance-updated", snapshot: observedState.snapshot))
    }

    private var sampleCards: [PreviewCardView] {
        descendants(stage).compactMap { $0 as? PreviewCardView }
    }

    private var sampleIsReady: Bool {
        !sampleCards.isEmpty && sampleCards.allSatisfy { ($0.accessibilityValue() as? String) == "Ready" }
    }

    private func observe(_ state: DockSnapshotState) {
        observedState = state
        if case .available = state { availableDeliveries += 1 }
        LiveHarness.emit(record(event: "state", snapshot: state.snapshot))
    }

    private func record(event: String, snapshot: DockSnapshot?) -> [String: Any] {
        var result: [String: Any] = [
            "event": event, "phase": phase, "state": observedState.label,
            "probe_count": backend.probeCount, "capture_count": backend.captureCount,
            "available_deliveries": availableDeliveries, "sample_ready": sampleIsReady,
            "sample_count": sampleCards.count, "stage_frame": LiveHarness.rect(stage.frame),
            "sample_frames": sampleCards.map { LiveHarness.rect(stage.convert($0.bounds, from: $0)) },
            "frontmost_pid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        ]
        for (key, identifier) in [("dock_image_frame", "prevDock.settings.dockSnapshot"),
                                  ("dock_crop_frame", "prevDock.settings.dockSnapshotCrop"),
                                  ("preview_panel_frame", "prevDock.settings.samplePreviewPanel")] {
            if let view = descendant(identifier: identifier) {
                result[key] = LiveHarness.rect(stage.convert(view.bounds, from: view))
            }
        }
        if let snapshot {
            result["edge"] = snapshot.geometry.edge.rawValue
            result["dock_frame"] = LiveHarness.rect(snapshot.dockRect)
            result["finder_frame"] = LiveHarness.rect(snapshot.finderRect)
            result["dock_in_image"] = LiveHarness.rect(snapshot.geometry.dockRectInImage)
            result["finder_in_image"] = LiveHarness.rect(snapshot.geometry.finderRectInImage)
            result["image_size"] = [snapshot.image.size.width, snapshot.image.size.height]
            result["display_id"] = snapshot.displayID
            result["screen_frame"] = LiveHarness.rect(snapshot.screenFrame)
            result["backing_scale"] = snapshot.backingScaleFactor
        }
        return result
    }

    private func saveStage(named name: String) throws {
        stage.layoutSubtreeIfNeeded()
        guard let bitmap = stage.bitmapImageRepForCachingDisplay(in: stage.bounds) else { throw LiveFailure("could not allocate stage screenshot") }
        stage.cacheDisplay(in: stage.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw LiveFailure("could not encode stage screenshot") }
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func moveAwayFromDock() {
        let screen = window.screen?.frame ?? NSScreen.screens[0].frame
        LiveHarness.move(toAppKitPoint: CGPoint(x: screen.midX, y: screen.midY))
    }

    private func revealDock(edge: DockSnapshotEdge) {
        let screen = window.screen?.frame ?? NSScreen.screens[0].frame
        switch edge {
        case .bottom: LiveHarness.move(toAppKitPoint: CGPoint(x: screen.midX, y: screen.minY + 1))
        case .left: LiveHarness.move(toAppKitPoint: CGPoint(x: screen.minX + 1, y: screen.midY))
        case .right: LiveHarness.move(toAppKitPoint: CGPoint(x: screen.maxX - 1, y: screen.midY))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func descendant(identifier: String) -> NSView? {
        descendants(stage).first { $0.accessibilityIdentifier() == identifier }
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw LiveFailure("\(phase): \(message)") }
    }
}

private final class ObservingDockSnapshotProvider: DockSnapshotProviding {
    var onChange: ((DockSnapshotState) -> Void)?
    private let service: DockSnapshotProviding

    init(service: DockSnapshotProviding, observe: @escaping (DockSnapshotState) -> Void) {
        self.service = service
        service.onChange = { [weak self] state in
            self?.onChange?(state)
            observe(state)
        }
    }

    func setActive(_ active: Bool) { service.setActive(active) }
    func refresh() { service.refresh() }
}

private final class CountingDockSnapshotBackend: DockSnapshotBackendProviding {
    private let backend = DockSnapshotBackend()
    private(set) var probeCount = 0
    private(set) var captureCount = 0

    func probe(context: DockSnapshotContext, completion: @escaping (DockSnapshotProbeResult) -> Void) {
        probeCount += 1
        backend.probe(context: context, completion: completion)
    }

    func capture(metadata: DockSnapshotMetadata, completion: @escaping (DockSnapshot?) -> Void) {
        captureCount += 1
        backend.capture(metadata: metadata, completion: completion)
    }
}

private extension DockSnapshotState {
    var snapshot: DockSnapshot? {
        if case .available(let snapshot) = self { return snapshot }
        return nil
    }

    var label: String {
        switch self {
        case .idle: return "idle"
        case .loading: return "loading"
        case .available: return "available"
        case .unavailable(let reason): return "unavailable.\(reason)"
        }
    }
}

private struct DockDesktopState {
    private static let domain = "com.apple.dock" as CFString
    private static let keys = ["orientation", "autohide"]
    private let values: [String: Any]

    static func save(to url: URL) throws -> DockDesktopState {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw LiveFailure("unrestored desktop-state.plist already exists") }
        guard !keys.contains(where: { CFPreferencesAppValueIsForced($0 as CFString, domain) }) else {
            throw LiveFailure("Dock orientation/autohide is managed and cannot be varied by this harness")
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let preview = NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.bambou932.prevDock").first
        let mouse = CGEvent(source: nil)?.location ?? .zero
        var dock = [String: Any]()
        for key in keys {
            if let value = CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) { dock[key] = value }
        }
        var values: [String: Any] = ["dock": dock, "mouse": [mouse.x, mouse.y], "frontmostPID": frontmost?.processIdentifier ?? -1]
        if let url = preview?.bundleURL { values["previewURL"] = url.path }
        if let bundle = frontmost?.bundleIdentifier { values["frontmostBundleID"] = bundle }
        try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: url)
        return DockDesktopState(values: values)
    }

    func stopPrevDock() throws {
        guard values["previewURL"] != nil,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.bambou932.prevDock").first else { return }
        _ = app.terminate()
        try LiveHarness.eventually("running prevDock did not quit") { app.isTerminated }
    }

    static func configure(edge: DockSnapshotEdge, autoHide: Bool) throws {
        CFPreferencesSetValue("orientation" as CFString, edge.rawValue as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSetValue("autohide" as CFString, autoHide ? kCFBooleanTrue : kCFBooleanFalse, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        try synchronizeAndRestartDock()
    }

    static func restore(from url: URL) throws {
        LiveHarness.isRestoring = true
        defer { LiveHarness.isRestoring = false }
        let raw = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil)
        guard let values = raw as? [String: Any], let dock = values["dock"] as? [String: Any] else { throw LiveFailure("invalid saved desktop state") }
        var errors = [String]()
        do { try restoreDock(dock) } catch { errors.append(String(describing: error)) }
        if let path = values["previewURL"] as? String,
           NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.bambou932.prevDock").isEmpty {
            do { try reopenPrevDock(at: path) } catch { errors.append(String(describing: error)) }
        }
        if let point = values["mouse"] as? [NSNumber], point.count == 2 {
            LiveHarness.move(quartzPoint: CGPoint(x: point[0].doubleValue, y: point[1].doubleValue))
        }
        let pid = (values["frontmostPID"] as? NSNumber)?.int32Value ?? -1
        let app = NSRunningApplication(processIdentifier: pid) ?? (values["frontmostBundleID"] as? String).flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
        }
        if let app, !app.isTerminated {
            _ = app.activate(options: [])
            do {
                try LiveHarness.eventually("original frontmost app did not reactivate") {
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
                }
            } catch { errors.append(String(describing: error)) }
        }
        guard errors.isEmpty else { throw LiveFailure("Desktop restoration: " + errors.joined(separator: "; ")) }
        try FileManager.default.removeItem(at: url)
        LiveHarness.emit(["event": "desktop-restored"])
    }

    private static func restoreDock(_ dock: [String: Any]) throws {
        let changed = keys.filter { key in
            let current = CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            if current == nil && dock[key] == nil { return false }
            guard let current, let saved = dock[key] else { return true }
            return !CFEqual(current, saved as CFTypeRef)
        }
        guard !changed.isEmpty else { return }
        for key in changed {
            CFPreferencesSetValue(key as CFString, dock[key] as CFPropertyList?, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        try synchronizeAndRestartDock()
    }

    private static func synchronizeAndRestartDock() throws {
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { throw LiveFailure("Dock preference synchronization failed") }
        let old = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        if let old { guard kill(old, SIGTERM) == 0 else { throw LiveFailure("could not restart the owned Dock process") } }
        try LiveHarness.eventually("Dock did not restart") {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return false }
            return app.processIdentifier != old && !app.isTerminated
        }
    }

    private static func reopenPrevDock(at path: String) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        var completed = false
        var launchError: Error?
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration) { _, error in
            DispatchQueue.main.async { launchError = error; completed = true }
        }
        try LiveHarness.eventually("prevDock did not reopen") { completed }
        if let launchError { throw launchError }
    }
}

private struct LiveFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

private enum LiveHarness {
    private static var interrupted = false
    private static var signalSources = [DispatchSourceSignal]()
    static var isRestoring = false

    static func installSignalHandlers() {
        for value in [SIGINT, SIGTERM, SIGHUP] {
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
            source.setEventHandler { interrupted = true }
            source.resume()
            signalSources.append(source)
        }
    }

    static func eventually(_ message: String, condition: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        repeat {
            try checkInterrupted()
            if condition() { return }
            pumpEvents()
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw LiveFailure(message)
    }

    static func wait(seconds: TimeInterval) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            try checkInterrupted()
            pumpEvents()
        } while ProcessInfo.processInfo.systemUptime < deadline
    }

    private static func checkInterrupted() throws {
        if interrupted && !isRestoring { throw LiveFailure("verification interrupted; restoring desktop") }
    }

    private static func pumpEvents() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        guard let application = NSApp else { return }
        while let event = application.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
            application.sendEvent(event)
        }
        application.updateWindows()
    }

    static func move(toAppKitPoint point: CGPoint) {
        move(quartzPoint: CGPoint(x: point.x, y: ScreenGeometry.appKitReferenceMaxY - point.y))
    }

    static func move(quartzPoint point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    static func rect(_ rect: CGRect) -> [CGFloat] { [rect.minX, rect.minY, rect.width, rect.height] }

    static func emit(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
        fflush(stdout)
    }
}

// Sample cards link this inert action boundary; Dock discovery, capture, permission and screen APIs remain real.
final class WindowPeekController {
    static let shared = WindowPeekController()
    static var unexpectedInteractions = 0
    func show(preview: WindowPreview) { Self.unexpectedInteractions += 1 }
    func updateSnapshot(preview: WindowPreview) { Self.unexpectedInteractions += 1 }
    func hide() { Self.unexpectedInteractions += 1 }
    func hide(windowID: CGWindowID) { Self.unexpectedInteractions += 1 }
}
