import ApplicationServices
import AppKit
import Foundation

private let prevDockBundleID = "io.github.bambou932.prevDock"
private let previewNamePrefix = "prevDock.preview."
private let idlePreviewMarker = "prevDock.preview.idle"
private let previewMinimumSize = CGSize(width: 80, height: 60)
private let previewWindowLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))

private struct Arguments {
    let dockPoint: CGPoint
    let iterationCount: Int
    let prevDockPID: pid_t
    let targetPID: pid_t
    let expectedExecutablePath: String
    let sweepPoints: [CGPoint]
    let expectsColdStart: Bool
    let spaceSwitch: SpaceSwitchDirection?
    let outsideDwell: TimeInterval
}

private enum SpaceSwitchDirection: String {
    case left
    case right

    var keyCode: CGKeyCode {
        self == .left ? 123 : 124
    }

    var opposite: SpaceSwitchDirection {
        self == .left ? .right : .left
    }
}

private struct PresentationWindow {
    let windowID: CGWindowID
    let marker: String
    let frame: CGRect
}

private let arguments = parseArguments()
validateApplications(arguments)
validateInstantSetting()
validateSweepPoints(arguments.sweepPoints, targetPID: arguments.targetPID)

let outsidePoint = safeOutsidePoint()
var knownPreviewWindowID: CGWindowID?
private let initialPresentation = currentPresentation(pid: arguments.prevDockPID, includeOffscreen: true)
knownPreviewWindowID = initialPresentation?.windowID
if arguments.expectsColdStart,
   let initialPresentation,
   initialPresentation.marker != idlePreviewMarker {
    fail("--expect-cold requires a newly started, not-yet-presented prevDock process")
}

var samples = [Double]()
var timeoutCount = 0
if let direction = arguments.spaceSwitch {
    if let elapsed = measureSpaceSwitchHover(
        pid: arguments.prevDockPID,
        targetPID: arguments.targetPID,
        dockPoint: arguments.dockPoint,
        outsidePoint: outsidePoint,
        direction: direction
    ) {
        samples.append(elapsed)
    } else {
        timeoutCount += 1
    }
} else {
    for _ in 0..<arguments.iterationCount {
        hidePreviewOrFail(pid: arguments.prevDockPID, outsidePoint: outsidePoint)
        usleep(useconds_t(arguments.outsideDwell * 1_000_000))
        for point in arguments.sweepPoints {
            postMouseMove(to: point)
            usleep(80_000)
        }

        let previousMarker = currentPresentation(
            pid: arguments.prevDockPID,
            includeOffscreen: true
        )?.marker
        let startedAt = CFAbsoluteTimeGetCurrent()
        postMouseMove(to: arguments.dockPoint)
        if waitForTargetPresentation(
            pid: arguments.prevDockPID,
            targetPID: arguments.targetPID,
            after: previousMarker,
            timeout: 1.2
        ) {
            samples.append((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        } else {
            timeoutCount += 1
        }
    }
}

hidePreviewOrFail(pid: arguments.prevDockPID, outsidePoint: outsidePoint)
guard samples.count == arguments.iterationCount else {
    fail("expected \(arguments.iterationCount) samples, received \(samples.count)")
}

let sorted = samples.sorted()
let p50 = percentile(0.50, in: sorted)
let p95 = percentile(0.95, in: sorted)
let maximum = sorted.last ?? 0
let outlierCount = samples.filter { $0 >= 500 }.count
let nativeSuppression = UserDefaults(suiteName: prevDockBundleID)?
    .bool(forKey: "nativeDockLabelSuppressionEnabled") == true
print("samples=\(samples.count) timeouts=\(timeoutCount) p50_ms=\(format(p50)) p95_ms=\(format(p95)) max_ms=\(format(maximum)) outliers_500ms=\(outlierCount) native_label_suppression=\(nativeSuppression ? "on" : "off")")

let exceedsLatencyTarget: Bool
if arguments.spaceSwitch != nil {
    print("space_hover_ms=\(format(samples[0]))")
    exceedsLatencyTarget = samples[0] > 300
} else if arguments.sweepPoints.isEmpty, arguments.expectsColdStart {
    let cold = samples[0]
    let cached = Array(samples.dropFirst()).sorted()
    let cachedP95 = percentile(0.95, in: cached)
    print("cold_ms=\(format(cold)) cached_samples=\(cached.count) cached_p95_ms=\(format(cachedP95))")
    exceedsLatencyTarget = cold > 300 || cachedP95 > 100
} else if arguments.sweepPoints.isEmpty {
    print("cached_samples=\(samples.count) cached_p95_ms=\(format(p95))")
    exceedsLatencyTarget = maximum > 300 || p95 > 100
} else {
    print("first_final_ms=\(format(samples[0])) final_p95_ms=\(format(p95))")
    exceedsLatencyTarget = maximum > 300 || p95 > 100
}
print("values_ms=\(samples.map(format).joined(separator: ","))")

if timeoutCount > 0 || outlierCount > 0 || exceedsLatencyTarget {
    exit(1)
}

private func parseArguments() -> Arguments {
    let values = Array(CommandLine.arguments.dropFirst())
    guard values.count >= 9,
          let appKitX = Double(values[0]),
          let appKitY = Double(values[1]),
          let iterationCount = Int(values[2]),
          iterationCount > 0 else {
        usage()
    }

    var prevDockPID: pid_t?
    var targetPID: pid_t?
    var executablePath: String?
    var sweepXValues = [Double]()
    var expectsColdStart = false
    var spaceSwitch: SpaceSwitchDirection?
    var outsideDwell: TimeInterval = 0.03
    var index = 3
    while index < values.count {
        switch values[index] {
        case "--prevdock-pid":
            index += 1
            prevDockPID = index < values.count ? pid_t(values[index]) : nil
        case "--target-pid":
            index += 1
            targetPID = index < values.count ? pid_t(values[index]) : nil
        case "--executable":
            index += 1
            executablePath = index < values.count ? values[index] : nil
        case "--sweep-x":
            index += 1
            guard index < values.count else { usage() }
            let pieces = values[index].split(separator: ",", omittingEmptySubsequences: false)
            guard pieces.count == 10,
                  pieces.allSatisfy({ Double($0) != nil }) else {
                fail("--sweep-x requires exactly 10 valid comma-separated coordinates")
            }
            sweepXValues = pieces.compactMap { Double($0) }
        case "--expect-cold":
            expectsColdStart = true
        case "--space-switch":
            index += 1
            guard index < values.count,
                  let direction = SpaceSwitchDirection(rawValue: values[index]) else {
                fail("--space-switch must be left or right")
            }
            spaceSwitch = direction
        case "--idle-ms":
            index += 1
            guard index < values.count,
                  let milliseconds = Double(values[index]),
                  milliseconds >= 0 else {
                fail("--idle-ms requires a non-negative number")
            }
            outsideDwell = milliseconds / 1000
        default:
            usage()
        }
        index += 1
    }

    guard let prevDockPID, let targetPID, let executablePath else { usage() }
    if spaceSwitch == nil {
        guard iterationCount >= 2 else { usage() }
    } else {
        guard iterationCount == 1, sweepXValues.isEmpty, !expectsColdStart else { usage() }
    }
    let referenceMaxY = primaryScreenMaxY()
    let dockPoint = CGPoint(x: appKitX, y: referenceMaxY - appKitY)
    let sweepPoints = sweepXValues.map { CGPoint(x: $0, y: referenceMaxY - appKitY) }
    guard Set(sweepPoints.map(\.x)).count == sweepPoints.count,
          !sweepPoints.contains(where: { abs($0.x - dockPoint.x) < 1 }) else {
        fail("sweep coordinates must be unique and exclude the final target")
    }
    return Arguments(
        dockPoint: dockPoint,
        iterationCount: iterationCount,
        prevDockPID: prevDockPID,
        targetPID: targetPID,
        expectedExecutablePath: executablePath,
        sweepPoints: sweepPoints,
        expectsColdStart: expectsColdStart,
        spaceSwitch: spaceSwitch,
        outsideDwell: outsideDwell
    )
}

private func usage() -> Never {
    fputs("usage: MeasureDockHover appkitX appkitY iterations --prevdock-pid PID --target-pid PID --executable PATH [--sweep-x x1,...,x10] [--expect-cold] [--space-switch left|right] [--idle-ms N]\n", stderr)
    exit(2)
}

private func validateApplications(_ arguments: Arguments) {
    let matchingInstances = NSRunningApplication
        .runningApplications(withBundleIdentifier: prevDockBundleID)
        .filter { !$0.isTerminated }
    guard matchingInstances.map(\.processIdentifier) == [arguments.prevDockPID] else {
        fail("exactly one prevDock instance must be running, and it must match --prevdock-pid")
    }
    guard let app = NSRunningApplication(processIdentifier: arguments.prevDockPID),
          app.bundleIdentifier == prevDockBundleID,
          !app.isTerminated else {
        fail("the requested prevDock PID is not running")
    }
    let actualPath = app.executableURL?.standardizedFileURL.resolvingSymlinksInPath().path
    let expectedPath = URL(fileURLWithPath: arguments.expectedExecutablePath)
        .standardizedFileURL
        .resolvingSymlinksInPath()
        .path
    guard actualPath == expectedPath else {
        fail("prevDock executable mismatch: \(actualPath ?? "missing")")
    }
    guard let target = NSRunningApplication(processIdentifier: arguments.targetPID),
          !target.isTerminated else {
        fail("the requested target PID is not running")
    }
    guard dockApplicationPID(at: arguments.dockPoint) == arguments.targetPID else {
        fail("the final Dock coordinate does not resolve to the requested target PID")
    }
}

private func validateInstantSetting() {
    let defaults = UserDefaults(suiteName: prevDockBundleID)
    guard let delay = defaults?.object(forKey: "previewSwitchDelay") as? NSNumber,
          delay.doubleValue == 0 else {
        fail("hover measurement requires the Instant preview setting")
    }
}

private func validateSweepPoints(_ points: [CGPoint], targetPID: pid_t) {
    guard !points.isEmpty else { return }
    let identities = points.compactMap(dockApplicationPID)
    guard identities.count == points.count,
          Set(identities).count == points.count,
          !identities.contains(targetPID) else {
        fail("every sweep coordinate must resolve to a distinct running Dock app other than the final target")
    }
}

private func dockApplicationPID(at point: CGPoint) -> pid_t? {
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
        return nil
    }
    let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(dockElement, Float(point.x), Float(point.y), &hit) == .success,
          var element = hit else {
        return nil
    }
    for _ in 0..<8 {
        if let url = urlAttribute(element, "AXURL" as CFString),
           let bundleID = Bundle(url: url)?.bundleIdentifier {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { !$0.isTerminated })?
                .processIdentifier
        }
        guard let parent = elementAttribute(element, kAXParentAttribute as CFString) else { break }
        element = parent
    }
    return nil
}

private func hidePreviewOrFail(pid: pid_t, outsidePoint: CGPoint) {
    postMouseMove(to: outsidePoint)
    guard waitForPreview(pid: pid, visible: false, timeout: 0.8) else {
        fail("preview did not hide before measurement")
    }
}

private func waitForTargetPresentation(
    pid: pid_t,
    targetPID: pid_t,
    after previousMarker: String?,
    timeout: TimeInterval,
    stableFor stableDuration: TimeInterval = 0,
    onFirstSeen: ((CFAbsoluteTime) -> Void)? = nil
) -> Bool {
    let expectedPrefix = "\(previewNamePrefix)\(targetPID)."
    let deadline = CFAbsoluteTimeGetCurrent() + timeout
    var candidateMarker: String?
    var candidateStartedAt = CFAbsoluteTimeGetCurrent()
    var didReportFirstSeen = false
    repeat {
        if let presentation = currentPresentation(pid: pid, includeOffscreen: false),
           presentation.marker.hasPrefix(expectedPrefix),
           presentation.marker != previousMarker {
            knownPreviewWindowID = presentation.windowID
            if candidateMarker != presentation.marker {
                candidateMarker = presentation.marker
                candidateStartedAt = CFAbsoluteTimeGetCurrent()
                if !didReportFirstSeen {
                    didReportFirstSeen = true
                    onFirstSeen?(candidateStartedAt)
                }
            }
            if CFAbsoluteTimeGetCurrent() - candidateStartedAt >= stableDuration {
                return true
            }
        } else {
            candidateMarker = nil
        }
        usleep(10_000)
    } while CFAbsoluteTimeGetCurrent() < deadline
    return false
}

private func measureSpaceSwitchHover(
    pid: pid_t,
    targetPID: pid_t,
    dockPoint: CGPoint,
    outsidePoint: CGPoint,
    direction: SpaceSwitchDirection
) -> Double? {
    hidePreviewOrFail(pid: pid, outsidePoint: outsidePoint)
    let previousMarker = currentPresentation(pid: pid, includeOffscreen: true)?.marker
    var startedAt: CFAbsoluteTime?
    let switched = postSpaceSwitchAndWait(direction) {
        startedAt = CFAbsoluteTimeGetCurrent()
        postMouseMove(to: dockPoint)
    }
    guard switched else {
        fputs("MeasureDockHover: Space did not change in the requested direction\n", stderr)
        return nil
    }
    guard let startedAt else {
        fputs("MeasureDockHover: Space notification did not start the hover clock\n", stderr)
        _ = postSpaceSwitchAndWait(direction.opposite)
        return nil
    }
    var firstPresentedAt: CFAbsoluteTime?
    guard waitForTargetPresentation(
        pid: pid,
        targetPID: targetPID,
        after: previousMarker,
        timeout: 1.2,
        stableFor: 0.08,
        onFirstSeen: { firstPresentedAt = $0 }
    ) else {
        fputs("MeasureDockHover: target preview did not stabilize after the Space change\n", stderr)
        _ = postSpaceSwitchAndWait(direction.opposite)
        return nil
    }
    let elapsed = ((firstPresentedAt ?? CFAbsoluteTimeGetCurrent()) - startedAt) * 1000
    guard postSpaceSwitchAndWait(direction.opposite) else {
        fputs("MeasureDockHover: failed to restore the original Space\n", stderr)
        return nil
    }
    return elapsed
}

private func postSpaceSwitchAndWait(
    _ direction: SpaceSwitchDirection,
    onChange: @escaping () -> Void = {}
) -> Bool {
    var didChange = false
    let center = NSWorkspace.shared.notificationCenter
    let observer = center.addObserver(
        forName: NSWorkspace.activeSpaceDidChangeNotification,
        object: nil,
        queue: .main
    ) { _ in
        guard !didChange else { return }
        didChange = true
        onChange()
    }
    guard postControlArrow(keyCode: direction.keyCode) else {
        center.removeObserver(observer)
        return false
    }
    let deadline = Date().addingTimeInterval(2)
    while !didChange, Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    center.removeObserver(observer)
    return didChange
}

private func postControlArrow(keyCode: CGKeyCode) -> Bool {
    let source = "tell application \"System Events\" to key code \(keyCode) using control down"
    var error: NSDictionary?
    _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
    return error == nil
}

private func waitForPreview(pid: pid_t, visible: Bool, timeout: TimeInterval) -> Bool {
    let deadline = CFAbsoluteTimeGetCurrent() + timeout
    repeat {
        if (currentPresentation(pid: pid, includeOffscreen: false) != nil) == visible {
            return true
        }
        usleep(10_000)
    } while CFAbsoluteTimeGetCurrent() < deadline
    return false
}

private func currentPresentation(pid: pid_t, includeOffscreen: Bool) -> PresentationWindow? {
    let options: CGWindowListOption
    let relativeWindow: CGWindowID
    if let knownPreviewWindowID {
        options = [.optionIncludingWindow, .excludeDesktopElements]
        relativeWindow = knownPreviewWindowID
    } else if includeOffscreen {
        options = [.optionAll, .excludeDesktopElements]
        relativeWindow = kCGNullWindowID
    } else {
        options = [.optionOnScreenOnly, .excludeDesktopElements]
        relativeWindow = kCGNullWindowID
    }
    let windows = CGWindowListCopyWindowInfo(options, relativeWindow) as? [[String: Any]] ?? []
    return windows.compactMap { description -> PresentationWindow? in
        guard description[kCGWindowOwnerPID as String] as? pid_t == pid,
              description[kCGWindowLayer as String] as? Int == previewWindowLayer,
              let windowID = description[kCGWindowNumber as String] as? CGWindowID else {
            return nil
        }
        let isOnscreen = description[kCGWindowIsOnscreen as String] as? Bool == true
        guard includeOffscreen || isOnscreen else { return nil }
        let frame = (description[kCGWindowBounds as String] as? NSDictionary)
            .flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
        guard frame.width >= previewMinimumSize.width,
              frame.height >= previewMinimumSize.height else {
            return nil
        }
        let marker = description[kCGWindowName as String] as? String ?? ""
        guard marker.hasPrefix(previewNamePrefix) else { return nil }
        return PresentationWindow(windowID: windowID, marker: marker, frame: frame)
    }
    .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
}

private func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
          let value,
          CFGetTypeID(value) == AXUIElementGetTypeID() else {
        return nil
    }
    return unsafeBitCast(value, to: AXUIElement.self)
}

private func urlAttribute(_ element: AXUIElement, _ attribute: CFString) -> URL? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
    return value as? URL
}

private func postMouseMove(to point: CGPoint) {
    CGEvent(
        mouseEventSource: nil,
        mouseType: .mouseMoved,
        mouseCursorPosition: point,
        mouseButton: .left
    )?.post(tap: .cghidEventTap)
}

private func safeOutsidePoint() -> CGPoint {
    guard let mainScreen = screen(for: CGMainDisplayID()) else { return CGPoint(x: 320, y: 500) }
    let appKitPoint = CGPoint(x: mainScreen.visibleFrame.midX, y: mainScreen.visibleFrame.midY)
    return CGPoint(x: appKitPoint.x, y: primaryScreenMaxY() - appKitPoint.y)
}

private func primaryScreenMaxY() -> CGFloat {
    screen(for: CGMainDisplayID())?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
}

private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first { screen in
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
    }
}

private func percentile(_ percentile: Double, in sorted: [Double]) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let index = Int(ceil(percentile * Double(sorted.count))) - 1
    return sorted[min(max(index, 0), sorted.count - 1)]
}

private func format(_ value: Double) -> String {
    String(format: "%.2f", value)
}

private func fail(_ message: String) -> Never {
    fputs("MeasureDockHover: \(message)\n", stderr)
    exit(2)
}
