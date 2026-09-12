import Cocoa
import ApplicationServices
import CoreGraphics

enum WindowDiscovery {
    private static let remoteWindowElementResolver = RemoteWindowElementResolver()

    static func commit(_ resolution: RemoteWindowElementResolution) {
        remoteWindowElementResolver.commit(resolution)
    }

    static func removeRemoteWindow(pid: pid_t, windowID: CGWindowID) {
        remoteWindowElementResolver.remove(pid: pid, windowID: windowID)
    }

    static func removeRemoteWindows(for pid: pid_t) {
        remoteWindowElementResolver.removeAll(for: pid)
    }

    static func makePreviews(
        for app: NSRunningApplication,
        previousPreviews cachedPreviews: [WindowPreview],
        previousElements: [CGWindowID: AXUIElement],
        cachedImage: (CGWindowID, CGRect) -> NSImage?,
        shouldContinue: () -> Bool
    ) -> WindowDiscoveryResult? {
        let pid = app.processIdentifier
        guard let windowResult = axWindows(for: app, shouldContinue: shouldContinue),
              shouldContinue() else {
            return nil
        }
        let records = windowResult.records
        let descriptions = WindowAccessibility.windowDescriptions(records.map(\.windowID))
        guard shouldContinue() else { return nil }
        let spaceSnapshot = WindowSpaceSnapshot.current()
        let focusedWindowID = WindowAccessibility.focusedWindowID(for: pid)
        guard shouldContinue() else { return nil }
        let screenRecordingGranted = PermissionManager.status.screenRecordingGranted
        guard shouldContinue() else { return nil }
        let displayableRecords = records
            .filter { record in
                guard let description = descriptions[record.windowID] else { return true }
                return description.ownerPID == pid
            }
            .filter { isDisplayable($0, description: descriptions[$0.windowID], app: app) }
            .sorted { focusedWindowFirst($0, $1, focusedWindowID: focusedWindowID) }
        let discoveredPreviews = displayableRecords.map {
            preview(
                from: $0,
                app: app,
                cachedImage: cachedImage,
                description: descriptions[$0.windowID],
                spaceSnapshot: spaceSnapshot,
                focusedWindowID: focusedWindowID,
                screenRecordingGranted: screenRecordingGranted
            )
        }
        guard shouldContinue() else { return nil }
        let previousPreviews = cachedPreviews
            .filter { !$0.app.isTerminated && $0.app.processIdentifier == pid }
            .map { screenRecordingGranted ? $0 : $0.replacingImage(with: nil) }
        guard let previews = try? WindowInventorySnapshot.merging(
            discovered: discoveredPreviews,
            previous: previousPreviews,
            unresolvedIDs: windowResult.remoteResolution.unresolvedWindowIDs,
            identifier: { $0.windowID },
            shouldRetain: { try shouldRetainCachedPreview($0, previousElements: previousElements, shouldContinue: shouldContinue) }
        ), shouldContinue() else { return nil }
        return WindowDiscoveryResult(
            previews: previews,
            windowElements: retainedPreviewElements(previews: previews, records: displayableRecords, previousElements: previousElements),
            remoteResolution: windowResult.remoteResolution,
            screenRecordingGranted: screenRecordingGranted
        )
    }

    private static func shouldRetainCachedPreview(
        _ preview: WindowPreview,
        previousElements: [CGWindowID: AXUIElement],
        shouldContinue: () -> Bool
    ) throws -> Bool {
        guard shouldContinue() else { throw WindowRetentionValidationError.cancelled }
        guard let element = previousElements[preview.windowID] else { return true }
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        guard shouldContinue() else { throw WindowRetentionValidationError.cancelled }
        // WindowServer can retain a closed window long after its AX element is destroyed.
        return error != .invalidUIElement
    }

    private static func retainedPreviewElements(
        previews: [WindowPreview],
        records: [WindowRecord],
        previousElements: [CGWindowID: AXUIElement]
    ) -> [CGWindowID: AXUIElement] {
        let discovered = Dictionary(uniqueKeysWithValues: records.map { ($0.windowID, $0.element) })
        return previews.reduce(into: [:]) { result, preview in
            result[preview.windowID] = discovered[preview.windowID] ?? previousElements[preview.windowID]
        }
    }

    private static func preview(
        from record: WindowRecord,
        app: NSRunningApplication,
        cachedImage: (CGWindowID, CGRect) -> NSImage?,
        description: WindowDescription?,
        spaceSnapshot: WindowSpaceSnapshot,
        focusedWindowID: CGWindowID?,
        screenRecordingGranted: Bool
    ) -> WindowPreview {
        let size = description?.bounds?.size ?? record.size ?? .zero
        let position = description?.bounds?.origin ?? record.position ?? .zero
        let bounds = CGRect(origin: position, size: size)
        let cachedImage = cachedImage(record.windowID, bounds)
        return WindowPreview(
            windowID: record.windowID,
            title: previewTitle(for: record, app: app),
            bounds: bounds,
            isMinimized: record.isMinimized,
            isFullscreen: record.isFullscreen,
            isFocused: record.windowID == focusedWindowID,
            desktop: spaceSnapshot.desktop(for: record.windowID),
            image: screenRecordingGranted ? cachedImage : nil,
            app: app
        )
    }

    private static func previewTitle(for record: WindowRecord, app: NSRunningApplication) -> String {
        if let title = record.title, !title.isEmpty {
            return title
        }
        return app.localizedName ?? "Window"
    }

    private static func axWindows(
        for app: NSRunningApplication,
        shouldContinue: () -> Bool
    ) -> AXWindowRecordResult? {
        guard let windowResult = axWindowElements(
            for: app.processIdentifier,
            shouldContinue: shouldContinue
        ) else {
            return nil
        }
        let windows = windowResult.elements
        var records = [WindowRecord]()

        for window in windows {
            guard shouldContinue() else { return nil }
            AXUIElementSetMessagingTimeout(window, WindowAccessibility.accessibilityMessagingTimeout)
            let identifier = WindowAccessibility.readWindowID(for: window)
            guard identifier.error != .cannotComplete else { return nil }
            guard let id = identifier.windowID else { continue }
            let attributes: WindowAccessibilityAttributes
            switch WindowAccessibilityAttributes.read(from: window, shouldContinue: shouldContinue) {
            case .available(let value):
                attributes = value
            case .unavailable(.invalidUIElement):
                continue
            case .unavailable:
                return nil
            }
            records.append(WindowRecord(
                windowID: id,
                element: window,
                title: attributes.title,
                role: attributes.role,
                subrole: attributes.subrole,
                position: attributes.position,
                size: validWindowSize(attributes.size),
                isMinimized: attributes.isMinimized,
                isFullscreen: attributes.isFullscreen,
                level: SkyLightCapture.level(windowID: id)
            ))
        }

        return AXWindowRecordResult(
            records: unique(records),
            remoteResolution: windowResult.remoteResolution
        )
    }

    private static func validWindowSize(_ size: CGSize?) -> CGSize? {
        guard let size, size.width > 0, size.height > 0 else { return nil }
        return size
    }

    static func windowElement(windowID: CGWindowID, app: NSRunningApplication) -> AXUIElement? {
        let appElement = WindowAccessibility.applicationElement(for: app.processIdentifier)
        let windows = AccessibilityHelpers.elementArrayAttribute(appElement, kAXWindowsAttribute as CFString)
        windows.forEach { AXUIElementSetMessagingTimeout($0, WindowAccessibility.accessibilityMessagingTimeout) }
        if let match = windows.first(where: { WindowAccessibility.windowID(for: $0) == windowID }) {
            return match
        }
        let knownWindowElements = windows.reduce(into: [CGWindowID: AXUIElement]()) { result, element in
            guard let windowID = WindowAccessibility.windowID(for: element) else { return }
            result[windowID] = element
        }
        guard let resolution = remoteWindowResolution(
            pid: app.processIdentifier,
            knownWindowElements: knownWindowElements
        ) else {
            return nil
        }
        remoteWindowElementResolver.commit(resolution)
        return resolution.windows.first { WindowAccessibility.windowID(for: $0) == windowID }
    }

    private static func axWindowElements(
        for pid: pid_t,
        shouldContinue: () -> Bool
    ) -> AXWindowElementResult? {
        guard shouldContinue() else { return nil }
        let appElement = WindowAccessibility.applicationElement(for: pid)
        var rawWindows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &rawWindows
        )
        guard result == .success || result == .attributeUnsupported ||
                result == .noValue || result == .notImplemented else {
            return nil
        }
        let axWindows = rawWindows as? [AXUIElement] ?? []
        guard shouldContinue() else { return nil }
        var knownWindowElements = [CGWindowID: AXUIElement]()
        for element in axWindows {
            guard shouldContinue() else { return nil }
            AXUIElementSetMessagingTimeout(element, WindowAccessibility.accessibilityMessagingTimeout)
            let identifier = WindowAccessibility.readWindowID(for: element)
            guard identifier.error != .cannotComplete else { return nil }
            guard let windowID = identifier.windowID else { continue }
            knownWindowElements[windowID] = element
        }
        guard let remoteResolution = remoteWindowResolution(
            pid: pid,
            knownWindowElements: knownWindowElements,
            shouldContinue: shouldContinue
        ) else {
            return nil
        }
        return AXWindowElementResult(
            elements: axWindows + remoteResolution.windows,
            remoteResolution: remoteResolution
        )
    }

    private static func remoteWindowResolution(
        pid: pid_t,
        knownWindowElements: [CGWindowID: AXUIElement],
        shouldContinue: () -> Bool = { true }
    ) -> RemoteWindowElementResolution? {
        guard shouldContinue() else { return nil }
        guard let snapshot = bruteForceWindowSnapshot(
            pid: pid,
            shouldContinue: shouldContinue
        ) else {
            return nil
        }
        return remoteWindowElementResolver.resolve(
            pid: pid,
            knownWindowIDs: Set(knownWindowElements.keys),
            knownWindowElements: knownWindowElements,
            targetWindowIDs: snapshot.targetWindowIDs,
            shouldContinue: shouldContinue
        )
    }

    private static func bruteForceWindowSnapshot(
        pid: pid_t,
        shouldContinue: () -> Bool
    ) -> BruteForceWindowSnapshot? {
        guard shouldContinue() else { return nil }
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return BruteForceWindowSnapshot(targetWindowIDs: nil)
        }
        var targetWindowIDs = Set<CGWindowID>()
        for description in windows {
            guard shouldContinue() else { return nil }
            guard description[kCGWindowOwnerPID as String] as? pid_t == pid,
                  let windowID = description[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }
            if isBruteForceTargetWindow(description, pid: pid),
               isAssignedToUserSpaceOrUnknown(windowID: windowID) {
                targetWindowIDs.insert(windowID)
            }
        }
        return BruteForceWindowSnapshot(targetWindowIDs: Optional(targetWindowIDs))
    }

    private static func isBruteForceTargetWindow(_ description: [String: Any], pid: pid_t) -> Bool {
        guard description[kCGWindowOwnerPID as String] as? pid_t == pid,
              (description[kCGWindowName as String] as? String)?.isEmpty == false,
              (description[kCGWindowLayer as String] as? Int ?? 0) <= CGWindowLevelForKey(.floatingWindow) else {
            return false
        }
        let bounds = (description[kCGWindowBounds as String] as? NSDictionary)
            .flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
        return bounds.width >= 80 && bounds.height >= 60
    }

    private static func isAssignedToUserSpaceOrUnknown(windowID: CGWindowID) -> Bool {
        WindowSpaceMembership.isRemoteRecoveryCandidate(
            spaceIDs: SkyLightCapture.spaceIDsIfAvailable(windowID: windowID)
        )
    }

    private static func unique(_ records: [WindowRecord]) -> [WindowRecord] {
        var seen = Set<CGWindowID>()
        return records.filter { record in
            if seen.contains(record.windowID) { return false }
            seen.insert(record.windowID)
            return true
        }
    }

    private static func isDisplayable(
        _ record: WindowRecord,
        description: WindowDescription?,
        app: NSRunningApplication
    ) -> Bool {
        guard record.role == kAXWindowRole as String else { return false }
        let size = record.size ?? description?.bounds?.size ?? .zero
        let level = record.level ?? description?.level ?? CGWindowLevel(0)
        guard size.width >= 80 &&
            size.height >= 60 &&
            level <= CGWindowLevelForKey(.floatingWindow) else {
            return false
        }

        return isStandardWindowSubrole(record.subrole) ||
            isAppSpecificDisplayableWindow(record, app: app, size: size)
    }

    private static func isStandardWindowSubrole(_ subrole: String?) -> Bool {
        [
            kAXStandardWindowSubrole as String,
            kAXDialogSubrole as String,
            kAXFloatingWindowSubrole as String
        ].contains(subrole ?? "")
    }

    private static func isAppSpecificDisplayableWindow(
        _ record: WindowRecord,
        app: NSRunningApplication,
        size: CGSize
    ) -> Bool {
        guard record.subrole == kAXUnknownSubrole as String else { return false }
        let bundleID = app.bundleIdentifier ?? ""
        if bundleID.hasPrefix("org.mozilla.firefox") {
            return size.height > 400
        }
        if bundleID.hasPrefix("org.videolan.vlc") {
            return true
        }
        return false
    }

    private static func oldestWindowFirst(_ lhs: WindowRecord, _ rhs: WindowRecord) -> Bool {
        lhs.windowID < rhs.windowID
    }

    private static func focusedWindowFirst(_ lhs: WindowRecord, _ rhs: WindowRecord, focusedWindowID: CGWindowID?) -> Bool {
        if let focusedWindowID {
            let lhsFocused = lhs.windowID == focusedWindowID
            let rhsFocused = rhs.windowID == focusedWindowID
            if lhsFocused != rhsFocused { return lhsFocused }
        }
        return oldestWindowFirst(lhs, rhs)
    }
}

private struct BruteForceWindowSnapshot {
    let targetWindowIDs: Set<CGWindowID>?
}

private struct AXWindowElementResult {
    let elements: [AXUIElement]
    let remoteResolution: RemoteWindowElementResolution
}

private struct AXWindowRecordResult {
    let records: [WindowRecord]
    let remoteResolution: RemoteWindowElementResolution
}

struct WindowDiscoveryResult {
    let previews: [WindowPreview]
    let windowElements: [CGWindowID: AXUIElement]
    let remoteResolution: RemoteWindowElementResolution
    let screenRecordingGranted: Bool
}

private enum WindowRetentionValidationError: Error {
    case cancelled
}

private struct WindowSpaceSnapshot {
    private let desktopsByID: [UInt64: WindowDesktop]

    static func current() -> WindowSpaceSnapshot {
        guard PrevDockSettings.previewDesktopGroupingEnabled else {
            return WindowSpaceSnapshot(desktops: [])
        }
        return WindowSpaceSnapshot(desktops: SkyLightCapture.managedDesktopSpaces())
    }

    init(desktops: [WindowDesktop]) {
        desktopsByID = Dictionary(uniqueKeysWithValues: desktops.map { ($0.id, $0) })
    }

    func desktop(for windowID: CGWindowID) -> WindowDesktop? {
        guard !desktopsByID.isEmpty else { return nil }
        let desktops = SkyLightCapture.spaceIDs(windowID: windowID).compactMap { desktopsByID[$0] }
        return desktops.first(where: \.isCurrent) ?? desktops.min { $0.sortOrder < $1.sortOrder }
    }
}

private struct WindowRecord {
    let windowID: CGWindowID
    let element: AXUIElement
    let title: String?
    let role: String?
    let subrole: String?
    let position: CGPoint?
    let size: CGSize?
    let isMinimized: Bool
    let isFullscreen: Bool
    let level: CGWindowLevel?
}
