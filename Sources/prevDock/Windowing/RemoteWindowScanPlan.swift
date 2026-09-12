import ApplicationServices
import CoreGraphics
import Foundation

enum RemoteWindowScanPlan {
    private static let fallbackScanLimit: UInt64 = 1000
    private static let maximumScanLimit: UInt64 = 20000
    private static let scanPadding: UInt64 = 1000
    private static let knownMappingTimeLimit: TimeInterval = 0.03

    static func prioritizedElementIDs(
        pid: pid_t,
        knownWindowElements: [CGWindowID: AXUIElement],
        missingWindowIDs: Set<CGWindowID>,
        scanLimit: UInt64,
        shouldContinue: () -> Bool
    ) -> [UInt64] {
        let knownMappings = knownElementIDMappings(
            pid: pid,
            elementsByWindowID: knownWindowElements,
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

    private static func knownElementIDMappings(
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
        var remoteToken = RemoteWindowToken(pid: pid)
        for elementID in UInt64(0)..<scanLimit {
            if elementID.isMultiple(of: 64),
               (!shouldContinue() || ProcessInfo.processInfo.systemUptime >= deadline) {
                return []
            }
            guard let element = remoteToken.element(for: elementID, messagingTimeout: nil),
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

    private static func interpolationBounds(
        for windowID: CGWindowID,
        in mappings: [KnownRemoteElementMapping]
    ) -> (lower: KnownRemoteElementMapping, upper: KnownRemoteElementMapping)? {
        guard let upperIndex = mappings.firstIndex(where: { $0.windowID > windowID }),
              upperIndex > mappings.startIndex else {
            return nil
        }
        return (mappings[upperIndex - 1], mappings[upperIndex])
    }

    static func tokenScanLimit(targetWindowIDs: Set<CGWindowID>?) -> UInt64 {
        guard let maxWindowID = targetWindowIDs?.max() else { return fallbackScanLimit }
        let paddedLimit = UInt64(maxWindowID) + scanPadding
        return min(max(fallbackScanLimit, paddedLimit), maximumScanLimit)
    }
}

private struct KnownRemoteElementMapping {
    let windowID: CGWindowID
    let elementID: UInt64
}
