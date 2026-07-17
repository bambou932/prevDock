import Foundation

@main
enum WindowThumbnailCapturePolicyTests {
    static func main() {
        testAllMissingCandidatesAreAdmittedWithoutStaleWaveDelay()
        testBackgroundConcurrencyRemainsBounded()
        testStaleCandidatesRemainBounded()
        testAttemptDecisions()
        testFailureBackoffAndSignatureChanges()
        testFailureCleanup()
        print("WindowThumbnailCapturePolicyTests: passed")
    }

    private static func testBackgroundConcurrencyRemainsBounded() {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = WindowThumbnailCapturePlan.maximumConcurrentCaptureCount
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        for _ in 0..<4 {
            queue.addOperation {
                entered.signal()
                release.wait()
            }
        }
        expect(entered.wait(timeout: .now() + 1) == .success, "first capture did not start")
        expect(entered.wait(timeout: .now() + 1) == .success, "second capture did not start")
        expect(entered.wait(timeout: .now() + 0.05) == .timedOut, "more than two captures started")
        for _ in 0..<4 {
            release.signal()
        }
        queue.waitUntilAllOperationsAreFinished()
    }

    private static func testAllMissingCandidatesAreAdmittedWithoutStaleWaveDelay() {
        let candidates = (1...6).map { Candidate(id: $0, isMissing: true) }
        let selected = WindowThumbnailCapturePlan.select(
            from: candidates,
            maximumStaleCount: 2,
            isMissing: \.isMissing
        )
        expect(selected.map(\.id) == [1, 2, 3, 4, 5, 6], "missing candidates were wave-limited")
        expect(
            WindowThumbnailCapturePlan.maximumConcurrentCaptureCount == 2,
            "background capture concurrency changed"
        )
    }

    private static func testStaleCandidatesRemainBounded() {
        let candidates = [
            Candidate(id: 1, isMissing: false),
            Candidate(id: 2, isMissing: true),
            Candidate(id: 3, isMissing: false),
            Candidate(id: 4, isMissing: true),
            Candidate(id: 5, isMissing: false)
        ]
        let selected = WindowThumbnailCapturePlan.select(
            from: candidates,
            maximumStaleCount: 2,
            isMissing: \.isMissing
        )
        expect(selected.map(\.id) == [2, 4, 1, 3], "missing/stale planning order is incorrect")
    }

    private static func testAttemptDecisions() {
        expect(
            decision(hasCachedImage: false, isBackingOff: true) == .unavailableBackoff,
            "backoff without a cache did not end Loading"
        )
        expect(
            decision(hasCachedImage: false, isInFlight: true) == .none,
            "an in-flight miss was scheduled twice"
        )
        expect(
            decision(hasCachedImage: false) == .captureMissing,
            "a cache miss was not admitted"
        )
        expect(
            decision(hasCachedImage: true, isMinimized: true, isStale: true) == .none,
            "a minimized last-known-good image was refreshed"
        )
        expect(
            decision(hasCachedImage: true, isStale: true) == .captureStale,
            "a stale visible image was not refreshed"
        )
        expect(
            decision(hasCachedImage: true, isStale: true, allowsStaleCapture: false) == .none,
            "missing-only work captured a stale image"
        )
        expect(
            decision(
                hasCachedImage: false,
                allowsMissingCapture: false,
                allowsStaleCapture: false
            ) == .none,
            "metadata-only work captured a missing image"
        )
    }

    private static func decision(
        hasCachedImage: Bool,
        isMinimized: Bool = false,
        isStale: Bool = false,
        isInFlight: Bool = false,
        isBackingOff: Bool = false,
        allowsMissingCapture: Bool = true,
        allowsStaleCapture: Bool = true
    ) -> WindowThumbnailAttemptDecision {
        WindowThumbnailAttemptPolicy.decide(
            hasCachedImage: hasCachedImage,
            isMinimized: isMinimized,
            isStale: isStale,
            isInFlight: isInFlight,
            isBackingOff: isBackingOff,
            allowsMissingCapture: allowsMissingCapture,
            allowsStaleCapture: allowsStaleCapture
        )
    }

    private static func testFailureBackoffAndSignatureChanges() {
        var backoff = WindowThumbnailFailureBackoff<Int, String>(retryDelays: [1, 2, 4])
        expect(backoff.allowsAttempt(for: 7, signature: "minimized", now: 10), "first attempt blocked")

        backoff.recordFailure(for: 7, signature: "minimized", now: 10)
        expect(!backoff.allowsAttempt(for: 7, signature: "minimized", now: 10.99), "first backoff ignored")
        expect(backoff.allowsAttempt(for: 7, signature: "minimized", now: 11), "first retry stayed blocked")

        backoff.recordFailure(for: 7, signature: "minimized", now: 11)
        expect(!backoff.allowsAttempt(for: 7, signature: "minimized", now: 12.99), "second backoff ignored")
        expect(backoff.allowsAttempt(for: 7, signature: "minimized", now: 13), "second retry stayed blocked")
        expect(backoff.failureCount(for: 7) == 2, "consecutive failures were not counted")

        expect(
            backoff.allowsAttempt(for: 7, signature: "restored", now: 11.1),
            "minimize or size transition did not bypass stale backoff"
        )
        backoff.recordFailure(for: 7, signature: "restored", now: 11.1)
        expect(backoff.failureCount(for: 7) == 1, "new signature did not reset failure count")

        backoff.recordSuccess(for: 7)
        expect(backoff.allowsAttempt(for: 7, signature: "restored", now: 11.1), "success did not clear backoff")
    }

    private static func testFailureCleanup() {
        var backoff = WindowThumbnailFailureBackoff<Int, String>(retryDelays: [1])
        backoff.recordFailure(for: 1, signature: "a", now: 0)
        backoff.recordFailure(for: 2, signature: "b", now: 0)
        backoff.removeAll { $0 == 1 }
        expect(backoff.failureCount(for: 1) == 0, "targeted cleanup retained removed state")
        expect(backoff.failureCount(for: 2) == 1, "targeted cleanup removed unrelated state")
        backoff.removeAll()
        expect(backoff.failureCount(for: 2) == 0, "full cleanup retained failure state")
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard condition() else {
            fatalError(message, file: file, line: line)
        }
    }
}

private struct Candidate {
    let id: Int
    let isMissing: Bool
}
