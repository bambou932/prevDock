import Foundation

enum WindowThumbnailAttemptDecision: Equatable {
    case none
    case captureMissing
    case captureStale
    case unavailableBackoff
}

enum WindowThumbnailAttemptPolicy {
    static func decide(
        hasCachedImage: Bool,
        isMinimized: Bool,
        isStale: Bool,
        isInFlight: Bool,
        isBackingOff: Bool,
        allowsMissingCapture: Bool,
        allowsStaleCapture: Bool
    ) -> WindowThumbnailAttemptDecision {
        guard allowsMissingCapture else { return .none }
        guard hasCachedImage else {
            if isBackingOff { return .unavailableBackoff }
            return isInFlight ? .none : .captureMissing
        }
        guard allowsStaleCapture,
              !isMinimized,
              isStale,
              !isInFlight,
              !isBackingOff else {
            return .none
        }
        return .captureStale
    }
}

struct WindowThumbnailFailureBackoff<Key: Hashable, Signature: Equatable> {
    private struct Failure {
        let signature: Signature
        let count: Int
        let retryAt: TimeInterval
    }

    private let retryDelays: [TimeInterval]
    private var failures = [Key: Failure]()

    init(retryDelays: [TimeInterval] = [0.75, 2, 5, 15]) {
        precondition(!retryDelays.isEmpty)
        self.retryDelays = retryDelays
    }

    func allowsAttempt(for key: Key, signature: Signature, now: TimeInterval) -> Bool {
        guard let failure = failures[key], failure.signature == signature else { return true }
        return now >= failure.retryAt
    }

    mutating func recordFailure(for key: Key, signature: Signature, now: TimeInterval) {
        let count: Int
        if let failure = failures[key], failure.signature == signature {
            count = failure.count + 1
        } else {
            count = 1
        }
        let delay = retryDelays[min(count - 1, retryDelays.count - 1)]
        failures[key] = Failure(signature: signature, count: count, retryAt: now + delay)
    }

    mutating func recordSuccess(for key: Key) {
        failures.removeValue(forKey: key)
    }

    mutating func removeAll() {
        failures.removeAll()
    }

    mutating func removeAll(where shouldRemove: (Key) -> Bool) {
        failures.keys.filter(shouldRemove).forEach { failures.removeValue(forKey: $0) }
    }

    func failureCount(for key: Key) -> Int {
        failures[key]?.count ?? 0
    }
}

enum WindowThumbnailCapturePlan {
    static let maximumConcurrentCaptureCount = 2

    static func select<Candidate>(
        from orderedCandidates: [Candidate],
        maximumStaleCount: Int,
        isMissing: (Candidate) -> Bool
    ) -> [Candidate] {
        var missing = [Candidate]()
        var stale = [Candidate]()
        for candidate in orderedCandidates {
            if isMissing(candidate) {
                missing.append(candidate)
            } else if stale.count < max(0, maximumStaleCount) {
                stale.append(candidate)
            }
        }
        return missing + stale
    }
}
