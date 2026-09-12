import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

@main
enum DockClickLiveTests {
    static let appID = "io.github.bambou932.prevDock"
    static let fixtureID = appID + ".PreviewWindowFixture"
    static let controllerID = appID + ".DockClickController"
    static var root = ""
    static var controllerPath = ""
    static var targetWasActivated = false

    static func main() {
        guard (3...4).contains(CommandLine.arguments.count),
              CommandLine.arguments.count == 3 || ["--windowless-only", "--window-updates-only", "--context-menu-only", "--inspect-window-updates"].contains(CommandLine.arguments[3]),
              AXIsProcessTrusted() else {
            fputs("Usage: DockClickLiveTests <repository-root> <controller-app> [--windowless-only|--window-updates-only|--context-menu-only|--inspect-window-updates]; Accessibility access is required\n", stderr)
            exit(2)
        }
        root = CommandLine.arguments[1]
        controllerPath = CommandLine.arguments[2]
        exit(exercise())
    }

    static func exercise() -> Int32 {
        let initialMouse = CGEvent(source: nil)?.location ?? .zero
        let originalFrontmost = NSWorkspace.shared.frontmostApplication
        let originalApp = running(appID)
        guard running(fixtureID) == nil, running(controllerID) == nil else {
            return fail("close existing preview fixtures before this test")
        }
        guard stop(originalApp) else { return fail("running prevDock did not quit") }
        defer {
            _ = stop(running(fixtureID))
            _ = stop(running(appID))
            _ = stop(running(controllerID))
            if originalApp != nil { _ = launch(root + "/build/prevDock.app") }
            move(initialMouse)
            _ = originalFrontmost?.activate(options: [])
        }
        guard launch(controllerPath, arguments: ["1"]),
              launch(root + "/.build/preview-window-fixture/PreviewWindowFixture.app", arguments: ["4"]),
              launchPreview() else { return fail("test apps did not launch") }
        wait(0.8)
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == fixtureID { targetWasActivated = true }
        }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if CommandLine.arguments.contains("--inspect-window-updates") {
            return inspectWindowUpdates() ? 0 : 1
        }
        if CommandLine.arguments.contains("--window-updates-only") {
            return windowListUpdatesWhileVisible() ? 0 : 1
        }
        if CommandLine.arguments.contains("--context-menu-only") {
            return contextMenuClick() && contextMenuClick(targetAlreadyActive: true) ? 0 : 1
        }
        if !CommandLine.arguments.contains("--windowless-only"), !runMultiWindowChecks() { return 1 }
        for _ in 0..<3 { signalFixture(SIGUSR2); wait(0.08) }
        guard eventually({ fixtureWindowCount() == 1 }), restartPreview(),
              nativeClick("cold single-window click") else { return fail("single-window click was not restored") }
        signalFixture(SIGUSR2)
        guard eventually({ fixtureWindowCount() == 0 }),
              windowlessHoverShowsNothing("last window closed"),
              newWindowAppearsAfterEmptyHover(), restartPreview(),
              windowlessHoverShowsNothing("cold windowless app"),
              nativeClick("cold zero-window reopen"),
              eventually({ fixtureWindowCount() == 1 }) else { return fail("zero-window lifecycle did not complete") }
        print("DockClickLiveTests: passed")
        return 0
    }

    static func runMultiWindowChecks() -> Bool {
        guard inactiveAppHoverShowsNothing(), previewClick("cold click", moveAwayAfterClick: true),
              previewClick("stale-cache click", delay: 1.5),
              previewClick("warm-cache click"), windowListUpdatesWhileVisible() else { return false }
        guard focusPreviewWindow(), previewClick("click after completed window selection"),
              focusPreviewWindow(physicalClick: true), minimizedPreviewSelection(),
              minimizedPreviewSelection(coldCache: true),
              quickHoverReturnAfterFocus(),
              contextMenuClick(), nativeClick("Shift-click", flags: .maskShift),
              contextMenuClick(targetAlreadyActive: true) else { return false }
        return true
    }

    static func windowListUpdatesWhileVisible() -> Bool {
        for overCard in [false, true] {
            guard windowListUpdate(overCard: overCard) else { return false }
        }
        guard previewClick("new-window selection setup"),
              let added = appendWindowToOpenShelf(),
              let title = attribute(added, kAXDescriptionAttribute) as? String,
              focusPreviewWindow(physicalClick: true, matchingTitle: title) else { return false }
        signalFixture(SIGUSR2)
        guard eventually({ fixtureWindowCount() == 4 }),
              previewClick("shelf after selecting new window") else { return false }
        print("PASS newly added card focuses its exact window without overlays reappearing")
        return true
    }

    static func windowListUpdate(overCard: Bool) -> Bool {
        guard previewClick("window-list update setup"),
              let oldID = previewCards().first.flatMap({ attribute($0, "AXIdentifier") as? String }),
              !overCard || hoverPreviewCard(identifier: oldID),
              let added = appendWindowToOpenShelf(),
              !overCard || hoverPreviewCard(identifier: oldID),
              let addedID = attribute(added, "AXIdentifier") as? String,
              addedThumbnailBecomesReady(identifier: addedID, overCard: overCard) else { return false }
        signalFixture(SIGUSR2)
        guard eventually({ fixtureWindowCount() == 4 && previewCardCount() == 4 }), !targetWasActivated else {
            _ = fail("removed window stayed in the open shelf or activated the app")
            return false
        }
        print("PASS open shelf updates added/removed windows and new thumbnails without activation (overCard=\(overCard))")
        return true
    }

    static func appendWindowToOpenShelf() -> AXUIElement? {
        let oldIDs = previewCards().compactMap { attribute($0, "AXIdentifier") as? String }
        let oldTitles = fixtureWindowTitles()
        guard oldIDs.count == 4, Set(oldIDs).count == 4, oldTitles.count == 4 else {
            _ = fail("window-growth fixture did not expose four distinct cards and windows")
            return nil
        }
        let started = ProcessInfo.processInfo.systemUptime
        signalFixture(SIGUSR1)
        guard eventually({ fixtureWindowCount() == 5 && previewCardCount() == 5 }), !targetWasActivated else {
            _ = fail("new window was not appended to the open shelf")
            return nil
        }
        let cards = previewCards()
        let ids = cards.compactMap { attribute($0, "AXIdentifier") as? String }
        let newTitles = fixtureWindowTitles().subtracting(oldTitles)
        guard Set(ids).count == 5, ids.filter({ oldIDs.contains($0) }) == oldIDs,
              Set(ids).subtracting(oldIDs).count == 1, newTitles.count == 1,
              let added = cards.first(where: { !oldIDs.contains(attribute($0, "AXIdentifier") as? String ?? "") }),
              let title = attribute(added, kAXDescriptionAttribute) as? String,
              newTitles.contains(title) else {
            _ = fail("new metadata did not preserve order or identify the actual newly opened window")
            return nil
        }
        print(String(format: "TRACE new window visible after %.3fs", ProcessInfo.processInfo.systemUptime - started))
        return added
    }

    static func hoverPreviewCard(identifier: String) -> Bool {
        guard let card = previewCards().first(where: { (attribute($0, "AXIdentifier") as? String) == identifier }),
              let point = center(of: card) else { return false }
        move(point)
        return observeWindowPeek(hoverInvariant: { !targetWasActivated })
    }

    static func addedThumbnailBecomesReady(identifier: String, overCard: Bool) -> Bool {
        guard eventually({
            previewCards().contains {
                (attribute($0, "AXIdentifier") as? String) == identifier &&
                    (attribute($0, kAXValueAttribute) as? String) == "Ready"
            }
        }), !targetWasActivated, !overCard || currentPeekFrame() != nil else {
            _ = fail("new window thumbnail stayed unavailable while viewing the shelf (overCard=\(overCard))")
            return false
        }
        return true
    }

    static func inspectWindowUpdates() -> Bool {
        guard previewClick("interactive window update inspection") else { return false }
        print("INSPECT ready: actual prevDock shelf and four disposable windows; SIGUSR1 adds and SIGUSR2 removes a fixture window. Restoring in 90 seconds.")
        fflush(stdout)
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        var previous = -1
        while ProcessInfo.processInfo.systemUptime < deadline {
            let count = previewCardCount()
            if count != previous {
                print("INSPECT visible preview cards=\(count)")
                fflush(stdout)
                previous = count
            }
            wait(0.2)
        }
        return true
    }

    static func prepareClick(delay: TimeInterval = 0.25) -> CGPoint? {
        guard let controller = running(controllerID) else { return nil }
        _ = controller.activate(options: [.activateAllWindows])
        move(CGPoint(x: 150, y: 200))
        guard eventually({ controller.isActive }) else {
            _ = fail("could not activate the test controller")
            return nil
        }
        wait(delay)
        targetWasActivated = false
        var point: CGPoint?
        _ = eventually { point = fixtureDockPoint(); return point != nil }
        return point
    }

    static func previewClick(_ label: String, delay: TimeInterval = 0.25, moveAwayAfterClick: Bool = false) -> Bool {
        guard let point = prepareClick(delay: delay) else { _ = fail("\(label): no Dock target"); return false }
        click(point)
        if moveAwayAfterClick { move(CGPoint(x: 150, y: 200)) }
        let shown = eventually { previewCardCount() == 4 || targetWasActivated }
        guard shown, !targetWasActivated, previewCardCount() == 4 else {
            _ = fail("\(label): activated=\(targetWasActivated), previewCards=\(previewCardCount())")
            return false
        }
        wait(0.15)
        guard !targetWasActivated else { _ = fail("\(label): app activated after presenting previews"); return false }
        print("PASS \(label) shows previews without activating the app")
        return true
    }

    static func nativeClick(_ label: String, flags: CGEventFlags = []) -> Bool {
        guard let point = prepareClick() else { return false }
        click(point, flags: flags)
        guard eventually({ targetWasActivated || running(fixtureID)?.isActive == true }) else {
            _ = fail("\(label): native activation was lost")
            return false
        }
        guard eventually({ previewCardCount() == 0 }) else {
            _ = fail("\(label): a preview obscures the native action")
            return false
        }
        print("PASS \(label) preserves native app behavior")
        return true
    }

    static func inactiveAppHoverShowsNothing() -> Bool {
        guard let point = inactiveDockPoint() else {
            print("SKIP inactive app hover: no non-running app is currently pinned in Dock")
            return true
        }
        move(CGPoint(x: 150, y: 200))
        wait(0.3)
        move(point)
        wait(1.5)
        guard overlaysStayAbsent() else {
            _ = fail("a non-running Dock app showed a prevDock name or preview panel")
            return false
        }
        print("PASS inactive Dock app shows no prevDock label or preview")
        return true
    }

    static func windowlessHoverShowsNothing(_ label: String) -> Bool {
        guard let point = prepareClick() else { return false }
        move(point)
        wait(1.5)
        // A fresh cache can outlive a close until the next bounded metadata scan completes.
        guard fixtureWindowCount() == 0, !targetWasActivated,
              eventually({ previewOverlayLayers().isEmpty }), overlaysStayAbsent() else {
            _ = fail("\(label): windows=\(fixtureWindowCount()), activated=\(targetWasActivated), layers=\(previewOverlayLayers()), cards=\(previewCardCount())")
            diagnoseWindowlessInventory()
            return false
        }
        print("PASS \(label) shows no empty preview panel")
        return true
    }

    static func newWindowAppearsAfterEmptyHover() -> Bool {
        signalFixture(SIGUSR1)
        guard eventually({ fixtureWindowCount() == 1 && previewCardCount() == 1 }) else {
            _ = fail("a real window did not appear after the empty preview was hidden")
            return false
        }
        signalFixture(SIGUSR2)
        guard eventually({ fixtureWindowCount() == 0 && previewOverlayLayers().isEmpty }) else {
            _ = fail("closing the new final window did not hide its preview")
            return false
        }
        print("PASS new windows appear during hover and the final closed window hides the shelf")
        return true
    }

    static func diagnoseWindowlessInventory() {
        guard let fixture = running(fixtureID) else { return }
        var rawWindows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(fixture.processIdentifier), kAXWindowsAttribute as CFString, &rawWindows)
        print("DIAGNOSTIC AXWindows result=\(result.rawValue) value=\(String(describing: rawWindows))")
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows where (window[kCGWindowOwnerPID as String] as? Int32) == fixture.processIdentifier {
            print("DIAGNOSTIC fixture CGWindow \(window)")
        }
        for card in previewCards() {
            print("DIAGNOSTIC card id=\(attribute(card, "AXIdentifier") as? String ?? "") label=\(attribute(card, kAXDescriptionAttribute) as? String ?? "")")
        }
    }

    static func overlaysStayAbsent() -> Bool {
        let cpuStarted = previewCPUTime()
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard previewOverlayLayers().isEmpty else { return false }
            wait(0.02)
        }
        if let cpuStarted, let cpuEnded = previewCPUTime() {
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            print(String(format: "TRACE empty hover CPU: %.1f%% of one core over %.2fs", (cpuEnded - cpuStarted) / elapsed * 100, elapsed))
        }
        return true
    }

    static func previewCPUTime() -> TimeInterval? {
        guard let app = running(appID) else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(app.processIdentifier), "-o", "time="]
        process.standardOutput = output
        do { try process.run() } catch { return nil }
        while process.isRunning { wait(0.01) }
        guard process.terminationStatus == 0,
              let value = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        let components = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard (2...3).contains(components.count) else { return nil }
        let numbers = components.compactMap { Double($0) }
        guard numbers.count == components.count else { return nil }
        return numbers.reduce(0) { $0 * 60 + $1 }
    }

    static func focusPreviewWindow(
        physicalClick: Bool = false,
        matchingTitle: String? = nil,
        hoverInvariant: () -> Bool = { true },
        beforeSelection: (AXUIElement) -> Bool = { _ in true }
    ) -> Bool {
        guard let fixture = running(fixtureID), !fixture.isActive else { return false }
        let cards = previewCards()
        let selectedCard: AXUIElement?
        if let matchingTitle {
            selectedCard = cards.first {
                let label = attribute($0, kAXDescriptionAttribute) as? String ?? ""
                return label == matchingTitle || label.hasPrefix(matchingTitle + " — ")
            }
        } else {
            selectedCard = cards.last
        }
        guard let card = selectedCard else {
            _ = fail("the requested preview card was not found")
            return false
        }
        let app = AXUIElementCreateApplication(fixture.processIdentifier)
        let label = attribute(card, kAXDescriptionAttribute) as? String ?? ""
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let title = windows.compactMap({ attribute($0, kAXTitleAttribute) as? String }).first(where: {
            label == $0 || label.hasPrefix($0 + " — ")
        }), let point = settledCenter(of: card) else {
            _ = fail("preview card could not select its window")
            return false
        }
        move(point)
        guard observeWindowPeek(hoverInvariant: hoverInvariant) else {
            let current = previewCards().first { (attribute($0, kAXDescriptionAttribute) as? String) == label }
            print("TRACE failed hover: title=\(label), initial=\(point), current=\(String(describing: current.flatMap(center))), cursor=\(String(describing: CGEvent(source: nil)?.location)), overlays=\(previewOverlayLayers()), cards=\(previewCardCount())")
            return false
        }
        guard let currentCard = previewCards().first(where: {
            (attribute($0, kAXDescriptionAttribute) as? String) == label
        }) else { _ = fail("selected card disappeared during metadata refresh"); return false }
        guard beforeSelection(currentCard) else { return false }
        if physicalClick {
            guard let currentPoint = center(of: currentCard) else { return false }
            click(currentPoint)
        } else if AXUIElementPerformAction(currentCard, kAXPressAction as CFString) != .success {
            _ = fail("preview accessibility selection failed")
            return false
        }
        guard overlaysRemainHiddenDuringFocus() else { return false }
        guard eventually({
            guard fixture.isActive, let value = attribute(app, kAXFocusedWindowAttribute),
                  CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
            return (attribute(value as! AXUIElement, kAXTitleAttribute) as? String) == title
        }) else {
            _ = fail("preview selection did not focus the selected window")
            return false
        }
        print("PASS hovered preview selection focuses the exact window without shelf/peek reappearing (physicalClick=\(physicalClick))")
        return true
    }

    static func observeWindowPeek(hoverInvariant: () -> Bool) -> Bool {
        var stateChanged = false
        let shown = eventually {
            stateChanged = !hoverInvariant()
            return stateChanged || previewOverlayLayers().contains(Int(CGWindowLevelForKey(.dockWindow)) - 1)
        }
        guard shown, !stateChanged else {
            _ = fail("hover did not show the window peek while preserving the real window state")
            return false
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 1.1
        repeat {
            guard hoverInvariant() else {
                _ = fail("hover changed the real window state before selection")
                return false
            }
            wait(0.04)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return true
    }

    static func minimizedPreviewSelection(coldCache: Bool = false) -> Bool {
        guard let fixture = running(fixtureID),
              let windows = attribute(AXUIElementCreateApplication(fixture.processIdentifier), kAXWindowsAttribute) as? [AXUIElement],
              let window = windows.first,
              let title = attribute(window, kAXTitleAttribute) as? String,
              let originalFrame = frame(of: window),
              AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success,
              eventually({ (attribute(window, kAXMinimizedAttribute) as? Bool) == true }),
              !coldCache || restartPreview(),
              previewClick("minimized-window preview", delay: 1.5),
              focusPreviewWindow(physicalClick: coldCache, matchingTitle: title, hoverInvariant: {
                  minimizedWindowIsUnchanged(window, fixture: fixture, originalFrame: originalFrame)
              }, beforeSelection: { card in
                  validateMinimizedHover(window: window, fixture: fixture, card: card, originalFrame: originalFrame)
              }),
              (attribute(window, kAXMinimizedAttribute) as? Bool) == false else {
            _ = fail("minimized preview selection did not restore its window")
            return false
        }
        print("PASS minimized thumbnail and original-position hover preserve minimization until selection (coldCache=\(coldCache))")
        return true
    }

    static func validateMinimizedHover(
        window: AXUIElement, fixture: NSRunningApplication, card: AXUIElement, originalFrame: CGRect
    ) -> Bool {
        guard minimizedWindowIsUnchanged(window, fixture: fixture, originalFrame: originalFrame) else {
            _ = fail("hovering a minimized preview changed the real window state or activated its app")
            return false
        }
        guard (attribute(card, kAXValueAttribute) as? String) == "Ready",
              let peekFrame = currentPeekFrame(),
              abs(peekFrame.minX - originalFrame.minX) < 1,
              abs(peekFrame.minY - originalFrame.minY) < 1,
              abs(peekFrame.width - originalFrame.width) < 1,
              abs(peekFrame.height - originalFrame.height) < 1 else {
            _ = fail("minimized window needs a ready thumbnail and a snapshot at its original bounds")
            return false
        }
        return true
    }

    static func minimizedWindowIsUnchanged(
        _ window: AXUIElement, fixture: NSRunningApplication, originalFrame: CGRect
    ) -> Bool {
        (attribute(window, kAXMinimizedAttribute) as? Bool) == true &&
            !fixture.isActive && !targetWasActivated && frame(of: window) == originalFrame
    }

    static func currentPeekFrame() -> CGRect? {
        guard let app = running(appID),
              let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let entry = entries.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier &&
                      ($0[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.dockWindow)) - 1
              }),
              let bounds = entry[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    static func quickHoverReturnAfterFocus() -> Bool {
        guard previewClick("preview before quick hover return"), let card = previewCards().last,
              let point = fixtureDockPoint(),
              AXUIElementPerformAction(card, kAXPressAction as CFString) == .success,
              eventually({ running(fixtureID)?.isActive == true }) else {
            _ = fail("quick hover return could not select the fixture")
            return false
        }
        move(CGPoint(x: 150, y: 200))
        wait(0.12)
        move(point)
        guard eventually({ previewCardCount() == 4 }) else {
            _ = fail("leaving and returning during the focus guard permanently blocked hover")
            return false
        }
        print("PASS quick Dock exit and hover return reopens previews after focus")
        return true
    }

    static func overlaysRemainHiddenDuringFocus() -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 2
        var previous: [Int]?
        var firstHidden: TimeInterval?
        var reappeared = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            let layers = previewOverlayLayers()
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            if previous != layers {
                print("TRACE focus overlays t=\(elapsed) layers=\(layers) targetActive=\(running(fixtureID)?.isActive == true)")
                previous = layers
            }
            if layers.isEmpty && firstHidden == nil { firstHidden = elapsed }
            if !layers.isEmpty && firstHidden != nil { reappeared = true }
            wait(0.01)
        }
        // WindowServer can publish the previous frame immediately after an external AX action reply.
        guard let firstHidden, firstHidden < 0.08, !reappeared else {
            _ = fail("focus overlay transition: firstHidden=\(String(describing: firstHidden)), reappeared=\(reappeared)")
            return false
        }
        return true
    }

    static func previewOverlayLayers() -> [Int] {
        guard let app = running(appID) else { return [] }
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        let levels: Set<Int> = [NSWindow.Level.popUpMenu.rawValue, NSWindow.Level.popUpMenu.rawValue + 1, dockLevel - 1, dockLevel - 2]
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap {
            guard ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                  let layer = $0[kCGWindowLayer as String] as? Int, levels.contains(layer) else { return nil }
            return layer
        }
    }

    static func center(of element: AXUIElement) -> CGPoint? {
        guard let frame = frame(of: element) else { return nil }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    static func settledCenter(of element: AXUIElement) -> CGPoint? {
        var previous: CGRect?
        var unchangedSince = ProcessInfo.processInfo.systemUptime
        let settled = eventually {
            guard let current = frame(of: element), current.width > 0, current.height > 0 else { return false }
            let now = ProcessInfo.processInfo.systemUptime
            if previous != current {
                previous = current
                unchangedSince = now
            }
            // AX publishes new cards before the shelf's frame animation finishes.
            guard now - unchangedSince >= 0.2,
                  let value = attribute(element, kAXWindowAttribute),
                  CFGetTypeID(value) == AXUIElementGetTypeID(),
                  let window = frame(of: value as! AXUIElement) else { return false }
            return window.insetBy(dx: -1, dy: -1).contains(current)
        }
        guard settled, let previous else {
            print("TRACE card did not settle inside its window: \(String(describing: previous))")
            return nil
        }
        return CGPoint(x: previous.midX, y: previous.midY)
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    static func contextMenuClick(targetAlreadyActive: Bool = false) -> Bool {
        guard let point = prepareClick() else { return false }
        if targetAlreadyActive {
            _ = running(fixtureID)?.activate(options: [.activateAllWindows])
            guard eventually({ running(fixtureID)?.isActive == true }) else { return false }
            wait(0.1)
            targetWasActivated = false
        }
        click(point, button: .right)
        guard eventually({ nativeDockMenuVisible() && previewCardCount() == 0 }) else {
            _ = fail("right-click did not show the native menu")
            return false
        }
        wait(2)
        click(point)
        guard eventually({ !nativeDockMenuVisible() && previewCardCount() == 4 }), !targetWasActivated else {
            print("TRACE remaining Dock menu windows: \(nativeDockMenuWindows())")
            _ = fail("click after context menu: activated=\(targetWasActivated), previewCards=\(previewCardCount())")
            return false
        }
        print("PASS left-click after the native context menu restores previews (targetAlreadyActive=\(targetAlreadyActive))")
        return true
    }

    static func nativeDockMenuVisible() -> Bool {
        !nativeDockMenuWindows().isEmpty
    }

    static func nativeDockMenuWindows() -> [[String: Any]] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.filter {
            let owner = $0[kCGWindowOwnerName as String] as? String ?? ""
            return (owner == "Dock" || owner == "DockHelper") &&
                ($0[kCGWindowLayer as String] as? Int ?? 0) >= NSWindow.Level.popUpMenu.rawValue
        }
    }

    static func restartPreview() -> Bool {
        guard stop(running(appID)), launchPreview() else { return false }
        wait(0.4)
        return true
    }

    static func launchPreview() -> Bool {
        launch(root + "/build/prevDock.app", arguments: [
            "-dockAppClickPreviewEnabled", "YES", "-nativeDockLabelSuppressionEnabled", "NO"
        ])
    }

    static func launch(_ path: String, arguments: [String] = []) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", path] + (arguments.isEmpty ? [] : ["--args"] + arguments)
        do { try process.run() } catch { return false }
        while process.isRunning { wait(0.02) }
        return process.terminationStatus == 0
    }

    static func stop(_ app: NSRunningApplication?) -> Bool {
        guard let app, !app.isTerminated else { return true }
        _ = app.terminate()
        return eventually { app.isTerminated }
    }

    static func running(_ id: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first
    }

    static func signalFixture(_ value: Int32) {
        if let app = running(fixtureID) { kill(app.processIdentifier, value) }
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func descendants(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < 12 else { return [] }
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        return [element] + children.flatMap { descendants($0, depth: depth + 1) }
    }

    static func fixtureDockPoint() -> CGPoint? {
        guard let dock = running("com.apple.dock") else { return nil }
        let element = AXUIElementCreateApplication(dock.processIdentifier)
        guard let item = descendants(element).first(where: {
            let rawURL = attribute($0, "AXURL")
            let url = (rawURL as? URL) ?? (rawURL as? String).flatMap(URL.init(string:))
            if let url { return url.lastPathComponent == "PreviewWindowFixture.app" }
            let title = attribute($0, kAXTitleAttribute) as? String
            return (attribute($0, kAXSubroleAttribute) as? String) == "AXApplicationDockItem" &&
                title == running(fixtureID)?.localizedName
        }), let position = attribute(item, kAXPositionAttribute),
        let size = attribute(item, kAXSizeAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
        CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGPoint(x: point.x + extent.width / 2, y: point.y + extent.height / 2)
    }

    static func inactiveDockPoint() -> CGPoint? {
        guard let dock = running("com.apple.dock") else { return nil }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        for item in descendants(root) {
            guard (attribute(item, kAXSubroleAttribute) as? String) == "AXApplicationDockItem" else { continue }
            let rawURL = attribute(item, "AXURL")
            let url = (rawURL as? URL) ?? (rawURL as? String).flatMap(URL.init(string:))
            guard let url, url.isFileURL, url.pathExtension.lowercased() == "app",
                  let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  running(id) == nil, let point = center(of: item) else { continue }
            return point
        }
        return nil
    }

    static func fixtureWindowCount() -> Int {
        guard let app = running(fixtureID) else { return -1 }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.1)
        var windows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows)
        if result == .noValue { return 0 }
        guard result == .success, let windows = windows as? [AXUIElement] else { return -1 }
        return windows.count
    }

    static func fixtureWindowTitles() -> Set<String> {
        guard let app = running(fixtureID),
              let windows = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return Set(windows.compactMap { attribute($0, kAXTitleAttribute) as? String })
    }

    static func previewCardCount() -> Int {
        previewCards().count
    }

    static func previewCards() -> [AXUIElement] {
        guard let app = running(appID), let fixture = running(fixtureID) else { return [] }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let panel = windows.first(where: {
            (attribute($0, kAXTitleAttribute) as? String ?? "").hasPrefix("prevDock.preview.\(fixture.processIdentifier).")
        }) else { return [] }
        return descendants(panel).filter {
            (attribute($0, "AXIdentifier") as? String ?? "").hasPrefix("prevDock.previewCard.")
        }
    }

    static func click(_ point: CGPoint, flags: CGEventFlags = [], button: CGMouseButton = .left) {
        let types: [CGEventType] = button == .right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
        for type in types {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
            wait(0.03)
        }
    }

    static func move(_ point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    static func wait(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    static func eventually(_ condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            wait(0.04)
        }
        return condition()
    }

    static func fail(_ message: String) -> Int32 {
        fputs("FAIL \(message)\n", stderr)
        return 1
    }
}
