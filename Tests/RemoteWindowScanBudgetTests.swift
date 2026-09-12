import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

private let mockQueries = MockRemoteWindowQueries()

func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>? {
    Unmanaged.passRetained(AXUIElementCreateApplication(-1))
}

func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: inout CGWindowID) -> AXError {
    mockQueries.perform()
    return .cannotComplete
}

@main
enum RemoteWindowScanBudgetTests {
    private static var failureCount = 0

    static func main() {
        testSlowQueriesRespectDeadline()
        testCancellationStopsEveryWorkerPromptly()
        testUnknownWindowRoles()
        guard failureCount == 0 else {
            fputs("RemoteWindowScanBudgetTests: \(failureCount) failure(s)\n", stderr)
            exit(1)
        }
        print("RemoteWindowScanBudgetTests: passed")
    }

    private static func testSlowQueriesRespectDeadline() {
        mockQueries.reset(delay: 0.04)
        let startedAt = ProcessInfo.processInfo.systemUptime
        let resolution = RemoteWindowElementResolver().resolve(
            pid: -1,
            knownWindowIDs: [],
            targetWindowIDs: [100]
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        expect(resolution != nil, "an expired scan budget should return its partial resolution")
        expect(resolution?.windows.isEmpty == true, "failed AX calls must not return windows")
        expect(resolution?.unresolvedWindowIDs == [100],
               "a timed-out scan must distinguish unresolved WindowServer targets from closed windows")
        expect(elapsed < 0.58, "slow calls must stop at the scan deadline, not after 16 calls per worker (\(elapsed)s)")
        expect(mockQueries.count <= 60, "the scan should stop after at most ten slow calls per worker")
    }

    private static func testCancellationStopsEveryWorkerPromptly() {
        mockQueries.reset(delay: 0.02)
        let resolution = RemoteWindowElementResolver().resolve(
            pid: -1,
            knownWindowIDs: [],
            targetWindowIDs: [100],
            shouldContinue: { mockQueries.count == 0 }
        )
        expect(resolution == nil, "a cancelled scan must not publish a partial result")
        expect(mockQueries.count <= 6, "cancellation should allow at most one in-progress query per worker")
    }

    private static func testUnknownWindowRoles() {
        var roleReads = 0
        expect(RemoteWindowRolePolicy.accepts(subrole: kAXStandardWindowSubrole) {
            roleReads += 1
            return nil
        }, "standard remote windows must remain valid without extra AX calls")
        expect(roleReads == 0, "ordinary remote scans must preserve their existing IPC cost")
        expect(RemoteWindowRolePolicy.accepts(subrole: kAXUnknownSubrole) { kAXWindowRole },
               "AXUnknown windows must reach the same Firefox/VLC compatibility filter as direct AX windows")
        expect(!RemoteWindowRolePolicy.accepts(subrole: kAXUnknownSubrole) { kAXButtonRole },
               "unknown controls sharing a parent window ID must not become remote windows")
        expect(!RemoteWindowRolePolicy.accepts(subrole: kAXUnknownSubrole) { nil },
               "a failed role query cannot prove an unknown element is a window")
        expect(!RemoteWindowRolePolicy.accepts(subrole: nil) { kAXWindowRole },
               "missing subroles must not broaden the established remote window policy")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard !condition() else { return }
        failureCount += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

private final class MockRemoteWindowQueries {
    private let lock = NSLock()
    private var queryCount = 0
    private var delay: TimeInterval = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return queryCount
    }

    func reset(delay: TimeInterval) {
        lock.lock()
        queryCount = 0
        self.delay = delay
        lock.unlock()
    }

    func perform() {
        lock.lock()
        queryCount += 1
        let delay = delay
        lock.unlock()
        Thread.sleep(forTimeInterval: delay)
    }
}
