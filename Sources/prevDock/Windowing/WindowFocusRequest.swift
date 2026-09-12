import Foundation

final class WindowFocusRequest {
    private enum State {
        case active
        case cancelled
        case completed
    }

    private let lock = NSLock()
    private var state = State.active

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .active
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .cancelled
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        state = .cancelled
    }

    @discardableResult
    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .active else { return false }
        state = .completed
        return true
    }

    func finishOnMain(_ completion: @escaping () -> Void) {
        DispatchQueue.main.async {
            guard self.finish() else { return }
            completion()
        }
    }
}
