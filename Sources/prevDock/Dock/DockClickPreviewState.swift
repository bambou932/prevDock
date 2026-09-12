import Foundation

struct DockClickPreviewState {
    enum Resolution: Equatable {
        case showPreview
        case restoreNativeClick
        case retry
        case keepPreview
    }

    let actionGeneration: Int
    let frontmostPID: pid_t?
    let startedAt: TimeInterval
    let deadline: TimeInterval
    let hasUsablePreviews: Bool

    init(
        actionGeneration: Int,
        frontmostPID: pid_t?,
        startedAt: TimeInterval,
        hasUsablePreviews: Bool,
        timeout: TimeInterval = 0.75
    ) {
        self.actionGeneration = actionGeneration
        self.frontmostPID = frontmostPID
        self.startedAt = startedAt
        deadline = startedAt + timeout
        self.hasUsablePreviews = hasUsablePreviews
    }

    static func shouldIntercept(completeCachedWindowCount: Int?) -> Bool {
        guard let count = completeCachedWindowCount else { return true }
        return count >= 2
    }

    func isCurrent(actionGeneration: Int, frontmostPID: pid_t?) -> Bool {
        self.actionGeneration == actionGeneration && self.frontmostPID == frontmostPID
    }

    func resolution(windowCount: Int, isComplete: Bool, now: TimeInterval) -> Resolution {
        if windowCount >= 2 { return .showPreview }
        if isComplete { return .restoreNativeClick }
        if hasUsablePreviews { return .keepPreview }
        return now < deadline ? .retry : .restoreNativeClick
    }

    var timeoutResolution: Resolution {
        hasUsablePreviews ? .keepPreview : .restoreNativeClick
    }
}
