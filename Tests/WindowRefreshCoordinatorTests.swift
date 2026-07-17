import Darwin
import Foundation

@main
enum WindowRefreshCoordinatorTests {
    private static var failureCount = 0

    static func main() {
        testConcurrentRegistrationsShareOneProducer()
        testBegunProducerAcceptsJoiners()
        testWarmForegroundRequestsJoinAcrossIntervals()
        testCompletionRegistrationRaceDoesNotLosePayloads()
        testCancelledQueuedWorkIsSkipped()
        testCancelledBegunGenerationCannotRemoveReplacement()
        testCancelCompletionRaceIsLinearized()
        testKeyIsolation()

        guard failureCount == 0 else {
            fputs("WindowRefreshCoordinatorTests: \(failureCount) failure(s)\n", stderr)
            exit(1)
        }
        print("WindowRefreshCoordinatorTests: passed")
    }

    private static func testBegunProducerAcceptsJoiners() {
        let coordinator = WindowRefreshCoordinator<Int, String>()
        let warm = coordinator.register(key: 44, payload: "warm")
        guard let token = warm.generationToStart else {
            expect(false, "warm request should start a producer")
            return
        }
        expect(coordinator.begin(token), "warm producer should begin")
        let foreground = coordinator.register(key: 44, payload: "foreground")

        expect(
            foreground.generationToStart == nil,
            "foreground metadata should join an already-running warm producer"
        )
        expect(
            coordinator.complete(token).sorted() == ["foreground", "warm"],
            "warm and foreground subscribers should share one metadata result"
        )
    }

    private static func testConcurrentRegistrationsShareOneProducer() {
        let coordinator = WindowRefreshCoordinator<Int, Int>()
        let producerTokens = LockedValue<[WindowRefreshGeneration<Int>]>([])
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "WindowRefreshCoordinatorTests.concurrent-register",
            attributes: .concurrent
        )

        for payload in 0..<100 {
            group.enter()
            queue.async {
                let registration = coordinator.register(key: 91, payload: payload)
                if let token = registration.generationToStart {
                    producerTokens.update { $0.append(token) }
                }
                group.leave()
            }
        }
        group.wait()

        let tokens = producerTokens.read()
        expect(tokens.count == 1, "100 same-key registrations should start one producer")
        guard let token = tokens.first else { return }
        expect(coordinator.isInFlight(for: 91), "registered work should be in flight")
        expect(coordinator.begin(token), "the sole producer should begin")
        expect(
            coordinator.complete(token).sorted() == Array(0..<100),
            "every concurrent registration should receive the shared result"
        )
        expect(!coordinator.isInFlight(for: 91), "completion should clear in-flight state")
    }

    private static func testWarmForegroundRequestsJoinAcrossIntervals() {
        let coordinator = WindowRefreshCoordinator<Int, String>()
        let warm = coordinator.register(key: 45, payload: "warm")
        guard let token = warm.generationToStart else {
            expect(false, "interval warm request should start a producer")
            return
        }
        expect(coordinator.begin(token), "interval warm producer should begin")

        var requests = [warm.request]
        for index in 0..<5 {
            usleep(80_000)
            let foreground = coordinator.register(key: 45, payload: "foreground-\(index)")
            requests.append(foreground.request)
            expect(
                foreground.generationToStart == nil,
                "80ms foreground requests should keep joining the warm producer"
            )
        }

        let payloads = coordinator.complete(token)
        expect(payloads.count == 6, "every interval subscriber should receive the shared result")
        expect(
            requests.allSatisfy { !$0.isActive && !$0.isCancelled },
            "shared completion should finish every interval request"
        )
    }

    private static func testCompletionRegistrationRaceDoesNotLosePayloads() {
        for iteration in 0..<250 {
            let coordinator = WindowRefreshCoordinator<Int, Int>()
            let first = coordinator.register(key: 7, payload: 1)
            guard let firstToken = first.generationToStart else {
                expect(false, "first registration should own a generation")
                return
            }
            expect(coordinator.begin(firstToken), "first race generation should begin")

            let delivered = LockedValue<[Int]>([])
            let secondRegistration = LockedValue<WindowRefreshRegistration<Int>?>(nil)
            let gate = DispatchSemaphore(value: 0)
            let group = DispatchGroup()
            let queue = DispatchQueue(
                label: "WindowRefreshCoordinatorTests.completion-race.\(iteration)",
                attributes: .concurrent
            )

            group.enter()
            queue.async {
                gate.wait()
                delivered.update { $0.append(contentsOf: coordinator.complete(firstToken)) }
                group.leave()
            }
            group.enter()
            queue.async {
                gate.wait()
                let registration = coordinator.register(key: 7, payload: 2)
                secondRegistration.update { $0 = registration }
                group.leave()
            }
            gate.signal()
            gate.signal()
            group.wait()

            guard let second = secondRegistration.read() else {
                expect(false, "racing registration should complete")
                return
            }
            if let secondToken = second.generationToStart {
                expect(
                    coordinator.begin(secondToken),
                    "registration after completion should start a new generation"
                )
                delivered.update { $0.append(contentsOf: coordinator.complete(secondToken)) }
            }
            expect(
                delivered.read().sorted() == [1, 2],
                "completion/register race should deliver each payload exactly once"
            )
            expect(!coordinator.isInFlight(for: 7), "race cleanup should leave no generation")
        }
    }

    private static func testCancelledQueuedWorkIsSkipped() {
        let coordinator = WindowRefreshCoordinator<String, String>()
        let first = coordinator.register(key: "A", payload: "A")
        let second = coordinator.register(key: "B", payload: "B")
        first.request.cancel()
        second.request.cancel()
        let final = coordinator.register(key: "C", payload: "C")

        guard let firstToken = first.generationToStart,
              let secondToken = second.generationToStart,
              let finalToken = final.generationToStart else {
            expect(false, "distinct queued keys should each own a generation")
            return
        }
        expect(first.request.isCancelled, "cancelled request should expose its state")
        expect(!coordinator.begin(firstToken), "cancelled queued A should not begin")
        expect(!coordinator.begin(secondToken), "cancelled queued B should not begin")
        expect(coordinator.begin(finalToken), "active final target C should begin")
        expect(coordinator.complete(finalToken) == ["C"], "only C should be delivered")

        let sharedFirst = coordinator.register(key: "shared", payload: "cancelled")
        let sharedSecond = coordinator.register(key: "shared", payload: "active")
        sharedFirst.request.cancel()
        guard let sharedToken = sharedFirst.generationToStart else {
            expect(false, "first shared request should own the producer")
            return
        }
        expect(
            sharedSecond.generationToStart == nil,
            "second active request should join the queued generation"
        )
        expect(coordinator.begin(sharedToken), "one active subscriber should keep work alive")
        expect(
            coordinator.complete(sharedToken) == ["active"],
            "cancelled subscribers should not receive completed payloads"
        )
    }

    private static func testCancelledBegunGenerationCannotRemoveReplacement() {
        let coordinator = WindowRefreshCoordinator<Int, String>()
        let stale = coordinator.register(key: 9, payload: "stale")
        guard let staleToken = stale.generationToStart else {
            expect(false, "stale request should own its generation")
            return
        }
        expect(coordinator.begin(staleToken), "stale generation should begin")
        stale.request.cancel()

        let replacement = coordinator.register(key: 9, payload: "replacement")
        guard let replacementToken = replacement.generationToStart else {
            expect(false, "replacement should start after the final subscriber cancels")
            return
        }
        expect(
            coordinator.complete(staleToken).isEmpty,
            "the old producer must not drain the replacement generation"
        )
        expect(
            coordinator.isInFlight(for: 9),
            "old completion must preserve replacement in-flight state"
        )
        expect(coordinator.begin(replacementToken), "replacement producer should begin")
        expect(
            coordinator.complete(replacementToken) == ["replacement"],
            "replacement payload should be delivered exactly once"
        )
    }

    private static func testCancelCompletionRaceIsLinearized() {
        for iteration in 0..<250 {
            let coordinator = WindowRefreshCoordinator<Int, Int>()
            let registration = coordinator.register(key: iteration, payload: iteration)
            guard let token = registration.generationToStart else {
                expect(false, "race request should own a generation")
                return
            }
            expect(coordinator.begin(token), "race generation should begin")
            let delivered = LockedValue<[Int]>([])
            let gate = DispatchSemaphore(value: 0)
            let group = DispatchGroup()
            let queue = DispatchQueue(
                label: "WindowRefreshCoordinatorTests.cancel-complete.\(iteration)",
                attributes: .concurrent
            )

            group.enter()
            queue.async {
                gate.wait()
                registration.request.cancel()
                group.leave()
            }
            group.enter()
            queue.async {
                gate.wait()
                delivered.update { $0.append(contentsOf: coordinator.complete(token)) }
                group.leave()
            }
            gate.signal()
            gate.signal()
            group.wait()

            expect(
                delivered.read().count <= 1,
                "cancel/complete race must deliver a payload at most once"
            )
            expect(
                !coordinator.isInFlight(for: iteration),
                "cancel/complete race should leave no generation"
            )
        }
    }

    private static func testKeyIsolation() {
        struct RefreshKey: Hashable {
            let pid: Int32
            let scope: Int
        }

        let coordinator = WindowRefreshCoordinator<RefreshKey, String>()
        let firstKey = RefreshKey(pid: 100, scope: 1)
        let secondKey = RefreshKey(pid: 200, scope: 1)
        let first = coordinator.register(key: firstKey, payload: "first")
        let joined = coordinator.register(key: firstKey, payload: "joined")
        let second = coordinator.register(key: secondKey, payload: "second")

        guard let firstToken = first.generationToStart,
              let secondToken = second.generationToStart else {
            expect(false, "different keys should start isolated generations")
            return
        }
        expect(joined.generationToStart == nil, "identical PID/key should coalesce")
        expect(coordinator.begin(firstToken), "first key should begin independently")
        expect(coordinator.begin(secondToken), "second key should begin independently")
        expect(
            coordinator.complete(firstToken).sorted() == ["first", "joined"],
            "first completion should drain only matching-key payloads"
        )
        expect(
            coordinator.isInFlight(for: secondKey),
            "first completion must preserve the other key"
        )
        expect(
            coordinator.complete(secondToken) == ["second"],
            "second completion should retain its own payload"
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard !condition() else { return }
        failureCount += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

private final class LockedValue<Value> {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func read() -> Value {
        lock.lock()
        let value = value
        lock.unlock()
        return value
    }

    func update(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&value)
        lock.unlock()
    }
}
