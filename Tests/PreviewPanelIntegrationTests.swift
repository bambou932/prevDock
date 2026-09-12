import AppKit
import Darwin

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
private enum PreviewPanelIntegrationTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain([
            PrevDockSettings.previewOverflowModeKey: PreviewOverflowMode.scroll.rawValue,
            PrevDockSettings.previewAutoFitEnabledKey: true,
            PrevDockSettings.previewDesktopGroupingEnabledKey: false,
            PrevDockSettings.previewCloseButtonEnabledKey: true
        ], forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        do {
            try testCompactCardActions()
            print("PASS compact cards preserve focus, close, and retry feedback")
            try testFocusTransitionBlocksReappearance()
            try testFocusFailureRestoresAndRetries()
            try testNewInteractionCancelsObsoleteFocus()
            print("PASS focus hides shelf and peek throughout pending, success, failure, and superseded actions")
            try testEmptyInventoryPresentation()
            try testEmptyInventoryDuringFocus()
            try testEmptyInventoryDuringRemoval()
            try testFinalWindowClose()
            print("PASS empty inventories hide and clear thumbnails, compact rows, pending removal, and final close")
            try testGrowingWindowListPreservesOrder()
            try testWindowGrowthIntoCompactList()
            try testMetadataGrowthDuringClose()
            print("PASS new windows preserve ordering, scrolling, focus suppression, and pending close ownership")
            try testCompactPanelTransitions()
            print("PASS live panel overflow, list refresh, scrolling, and thumbnail recovery")
            try testLegacyDockGeometry()
            print("PASS manual layouts fit every Dock edge and rebuild changed viewports")
        } catch {
            fputs("FAIL \(error)\n", stderr)
            exit(1)
        }
    }

    private static func testCompactCardActions() throws {
        var focusCount = 0
        var closeCount = 0
        let card = PreviewCardView(
            preview: preview(1), imageHeight: 0,
            compactSize: NSSize(width: 400, height: 42),
            showsCloseButtonOverride: true,
            onFocus: { _, completion in focusCount += 1; completion(false) },
            onClose: { _, completion in closeCount += 1; completion(false) }
        )
        card.layoutSubtreeIfNeeded()
        try expect(card.accessibilityPerformPress(), "compact row could not be activated")
        try expect(focusCount == 1, "compact row did not invoke focus callback")
        guard let close = descendants(of: NSButton.self, in: card).first else {
            throw TestFailure(description: "compact row lost its close button")
        }
        close.performClick(nil)
        try expect(closeCount == 1 && close.isEnabled, "close failure did not restore interaction")
        try expect(card.accessibilityPerformPress(), "compact row could not retry focus after failure")
        try expect(focusCount == 2, "compact focus retry was lost")
        try expect(card.bounds.contains(close.frame), "real close button escaped compact row")
        try expect(descendants(of: NSProgressIndicator.self, in: card).isEmpty, "title list created thumbnail spinners")
    }

    private static func testFocusTransitionBlocksReappearance() throws {
        let (controller, panel, requests) = try focusFixture()
        defer { controller.resumePresentationForInteraction(); controller.hide() }
        let (selected, point) = try hoverFirstCard(controller: controller, panel: panel)
        let originalCards = descendants(of: PreviewCardView.self, in: panel.contentView!)
        try expect(selected.accessibilityPerformPress(), "selected card must initiate focus")
        try expect(requests.requests.count == 1 && requests.startedHidden == [true] && requests.performerStartedHidden == [true],
                   "shelf and peek must hide before both start callback and OS focus performer")
        try expect(controller.isFocusTransitionActive && !controller.isVisible && !WindowPeekController.shared.isShowingLivePreview,
                   "pending focus must immediately hide every preview layer")
        try exerciseBlockedRefreshes(controller: controller, cards: originalCards, point: point)
        try expect(requests.requests.count == 1, "new-window metadata must not issue another pending focus command")
        requests.complete(0, success: true)
        try expect(!controller.isFocusTransitionActive && requests.finished == [true], "owned focus must finish once")
        try exerciseBlockedRefreshes(controller: controller, cards: originalCards, point: point)
        try expect(requests.requests.count == 1, "new-window metadata must not refocus after a successful selection")
        requests.callbacks[0](false)
        try expect(requests.finished == [true] && !controller.isVisible, "duplicate completion must not restore a succeeded shelf")
        controller.resumePresentationForInteraction()
        prepareDockPointer()
        try expect(requests.requests[0].isCancelled, "new intent must cancel obsolete post-focus work")
        try expect(controller.show(previews: [preview(1), preview(2)], app: .current, anchoredTo: focusAnchor()) == .shown,
                   "explicit interaction must admit a new presentation")
        _ = try hoverFirstCard(controller: controller, panel: panel)
    }

    private static func exerciseBlockedRefreshes(
        controller: PreviewPanelController, cards: [PreviewCardView], point: CGPoint
    ) throws {
        for count in [2, 3, 24, 1] {
            let result = controller.show(previews: (0..<count).map { preview(UInt32($0 + 1)) }, app: .current, anchoredTo: focusAnchor())
            try expect(result == .suppressed, "metadata and layout changes must not bypass the focus block")
            controller.synchronizeHoverEffects(at: point)
            for card in cards {
                card.synchronizeHover(at: point)
                try expect(!card.restoreHoverIfNeeded(at: point), "reflow cannot reactivate a suspended card")
                try expect(!card.accessibilityPerformPress(), "peer actions must be suspended for the whole presentation")
            }
            try expect(!controller.isVisible && !WindowPeekController.shared.isShowingLivePreview,
                       "preview layers must remain hidden during each pending refresh attempt")
        }
    }

    private static func testFocusFailureRestoresAndRetries() throws {
        let (controller, panel, requests) = try focusFixture()
        defer { controller.resumePresentationForInteraction(); controller.hide() }
        let (selected, point) = try hoverFirstCard(controller: controller, panel: panel)
        let originalCards = descendants(of: PreviewCardView.self, in: panel.contentView!)
        let originalFrame = panel.frame
        try expect(selected.accessibilityPerformPress(), "focus failure fixture must initiate focus")
        DockCursorTracker.shared.updateFromAppKitPoint(point)
        requests.complete(0, success: false)
        try expect(requests.requests[0].isCancelled, "failed focus must cancel residual focus work before restoring the shelf")
        try expect(controller.isVisible && !controller.isFocusTransitionActive && panel.frame == originalFrame,
                   "failure must restore the original shelf and position")
        let restoredCards = descendants(of: PreviewCardView.self, in: panel.contentView!)
        try expect(zip(originalCards, restoredCards).allSatisfy { $0 === $1 }, "failure must retain action feedback on original cards")
        try expect(descendants(of: NSTextField.self, in: selected).contains { $0.stringValue == "Open failed" },
                   "failure must remain visible and retryable")
        controller.synchronizeHoverEffects(at: point)
        try expect(!WindowPeekController.shared.isShowingLivePreview && restoredCards.allSatisfy { !$0.isHoverActive },
                   "failure restore must not restart a peek under the stationary pointer")
        try expect(selected.accessibilityPerformPress() && requests.requests.count == 2, "failed focus must allow retry")
        requests.callbacks[0](true)
        try expect(controller.isFocusTransitionActive && !controller.isVisible, "old failure completion cannot finish a retry")
        requests.complete(1, success: true)
        try expect(requests.finished == [false, true] && !controller.isVisible, "only the current retry may finish")
    }

    private static func testNewInteractionCancelsObsoleteFocus() throws {
        let (controller, panel, requests) = try focusFixture()
        defer { controller.resumePresentationForInteraction(); controller.hide() }
        let (selected, _) = try hoverFirstCard(controller: controller, panel: panel)
        try expect(selected.accessibilityPerformPress(), "cancellation fixture must start focus")
        try expect(controller.show(previews: [], app: .current, anchoredTo: focusAnchor()) == .hidden,
                   "empty content must remain compatible with superseding a pending focus")
        controller.resumePresentationForInteraction()
        prepareDockPointer()
        try expect(requests.requests[0].isCancelled && !controller.isFocusTransitionActive, "new interaction must cancel pending OS focus")
        try expect(controller.show(previews: (10...33).map { preview(UInt32($0)) }, app: .current, anchoredTo: focusAnchor()) == .shown,
                   "new user intent must be able to open another shelf")
        let newFrame = panel.frame
        for staleResult in [true, false] { requests.callbacks[0](staleResult) }
        try expect(controller.isVisible && panel.frame == newFrame && requests.finished.isEmpty,
                   "late completion must not hide or restore over the newer presentation")
        try expect(descendants(of: PreviewCardView.self, in: panel.contentView!).count == 24,
                   "late completion must not replace the newer compact list")
        _ = try hoverFirstCard(controller: controller, panel: panel)
    }

    private static func focusFixture() throws -> (PreviewPanelController, NSPanel, FocusRequests) {
        let requests = FocusRequests()
        let controller = PreviewPanelController(focusPerformer: requests.perform)
        controller.onFocusTransitionStarted = { [weak controller] in
            requests.startedHidden.append(controller?.isVisible == false && !WindowPeekController.shared.isShowingLivePreview)
            controller?.hide() // Monitor cancellation and Space notifications may hide again during focus.
        }
        controller.onFocusTransitionFinished = { requests.finished.append($0) }
        requests.onPerform = { [weak controller, weak requests] in
            guard let requests else { return }
            requests.performerStartedHidden.append(controller?.isVisible == false &&
                controller?.isFocusTransitionActive == true && !WindowPeekController.shared.isShowingLivePreview &&
                requests.startedHidden.count == requests.requests.count)
        }
        prepareDockPointer()
        controller.show(previews: [preview(1), preview(2)], app: .current, anchoredTo: focusAnchor())
        guard let panel = NSApp.windows.first(where: { $0.isVisible && $0.title.hasPrefix("prevDock.preview.") }) as? NSPanel else {
            throw TestFailure(description: "focus fixture shelf was not presented")
        }
        return (controller, panel, requests)
    }

    private static func hoverFirstCard(controller: PreviewPanelController, panel: NSPanel) throws -> (PreviewCardView, CGPoint) {
        panel.contentView?.layoutSubtreeIfNeeded()
        guard let card = descendants(of: PreviewCardView.self, in: panel.contentView!).first else {
            throw TestFailure(description: "focus fixture card was not presented")
        }
        let rect = card.bounds.intersection(card.visibleRect)
        let point = panel.convertPoint(toScreen: card.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil))
        DockCursorTracker.shared.updateFromAppKitPoint(point)
        controller.synchronizeHoverEffects(at: point)
        try expect(card.isHoverActive && WindowPeekController.shared.isShowingLivePreview,
                   "focus regression must start with a real visible peek (hover=\(card.isHoverActive), peek=\(WindowPeekController.shared.isShowingLivePreview))")
        return (card, point)
    }

    private static func prepareDockPointer() {
        let anchor = focusAnchor()
        DockCursorTracker.shared.updateFromAppKitPoint(NSPoint(x: anchor.midX, y: anchor.midY))
    }

    private static func testEmptyInventoryPresentation() throws {
        let controller = PreviewPanelController()
        defer { controller.hide() }
        try expect(controller.show(previews: [], app: .current, anchoredTo: focusAnchor()) == .hidden,
                   "cold empty inventory must report no presentation")
        try expect(!controller.isVisible && controller.visibleApp == nil && !controller.needsBackgroundThumbnails,
                   "cold empty inventory must not create a shelf or thumbnail work")
        for count in [2, 24] {
            prepareDockPointer()
            controller.show(previews: (1...count).map { preview(UInt32($0)) }, app: .current, anchoredTo: focusAnchor())
            let panel = try visiblePreviewPanel()
            let (card, point) = try hoverFirstCard(controller: controller, panel: panel)
            try expect(controller.show(previews: [], app: .current, anchoredTo: focusAnchor()) == .hidden,
                       "empty refresh must dismiss a previously visible shelf")
            controller.updateThumbnail(windowID: 900_001, image: sampleImage())
            controller.markThumbnailUnavailable(windowID: 900_001)
            card.synchronizeHover(at: point)
            try expect(!card.restoreHoverIfNeeded(at: point), "removed cards must not recover their hover")
            try expect(controller.refreshForSettingsChange() == nil, "settings refresh must not resurrect an empty inventory")
            try expectEmptyPresentation(controller: controller, panel: panel)
            drainMainQueue(for: 0.25)
            try expectEmptyPresentation(controller: controller, panel: panel)
        }
        prepareDockPointer()
        try expect(controller.show(previews: [preview(4)], app: .current, anchoredTo: focusAnchor()) == .shown,
                   "a real window appearing after an empty inventory must be presentable")
        let panel = try visiblePreviewPanel()
        try expect(descendants(of: PreviewCardView.self, in: panel.contentView!).count == 1,
                   "returning windows must not retain the old inventory")
        _ = try hoverFirstCard(controller: controller, panel: panel)
    }

    private static func testEmptyInventoryDuringRemoval() throws {
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        var settings = original
        settings[PrevDockSettings.previewAutoFitEnabledKey] = false
        for mode in [PreviewOverflowMode.scroll, .wrap] {
            settings[PrevDockSettings.previewOverflowModeKey] = mode.rawValue
            defaults.setVolatileDomain(settings, forName: UserDefaults.argumentDomain)
            let controller = PreviewPanelController()
            defer { controller.hide() }
            prepareDockPointer()
            controller.show(previews: [preview(1), preview(2)], app: .current, anchoredTo: focusAnchor())
            let panel = try visiblePreviewPanel()
            controller.show(previews: [preview(2)], app: .current, anchoredTo: focusAnchor())
            controller.show(previews: [], app: .current, anchoredTo: focusAnchor())
            try expectEmptyPresentation(controller: controller, panel: panel)
            drainMainQueue(for: 0.3)
            try expectEmptyPresentation(controller: controller, panel: panel)
            controller.show(previews: [preview(3)], app: .current, anchoredTo: focusAnchor())
            try expect(controller.isVisible, "empty inventory must not block later manual presentations")
            controller.hide()
        }
    }

    private static func testEmptyInventoryDuringFocus() throws {
        for success in [false, true] {
            let (controller, panel, requests) = try focusFixture()
            defer { controller.resumePresentationForInteraction(); controller.hide() }
            let (selected, _) = try hoverFirstCard(controller: controller, panel: panel)
            try expect(selected.accessibilityPerformPress(), "empty focus fixture must initiate focus")
            try expect(controller.show(previews: [], app: OtherApplication(), anchoredTo: focusAnchor()) == .suppressed,
                       "another app's empty refresh must not clear the selected app")
            try expect(descendants(of: PreviewCardView.self, in: panel.contentView!).count == 2,
                       "unrelated empty refresh must retain the selected app's cards")
            try expect(controller.show(previews: [], app: .current, anchoredTo: focusAnchor()) == .hidden,
                       "matching empty refresh must clear the selected app's obsolete cards")
            try expect(controller.isFocusTransitionActive && requests.requests[0].isActive,
                       "empty content must not cancel or finish the selected focus")
            try expectEmptyPresentation(controller: controller, panel: panel)
            try expect(controller.show(previews: [preview(3)], app: .current, anchoredTo: focusAnchor()) == .suppressed,
                       "clearing empty content must not admit metadata while focus remains pending")
            requests.complete(0, success: success)
            try expect(requests.finished == [success] && !controller.isFocusTransitionActive,
                       "empty focus completion must retain ownership and finish once")
            try expectEmptyPresentation(controller: controller, panel: panel)
            requests.callbacks[0](!success)
            try expectEmptyPresentation(controller: controller, panel: panel)
            controller.resumePresentationForInteraction()
            prepareDockPointer()
            try expect(controller.show(previews: [preview(4)], app: .current, anchoredTo: focusAnchor()) == .shown,
                       "fresh user intent must reopen after clearing content during focus")
            requests.callbacks[0](false)
            try expect(controller.isVisible && descendants(of: PreviewCardView.self, in: panel.contentView!).count == 1,
                       "obsolete focus completion must not replace a newer real window")
        }
    }

    private static func testFinalWindowClose() throws {
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        for usesAutoFit in [true, false] {
            var settings = original
            settings[PrevDockSettings.previewAutoFitEnabledKey] = usesAutoFit
            defaults.setVolatileDomain(settings, forName: UserDefaults.argumentDomain)
            let closes = CloseRequests()
            let controller = PreviewPanelController(closePerformer: closes.perform)
            defer { controller.hide() }
            for receivesEmptyRefresh in [false, true] {
                prepareDockPointer()
                controller.show(previews: [preview(1)], app: .current, anchoredTo: focusAnchor())
                let panel = try visiblePreviewPanel()
                let (card, _) = try hoverFirstCard(controller: controller, panel: panel)
                guard let button = descendants(of: NSButton.self, in: card).first else {
                    throw TestFailure(description: "final preview must expose its close action")
                }
                button.performClick(nil)
                try expect(closes.callbacks.count == 1, "final close must invoke exactly one window action")
                if receivesEmptyRefresh {
                    controller.show(previews: [], app: .current, anchoredTo: focusAnchor())
                }
                closes.callbacks.removeFirst()(true)
                drainMainQueue(for: 0.3)
                try expectEmptyPresentation(controller: controller, panel: panel)
            }
        }
    }

    private static func expectEmptyPresentation(controller: PreviewPanelController, panel: NSPanel) throws {
        try expect(!controller.isVisible && controller.visibleApp == nil && !controller.needsBackgroundThumbnails,
                   "empty inventory must not leave a visible or capturing shelf")
        try expect(!WindowPeekController.shared.isShowingLivePreview, "empty inventory must dismiss its hover peek")
        try expect(descendants(of: PreviewCardView.self, in: panel.contentView!).isEmpty,
                   "empty inventory must release obsolete cards")
        try expect(descendants(of: NSTextField.self, in: panel.contentView!).isEmpty,
                   "empty inventory must not contain an app-name or no-window placeholder")
    }

    private static func visiblePreviewPanel() throws -> NSPanel {
        guard let panel = NSApp.windows.first(where: { $0.isVisible && $0.title.hasPrefix("prevDock.preview.") }) as? NSPanel else {
            throw TestFailure(description: "expected a visible preview shelf")
        }
        return panel
    }

    private static func drainMainQueue(for duration: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(duration))
    }

    private static func focusAnchor() -> NSRect {
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: frame.midX, y: frame.minY, width: 56, height: 60)
    }

    private static func testGrowingWindowListPreservesOrder() throws {
        let controller = PreviewPanelController()
        defer { controller.hide() }
        prepareDockPointer()
        let previews = (1...3).map { preview(UInt32($0)) }
        controller.show(previews: Array(previews.prefix(2)), app: .current, anchoredTo: focusAnchor())
        let panel = try visiblePreviewPanel()
        try expectPresentedWindows([1, 2], in: panel)
        try expect(controller.show(previews: Array(previews.reversed()), app: .current, anchoredTo: focusAnchor()) == .shown,
                   "a third window must join the already visible shelf")
        try expectPresentedWindows([1, 2, 3], in: panel)
        let cards = descendants(of: PreviewCardView.self, in: panel.contentView!)
        controller.show(previews: [previews[1], previews[2], previews[0]], app: .current, anchoredTo: focusAnchor())
        try expectPresentedWindows([1, 2, 3], in: panel)
        let refreshedCards = descendants(of: PreviewCardView.self, in: panel.contentView!)
        try expect(cards.count == refreshedCards.count && zip(cards, refreshedCards).allSatisfy { $0 === $1 },
                   "an unchanged window set must reuse cards even when incoming metadata is reordered")
        try expect(controller.isVisible && !controller.isFocusTransitionActive,
                   "metadata-only growth must keep the shelf visible without starting focus")
    }

    private static func testWindowGrowthIntoCompactList() throws {
        let controller = PreviewPanelController()
        defer { controller.hide() }
        prepareDockPointer()
        let previews = (1...50).map { preview(UInt32($0)) }
        controller.show(previews: Array(previews.prefix(2)), app: .current, anchoredTo: focusAnchor())
        let panel = try visiblePreviewPanel()
        try expect(controller.needsBackgroundThumbnails, "growth fixture must start with automatic thumbnails")
        controller.show(previews: Array(previews.reversed()), app: .current, anchoredTo: focusAnchor())
        try expectPresentedWindows((1...50).map { UInt32($0) }, in: panel)
        try expect(!controller.needsBackgroundThumbnails,
                   "growing past thumbnail capacity must use compact rows without background capture work")
        try expect(descendants(of: NSProgressIndicator.self, in: panel.contentView!).isEmpty,
                   "new compact rows must not introduce thumbnail loading spinners")
        try verifyScrolledCompactGrowth(controller: controller, panel: panel)
    }

    private static func verifyScrolledCompactGrowth(controller: PreviewPanelController, panel: NSPanel) throws {
        guard let scroll = descendants(of: NSScrollView.self, in: panel.contentView!).first else {
            throw TestFailure(description: "growing compact list must expose a scroll viewport")
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 420))
        scroll.reflectScrolledClipView(scroll.contentView)
        let originalPosition = scroll.contentView.bounds.origin
        let grownPreviews = (1...60).reversed().map { preview(UInt32($0)) }
        controller.show(previews: grownPreviews, app: .current, anchoredTo: focusAnchor())
        try expectPresentedWindows((1...60).map { UInt32($0) }, in: panel)
        guard let updatedScroll = descendants(of: NSScrollView.self, in: panel.contentView!).first,
              let document = updatedScroll.documentView else {
            throw TestFailure(description: "adding compact rows must retain a scroll viewport")
        }
        let position = updatedScroll.contentView.bounds.origin
        try expect(abs(position.x - originalPosition.x) < 1 && abs(position.y - originalPosition.y) < 1,
                   "appending windows must preserve the existing compact scroll offset")
        try expect(position.x >= 0 && position.y >= 0 &&
                   position.x <= max(0, document.bounds.width - updatedScroll.contentView.bounds.width) + 0.5 &&
                   position.y <= max(0, document.bounds.height - updatedScroll.contentView.bounds.height) + 0.5,
                   "the restored viewport must remain within the expanded document")
    }

    private static func testMetadataGrowthDuringClose() throws {
        for succeeds in [false, true] {
            try verifyMetadataGrowthDuringClose(succeeds: succeeds)
        }
    }

    private static func verifyMetadataGrowthDuringClose(succeeds: Bool) throws {
        let closes = CloseRequests()
        let focuses = FocusRequests()
        let controller = PreviewPanelController(focusPerformer: focuses.perform, closePerformer: closes.perform)
        defer { controller.hide() }
        prepareDockPointer()
        controller.show(previews: [preview(1), preview(2)], app: .current, anchoredTo: focusAnchor())
        let panel = try visiblePreviewPanel()
        guard let card = descendants(of: PreviewCardView.self, in: panel.contentView!).first,
              let button = descendants(of: NSButton.self, in: card).first else {
            throw TestFailure(description: "pending-close growth fixture requires a close button")
        }
        button.performClick(nil)
        try expect(closes.windowIDs == [900_001] && closes.callbacks.count == 1,
                   "one close click must start exactly one command for the selected window")
        controller.show(previews: [preview(3), preview(2), preview(1)], app: .current, anchoredTo: focusAnchor())
        try expectPresentedWindows([1, 2, 3], in: panel)
        try expect(closes.windowIDs == [900_001] && focuses.requests.isEmpty,
                   "new-window metadata must not duplicate close or activate a window")
        closes.callbacks[0](succeeds)
        drainMainQueue(for: 0.3)
        try expectPresentedWindows(succeeds ? [2, 3] : [1, 2, 3], in: panel)
        try expect(controller.isVisible && closes.windowIDs == [900_001] && focuses.requests.isEmpty,
                   "the pending close result must affect only its original window without issuing more commands")
    }

    private static func expectPresentedWindows(_ ids: [UInt32], in panel: NSPanel) throws {
        guard let content = panel.contentView else { throw TestFailure(description: "preview content is missing") }
        content.layoutSubtreeIfNeeded()
        let cards = descendants(of: PreviewCardView.self, in: content)
        let actual = cards.compactMap { $0.accessibilityIdentifier() }
        let expected = ids.map { "prevDock.previewCard.\(900_000 + $0)" }
        try expect(cards.count == ids.count && actual == expected,
                   "window snapshot must appear once in stable order: expected \(expected), got \(actual)")
        try expect(Set(actual).count == actual.count, "window growth must not create duplicate cards")
    }

    private static func testCompactPanelTransitions() throws {
        guard let screen = NSScreen.main else { throw TestFailure(description: "AppKit screen unavailable") }
        let anchor = NSRect(x: screen.frame.midX, y: screen.frame.minY, width: 56, height: 60)
        let controller = PreviewPanelController()
        defer { controller.hide() }
        let previews = (1...50).map { preview(UInt32($0)) }
        try expect(controller.show(previews: previews, app: .current, anchoredTo: anchor) == .shown,
                   "overflow required an external Dock menu")
        try expect(!controller.needsBackgroundThumbnails, "title list requested background thumbnail work")
        guard let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }),
              let content = panel.contentView else {
            throw TestFailure(description: "compact panel was not shown")
        }
        content.layoutSubtreeIfNeeded()
        try expect(descendants(of: PreviewCardView.self, in: content).count == 50, "overflow lost windows")
        let available = PreviewPanelAvailableSpace.size(
            visibleFrame: screen.visibleFrame, screenFrame: screen.frame,
            dockAnchor: anchor, dockEdge: .bottom
        )
        try expect(panel.frame.width <= available.width && panel.frame.height <= available.height,
                   "compact list exceeded available screen bounds")
        guard let scroll = descendants(of: NSScrollView.self, in: content).first else {
            throw TestFailure(description: "fifty-window list could not scroll")
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 420))
        scroll.reflectScrolledClipView(scroll.contentView)
        let offset = scroll.contentView.bounds.minY
        controller.show(previews: Array(previews.prefix(45)), app: .current, anchoredTo: anchor)
        content.layoutSubtreeIfNeeded()
        guard let rebuiltScroll = descendants(of: NSScrollView.self, in: content).first else {
            throw TestFailure(description: "list removal lost scrolling")
        }
        try expect(abs(rebuiltScroll.contentView.bounds.minY - offset) < 1, "list removal reset scroll position")
        try saveSnapshot(content, name: "compact-overflow.png")
        try testLiveCloseButtonSetting(controller: controller, content: content)

        controller.show(previews: Array(previews.prefix(2)), app: .current, anchoredTo: anchor)
        content.layoutSubtreeIfNeeded()
        try expect(controller.needsBackgroundThumbnails, "closing windows failed to restore thumbnails")
        try expect(descendants(of: PreviewCardView.self, in: content).count == 2, "thumbnail transition retained stale rows")
        try expect(descendants(of: NSScrollView.self, in: content).isEmpty, "fitting thumbnails unexpectedly scroll")
        try saveSnapshot(content, name: "auto-thumbnails.png")
    }

    private static func testLiveCloseButtonSetting(controller: PreviewPanelController, content: NSView) throws {
        let defaults = UserDefaults.standard
        var settings = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        settings[PrevDockSettings.previewCloseButtonEnabledKey] = false
        defaults.setVolatileDomain(settings, forName: UserDefaults.argumentDomain)
        controller.refreshForSettingsChange()
        try expect(descendants(of: NSButton.self, in: content).isEmpty, "visible compact list ignored close-button setting")
        settings[PrevDockSettings.previewCloseButtonEnabledKey] = true
        defaults.setVolatileDomain(settings, forName: UserDefaults.argumentDomain)
        controller.refreshForSettingsChange()
    }

    private static func testLegacyDockGeometry() throws {
        guard let screen = NSScreen.main else { throw TestFailure(description: "AppKit screen unavailable") }
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        var settings = original
        settings[PrevDockSettings.previewAutoFitEnabledKey] = false
        settings[PrevDockSettings.previewWindowHeightKey] = PreviewWindowHeight.extraLarge.rawValue
        let previews = (1...50).map { preview(UInt32($0)) }
        let anchors: [(PreviewPanelDockEdge, CGRect)] = [
            (.bottom, CGRect(x: screen.frame.midX, y: screen.frame.minY, width: 56, height: 180)),
            (.left, CGRect(x: screen.frame.minX, y: screen.frame.midY, width: 180, height: 56)),
            (.right, CGRect(x: screen.frame.maxX - 180, y: screen.frame.midY, width: 180, height: 56)),
            (.top, CGRect(x: screen.frame.midX, y: screen.frame.maxY - 180, width: 56, height: 180)),
            (.bottom, CGRect(x: screen.frame.midX, y: screen.frame.minY, width: 56, height: screen.frame.height * 0.48))
        ]
        for mode in [PreviewOverflowMode.scroll, .wrap] {
            settings[PrevDockSettings.previewOverflowModeKey] = mode.rawValue
            defaults.setVolatileDomain(settings, forName: UserDefaults.argumentDomain)
            let controller = PreviewPanelController()
            defer { controller.hide() }
            var previousScroll: NSScrollView?
            var previousWidth: CGFloat?
            for (edge, anchor) in anchors {
                controller.show(previews: previews, app: .current, anchoredTo: anchor)
                guard let panel = NSApp.windows.first(where: { $0.isVisible && $0.title.hasPrefix("prevDock.preview.") }),
                      let content = panel.contentView else {
                    throw TestFailure(description: "manual preview panel was not shown")
                }
                content.layoutSubtreeIfNeeded()
                let available = PreviewPanelAvailableSpace.size(
                    visibleFrame: screen.visibleFrame, screenFrame: screen.frame,
                    dockAnchor: anchor, dockEdge: edge
                )
                try expect(panel.frame.width <= available.width + 0.5 && panel.frame.height <= available.height + 0.5,
                           "\(mode) \(edge) preview escaped the available Dock-side area")
                let scroll = descendants(of: NSScrollView.self, in: content).first
                if let previousScroll, let previousWidth, abs(previousWidth - available.width) > 1 {
                    try expect(scroll !== previousScroll, "changed Dock geometry reused stale scroll constraints")
                }
                previousScroll = scroll
                previousWidth = available.width
                try expect(descendants(of: PreviewCardView.self, in: content).count == previews.count,
                           "manual overflow omitted a window")
            }
            controller.hide()
        }
    }

    private static func preview(_ id: UInt32) -> WindowPreview {
        WindowPreview(
            windowID: 900_000 + id,
            title: "Window \(id) — Project document",
            bounds: NSRect(x: 0, y: 0, width: 1200, height: 800),
            isMinimized: id.isMultiple(of: 3), isFullscreen: false,
            isFocused: id == 1, desktop: nil, image: sampleImage(), app: .current
        )
    }

    private static func sampleImage() -> NSImage {
        NSImage(size: NSSize(width: 600, height: 400), flipped: false) { rect in
            NSColor(calibratedRed: 0.17, green: 0.24, blue: 0.35, alpha: 1).setFill()
            rect.fill()
            for index in 0..<6 {
                NSColor.white.withAlphaComponent(0.15).setFill()
                NSRect(x: 32, y: 40 + index * 48, width: 500 - index * 35, height: 15).fill()
            }
            return true
        }
    }

    private static func saveSnapshot(_ view: NSView, name: String) throws {
        guard CommandLine.arguments.count > 1,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name))
    }

    private static func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(of: type, in: $0) }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(description: message) }
    }
}

private final class OtherApplication: NSRunningApplication, @unchecked Sendable {
    override var processIdentifier: pid_t { -1 }
}

private final class FocusRequests {
    var requests = [WindowFocusRequest]()
    var callbacks = [(Bool) -> Void]()
    var startedHidden = [Bool]()
    var performerStartedHidden = [Bool]()
    var finished = [Bool]()
    var onPerform: (() -> Void)?

    func perform(windowID: CGWindowID, app: NSRunningApplication, completion: @escaping (Bool) -> Void) -> WindowFocusRequest {
        let request = WindowFocusRequest()
        requests.append(request)
        callbacks.append(completion)
        onPerform?()
        return request
    }

    func complete(_ index: Int, success: Bool) {
        guard requests[index].finish() else { return }
        callbacks[index](success)
    }
}

private final class CloseRequests {
    var callbacks = [(Bool) -> Void]()
    var windowIDs = [CGWindowID]()

    func perform(windowID: CGWindowID, app: NSRunningApplication, isFullscreen: Bool, completion: @escaping (Bool) -> Void) {
        windowIDs.append(windowID)
        callbacks.append(completion)
    }
}
