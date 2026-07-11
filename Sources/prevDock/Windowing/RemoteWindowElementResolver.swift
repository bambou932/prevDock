import ApplicationServices
import CoreGraphics
import Foundation

struct RemoteWindowElementResolution {
    let windows: [AXUIElement]
    let cachedWindowCount: Int
    let scanIterationCount: UInt64
    fileprivate let cacheCommit: RemoteWindowElementCacheCommit?
}

final class RemoteWindowElementResolver {
    private let elementIDCache = RemoteWindowElementIDCache()
    private let fallbackScanLimit: UInt64 = 1000
    private let maximumScanLimit: UInt64 = 20000
    private let scanPadding: UInt64 = 1000
    private let maximumConcurrentScanCount = 6
    private let cancellationCheckStride: UInt64 = 16
    private let targetedScanTimeLimit: TimeInterval = 0.35
    private let knownMappingTimeLimit: TimeInterval = 0.03
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
            elementForID: { self.remoteElement(pid: pid, elementID: $0) },
            validates: { self.isExpectedWindow($0, windowID: $1) },
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
        let deadline = Date().addingTimeInterval(0.10)
        let scanLimit = remoteTokenScanLimit(targetWindowIDs: nil)
        var remoteToken = baseRemoteToken(pid: pid)
        var windows = [AXUIElement]()
        var scanIterationCount: UInt64 = 0
        for elementID in UInt64(0)..<scanLimit {
            guard Date() < deadline else { break }
            scanIterationCount += 1
            if scanIterationCount.isMultiple(of: 64), !shouldContinue() { return nil }
            setElementID(elementID, in: &remoteToken)
            guard let element = _AXUIElementCreateWithRemoteToken(remoteToken as CFData)?.takeRetainedValue() else {
                continue
            }
            guard isAXWindowElement(element) else { continue }
            guard let resolvedWindowID = windowID(for: element) else {
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
        let scanLimit = remoteTokenScanLimit(targetWindowIDs: targetWindowIDs)
        let state = ConcurrentRemoteWindowScanState(
            windows: initialWindows,
            missingWindowIDs: missingWindowIDs
        )
        let prioritizedElementIDs = prioritizedElementIDs(
            context: context,
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
            var remoteToken = baseRemoteToken(pid: context.pid)
            var iterationCount: UInt64 = 0
            for index in stride(from: workerIndex, to: elementIDs.count, by: workerCount) {
                iterationCount += 1
                if iterationCount.isMultiple(of: cancellationCheckStride) {
                    guard shouldContinue(),
                          !state.isComplete,
                          ProcessInfo.processInfo.systemUptime < deadline else {
                        break
                    }
                }
                let elementID = elementIDs[index]
                setElementID(elementID, in: &remoteToken)
                guard let element = _AXUIElementCreateWithRemoteToken(remoteToken as CFData)?.takeRetainedValue(),
                      let resolvedWindowID = windowID(for: element),
                      targetWindowIDs.contains(resolvedWindowID),
                      !context.knownWindowIDs.contains(resolvedWindowID),
                      isAXWindowElement(element) else {
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

    private func prioritizedElementIDs(
        context: RemoteWindowScanContext,
        missingWindowIDs: Set<CGWindowID>,
        scanLimit: UInt64,
        shouldContinue: () -> Bool
    ) -> [UInt64] {
        let knownMappings = knownElementIDMappings(
            pid: context.pid,
            elementsByWindowID: context.knownWindowElements,
            scanLimit: scanLimit,
            deadline: ProcessInfo.processInfo.systemUptime + knownMappingTimeLimit,
            shouldContinue: shouldContinue
        )
        guard knownMappings.count >= 2, shouldContinue() else { return [] }
        let sortedMappings = knownMappings.sorted { $0.windowID < $1.windowID }
        var prioritized = Set<UInt64>()
        for windowID in missingWindowIDs {
            guard let bounds = interpolationBounds(for: windowID, in: sortedMappings) else {
                continue
            }
            let windowSpan = Double(bounds.upper.windowID - bounds.lower.windowID)
            let ratio = Double(windowID - bounds.lower.windowID) / windowSpan
            let elementSpan = Double(bounds.upper.elementID) - Double(bounds.lower.elementID)
            let estimate = Double(bounds.lower.elementID) + ratio * elementSpan
            guard estimate.isFinite else { continue }
            let center = min(max(UInt64(max(0, estimate.rounded())), 0), scanLimit - 1)
            let radius: UInt64 = 1024
            let lower = center > radius ? center - radius : 0
            let upper = min(scanLimit, center + radius + 1)
            prioritized.formUnion(lower..<upper)
        }
        return prioritized.sorted()
    }

    private func knownElementIDMappings(
        pid: pid_t,
        elementsByWindowID: [CGWindowID: AXUIElement],
        scanLimit: UInt64,
        deadline: TimeInterval,
        shouldContinue: () -> Bool
    ) -> [KnownRemoteElementMapping] {
        guard elementsByWindowID.count >= 2 else { return [] }
        let elementsByHash = Dictionary(grouping: elementsByWindowID) {
            CFHash($0.value)
        }
        var unresolvedWindowIDs = Set(elementsByWindowID.keys)
        var mappings = [KnownRemoteElementMapping]()
        var remoteToken = baseRemoteToken(pid: pid)
        for elementID in UInt64(0)..<scanLimit {
            if elementID.isMultiple(of: 64),
               (!shouldContinue() || ProcessInfo.processInfo.systemUptime >= deadline) {
                return []
            }
            setElementID(elementID, in: &remoteToken)
            guard let element = _AXUIElementCreateWithRemoteToken(remoteToken as CFData)?.takeRetainedValue(),
                  let candidates = elementsByHash[CFHash(element)] else {
                continue
            }
            for (windowID, knownElement) in candidates where unresolvedWindowIDs.contains(windowID) {
                guard CFEqual(element, knownElement) else { continue }
                unresolvedWindowIDs.remove(windowID)
                mappings.append(KnownRemoteElementMapping(windowID: windowID, elementID: elementID))
            }
            if unresolvedWindowIDs.isEmpty { break }
        }
        return mappings
    }

    private func interpolationBounds(
        for windowID: CGWindowID,
        in mappings: [KnownRemoteElementMapping]
    ) -> (lower: KnownRemoteElementMapping, upper: KnownRemoteElementMapping)? {
        guard let upperIndex = mappings.firstIndex(where: { $0.windowID > windowID }),
              upperIndex > mappings.startIndex else {
            return nil
        }
        return (mappings[upperIndex - 1], mappings[upperIndex])
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

    private func remoteElement(pid: pid_t, elementID: UInt64) -> AXUIElement? {
        var remoteToken = baseRemoteToken(pid: pid)
        setElementID(elementID, in: &remoteToken)
        return _AXUIElementCreateWithRemoteToken(remoteToken as CFData)?.takeRetainedValue()
    }

    private func baseRemoteToken(pid: pid_t) -> Data {
        var remoteToken = Data(count: 20)
        remoteToken.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        remoteToken.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        remoteToken.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
        return remoteToken
    }

    private func setElementID(_ elementID: UInt64, in remoteToken: inout Data) {
        remoteToken.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })
    }

    private func isExpectedWindow(_ element: AXUIElement, windowID expectedWindowID: CGWindowID) -> Bool {
        isAXWindowElement(element) && windowID(for: element) == expectedWindowID
    }

    private func isAXWindowElement(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &value
        ) == .success else {
            return false
        }
        let subrole = value as? String
        return [
            kAXStandardWindowSubrole as String,
            kAXDialogSubrole as String,
            kAXFloatingWindowSubrole as String
        ].contains(subrole ?? "")
    }

    private func windowID(for element: AXUIElement) -> CGWindowID? {
        var id = CGWindowID(0)
        guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    private func remoteTokenScanLimit(targetWindowIDs: Set<CGWindowID>?) -> UInt64 {
        guard let maxWindowID = targetWindowIDs?.max() else { return fallbackScanLimit }
        let paddedLimit = UInt64(maxWindowID) + scanPadding
        return min(max(fallbackScanLimit, paddedLimit), maximumScanLimit)
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

private struct KnownRemoteElementMapping {
    let windowID: CGWindowID
    let elementID: UInt64
}

private struct RemoteWindowElementCacheCommit {
    let pid: pid_t
    let expectedRevision: UInt64
    let retainedWindowIDs: Set<CGWindowID>
    let rejectedElementIDsByWindow: [CGWindowID: UInt64]
    let elementIDsByWindow: [CGWindowID: UInt64]
}

private struct RemoteWindowElementMapping {
    let elementID: UInt64
    let windowID: CGWindowID
}

private final class ConcurrentRemoteWindowScanState {
    private let lock = NSLock()
    private var windows: [AXUIElement]
    private var missingWindowIDs: Set<CGWindowID>
    private var pendingMappings = [RemoteWindowElementMapping]()
    private var scanIterationCount: UInt64 = 0

    init(windows: [AXUIElement], missingWindowIDs: Set<CGWindowID>) {
        self.windows = windows
        self.missingWindowIDs = missingWindowIDs
    }

    var isComplete: Bool {
        lock.lock()
        let isComplete = missingWindowIDs.isEmpty
        lock.unlock()
        return isComplete
    }

    func accept(
        element: AXUIElement,
        elementID: UInt64,
        windowID: CGWindowID
    ) {
        lock.lock()
        guard missingWindowIDs.remove(windowID) != nil else {
            lock.unlock()
            return
        }
        windows.append(element)
        pendingMappings.append(RemoteWindowElementMapping(
            elementID: elementID,
            windowID: windowID
        ))
        lock.unlock()
    }

    func addScanIterations(_ count: UInt64) {
        lock.lock()
        scanIterationCount += count
        lock.unlock()
    }

    var result: ConcurrentRemoteWindowScanResult {
        lock.lock()
        let result = ConcurrentRemoteWindowScanResult(
            windows: windows,
            pendingMappings: pendingMappings,
            scanIterationCount: scanIterationCount
        )
        lock.unlock()
        return result
    }
}

private struct ConcurrentRemoteWindowScanResult {
    let windows: [AXUIElement]
    let pendingMappings: [RemoteWindowElementMapping]
    let scanIterationCount: UInt64
}

private struct ValidatedRemoteElements {
    let elements: [CGWindowID: AXUIElement]
    let rejectedElementIDsByWindow: [CGWindowID: UInt64]
}
