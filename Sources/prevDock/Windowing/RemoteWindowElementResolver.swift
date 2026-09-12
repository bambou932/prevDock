import ApplicationServices
import CoreGraphics
import Foundation

struct RemoteWindowElementResolution {
    let windows: [AXUIElement]
    let cachedWindowCount: Int
    let scanIterationCount: UInt64
    let unresolvedWindowIDs: Set<CGWindowID>?
    fileprivate let cacheCommit: RemoteWindowElementCacheCommit?
}

final class RemoteWindowElementResolver {
    private let elementIDCache = RemoteWindowElementIDCache()
    private let maximumConcurrentScanCount = 6
    private let targetedScanTimeLimit: TimeInterval = 0.35
    private let prioritizedScanTimeLimit: TimeInterval = 0.10

    func resolve(
        pid: pid_t,
        knownWindowIDs: Set<CGWindowID>,
        knownWindowElements: [CGWindowID: AXUIElement] = [:],
        targetWindowIDs: Set<CGWindowID>?,
        shouldContinue: () -> Bool = { true }
    ) -> RemoteWindowElementResolution? {
        guard shouldContinue() else { return nil }
        guard let targetWindowIDs else {
            return resolveWithoutTargetSnapshot(
                pid: pid,
                knownWindowIDs: knownWindowIDs,
                shouldContinue: shouldContinue
            )
        }
        let expectedCacheRevision = elementIDCache.revision(for: pid)
        guard !targetWindowIDs.isEmpty else {
            return RemoteWindowElementResolution(
                windows: [],
                cachedWindowCount: 0,
                scanIterationCount: 0,
                unresolvedWindowIDs: [],
                cacheCommit: cacheCommit(
                    pid: pid,
                    expectedRevision: expectedCacheRevision,
                    targetWindowIDs: targetWindowIDs
                )
            )
        }
        var missingWindowIDs = targetWindowIDs.subtracting(knownWindowIDs)
        guard !missingWindowIDs.isEmpty else {
            return RemoteWindowElementResolution(
                windows: [],
                cachedWindowCount: 0,
                scanIterationCount: 0,
                unresolvedWindowIDs: [],
                cacheCommit: cacheCommit(
                    pid: pid,
                    expectedRevision: expectedCacheRevision,
                    targetWindowIDs: targetWindowIDs
                )
            )
        }
        let cachedResolution = validatedCachedElements(
            pid: pid,
            knownWindowIDs: knownWindowIDs,
            targetWindowIDs: targetWindowIDs,
            shouldContinue: shouldContinue
        )
        guard shouldContinue() else { return nil }
        let cachedElements = cachedResolution.elements
        missingWindowIDs.subtract(cachedElements.keys)
        missingWindowIDs.formUnion(cachedResolution.rejectedElementIDsByWindow.keys)
        let cachedWindowIDs = Set(cachedElements.keys)
        let windows = cachedWindowIDs.sorted().compactMap { cachedElements[$0] }
        guard !missingWindowIDs.isEmpty else {
            return RemoteWindowElementResolution(
                windows: windows,
                cachedWindowCount: cachedElements.count,
                scanIterationCount: 0,
                unresolvedWindowIDs: [],
                cacheCommit: cacheCommit(
                    pid: pid,
                    expectedRevision: expectedCacheRevision,
                    targetWindowIDs: targetWindowIDs,
                    rejectedElementIDsByWindow: cachedResolution.rejectedElementIDsByWindow
                )
            )
        }
        let context = RemoteWindowScanContext(
            pid: pid,
            expectedCacheRevision: expectedCacheRevision,
            knownWindowIDs: knownWindowIDs,
            knownWindowElements: knownWindowElements,
            targetWindowIDs: Optional(targetWindowIDs),
            cachedWindowIDs: cachedWindowIDs,
            rejectedElementIDsByWindow: cachedResolution.rejectedElementIDsByWindow
        )
        return scan(
            context: context,
            initialWindows: windows,
            missingWindowIDs: missingWindowIDs,
            shouldContinue: shouldContinue
        )
    }

    func commit(_ resolution: RemoteWindowElementResolution) {
        guard let commit = resolution.cacheCommit else { return }
        elementIDCache.apply(
            pid: commit.pid,
            expectedRevision: commit.expectedRevision,
            retainingWindowIDs: commit.retainedWindowIDs,
            rejectedElementIDsByWindow: commit.rejectedElementIDsByWindow,
            recording: commit.elementIDsByWindow
        )
    }

    private func resolveWithoutTargetSnapshot(
        pid: pid_t,
        knownWindowIDs: Set<CGWindowID>,
        shouldContinue: () -> Bool
    ) -> RemoteWindowElementResolution? {
        let context = RemoteWindowScanContext(
            pid: pid,
            expectedCacheRevision: nil,
            knownWindowIDs: knownWindowIDs,
            knownWindowElements: [:],
            targetWindowIDs: nil,
            cachedWindowIDs: [],
            rejectedElementIDsByWindow: [:]
        )
        return scan(
            context: context,
            initialWindows: [],
            missingWindowIDs: [],
            shouldContinue: shouldContinue
        )
    }

    private func validatedCachedElements(
        pid: pid_t,
        knownWindowIDs: Set<CGWindowID>,
        targetWindowIDs: Set<CGWindowID>,
        shouldContinue: () -> Bool
    ) -> ValidatedRemoteElements {
        var rejectedElementIDsByWindow = [CGWindowID: UInt64]()
        let elements = elementIDCache.resolve(
            pid: pid,
            windowIDs: targetWindowIDs.subtracting(knownWindowIDs),
            elementForID: { RemoteWindowToken.element(pid: pid, elementID: $0) },
            validates: { RemoteWindowElementValidation.isExpectedWindow($0, windowID: $1) },
            onRejected: { rejectedElementIDsByWindow[$0] = $1 },
            evictsRejected: false,
            shouldContinue: shouldContinue
        )
        return ValidatedRemoteElements(
            elements: elements,
            rejectedElementIDsByWindow: rejectedElementIDsByWindow
        )
    }

    private func scan(
        context: RemoteWindowScanContext,
        initialWindows: [AXUIElement],
        missingWindowIDs initialMissingWindowIDs: Set<CGWindowID>,
        shouldContinue: () -> Bool
    ) -> RemoteWindowElementResolution? {
        guard context.targetWindowIDs == nil else {
            return scanTargetedWindows(
                context: context,
                initialWindows: initialWindows,
                missingWindowIDs: initialMissingWindowIDs,
                shouldContinue: shouldContinue
            )
        }
        return scanUntargetedWindows(
            pid: context.pid,
            knownWindowIDs: context.knownWindowIDs,
            shouldContinue: shouldContinue
        )
    }

    private func scanUntargetedWindows(
        pid: pid_t,
        knownWindowIDs: Set<CGWindowID>,
        shouldContinue: () -> Bool
    ) -> RemoteWindowElementResolution? {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.10
        let scanLimit = RemoteWindowScanPlan.tokenScanLimit(targetWindowIDs: nil)
        var remoteToken = RemoteWindowToken(pid: pid)
        var windows = [AXUIElement]()
        var scanIterationCount: UInt64 = 0
        for elementID in UInt64(0)..<scanLimit {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            guard shouldContinue() else { return nil }
            scanIterationCount += 1
            guard let element = remoteToken.element(for: elementID) else {
                continue
            }
            guard RemoteWindowElementValidation.isAXWindowElement(element) else { continue }
            guard let resolvedWindowID = RemoteWindowElementValidation.windowID(for: element) else {
                windows.append(element)
                continue
            }
            if !knownWindowIDs.contains(resolvedWindowID) {
                windows.append(element)
            }
        }
        guard shouldContinue() else { return nil }
        return RemoteWindowElementResolution(
            windows: windows,
            cachedWindowCount: 0,
            scanIterationCount: scanIterationCount,
            unresolvedWindowIDs: nil,
            cacheCommit: nil
        )
    }

    private func scanTargetedWindows(
        context: RemoteWindowScanContext,
        initialWindows: [AXUIElement],
        missingWindowIDs: Set<CGWindowID>,
        shouldContinue: () -> Bool
    ) -> RemoteWindowElementResolution? {
        guard let targetWindowIDs = context.targetWindowIDs,
              let expectedCacheRevision = context.expectedCacheRevision else {
            return nil
        }
        let scanLimit = RemoteWindowScanPlan.tokenScanLimit(targetWindowIDs: targetWindowIDs)
        let state = ConcurrentRemoteWindowScanState(
            windows: initialWindows,
            missingWindowIDs: missingWindowIDs
        )
        let prioritizedElementIDs = RemoteWindowScanPlan.prioritizedElementIDs(
            pid: context.pid,
            knownWindowElements: context.knownWindowElements,
            missingWindowIDs: missingWindowIDs,
            scanLimit: scanLimit,
            shouldContinue: shouldContinue
        )
        let prioritizedDeadline = ProcessInfo.processInfo.systemUptime + prioritizedScanTimeLimit
        scanTargetedElements(
            prioritizedElementIDs,
            context: context,
            state: state,
            deadline: prioritizedDeadline,
            shouldContinue: shouldContinue
        )
        if !state.isComplete, shouldContinue() {
            let fallbackDeadline = ProcessInfo.processInfo.systemUptime + targetedScanTimeLimit
            scanTargetedElements(
                Array(UInt64(0)..<scanLimit),
                context: context,
                state: state,
                deadline: fallbackDeadline,
                shouldContinue: shouldContinue
            )
        }

        guard shouldContinue() else { return nil }
        let result = state.result
        let elementIDsByWindow = Dictionary(
            result.pendingMappings.map { ($0.windowID, $0.elementID) },
            uniquingKeysWith: { _, newest in newest }
        )
        return RemoteWindowElementResolution(
            windows: result.windows,
            cachedWindowCount: context.cachedWindowIDs.count,
            scanIterationCount: result.scanIterationCount,
            unresolvedWindowIDs: result.missingWindowIDs,
            cacheCommit: cacheCommit(
                pid: context.pid,
                expectedRevision: expectedCacheRevision,
                targetWindowIDs: targetWindowIDs,
                rejectedElementIDsByWindow: context.rejectedElementIDsByWindow,
                elementIDsByWindow: elementIDsByWindow
            )
        )
    }

    private func scanTargetedElements(
        _ elementIDs: [UInt64],
        context: RemoteWindowScanContext,
        state: ConcurrentRemoteWindowScanState,
        deadline: TimeInterval,
        shouldContinue: () -> Bool
    ) {
        guard !elementIDs.isEmpty,
              let targetWindowIDs = context.targetWindowIDs else {
            return
        }
        let workerCount = min(maximumConcurrentScanCount, elementIDs.count)
        DispatchQueue.concurrentPerform(iterations: workerCount) { workerIndex in
            var remoteToken = RemoteWindowToken(pid: context.pid)
            var iterationCount: UInt64 = 0
            for index in stride(from: workerIndex, to: elementIDs.count, by: workerCount) {
                guard shouldContinue(),
                      !state.isComplete,
                      ProcessInfo.processInfo.systemUptime < deadline else {
                    break
                }
                iterationCount += 1
                let elementID = elementIDs[index]
                guard let element = remoteToken.element(for: elementID) else {
                    continue
                }
                guard let resolvedWindowID = RemoteWindowElementValidation.windowID(for: element),
                      targetWindowIDs.contains(resolvedWindowID),
                      !context.knownWindowIDs.contains(resolvedWindowID),
                      RemoteWindowElementValidation.isAXWindowElement(element) else {
                    continue
                }
                state.accept(
                    element: element,
                    elementID: elementID,
                    windowID: resolvedWindowID
                )
                if state.isComplete { break }
            }
            state.addScanIterations(iterationCount)
        }
    }

    private func cacheCommit(
        pid: pid_t,
        expectedRevision: UInt64,
        targetWindowIDs: Set<CGWindowID>,
        rejectedElementIDsByWindow: [CGWindowID: UInt64] = [:],
        elementIDsByWindow: [CGWindowID: UInt64] = [:]
    ) -> RemoteWindowElementCacheCommit {
        RemoteWindowElementCacheCommit(
            pid: pid,
            expectedRevision: expectedRevision,
            retainedWindowIDs: targetWindowIDs,
            rejectedElementIDsByWindow: rejectedElementIDsByWindow,
            elementIDsByWindow: elementIDsByWindow
        )
    }

    func remove(pid: pid_t, windowID: CGWindowID) {
        elementIDCache.remove(pid: pid, windowID: windowID)
    }

    func removeAll(for pid: pid_t) {
        elementIDCache.removeAll(for: pid)
    }
}

private struct RemoteWindowScanContext {
    let pid: pid_t
    let expectedCacheRevision: UInt64?
    let knownWindowIDs: Set<CGWindowID>
    let knownWindowElements: [CGWindowID: AXUIElement]
    let targetWindowIDs: Set<CGWindowID>?
    let cachedWindowIDs: Set<CGWindowID>
    let rejectedElementIDsByWindow: [CGWindowID: UInt64]
}

private struct RemoteWindowElementCacheCommit {
    let pid: pid_t
    let expectedRevision: UInt64
    let retainedWindowIDs: Set<CGWindowID>
    let rejectedElementIDsByWindow: [CGWindowID: UInt64]
    let elementIDsByWindow: [CGWindowID: UInt64]
}

private struct ValidatedRemoteElements {
    let elements: [CGWindowID: AXUIElement]
    let rejectedElementIDsByWindow: [CGWindowID: UInt64]
}
