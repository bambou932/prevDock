import AppKit
import Darwin

@main
enum PermissionStatusCacheTests {
    static func main() {
        testConcurrentCallsShareMainThreadSnapshot()
        testExpiryObservesRevocationAndRecovery()
        testExplicitRefreshBypassesLifetime()
        testBackgroundInitializationDoesNotBlock()
        print("PermissionStatusCacheTests: passed")
    }

    private static func testConcurrentCallsShareMainThreadSnapshot() {
        let fixture = ProbeFixture()
        let cache = fixture.makeCache()
        expect(cache.value, "main-thread initialization should read granted access")
        expect(concurrentValues(cache).allSatisfy { $0 }, "fresh concurrent callers should see the same grant")
        expect(fixture.probeCount == 1, "fresh concurrent reads must not repeat native preflight")
        fixture.now = 0.5
        expect(concurrentValues(cache).allSatisfy { $0 }, "stale concurrent reads should return the previous snapshot immediately")
        expect(fixture.probeCount == 1, "background reads must not probe while the main queue is occupied")
        drainMainQueue()
        expect(fixture.probeCount == 2, "all stale concurrent readers should coalesce into one main-thread probe")
        expect(fixture.changedValues.isEmpty, "unchanged snapshots should not notify")
    }

    private static func testExpiryObservesRevocationAndRecovery() {
        let fixture = ProbeFixture()
        let cache = fixture.makeCache()
        expect(cache.value, "initial access should be granted")
        fixture.granted = false
        fixture.now = 0.49
        expect(cache.value, "snapshot should remain stable within its bounded lifetime")
        fixture.now = 0.5
        expect(!cache.value, "expiry must observe actual revocation")
        expect(fixture.changedValues.isEmpty, "change callbacks must not run reentrantly inside status reads")
        drainMainQueue()
        expect(fixture.changedValues == [false], "revocation should notify once")
        fixture.granted = true
        fixture.now = 1
        expect(concurrentValues(cache).allSatisfy { !$0 }, "stale background readers should remain denied until sampled")
        drainMainQueue()
        expect(cache.value, "a later grant should recover without restarting")
        expect(fixture.changedValues == [false, true], "recovery should notify once")
    }

    private static func testExplicitRefreshBypassesLifetime() {
        let fixture = ProbeFixture()
        let cache = fixture.makeCache()
        expect(cache.value, "initial explicit-refresh fixture should be granted")
        fixture.granted = false
        expect(!cache.refresh(), "request completion should be able to refresh before expiry")
        expect(fixture.probeCount == 2, "explicit refresh should perform exactly one new probe")
        drainMainQueue()
        expect(fixture.changedValues == [false], "explicit refresh should report changed permissions")
    }

    private static func testBackgroundInitializationDoesNotBlock() {
        let fixture = ProbeFixture()
        let cache = fixture.makeCache()
        expect(concurrentValues(cache).allSatisfy { !$0 }, "uninitialized background reads should fail closed without blocking")
        expect(fixture.probeCount == 0, "background initialization must defer native probing")
        drainMainQueue()
        expect(fixture.probeCount == 1 && cache.value, "one queued main-thread probe should initialize access")
    }

    private static func concurrentValues(_ cache: PermissionStatusCache<Bool>) -> [Bool] {
        let values = LockedValues()
        let group = DispatchGroup()
        for _ in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                values.append(cache.value)
                group.leave()
            }
        }
        expect(group.wait(timeout: .now() + 2) == .success, "background status reads must not wait synchronously for the main queue")
        return values.values
    }

    private static func drainMainQueue() {
        var drained = false
        DispatchQueue.main.async {
            DispatchQueue.main.async { drained = true }
        }
        let deadline = Date().addingTimeInterval(2)
        while !drained, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
        expect(drained, "queued refresh and change notification should complete")
    }

    fileprivate static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}

private final class ProbeFixture {
    var now: TimeInterval = 0
    var granted = true
    var probeCount = 0
    var changedValues = [Bool]()

    func makeCache() -> PermissionStatusCache<Bool> {
        PermissionStatusCache(
            unavailableValue: false,
            clock: { self.now },
            probe: {
                PermissionStatusCacheTests.expect(Thread.isMainThread, "native permission probes must run on main")
                self.probeCount += 1
                return self.granted
            },
            onChange: {
                PermissionStatusCacheTests.expect(Thread.isMainThread, "permission notifications must run on main")
                self.changedValues.append($0)
            }
        )
    }
}

private final class LockedValues {
    private let lock = NSLock()
    private var storage = [Bool]()

    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Bool) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
