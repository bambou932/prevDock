import Foundation

@main
enum WindowFocusRequestTests {
    static func main() {
        testCancellationBeforeQueuedDelivery()
        testCompletionIsAsynchronousAndOnMain()
        testConcurrentCompletionOnlyWinsOnce()
        testCancellationAndCompletionRace()
        testCompletedRequestRestorationEndsWithNewIntent()
        print("Window focus request tests passed")
    }

    private static func testCancellationBeforeQueuedDelivery() {
        let request = WindowFocusRequest()
        var completed = false
        request.finishOnMain { completed = true }
        request.cancel()
        drainMainQueue()
        check(!completed, "cancelling while a result is queued must suppress the callback")
        check(request.isCancelled && !request.isActive, "cancelled requests cannot run remaining focus work")
        check(!request.finish(), "cancellation must win over a later finish attempt")
    }

    private static func testCompletionIsAsynchronousAndOnMain() {
        let request = WindowFocusRequest()
        var completed = false
        request.finishOnMain {
            check(Thread.isMainThread, "focus completion must be delivered on main")
            completed = true
        }
        check(!completed && request.isActive, "completion must not race request assignment at the call site")
        drainMainQueue()
        check(completed && !request.isActive && !request.isCancelled, "successful delivery completes the request")
    }

    private static func testConcurrentCompletionOnlyWinsOnce() {
        let request = WindowFocusRequest()
        var completions = 0
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            request.finishOnMain {
                check(Thread.isMainThread, "worker results must be marshalled to main")
                completions += 1
            }
        }
        drainMainQueue()
        check(completions == 1, "concurrent verification results may deliver only once")
    }

    private static func testCancellationAndCompletionRace() {
        for _ in 0..<100 {
            let request = WindowFocusRequest()
            let counter = LockedCounter()
            DispatchQueue.concurrentPerform(iterations: 16) { index in
                if index.isMultiple(of: 2) {
                    request.cancel()
                } else if request.finish() {
                    counter.increment()
                }
            }
            check(!request.isActive, "racing terminal operations must always terminate the request")
            check(counter.value <= 1, "only one finisher may win a cancellation race")
            check(request.isCancelled, "cancellation must invalidate side effects even after a racing completion")
            check(!request.finish(), "a cancellation race must not permit another completion")
        }
    }

    private static func testCompletedRequestRestorationEndsWithNewIntent() {
        let request = WindowFocusRequest()
        check(request.finish(), "first completion should succeed")
        check(!request.isCancelled, "success must retain existing Space-return restoration until a new intent")
        request.cancel()
        check(request.isCancelled, "new intent must invalidate completed focus's delayed Space restoration")
        check(!request.finish(), "a completed request cannot deliver another result")
    }

    private static func drainMainQueue() {
        var drained = false
        DispatchQueue.main.async { drained = true }
        let deadline = Date().addingTimeInterval(2)
        while !drained && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        check(drained, "main queue did not drain")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}

private final class LockedCounter {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}
