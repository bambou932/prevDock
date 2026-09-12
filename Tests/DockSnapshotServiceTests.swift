import AppKit

@main
enum DockSnapshotServiceTests {
    static func main() {
        stableMetadataDoesNotCaptureAgain()
        hidingRejectsSlowCapture()
        reactivationWaitsForOldCaptureWithoutShowingIt()
        explicitRefreshSurvivesPendingProbes()
        permissionLossClearsPixelsAndLateResults()
        initialProbeHasLoadingDeadline()
        changedContextClearsPixelsImmediately()
        failedCaptureHasBackoff()
        slowCaptureCanRecoverAfterDeadline()
        validationProbeMustStartAfterCapture()
        failedCaptureCooldownSurvivesVisibilityInvalidation()
        failedCaptureCooldownSurvivesContextAndReactivation()
        obsoleteCaptureFailureStillHasCooldown()
        print("Dock snapshot service tests passed")
    }

    private static func stableMetadataDoesNotCaptureAgain() {
        let test = Harness()
        test.makeAvailable()
        for _ in 0..<4 {
            test.service.poll()
            test.backend.finishProbe(.visible(test.metadata))
        }
        check(test.backend.captureCount == 1, "unchanged metadata must not capture pixels each second")
        check(test.availableCount == 1, "unchanged metadata must not republish an image")
        test.service.setActive(false)
        test.service.poll()
        check(test.backend.probes.isEmpty, "inactive pages must stop polling")
    }

    private static func hidingRejectsSlowCapture() {
        let test = Harness()
        test.startCapture()
        test.service.poll()
        test.backend.finishProbe(.hidden)
        check(test.last == "hidden", "hidden metadata must immediately clear the image")
        test.backend.finishCapture(test.snapshot)
        test.backend.finishProbe(.hidden)
        check(test.availableCount == 0 && test.last == "hidden", "late capture must not replace hidden state")
        test.service.poll()
        test.backend.finishProbe(.visible(test.metadata))
        check(test.backend.captureCount == 2, "showing the same geometry after hiding requires fresh pixels")
        test.finishCapture()
        check(test.availableCount == 1, "fresh visible capture may display after validation")
    }

    private static func reactivationWaitsForOldCaptureWithoutShowingIt() {
        let test = Harness()
        test.startCapture()
        test.service.setActive(false)
        test.service.setActive(true)
        test.backend.finishProbe(.visible(test.metadata))
        check(test.backend.captureCount == 1, "reactivating cannot overlap the old native capture")
        test.backend.finishCapture(test.snapshot)
        test.backend.finishProbe(.visible(test.metadata))
        check(test.availableCount == 0 && test.backend.captureCount == 2, "old activation pixels cannot display in a new activation")
        test.finishCapture()
        check(test.availableCount == 1, "new activation's validated capture should display")
    }

    private static func explicitRefreshSurvivesPendingProbes() {
        let test = Harness()
        test.startCapture()
        test.service.refresh()
        test.service.poll()
        test.service.poll()
        check(test.backend.probes.count == 1, "only one metadata request may execute")
        test.backend.finishProbe(.visible(test.metadata))
        check(test.backend.probes.count == 1, "periodic requests must coalesce into one latest pending probe")
        test.backend.finishProbe(.visible(test.metadata))
        test.backend.finishCapture(test.snapshot)
        test.backend.finishProbe(.visible(test.metadata))
        check(test.backend.captureCount == 2, "pending explicit content refresh must survive later metadata-only polls")
        test.finishCapture()
        test.service.poll()
        test.backend.finishProbe(.visible(test.metadata))
        check(test.backend.captureCount == 2, "consuming refresh intent must not create a capture loop")
    }

    private static func permissionLossClearsPixelsAndLateResults() {
        let test = Harness()
        test.makeAvailable()
        test.service.refresh()
        test.backend.finishProbe(.visible(test.metadata))
        test.environment.allowed = false
        test.service.poll()
        check(test.last == "permissions", "permission loss must clear the presented image")
        test.backend.finishCapture(test.snapshot)
        check(test.last == "permissions" && test.availableCount == 1, "late pixels cannot bypass revoked permission")
        check(test.backend.probes.isEmpty, "revoked permissions must prevent native probing")
        test.environment.allowed = true
        test.service.poll()
        test.backend.finishProbe(.visible(test.metadata))
        test.finishCapture()
        check(test.availableCount == 2, "permission recovery requires a new capture")
    }

    private static func initialProbeHasLoadingDeadline() {
        let test = Harness()
        test.service.setActive(true)
        test.environment.time = 1.99
        test.service.poll()
        check(test.last == "loading", "initial metadata may load up to two seconds")
        test.environment.time = 2
        test.service.poll()
        check(test.last == "captureFailed", "a slow first metadata response cannot leave permanent loading")
        check(test.backend.probes.count == 1, "a stuck metadata request must not grow the queue")
    }

    private static func changedContextClearsPixelsImmediately() {
        let test = Harness()
        test.makeAvailable()
        test.environment.context = makeContext(windowNumber: 2)
        test.service.poll()
        check(test.last == "loading", "changing the target window must immediately clear incompatible pixels")
        test.environment.time = 2
        test.service.poll()
        check(test.last == "captureFailed", "a changed context also has a finite loading deadline")
        test.service.setActive(false)
        test.backend.finishProbe(.visible(test.metadata))
        check(test.last == "idle", "a closed page must reject late metadata")
    }

    private static func failedCaptureHasBackoff() {
        let test = Harness()
        test.startCapture()
        test.backend.finishCapture(nil)
        check(test.last == "captureFailed", "capture failure needs its own state")
        test.environment.time = 4.99
        test.service.refresh()
        test.backend.finishProbe(.visible(test.metadata))
        check(test.backend.captureCount == 1, "even manual refresh must respect the five-second failed capture backoff")
        test.environment.time = 5
        test.service.poll()
        test.backend.finishProbe(.visible(test.metadata))
        check(test.backend.captureCount == 2, "failed capture may retry after five seconds")
    }

    private static func slowCaptureCanRecoverAfterDeadline() {
        let test = Harness()
        test.startCapture()
        test.environment.time = 2
        test.service.poll()
        check(test.last == "captureFailed", "slow capture must stop showing a loading indicator")
        test.backend.finishProbe(.visible(test.metadata))
        test.finishCapture()
        check(test.last == "available", "a late successful capture may recover after fresh visibility validation")
    }

    private static func validationProbeMustStartAfterCapture() {
        let test = Harness()
        test.startCapture()
        test.service.poll()
        test.backend.finishCapture(test.snapshot)
        test.backend.finishProbe(.visible(test.metadata))
        check(test.availableCount == 0, "a probe started before capture finished cannot validate those pixels")
        check(test.backend.probes.count == 1, "validation must request one fresh post-capture probe")
        test.backend.finishProbe(.hidden)
        check(test.last == "hidden" && test.availableCount == 0, "post-capture hiding must win before any pixels are presented")
    }

    private static func failedCaptureCooldownSurvivesVisibilityInvalidation() {
        for invalidation in [DockSnapshotProbeResult.hidden, .unavailable] {
            let test = Harness()
            test.startCapture()
            test.backend.finishCapture(nil)
            test.environment.time = 1
            test.service.poll()
            test.backend.finishProbe(invalidation)
            test.environment.time = 2
            test.service.poll()
            test.backend.finishProbe(.visible(test.metadata))
            check(test.backend.captureCount == 1, "hidden or unknown metadata must not reset a failed capture's cooldown")
            for time in [4.0, 4.99] {
                test.environment.time = time
                test.service.poll()
                test.backend.finishProbe(.visible(test.metadata))
                check(test.backend.captureCount == 1, "failure cooldown must survive loading UI timeout")
            }
            test.environment.time = 5
            test.service.poll()
            test.backend.finishProbe(.visible(test.metadata))
            check(test.backend.captureCount == 2, "loading UI timeout must not extend the original five-second retry deadline")
        }
    }

    private static func failedCaptureCooldownSurvivesContextAndReactivation() {
        let test = Harness()
        test.startCapture()
        test.backend.finishCapture(nil)
        test.environment.time = 1
        test.service.poll()
        let original = test.metadata
        let moved = DockSnapshotMetadata(context: original.context, display: original.display, windowID: original.windowID,
                                         edge: original.edge, windowBounds: original.windowBounds,
                                         dockRect: original.dockRect.offsetBy(dx: 1, dy: 0),
                                         finderRect: original.finderRect.offsetBy(dx: 1, dy: 0))
        test.backend.finishProbe(.visible(moved))
        check(test.backend.captureCount == 1, "Dock geometry changes must not bypass failure cooldown")
        test.environment.time = 2
        test.environment.context = makeContext(windowNumber: 2)
        test.service.poll()
        test.backend.finishProbe(.visible(test.metadata))
        check(test.backend.captureCount == 1, "switching settings contexts must preserve the remaining cooldown")
        test.environment.time = 3
        test.service.setActive(false)
        test.service.setActive(true)
        test.backend.finishProbe(.visible(test.metadata))
        check(test.backend.captureCount == 1, "reactivation must not reset the service's failed capture budget")
        test.environment.time = 5
        test.service.poll()
        test.backend.finishProbe(.visible(test.metadata))
        check(test.backend.captureCount == 2, "the new context should retry automatically at the original deadline")
    }

    private static func obsoleteCaptureFailureStillHasCooldown() {
        let test = Harness()
        test.startCapture()
        test.service.setActive(false)
        test.environment.time = 1
        test.backend.finishCapture(nil)
        check(test.last == "idle", "an obsolete failed capture cannot change inactive UI state")
        test.environment.time = 2
        test.service.setActive(true)
        test.backend.finishProbe(.visible(test.metadata))
        check(test.backend.captureCount == 1, "a native failure while inactive still throttles the next capture")
        test.environment.time = 5.99
        test.service.poll()
        test.backend.finishProbe(.visible(test.metadata))
        check(test.backend.captureCount == 1, "cooldown begins at actual failure completion")
        test.environment.time = 6
        test.service.poll()
        test.backend.finishProbe(.visible(test.metadata))
        check(test.backend.captureCount == 2, "the queued active context may retry after the actual failure deadline")
    }

    private static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
    }

    private static func makeContext(windowNumber: Int = 1) -> DockSnapshotContext {
        DockSnapshotContext(windowNumber: windowNumber, preferredDisplayID: 1,
                            displays: [DockSnapshotDisplay(id: 1, name: "Test display", frame: CGRect(x: 0, y: 0, width: 1200, height: 900),
                                                           visibleFrame: CGRect(x: 0, y: 70, width: 1200, height: 805), backingScaleFactor: 2)],
                            referenceMaxY: 900, dockPID: 42)
    }

    private final class Environment {
        var time: TimeInterval = 0
        var allowed = true
        var context = makeContext()
    }

    private final class Harness {
        let environment = Environment()
        let backend = FakeBackend()
        let service: DockSnapshotService
        var events = [String]()
        var last: String { events.last ?? "none" }
        var availableCount: Int { events.filter { $0 == "available" }.count }
        var metadata: DockSnapshotMetadata {
            DockSnapshotMetadata(context: environment.context, display: environment.context.displays[0], windowID: 10,
                                 edge: .bottom, windowBounds: CGRect(x: 200, y: 815, width: 800, height: 85),
                                 dockRect: CGRect(x: 200, y: 820, width: 800, height: 80), finderRect: CGRect(x: 212, y: 830, width: 60, height: 60))
        }
        var snapshot: DockSnapshot {
            DockSnapshot(image: NSImage(size: NSSize(width: 800, height: 85)),
                         geometry: DockSnapshotGeometry(edge: .bottom, imageSize: NSSize(width: 800, height: 85),
                                                        dockRectInImage: CGRect(x: 0, y: 0, width: 800, height: 80), finderRectInImage: CGRect(x: 12, y: 10, width: 60, height: 60)),
                         dockRect: environment.context.appKitRect(metadata.dockRect), finderRect: environment.context.appKitRect(metadata.finderRect),
                         screenFrame: metadata.display.frame, screenVisibleFrame: metadata.display.visibleFrame,
                         displayID: 1, displayName: "Test display", backingScaleFactor: 2)
        }

        init() {
            let environment = self.environment
            service = DockSnapshotService(contextProvider: { environment.context }, backend: backend,
                                          permissions: { environment.allowed }, now: { environment.time }, schedulesTimers: false)
            service.onChange = { [weak self] state in
                switch state {
                case .idle: self?.events.append("idle")
                case .loading: self?.events.append("loading")
                case .available: self?.events.append("available")
                case .unavailable(let reason): self?.events.append(String(describing: reason))
                }
            }
        }

        func startCapture() {
            service.setActive(true)
            backend.finishProbe(.visible(metadata))
        }

        func finishCapture() {
            backend.finishCapture(snapshot)
            backend.finishProbe(.visible(metadata))
        }

        func makeAvailable() {
            startCapture()
            finishCapture()
        }
    }

    private final class FakeBackend: DockSnapshotBackendProviding {
        var probes = [(DockSnapshotProbeResult) -> Void]()
        var captures = [(DockSnapshot?) -> Void]()
        var captureCount = 0
        func probe(context: DockSnapshotContext, completion: @escaping (DockSnapshotProbeResult) -> Void) { probes.append(completion) }
        func capture(metadata: DockSnapshotMetadata, completion: @escaping (DockSnapshot?) -> Void) {
            captureCount += 1
            captures.append(completion)
        }
        func finishProbe(_ result: DockSnapshotProbeResult) { probes.removeFirst()(result) }
        func finishCapture(_ snapshot: DockSnapshot?) { captures.removeFirst()(snapshot) }
    }
}

final class DockSnapshotBackend: DockSnapshotBackendProviding {
    func probe(context: DockSnapshotContext, completion: @escaping (DockSnapshotProbeResult) -> Void) { fatalError("Native backend must not run in unit tests") }
    func capture(metadata: DockSnapshotMetadata, completion: @escaping (DockSnapshot?) -> Void) { fatalError("Native backend must not run in unit tests") }
}

enum PermissionManager {
    struct Status { let allGranted: Bool }
    static let status = Status(allGranted: true)
    static let didChangeNotification = Notification.Name("TestPermissionsChanged")
}

enum ScreenGeometry { static let appKitReferenceMaxY: CGFloat = 900 }
