import Cocoa
import ApplicationServices
import CoreGraphics

enum WindowCommands {
    private static let actionQueue = DispatchQueue(label: "prevDock.window-actions", qos: .userInteractive)
    private static let axFullScreenAttribute = "AXFullScreen" as CFString
    private static var focusRestorationObserver: NSObjectProtocol?
    private static var pendingFocusRestoration: FocusRestoration?
    private static var focusRestorationGeneration = 0

    private struct FocusRestoration {
        let sourceDesktopIDs: Set<UInt64>
        let targetDesktopIDs: Set<UInt64>
        let sourceAppPID: pid_t
        let sourceWindowID: CGWindowID?
        let targetAppPID: pid_t
        let request: WindowFocusRequest
    }

    @discardableResult
    static func focusWindow(
        windowID: CGWindowID,
        app: NSRunningApplication,
        completion: @escaping (Bool) -> Void = { _ in }
    ) -> WindowFocusRequest {
        let request = WindowFocusRequest()
        actionQueue.async {
            guard request.isActive else { return }
            guard !app.isTerminated,
                  let window = WindowDiscovery.windowElement(windowID: windowID, app: app) else {
                completeWindowFocus(false, request: request, completion: completion)
                return
            }

            DispatchQueue.main.async {
                guard request.isActive else { return }
                guard !app.isTerminated else {
                    completeWindowFocus(false, request: request, completion: completion)
                    return
                }
                prepareFocusRestoration(targetWindowID: windowID, targetApp: app, request: request)
                guard request.isActive else { return }
                unminimize(window)
                guard request.isActive else { return }
                let focused = applySingleWindowFocus(
                    to: window,
                    windowID: windowID,
                    app: app,
                    request: request
                )
                if focused {
                    raiseFocusedWindowIfStillActive(window, windowID: windowID, app: app, request: request)
                }
                verifyFocusedWindow(
                    windowID: windowID,
                    app: app,
                    requestedFocus: focused,
                    observedFocusedWindow: false,
                    attempt: 0,
                    request: request,
                    completion: completion
                )
            }
        }
        return request
    }

    private static func completeWindowFocus(
        _ success: Bool,
        request: WindowFocusRequest,
        completion: @escaping (Bool) -> Void
    ) {
        request.finishOnMain {
            completion(success)
        }
    }

    private static func verifyFocusedWindow(
        windowID: CGWindowID,
        app: NSRunningApplication,
        requestedFocus: Bool,
        observedFocusedWindow: Bool,
        attempt: Int,
        request: WindowFocusRequest,
        completion: @escaping (Bool) -> Void
    ) {
        guard request.isActive else { return }
        actionQueue.asyncAfter(deadline: .now() + 0.1) {
            guard request.isActive else { return }
            guard !app.isTerminated else {
                completeWindowFocus(false, request: request, completion: completion)
                return
            }
            let focusedID = WindowAccessibility.focusedWindowID(for: app.processIdentifier)
            if focusedID == windowID, app.isActive {
                completeWindowFocus(true, request: request, completion: completion)
                return
            }
            let observedFocusedWindow = observedFocusedWindow || focusedID != nil
            guard attempt < 15 else {
                let succeededWithoutAXVerification = requestedFocus &&
                    app.isActive &&
                    !observedFocusedWindow
                completeWindowFocus(succeededWithoutAXVerification, request: request, completion: completion)
                return
            }
            verifyFocusedWindow(
                windowID: windowID,
                app: app,
                requestedFocus: requestedFocus,
                observedFocusedWindow: observedFocusedWindow,
                attempt: attempt + 1,
                request: request,
                completion: completion
            )
        }
    }

    private static func raiseFocusedWindowIfStillActive(
        _ window: AXUIElement,
        windowID: CGWindowID,
        app: NSRunningApplication,
        request: WindowFocusRequest
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard !request.isCancelled, app.isActive,
                  WindowAccessibility.focusedWindowID(for: app.processIdentifier) == windowID else {
                return
            }
            guard !request.isCancelled else { return }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }

    static func closeWindow(
        windowID: CGWindowID,
        app: NSRunningApplication,
        isFullscreen: Bool = false,
        completion: @escaping (Bool) -> Void
    ) {
        actionQueue.async {
            guard let window = WindowDiscovery.windowElement(windowID: windowID, app: app) else {
                completeWindowAction(false, completion: completion)
                return
            }

            if isFullscreen,
               AXUIElementSetAttributeValue(window, axFullScreenAttribute, kCFBooleanFalse) == .success {
                closeAfterFullscreenExit(
                    window,
                    windowID: windowID,
                    app: app,
                    attempt: 0,
                    completion: completion
                )
                return
            }
            requestCloseAndVerify(window, windowID: windowID, app: app, completion: completion)
        }
    }

    private static func closeAfterFullscreenExit(
        _ window: AXUIElement,
        windowID: CGWindowID,
        app: NSRunningApplication,
        attempt: Int,
        completion: @escaping (Bool) -> Void
    ) {
        let isStillFullscreen = AccessibilityHelpers.boolAttribute(window, axFullScreenAttribute) == true
        guard isStillFullscreen, attempt < 12 else {
            requestCloseAndVerify(window, windowID: windowID, app: app, completion: completion)
            return
        }
        actionQueue.asyncAfter(deadline: .now() + 0.15) {
            closeAfterFullscreenExit(
                window,
                windowID: windowID,
                app: app,
                attempt: attempt + 1,
                completion: completion
            )
        }
    }

    private static func requestCloseAndVerify(
        _ window: AXUIElement,
        windowID: CGWindowID,
        app: NSRunningApplication,
        completion: @escaping (Bool) -> Void
    ) {
        requestCloseWithRetry(
            window,
            windowID: windowID,
            app: app,
            attempt: 0,
            completion: completion
        )
    }

    private static func requestCloseWithRetry(
        _ window: AXUIElement,
        windowID: CGWindowID,
        app: NSRunningApplication,
        attempt: Int,
        completion: @escaping (Bool) -> Void
    ) {
        let didRequestClose = requestClose(for: window)
        guard !didRequestClose, attempt < 2 else {
            verifyClosed(
                window,
                windowID: windowID,
                app: app,
                closedObservationCount: 0,
                attempt: 0,
                completion: completion
            )
            return
        }
        actionQueue.asyncAfter(deadline: .now() + 0.1) {
            requestCloseWithRetry(
                window,
                windowID: windowID,
                app: app,
                attempt: attempt + 1,
                completion: completion
            )
        }
    }

    private static func requestClose(for window: AXUIElement) -> Bool {
        if let closeButton = WindowAccessibility.axElementAttribute(window, kAXCloseButtonAttribute as CFString) {
            let result = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
            if result == .success { return true }
        }

        return AXUIElementPerformAction(window, "AXClose" as CFString) == .success
    }

    private static func applyFocus(to window: AXUIElement, appElement: AXUIElement, request: WindowFocusRequest) -> Bool {
        guard !request.isCancelled else { return false }
        let frontmost = AXUIElementSetAttributeValue(
            appElement,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        guard !request.isCancelled else { return false }
        let focusedWindow = AXUIElementSetAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            window
        )
        guard !request.isCancelled else { return false }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        guard !request.isCancelled else { return false }
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard !request.isCancelled else { return false }
        let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        return frontmost == .success || focusedWindow == .success || raised == .success
    }

    private static func unminimize(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }

    private static func applySingleWindowFocus(
        to window: AXUIElement,
        windowID: CGWindowID,
        app: NSRunningApplication,
        request: WindowFocusRequest
    ) -> Bool {
        guard !request.isCancelled else { return false }
        if SkyLightCapture.focusWindow(windowID: windowID, pid: app.processIdentifier) {
            guard !request.isCancelled else { return false }
            return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success || app.isActive
        }
        guard !request.isCancelled else { return false }
        let activated = activate(app)
        let appElement = WindowAccessibility.applicationElement(for: app.processIdentifier)
        return applyFocus(to: window, appElement: appElement, request: request) || activated
    }

    private static func prepareFocusRestoration(
        targetWindowID: CGWindowID,
        targetApp: NSRunningApplication,
        request: WindowFocusRequest
    ) {
        let restoration = focusRestoration(targetWindowID: targetWindowID, targetApp: targetApp, request: request)
        guard request.isActive else { return }
        focusRestorationGeneration += 1
        let generation = focusRestorationGeneration
        guard let restoration else {
            pendingFocusRestoration = nil
            return
        }
        pendingFocusRestoration = restoration
        installFocusRestorationObserver()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            guard focusRestorationGeneration == generation else { return }
            pendingFocusRestoration = nil
        }
    }

    private static func focusRestoration(
        targetWindowID: CGWindowID,
        targetApp: NSRunningApplication,
        request: WindowFocusRequest
    ) -> FocusRestoration? {
        guard let sourceApp = NSWorkspace.shared.frontmostApplication,
              sourceApp.processIdentifier != targetApp.processIdentifier else {
            return nil
        }
        let sourceDesktopIDs = SkyLightCapture.currentDesktopIDs()
        let targetDesktopIDs = Set(SkyLightCapture.spaceIDs(windowID: targetWindowID))
        guard !sourceDesktopIDs.isEmpty,
              !targetDesktopIDs.isEmpty,
              targetDesktopIDs.isDisjoint(with: sourceDesktopIDs) else {
            return nil
        }
        return FocusRestoration(
            sourceDesktopIDs: sourceDesktopIDs,
            targetDesktopIDs: targetDesktopIDs,
            sourceAppPID: sourceApp.processIdentifier,
            sourceWindowID: WindowAccessibility.focusedWindowID(for: sourceApp.processIdentifier),
            targetAppPID: targetApp.processIdentifier,
            request: request
        )
    }

    private static func installFocusRestorationObserver() {
        guard focusRestorationObserver == nil else { return }
        focusRestorationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            restoreFocusAfterSpaceChange()
        }
    }

    private static func restoreFocusAfterSpaceChange() {
        guard let restoration = pendingFocusRestoration else { return }
        guard !restoration.request.isCancelled else {
            pendingFocusRestoration = nil
            return
        }
        let currentDesktopIDs = SkyLightCapture.currentDesktopIDs()
        guard currentDesktopIDs.isDisjoint(with: restoration.targetDesktopIDs),
              !currentDesktopIDs.isDisjoint(with: restoration.sourceDesktopIDs) else {
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == restoration.targetAppPID else {
            pendingFocusRestoration = nil
            return
        }
        pendingFocusRestoration = nil
        restoreFocus(restoration)
    }

    private static func restoreFocus(_ restoration: FocusRestoration) {
        guard !restoration.request.isCancelled,
              let app = NSRunningApplication(processIdentifier: restoration.sourceAppPID) else { return }
        guard let windowID = restoration.sourceWindowID else {
            activate(app)
            return
        }
        actionQueue.async {
            guard !restoration.request.isCancelled else { return }
            guard let window = WindowDiscovery.windowElement(windowID: windowID, app: app) else {
                DispatchQueue.main.async {
                    guard !restoration.request.isCancelled else { return }
                    _ = activate(app)
                }
                return
            }
            DispatchQueue.main.async {
                guard !restoration.request.isCancelled else { return }
                if applySingleWindowFocus(to: window, windowID: windowID, app: app, request: restoration.request) {
                    raiseFocusedWindowIfStillActive(window, windowID: windowID, app: app, request: restoration.request)
                }
            }
        }
    }

    @discardableResult
    private static func activate(_ app: NSRunningApplication) -> Bool {
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: app)
            return app.activate(from: NSRunningApplication.current, options: [])
        }
        return app.activate(options: [])
    }

    private static func verifyClosed(
        _ window: AXUIElement,
        windowID: CGWindowID,
        app: NSRunningApplication,
        closedObservationCount: Int,
        attempt: Int,
        completion: @escaping (Bool) -> Void
    ) {
        actionQueue.asyncAfter(deadline: .now() + 0.15) {
            let presence = windowPresence(window, windowID: windowID, app: app)
            if presence == .closed, closedObservationCount >= 1 {
                WindowInventory.removeClosedWindow(windowID: windowID, app: app) { completion(true) }
                return
            }
            guard attempt < 8 else {
                completeWindowAction(false, completion: completion)
                return
            }
            verifyClosed(
                window,
                windowID: windowID,
                app: app,
                closedObservationCount: presence == .closed ? closedObservationCount + 1 : 0,
                attempt: attempt + 1,
                completion: completion
            )
        }
    }

    private static func windowPresence(
        _ window: AXUIElement,
        windowID: CGWindowID,
        app: NSRunningApplication
    ) -> WindowPresence {
        guard !app.isTerminated else { return .closed }
        if let description = WindowAccessibility.windowDescriptions([windowID])[windowID] {
            return description.ownerPID == app.processIdentifier ? .open : .closed
        }

        var role: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            window,
            kAXRoleAttribute as CFString,
            &role
        )
        switch result {
        case .success:
            guard let currentWindowID = WindowAccessibility.windowID(for: window) else { return .unknown }
            return currentWindowID == windowID ? .open : .closed
        case .invalidUIElement, .noValue:
            return .closed
        default:
            return .unknown
        }
    }

    private static func completeWindowAction(
        _ success: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.main.async {
            completion(success)
        }
    }
}

private enum WindowPresence: Equatable {
    case open
    case closed
    case unknown
}
