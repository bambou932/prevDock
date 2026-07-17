import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: inout CGWindowID) -> AXError

@_silgen_name("_AXUIElementCreateWithRemoteToken")
func _AXUIElementCreateWithRemoteToken(_ remoteToken: CFData) -> Unmanaged<AXUIElement>?

typealias CGSConnectionID = UInt32

struct CGSSpaceMask: OptionSet {
    let rawValue: UInt32

    static let current = CGSSpaceMask(rawValue: 1 << 0)
    static let others = CGSSpaceMask(rawValue: 1 << 1)
    static let user = CGSSpaceMask(rawValue: 1 << 2)
}

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(
    _ connection: CGSConnectionID,
    _ mask: CGSSpaceMask,
    _ windows: CFArray
) -> Unmanaged<CFArray>?

@main
enum RemoteWindowElementResolverLiveTests {
    static func main() {
        let query = CommandLine.arguments.dropFirst().first ?? "com.google.Chrome"
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == query || ($0.localizedName ?? "").localizedCaseInsensitiveContains(query)
        }) else {
            fail("app is not running: \(query)")
        }

        let knownWindowElements = accessibilityWindowElements(pid: app.processIdentifier)
        let knownWindowIDs = Set(knownWindowElements.keys)
        let snapshot = windowSnapshot(pid: app.processIdentifier)
        let missingWindowIDs = snapshot.targetWindowIDs.subtracting(knownWindowIDs)
        let resolver = RemoteWindowElementResolver()
        guard !missingWindowIDs.isEmpty else {
            guard let resolution = resolver.resolve(
                pid: app.processIdentifier,
                knownWindowIDs: knownWindowIDs,
                knownWindowElements: knownWindowElements,
                targetWindowIDs: snapshot.targetWindowIDs
            ), resolution.windows.isEmpty,
               resolution.scanIterationCount == 0 else {
                fail("all-known targets should not run the fallback scan")
            }
            print("app=\(app.localizedName ?? query) pid=\(app.processIdentifier)")
            print("known=\(knownWindowIDs.count) targets=\(snapshot.targetWindowIDs.count) missing=0 no_space_excluded=\(snapshot.excludedNoSpaceWindowIDs.count)")
            print("RemoteWindowElementResolverLiveTests: passed (no remote-only targets)")
            return
        }

        let cancellationGate = CancellationGate(successfulCheckCount: 3)
        guard resolver.resolve(
            pid: app.processIdentifier,
            knownWindowIDs: knownWindowIDs,
            knownWindowElements: knownWindowElements,
            targetWindowIDs: snapshot.targetWindowIDs,
            shouldContinue: cancellationGate.shouldContinue
        ) == nil else {
            fail("mid-scan cancellation should not return a partial resolution")
        }
        let first = measuredResolution(
            resolver: resolver,
            pid: app.processIdentifier,
            knownWindowIDs: knownWindowIDs,
            knownWindowElements: knownWindowElements,
            snapshot: snapshot
        )
        let beforeCommit = measuredResolution(
            resolver: resolver,
            pid: app.processIdentifier,
            knownWindowIDs: knownWindowIDs,
            knownWindowElements: knownWindowElements,
            snapshot: snapshot
        )
        guard beforeCommit.resolution.scanIterationCount > 0 else {
            fail("an uncommitted scan must not publish remote cache mappings")
        }
        resolver.commit(first.resolution)
        let second = measuredResolution(
            resolver: resolver,
            pid: app.processIdentifier,
            knownWindowIDs: knownWindowIDs,
            knownWindowElements: knownWindowElements,
            snapshot: snapshot
        )
        let firstWindowIDs = knownWindowIDs.union(windowIDs(first.resolution.windows))
        let secondWindowIDs = knownWindowIDs.union(windowIDs(second.resolution.windows))
        let firstRemoteWindowIDs = windowIDs(first.resolution.windows)
        let secondRemoteWindowIDs = windowIDs(second.resolution.windows)

        guard firstRemoteWindowIDs == missingWindowIDs else {
            fail("initial scan returned windows outside the eligible remote targets")
        }
        guard secondRemoteWindowIDs == missingWindowIDs else {
            fail("cached lookup returned windows outside the eligible remote targets")
        }
        guard firstRemoteWindowIDs.isDisjoint(with: snapshot.excludedNoSpaceWindowIDs) else {
            fail("initial scan reintroduced a no-Space auxiliary window")
        }
        guard missingWindowIDs.isSubset(of: firstWindowIDs) else {
            fail("initial scan did not resolve every remote-only target")
        }
        guard missingWindowIDs.isSubset(of: secondWindowIDs) else {
            fail("cached lookup did not resolve every remote-only target")
        }
        guard firstWindowIDs == secondWindowIDs else {
            fail("cached lookup changed the combined window set")
        }
        guard first.resolution.scanIterationCount > 0 else {
            fail("initial lookup unexpectedly skipped the fallback scan")
        }
        guard second.resolution.scanIterationCount == 0 else {
            fail("cached lookup unexpectedly repeated the fallback scan")
        }
        guard let allTargetsKnown = resolver.resolve(
            pid: app.processIdentifier,
            knownWindowIDs: knownWindowIDs.union(snapshot.targetWindowIDs),
            knownWindowElements: knownWindowElements,
            targetWindowIDs: snapshot.targetWindowIDs
        ) else {
            fail("all-known target lookup was unexpectedly cancelled")
        }
        guard allTargetsKnown.windows.isEmpty,
              allTargetsKnown.cachedWindowCount == 0,
              allTargetsKnown.scanIterationCount == 0 else {
            fail("known targets should preserve the original empty fallback result")
        }
        guard let emptyTargets = resolver.resolve(
            pid: app.processIdentifier,
            knownWindowIDs: knownWindowIDs,
            knownWindowElements: knownWindowElements,
            targetWindowIDs: []
        ) else {
            fail("empty-target fallback was unexpectedly cancelled")
        }
        guard emptyTargets.windows.isEmpty,
              emptyTargets.cachedWindowCount == 0,
              emptyTargets.scanIterationCount == 0 else {
            fail("a successful empty target snapshot must not run an unfiltered scan")
        }
        guard let unavailableSnapshot = resolver.resolve(
            pid: app.processIdentifier,
            knownWindowIDs: knownWindowIDs,
            knownWindowElements: knownWindowElements,
            targetWindowIDs: nil
        ), unavailableSnapshot.scanIterationCount > 0 else {
            fail("an unavailable target snapshot should preserve fail-open fallback scanning")
        }

        print("app=\(app.localizedName ?? query) pid=\(app.processIdentifier)")
        print("known=\(knownWindowIDs.count) targets=\(snapshot.targetWindowIDs.count) missing=\(missingWindowIDs.count) no_space_excluded=\(snapshot.excludedNoSpaceWindowIDs.count)")
        print(String(format: "first_ms=%.2f first_iterations=%llu", first.elapsedMilliseconds, first.resolution.scanIterationCount))
        print(String(format: "cached_ms=%.3f cached_windows=%d", second.elapsedMilliseconds, second.resolution.cachedWindowCount))
        print("RemoteWindowElementResolverLiveTests: passed")
    }

    private static func measuredResolution(
        resolver: RemoteWindowElementResolver,
        pid: pid_t,
        knownWindowIDs: Set<CGWindowID>,
        knownWindowElements: [CGWindowID: AXUIElement],
        snapshot: WindowSnapshot
    ) -> (resolution: RemoteWindowElementResolution, elapsedMilliseconds: Double) {
        let startedAt = CFAbsoluteTimeGetCurrent()
        guard let resolution = resolver.resolve(
            pid: pid,
            knownWindowIDs: knownWindowIDs,
            knownWindowElements: knownWindowElements,
            targetWindowIDs: snapshot.targetWindowIDs
        ) else {
            fail("live resolution was unexpectedly cancelled")
        }
        return (resolution, (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
    }

    private static func accessibilityWindowElements(pid: pid_t) -> [CGWindowID: AXUIElement] {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success else {
            return [:]
        }
        return (value as? [AXUIElement] ?? []).reduce(into: [:]) { result, element in
            guard let windowID = windowID(element) else { return }
            result[windowID] = element
        }
    }

    private static func windowSnapshot(pid: pid_t) -> WindowSnapshot {
        let descriptions = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        var targetWindowIDs = Set<CGWindowID>()
        var excludedNoSpaceWindowIDs = Set<CGWindowID>()

        for description in descriptions {
            guard description[kCGWindowOwnerPID as String] as? pid_t == pid,
                  let windowID = description[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }
            guard isStructurallyEligibleTargetWindow(description) else { continue }
            let spaceIDs = spaceIDsIfAvailable(windowID: windowID)
            if spaceIDs?.isEmpty == true {
                excludedNoSpaceWindowIDs.insert(windowID)
            } else {
                targetWindowIDs.insert(windowID)
            }
        }
        return WindowSnapshot(
            targetWindowIDs: targetWindowIDs,
            excludedNoSpaceWindowIDs: excludedNoSpaceWindowIDs
        )
    }

    private static func isStructurallyEligibleTargetWindow(_ description: [String: Any]) -> Bool {
        guard (description[kCGWindowName as String] as? String)?.isEmpty == false,
              (description[kCGWindowLayer as String] as? Int ?? 0) <= CGWindowLevelForKey(.floatingWindow) else {
            return false
        }
        let bounds = (description[kCGWindowBounds as String] as? NSDictionary)
            .flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
        return bounds.width >= 80 && bounds.height >= 60
    }

    private static func spaceIDsIfAvailable(windowID: CGWindowID) -> [UInt64]? {
        let windows = [NSNumber(value: windowID)] as CFArray
        let mask: CGSSpaceMask = [.current, .others, .user]
        guard let result = CGSCopySpacesForWindows(CGSMainConnectionID(), mask, windows) else {
            return nil
        }
        let spaces = result.takeRetainedValue() as NSArray
        return spaces.compactMap { ($0 as? NSNumber)?.uint64Value }
    }

    private static func windowIDs(_ windows: [AXUIElement]) -> Set<CGWindowID> {
        Set(windows.compactMap(windowID))
    }

    private static func windowID(_ window: AXUIElement) -> CGWindowID? {
        var windowID = CGWindowID(0)
        guard _AXUIElementGetWindow(window, &windowID) == .success,
              windowID != 0 else {
            return nil
        }
        return windowID
    }

    private static func fail(_ message: String) -> Never {
        fputs("RemoteWindowElementResolverLiveTests: \(message)\n", stderr)
        exit(1)
    }
}

private final class CancellationGate {
    private let lock = NSLock()
    private let successfulCheckCount: Int
    private var checkCount = 0

    init(successfulCheckCount: Int) {
        self.successfulCheckCount = successfulCheckCount
    }

    func shouldContinue() -> Bool {
        lock.lock()
        checkCount += 1
        let shouldContinue = checkCount <= successfulCheckCount
        lock.unlock()
        return shouldContinue
    }
}

private struct WindowSnapshot {
    let targetWindowIDs: Set<CGWindowID>
    let excludedNoSpaceWindowIDs: Set<CGWindowID>
}
