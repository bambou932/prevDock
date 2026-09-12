import Foundation

final class PermissionStatusCache<Value: Equatable> {
    private let lock = NSLock()
    private let unavailableValue: Value
    private let refreshInterval: TimeInterval
    private let clock: () -> TimeInterval
    private let probe: () -> Value
    private let onChange: (Value) -> Void
    private var snapshot: Value?
    private var checkedAt: TimeInterval = 0
    private var isRefreshScheduled = false

    init(
        unavailableValue: Value,
        refreshInterval: TimeInterval = 0.5,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        probe: @escaping () -> Value,
        onChange: @escaping (Value) -> Void = { _ in }
    ) {
        self.unavailableValue = unavailableValue
        self.refreshInterval = refreshInterval
        self.clock = clock
        self.probe = probe
        self.onChange = onChange
    }

    var value: Value {
        read(forceRefresh: false)
    }

    @discardableResult
    func refresh() -> Value {
        read(forceRefresh: true)
    }

    private func read(forceRefresh: Bool) -> Value {
        lock.lock()
        let cached = snapshot ?? unavailableValue
        let needsRefresh = snapshot == nil || clock() - checkedAt >= refreshInterval
        guard (forceRefresh || needsRefresh), !isRefreshScheduled else {
            lock.unlock()
            return cached
        }
        isRefreshScheduled = true
        lock.unlock()
        if Thread.isMainThread { return sample() }
        // Repeated preflight calls during native captures can spuriously deny access.
        // Capture workers share a bounded snapshot and never synchronously wait for the main queue.
        DispatchQueue.main.async { [weak self] in
            _ = self?.sample()
        }
        return cached
    }

    private func sample() -> Value {
        let current = probe()
        lock.lock()
        let previous = snapshot
        snapshot = current
        checkedAt = clock()
        isRefreshScheduled = false
        lock.unlock()
        if let previous, previous != current {
            DispatchQueue.main.async { [onChange] in
                onChange(current)
            }
        }
        return current
    }
}
