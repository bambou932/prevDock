import Foundation

final class WindowRefreshRequest {
    private enum State: Equatable {
        case active
        case cancelled
        case completed
    }

    private let lock = NSLock()
    private var state = State.active
    private var cancellationHandler: (() -> Void)?

    fileprivate init(cancellationHandler: @escaping () -> Void) {
        self.cancellationHandler = cancellationHandler
    }

    var isCancelled: Bool {
        lock.lock()
        let isCancelled = state == .cancelled
        lock.unlock()
        return isCancelled
    }

    func cancel() {
        lock.lock()
        guard state == .active else {
            lock.unlock()
            return
        }
        state = .cancelled
        let handler = cancellationHandler
        cancellationHandler = nil
        lock.unlock()
        handler?()
    }

    var isActive: Bool {
        lock.lock()
        let isActive = state == .active
        lock.unlock()
        return isActive
    }

    fileprivate func claimCompletion() -> Bool {
        lock.lock()
        guard state == .active else {
            lock.unlock()
            return false
        }
        state = .completed
        cancellationHandler = nil
        lock.unlock()
        return true
    }
}

struct WindowRefreshGeneration<Key: Hashable> {
    let key: Key
    fileprivate let identifier: UInt64
}

struct WindowRefreshRegistration<Key: Hashable> {
    let request: WindowRefreshRequest
    let generationToStart: WindowRefreshGeneration<Key>?
}

final class WindowRefreshCoordinator<Key: Hashable, Payload> {
    private struct PendingPayload {
        let identifier: UInt64
        let request: WindowRefreshRequest
        let payload: Payload
    }

    private struct Generation {
        let identifier: UInt64
        var hasBegun: Bool
        var pendingPayloads: [PendingPayload]
    }

    private let lock = NSLock()
    private var generationsByKey = [Key: Generation]()
    private var nextIdentifier: UInt64 = 0

    func register(key: Key, payload: Payload) -> WindowRefreshRegistration<Key> {
        lock.lock()
        let registration = registerLocked(key: key, payload: payload)
        lock.unlock()
        return registration
    }

    func begin(_ token: WindowRefreshGeneration<Key>) -> Bool {
        lock.lock()
        guard var generation = matchingGeneration(for: token),
              !generation.hasBegun,
              generation.pendingPayloads.contains(where: { $0.request.isActive }) else {
            removeInactiveGenerationLocked(for: token)
            lock.unlock()
            return false
        }
        generation.hasBegun = true
        generationsByKey[token.key] = generation
        lock.unlock()
        return true
    }

    func shouldContinue(_ token: WindowRefreshGeneration<Key>) -> Bool {
        lock.lock()
        let shouldContinue = matchingGeneration(for: token)?
            .pendingPayloads
            .contains(where: { $0.request.isActive }) == true
        lock.unlock()
        return shouldContinue
    }

    func complete(_ token: WindowRefreshGeneration<Key>) -> [Payload] {
        lock.lock()
        guard let generation = matchingGeneration(for: token) else {
            lock.unlock()
            return []
        }
        generationsByKey.removeValue(forKey: token.key)
        let payloads = generation.pendingPayloads.compactMap { pending in
            pending.request.claimCompletion() ? pending.payload : nil
        }
        lock.unlock()
        return payloads
    }

    func isInFlight(for key: Key) -> Bool {
        lock.lock()
        let isInFlight = generationsByKey[key]?
            .pendingPayloads
            .contains(where: { $0.request.isActive }) == true
        lock.unlock()
        return isInFlight
    }

    private func registerLocked(
        key: Key,
        payload: Payload
    ) -> WindowRefreshRegistration<Key> {
        if var generation = generationsByKey[key],
           generation.pendingPayloads.contains(where: { $0.request.isActive }) {
            let pending = makePendingPayload(
                key: key,
                generationIdentifier: generation.identifier,
                payload: payload
            )
            generation.pendingPayloads.append(pending)
            generationsByKey[key] = generation
            return WindowRefreshRegistration(
                request: pending.request,
                generationToStart: nil
            )
        }

        let generationIdentifier = makeIdentifierLocked()
        let pending = makePendingPayload(
            key: key,
            generationIdentifier: generationIdentifier,
            payload: payload
        )
        generationsByKey[key] = Generation(
            identifier: generationIdentifier,
            hasBegun: false,
            pendingPayloads: [pending]
        )
        return WindowRefreshRegistration(
            request: pending.request,
            generationToStart: WindowRefreshGeneration(
                key: key,
                identifier: generationIdentifier
            )
        )
    }

    private func makePendingPayload(
        key: Key,
        generationIdentifier: UInt64,
        payload: Payload
    ) -> PendingPayload {
        let requestIdentifier = makeIdentifierLocked()
        let request = WindowRefreshRequest { [weak self] in
            self?.cancel(
                key: key,
                generationIdentifier: generationIdentifier,
                requestIdentifier: requestIdentifier
            )
        }
        return PendingPayload(
            identifier: requestIdentifier,
            request: request,
            payload: payload
        )
    }

    private func cancel(
        key: Key,
        generationIdentifier: UInt64,
        requestIdentifier: UInt64
    ) {
        lock.lock()
        guard var generation = generationsByKey[key],
              generation.identifier == generationIdentifier else {
            lock.unlock()
            return
        }
        generation.pendingPayloads.removeAll { $0.identifier == requestIdentifier }
        if generation.pendingPayloads.isEmpty {
            generationsByKey.removeValue(forKey: key)
        } else {
            generationsByKey[key] = generation
        }
        lock.unlock()
    }

    private func matchingGeneration(
        for token: WindowRefreshGeneration<Key>
    ) -> Generation? {
        guard let generation = generationsByKey[token.key],
              generation.identifier == token.identifier else {
            return nil
        }
        return generation
    }

    private func removeInactiveGenerationLocked(
        for token: WindowRefreshGeneration<Key>
    ) {
        guard let generation = matchingGeneration(for: token),
              !generation.pendingPayloads.contains(where: { $0.request.isActive }) else {
            return
        }
        generationsByKey.removeValue(forKey: token.key)
    }

    private func makeIdentifierLocked() -> UInt64 {
        nextIdentifier &+= 1
        return nextIdentifier
    }
}
