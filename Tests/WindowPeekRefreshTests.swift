import Cocoa

@main
enum WindowPeekRefreshTests {
    private static var failureCount = 0
    private static let controller = WindowPeekController.shared

    static func main() {
        _ = NSApplication.shared
        testRapidHoverChangesCaptureOnlyLatestTarget()
        testGeometryChangesWaitForCurrentCapture()
        testHidingStopsPendingRefresh()
        testHideAndReopenUsesLatestTarget()
        testMinimizedSnapshotsNeverCapture()
        testLateSnapshotsRespectHoverTarget()
        testLiveToMinimizedDiscardsInFlightCapture()
        testMinimizedToLiveWaitsForPreviousCapture()
        testInvalidSnapshotsClearPresentation()
        testSnapshotPermissionRevocationAndReopen()
        guard failureCount == 0 else {
            fputs("WindowPeekRefreshTests: \(failureCount) failure(s)\n", stderr)
            exit(1)
        }
        print("WindowPeekRefreshTests: passed")
    }

    private static func testRapidHoverChangesCaptureOnlyLatestTarget() {
        WindowInventory.reset()
        controller.show(preview: preview(1))
        controller.show(preview: preview(2))
        controller.show(preview: preview(3))
        expect(!controller.isShowingLivePreview, "an image-less pending peek must allow background thumbnail refresh")
        expect(WindowInventory.requestedIDs == [1], "hover changes should share one in-flight capture")
        completeNextCapture()
        expect(WindowInventory.requestedIDs == [1, 3], "completion should skip obsolete intermediate hovers")
        expect(!controller.isShowingLivePreview, "waiting for the latest capture must not count as a visible peek")
        controller.show(preview: preview(3))
        expect(WindowInventory.requestedIDs == [1, 3], "repeating the latest hover must not duplicate its capture")
        finishTest()
    }

    private static func testGeometryChangesWaitForCurrentCapture() {
        WindowInventory.reset()
        controller.show(preview: preview(4))
        controller.show(preview: preview(4, width: 320))
        expect(WindowInventory.requestedIDs == [4], "resizing the same window should not overlap captures")
        completeNextCapture()
        expect(WindowInventory.requestedWidths == [240, 320], "fresh capture should use the latest bounds")
        finishTest()
    }

    private static func testHidingStopsPendingRefresh() {
        WindowInventory.reset()
        controller.show(preview: preview(5))
        controller.hide()
        completeNextCapture()
        expect(WindowInventory.requestedIDs == [5], "a hidden peek must not restart after its capture completes")
        expect(!controller.isShowingLivePreview, "hiding should deactivate live preview")
        finishTest()
    }

    private static func testHideAndReopenUsesLatestTarget() {
        WindowInventory.reset()
        controller.show(preview: preview(6))
        controller.hide()
        controller.show(preview: preview(7))
        expect(WindowInventory.requestedIDs == [6], "reopening must wait for the existing capture")
        completeNextCapture()
        expect(WindowInventory.requestedIDs == [6, 7], "reopened peek should recover when old capture completes")
        finishTest()
    }

    private static func testMinimizedSnapshotsNeverCapture() {
        WindowInventory.reset()
        let minimized = preview(20, minimized: true, image: sampleImage())
        controller.show(preview: minimized)
        expect(peekPanel?.isVisible == true, "a cached minimized window should show its snapshot")
        expect(peekPanel?.frame == minimized.bounds, "a minimized snapshot should retain the original window frame")
        expect(!controller.isShowingLivePreview, "a static snapshot must not claim live capture ownership")
        for _ in 0..<5 { controller.show(preview: minimized) }
        RunLoop.main.run(until: Date().addingTimeInterval(1.05))
        expect(WindowInventory.requestedIDs.isEmpty, "minimized snapshots must not request captures or schedule a refresh")
        finishTest()
    }

    private static func testLateSnapshotsRespectHoverTarget() {
        WindowInventory.reset()
        controller.show(preview: preview(21, minimized: true))
        expect(peekPanel?.isVisible == false, "a minimized window without an image must not show an empty overlay")
        controller.updateSnapshot(preview: preview(21, minimized: true, image: sampleImage()))
        expect(peekPanel?.isVisible == true, "a late snapshot should fill the current minimized hover")
        controller.show(preview: preview(22, width: 320, minimized: true))
        controller.updateSnapshot(preview: preview(21, minimized: true, image: sampleImage()))
        expect(peekPanel?.isVisible == false, "an old hover's late image must not reopen its snapshot")
        let current = preview(22, width: 320, minimized: true, image: sampleImage())
        controller.updateSnapshot(preview: current)
        expect(peekPanel?.frame == current.bounds && peekPanel?.isVisible == true,
               "the latest target should accept its own late image")
        controller.hide()
        controller.updateSnapshot(preview: current)
        expect(peekPanel?.isVisible == false, "late images must not reopen a hidden snapshot")
        expect(WindowInventory.requestedIDs.isEmpty, "late snapshot delivery must stay capture-free")
        finishTest()
    }

    private static func testLiveToMinimizedDiscardsInFlightCapture() {
        WindowInventory.reset()
        var liveUpdates = 0
        controller.setLiveImageUpdateHandler { _, _ in liveUpdates += 1 }
        controller.show(preview: preview(23))
        controller.show(preview: preview(23, minimized: true, image: sampleImage()))
        completeNextCapture(.captured(sampleImage()))
        expect(liveUpdates == 0, "a pre-minimize capture must not publish after the state transition")
        expect(peekPanel?.isVisible == true && !controller.isShowingLivePreview,
               "an old live completion must preserve the static snapshot")
        expect(WindowInventory.requestedIDs == [23], "minimizing must stop the live refresh chain")
        finishTest()
    }

    private static func testMinimizedToLiveWaitsForPreviousCapture() {
        WindowInventory.reset()
        var liveUpdates = 0
        controller.setLiveImageUpdateHandler { _, _ in liveUpdates += 1 }
        controller.show(preview: preview(24))
        controller.show(preview: preview(24, minimized: true, image: sampleImage()))
        controller.show(preview: preview(24, width: 320))
        expect(WindowInventory.requestedWidths == [240], "restoring must wait for the pre-minimize capture")
        completeNextCapture(.captured(sampleImage()))
        expect(liveUpdates == 0 && WindowInventory.requestedWidths == [240, 320],
               "restoring must discard the old capture and request the latest geometry")
        controller.updateSnapshot(preview: preview(24, minimized: true, image: sampleImage()))
        completeNextCapture(.captured(sampleImage()))
        expect(liveUpdates == 1 && peekPanel?.frame.width == 320 && controller.isShowingLivePreview,
               "a stale minimized image must not replace the restored live target")
        finishTest()
    }

    private static func testInvalidSnapshotsClearPresentation() {
        WindowInventory.reset()
        let valid = preview(25, minimized: true, image: sampleImage())
        let invalidBounds = [
            CGRect(x: 40, y: 40, width: 79, height: 160),
            CGRect(x: CGFloat.nan, y: 40, width: 240, height: 160),
            CGRect(x: 40, y: 40, width: CGFloat.infinity, height: 160),
            CGRect(x: 1_000_000, y: 1_000_000, width: 240, height: 160)
        ]
        for bounds in invalidBounds {
            controller.show(preview: valid)
            controller.show(preview: WindowPreview(windowID: 26, bounds: bounds, isMinimized: true, image: sampleImage()))
            expect(peekPanel?.isVisible == false, "invalid or disconnected snapshot bounds must clear the overlay")
        }
        controller.show(preview: valid)
        controller.show(preview: preview(25, minimized: true))
        expect(peekPanel?.isVisible == false, "an unavailable replacement must not leave a stale snapshot visible")
        expect(WindowInventory.requestedIDs.isEmpty, "invalid snapshots must not trigger capture recovery")
        finishTest()
    }

    private static func testSnapshotPermissionRevocationAndReopen() {
        WindowInventory.reset()
        let minimized = preview(27, minimized: true, image: sampleImage())
        controller.show(preview: minimized)
        PermissionManager.status.screenRecordingGranted = false
        controller.updateSnapshot(preview: minimized)
        expect(peekPanel?.isVisible == false, "permission loss must dismiss a static snapshot")
        controller.show(preview: minimized)
        expect(peekPanel?.isVisible == false, "cached images must not bypass the permission gate")
        PermissionManager.status.screenRecordingGranted = true
        controller.updateSnapshot(preview: minimized)
        expect(peekPanel?.isVisible == false, "permission recovery must not revive stale hover ownership")
        controller.show(preview: minimized)
        expect(peekPanel?.isVisible == true, "a fresh hover should reopen an allowed cached snapshot")
        expect(WindowInventory.requestedIDs.isEmpty, "snapshot reopen must not start live capture")
        finishTest()
    }

    private static var peekPanel: NSWindow? {
        let level = Int(CGWindowLevelForKey(.dockWindow)) - 1
        return NSApp.windows.first { $0.level.rawValue == level }
    }

    private static func sampleImage() -> NSImage {
        NSImage(size: NSSize(width: 240, height: 160), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
    }

    private static func finishTest() {
        controller.hide()
        while !WindowInventory.completions.isEmpty {
            completeNextCapture()
        }
    }

    private static func completeNextCapture(_ result: FreshThumbnailCaptureResult = .unavailable) {
        guard !WindowInventory.completions.isEmpty else {
            expect(false, "test should have a pending capture")
            return
        }
        WindowInventory.completions.removeFirst()(result)
        var completed = false
        DispatchQueue.main.async { completed = true }
        let deadline = Date().addingTimeInterval(1)
        while !completed, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
        expect(completed, "main queue should deliver capture completion")
    }

    private static func preview(_ id: CGWindowID, width: CGFloat = 240, minimized: Bool = false, image: NSImage? = nil) -> WindowPreview {
        WindowPreview(windowID: id, bounds: CGRect(x: 40, y: 40, width: width, height: 160), isMinimized: minimized, image: image)
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard !condition else { return }
        failureCount += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

struct WindowPreview {
    let windowID: CGWindowID
    let bounds: CGRect
    var isMinimized = false
    var isFullscreen = false
    var image: NSImage? = nil
}

enum FreshThumbnailCaptureResult {
    case captured(NSImage)
    case cached(NSImage)
    case unavailable
}

enum WindowInventory {
    static var requestedIDs = [CGWindowID]()
    static var requestedWidths = [CGFloat]()
    static var completions = [(FreshThumbnailCaptureResult) -> Void]()

    static func captureFreshThumbnail(for preview: WindowPreview, completion: @escaping (FreshThumbnailCaptureResult) -> Void) {
        requestedIDs.append(preview.windowID)
        requestedWidths.append(preview.bounds.width)
        completions.append(completion)
    }

    static func reset() {
        requestedIDs = []
        requestedWidths = []
        completions = []
    }
}

enum PermissionManager {
    struct Status {
        var screenRecordingGranted = true
    }
    static var status = Status()
}

enum LivePreviewCadence {
    static func appKitFrame(fromWindowBounds bounds: CGRect) -> CGRect { bounds }
    static func interval(forWindowBounds bounds: CGRect) -> TimeInterval { 1 }
}
