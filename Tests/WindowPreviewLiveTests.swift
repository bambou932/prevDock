import AppKit
import ApplicationServices
import Darwin

@main
enum WindowPreviewLiveTests {
    static func main() {
        _ = NSApplication.shared
        guard PermissionManager.status.allGranted else {
            fail("live preview tests require Accessibility and Screen Recording access")
        }
        let bundleID = CommandLine.arguments.dropFirst().first ?? "com.google.Chrome"
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            fail("requested application is not running")
        }
        WindowInventory.setBackgroundThumbnailTarget(pid: app.processIdentifier)
        defer { WindowInventory.setBackgroundThumbnailTarget(pid: nil) }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let initial = refresh(app)
        expect(!initial.isEmpty, "metadata discovery returned no windows")
        let metadataMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        var results = [CGWindowID: Bool]()
        WindowInventory.refreshThumbnails(for: app) { windowID, result in
            results[windowID] = result.image != nil
        }
        expect(wait(until: { results.count == initial.count }, timeout: 8),
               "some thumbnail requests never completed")
        expect(results.values.contains(true), "no real window thumbnails were captured")
        if CommandLine.arguments.contains("--require-all") {
            expect(results.values.allSatisfy { $0 }, "an available fixture window lost its thumbnail")
        }
        let cached = refresh(app)
        let capturedIDs = Set(results.filter { $0.value }.map(\.key))
        let cachedImageIDs = Set(cached.filter { $0.image != nil }.map(\.windowID))
        expect(capturedIDs.isSubset(of: cachedImageIDs), "metadata refresh discarded valid cached thumbnails")
        WindowInventory.setBackgroundThumbnailTarget(pid: nil)
        WindowInventory.setBackgroundThumbnailTarget(pid: app.processIdentifier)
        let restored = refresh(app)
        expect(Set(restored.map(\.windowID)) == Set(cached.map(\.windowID)),
               "target restoration changed window inventory")
        print(String(format: "metadata_ms=%.2f windows=%d captured=%d unavailable=%d",
                     metadataMilliseconds, initial.count, capturedIDs.count, results.count - capturedIDs.count))
        if CommandLine.arguments.contains("--stress"),
           let preview = restored.first(where: { $0.image != nil && !$0.isMinimized }) {
            testContinuousRefresh(app: app, preview: preview)
        }
        print("WindowPreviewLiveTests: passed")
    }

    private static func testContinuousRefresh(app: NSRunningApplication, preview: WindowPreview) {
        var liveInFlight = false
        var nextMetadata = ProcessInfo.processInfo.systemUptime
        var nextThumbnail = nextMetadata
        let deadline = nextMetadata + 10
        var deniedSnapshots = 0
        var liveCaptures = 0
        var liveUnavailable = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            let now = ProcessInfo.processInfo.systemUptime
            if !PermissionManager.status.screenRecordingGranted { deniedSnapshots += 1 }
            if now >= nextMetadata {
                nextMetadata = now + 0.5
                WindowInventory.refreshWindows(for: app, metadata: { _ in }, thumbnail: { _, _ in })
            }
            if now >= nextThumbnail {
                nextThumbnail = now + 0.1
                WindowInventory.refreshThumbnails(for: app) { _, _ in }
            }
            if !liveInFlight {
                liveInFlight = true
                WindowInventory.captureFreshThumbnail(for: preview) { result in
                    DispatchQueue.main.async {
                        if result.image != nil { liveCaptures += 1 } else { liveUnavailable += 1 }
                        liveInFlight = false
                    }
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        expect(wait(until: { !liveInFlight }, timeout: 2), "last live capture never completed")
        expect(deniedSnapshots == 0, "permission changed unexpectedly during continuous capture")
        expect(liveCaptures > 1 && liveUnavailable == 0, "continuous captures lost an available thumbnail")
        print("stress_seconds=10 live_captured=\(liveCaptures) live_unavailable=\(liveUnavailable) denied_snapshots=\(deniedSnapshots)")
    }

    private static func refresh(_ app: NSRunningApplication) -> [WindowPreview] {
        var result: [WindowPreview]?
        let request = WindowInventory.refreshWindows(for: app, metadata: { result = $0 }, thumbnail: { _, _ in })
        expect(wait(until: { result != nil }, timeout: 5), "window refresh never delivered metadata")
        expect(!request.isActive, "completed refresh is still active")
        return result ?? []
    }

    private static func wait(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}
