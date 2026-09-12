import Cocoa

@main
enum DockPreviewRefreshTests {
    private static let app = NSRunningApplication.current

    static func main() {
        testMetadataCancellationDoesNotConsumeNewRequest()
        testClickValidationOwnsItsMetadataRequest()
        testThumbnailTargetGenerationRejectsRoundTrips()
        testMissingOnlyThumbnailsKeepTheCaptureBudget()
        testCanceledWarmupCanRetryImmediately()
        testSpaceChangeRejectsOldWarmupCompletion()
        print("Dock preview refresh tests passed")
    }

    private static func testMetadataCancellationDoesNotConsumeNewRequest() {
        WindowInventory.reset()
        let refreshes = DockPreviewRefreshController()
        defer { withExtendedLifetime(refreshes) {} }
        var delivered = [String]()
        refreshes.refreshMetadata(for: app, targetKey: "old") { _, _ in delivered.append("old") }
        refreshes.refreshMetadata(for: app, targetKey: "old") { _, _ in delivered.append("duplicate") }
        check(WindowInventory.metadata.count == 1, "one metadata request owns the pending slot")
        refreshes.cancelRefreshRequests(except: "new")
        check(!WindowInventory.metadata[0].request.isActive, "switching targets cancels the old subscriber")
        refreshes.refreshMetadata(for: app, targetKey: "new") { _, _ in delivered.append("new") }
        WindowInventory.metadata[0].completion([])
        check(delivered.isEmpty, "a queued completion from the old target must be ignored")
        WindowInventory.metadata[1].completion([])
        check(delivered == ["new"], "the old completion must not consume the replacement request")
    }

    private static func testClickValidationOwnsItsMetadataRequest() {
        WindowInventory.reset()
        let refreshes = DockPreviewRefreshController()
        defer { withExtendedLifetime(refreshes) {} }
        var delivered = [String]()
        refreshes.refreshMetadata(for: app, targetKey: "app") { _, _ in delivered.append("hover") }
        refreshes.refreshClickValidation(for: app, targetKey: "app") { _ in delivered.append("click") }
        check(!WindowInventory.metadata[0].request.isActive, "click validation replaces the hover subscriber")
        refreshes.refreshMetadata(for: app, targetKey: "app") { _, _ in delivered.append("overlap") }
        check(WindowInventory.metadata.count == 2, "hover cannot register over same-target click validation")
        refreshes.cancelClickValidationRefresh()
        refreshes.refreshClickValidation(for: app, targetKey: "app") { _ in delivered.append("new click") }
        WindowInventory.metadata[0].completion([])
        WindowInventory.metadata[1].completion([])
        check(delivered.isEmpty, "neither canceled hover nor canceled click may deliver")
        WindowInventory.metadata[2].completion([])
        check(delivered == ["new click"], "the current click still receives its metadata")
        refreshes.refreshMetadata(for: app, targetKey: "app") { _, _ in delivered.append("resumed hover") }
        check(WindowInventory.metadata.count == 4, "consuming validation releases hover metadata refresh")
    }

    private static func testThumbnailTargetGenerationRejectsRoundTrips() {
        WindowInventory.reset()
        let refreshes = DockPreviewRefreshController()
        defer { withExtendedLifetime(refreshes) {} }
        var delivered = [CGWindowID]()
        refreshes.setThumbnailTargetPID(app.processIdentifier)
        refreshes.refreshThumbnails(for: app) { windowID, _ in delivered.append(windowID) }
        refreshes.setThumbnailTargetPID(nil)
        refreshes.setThumbnailTargetPID(app.processIdentifier)
        WindowInventory.thumbnails[0](1, .unavailable)
        check(delivered.isEmpty, "leaving and returning to one PID must still reject its old capture")
        refreshes.refreshThumbnails(for: app) { windowID, _ in delivered.append(windowID) }
        refreshes.setThumbnailTargetPID(app.processIdentifier)
        WindowInventory.thumbnails[1](2, .unavailable)
        check(delivered == [2], "repeating the current PID must not invalidate its own capture")
        refreshes.resetThumbnailTarget()
        WindowInventory.thumbnails[1](3, .unavailable)
        check(delivered == [2], "monitor restart always invalidates previous captures")
    }

    private static func testCanceledWarmupCanRetryImmediately() {
        WindowInventory.reset()
        let refreshes = DockPreviewRefreshController()
        defer { withExtendedLifetime(refreshes) {} }
        warm(refreshes, now: 10)
        check(WindowInventory.warmups.count == 1, "a dwelled target should warm once")
        warm(refreshes, now: 10.01)
        check(WindowInventory.warmups.count == 1, "a pending warmup must coalesce")
        refreshes.cancelRefreshRequests()
        warm(refreshes, now: 10.02)
        check(WindowInventory.warmups.count == 2, "canceling active warmup releases its per-app throttle")
        WindowInventory.warmups[0].completion([])
        warm(refreshes, now: 10.03)
        check(WindowInventory.warmups.count == 2, "old completion must not clear the replacement warmup")
    }

    private static func testMissingOnlyThumbnailsKeepTheCaptureBudget() {
        WindowInventory.reset()
        let refreshes = DockPreviewRefreshController()
        refreshes.setThumbnailTargetPID(app.processIdentifier)
        refreshes.refreshThumbnails(for: app, maximumStaleCount: 0) { _, _ in }
        refreshes.refreshThumbnails(for: app) { _, _ in }
        check(WindowInventory.staleCaptureLimits == [0, 2], "peek fills missing images without spending the regular stale-image budget")
        withExtendedLifetime(refreshes) {}
    }

    private static func testSpaceChangeRejectsOldWarmupCompletion() {
        WindowInventory.reset()
        let refreshes = DockPreviewRefreshController()
        defer { withExtendedLifetime(refreshes) {} }
        refreshes.spaceDidChange()
        warm(refreshes, now: 20)
        refreshes.spaceDidChange()
        WindowInventory.warmups[0].completion([])
        check(refreshes.needsSpaceRefresh(for: app.processIdentifier), "old-space warmup cannot complete the new epoch")
        warm(refreshes, now: 20.01)
        check(WindowInventory.warmups.count == 2, "a new Space bypasses the normal warmup throttle")
        WindowInventory.warmups[1].completion([])
        check(!refreshes.needsSpaceRefresh(for: app.processIdentifier), "current-space warmup records its epoch")
    }

    private static func warm(_ refreshes: DockPreviewRefreshController, now: TimeInterval) {
        let target = DockHoverTarget(app: app, title: "Fixture", url: nil, anchor: .zero)
        refreshes.warmPreviewCacheIfNeeded(
            for: target, now: now, pendingTarget: target,
            pendingTargetStartedAt: now - 0.1, fastTickInterval: 0.08
        )
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}

struct WindowPreview {}

enum FreshThumbnailCaptureResult {
    case unavailable
}

enum WindowThumbnailRefreshPolicy {
    case none
}

final class WindowRefreshRequest {
    private(set) var isActive = true

    func cancel() { isActive = false }
}

enum PrevDockSettings {
    static let previewSwitchDelay: TimeInterval = 0.2
}

enum WindowInventory {
    struct Pending {
        let request = WindowRefreshRequest()
        let completion: ([WindowPreview]) -> Void
    }

    static var metadata = [Pending]()
    static var warmups = [Pending]()
    static var thumbnails = [(CGWindowID, FreshThumbnailCaptureResult) -> Void]()
    static var staleCaptureLimits = [Int]()

    static func reset() {
        metadata = []
        warmups = []
        thumbnails = []
        staleCaptureLimits = []
    }

    static func setBackgroundThumbnailTarget(pid: pid_t?) {}

    static func cachedWindows(for app: NSRunningApplication, refreshedWithin age: TimeInterval) -> [WindowPreview]? {
        nil
    }

    static func refreshWindows(
        for app: NSRunningApplication,
        thumbnailPolicy: WindowThumbnailRefreshPolicy,
        metadata completion: @escaping ([WindowPreview]) -> Void,
        thumbnail: @escaping (CGWindowID, NSImage) -> Void
    ) -> WindowRefreshRequest {
        let pending = Pending(completion: completion)
        metadata.append(pending)
        return pending.request
    }

    static func warmPreviewCache(
        for app: NSRunningApplication,
        completion: @escaping ([WindowPreview]) -> Void
    ) -> WindowRefreshRequest {
        let pending = Pending(completion: completion)
        warmups.append(pending)
        return pending.request
    }

    static func refreshThumbnails(
        for app: NSRunningApplication,
        maximumStaleCount: Int,
        completion: @escaping (CGWindowID, FreshThumbnailCaptureResult) -> Void
    ) {
        staleCaptureLimits.append(maximumStaleCount)
        thumbnails.append(completion)
    }
}
