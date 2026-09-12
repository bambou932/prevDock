import AppKit
import Darwin

@main
enum PreviewLoadingTests {
    static func main() {
        _ = NSApplication.shared
        testActionsEndHoverOwnership()
        testHoverRejectsDisplacedTrackingEvents()
        testHoverRespectsClipAndInitialGate()
        testDesktopGroupTrackingBounds()
        testAccessibleCloseWithoutMouseHover()
        testMinimizedSnapshotDelivery()
        let preview = WindowPreview.placeholder
        let card = PreviewCardView(preview: preview, imageHeight: 140)
        let compact = PreviewCardView(preview: preview, imageHeight: 0,
                                      compactSize: NSSize(width: 400, height: 42))
        expect(card.accessibilityValue() as? String == "Loading", "missing image starts loading")
        let firstPlaceholder = descendants(in: card).first { $0 is ThumbnailLoadingView }
        card.updatePreview(preview)
        expect(descendants(in: card).first { $0 is ThumbnailLoadingView } === firstPlaceholder,
               "metadata refresh reuses the loading placeholder")
        runLoop(for: 1.1)
        card.updatePreview(preview)
        runLoop(for: 1.1)
        expect(card.accessibilityValue() as? String == "Unavailable",
               "repeated metadata refresh must not prolong loading indefinitely")
        compact.updatePreview(preview)
        compact.markThumbnailUnavailable()
        expect(compact.accessibilityValue() as? String == "Ready", "title-only rows must never wait for thumbnails")
        expect(!descendants(in: compact).contains { $0 is ThumbnailUnavailableView || $0 is ThumbnailLoadingView },
               "title-only rows must never create thumbnail placeholders")
        let image = NSImage(size: NSSize(width: 100, height: 100))
        card.updateImage(image, animated: false)
        expect(card.accessibilityValue() as? String == "Ready", "late capture recovers a timed-out card")
        expect(!descendants(in: card).contains { $0 is ThumbnailUnavailableView || $0 is ThumbnailLoadingView },
               "late image replaces the fallback")
        let readyCard = PreviewCardView(preview: preview, imageHeight: 140)
        readyCard.updateImage(image, animated: false)
        runLoop(for: 2.1)
        expect(readyCard.accessibilityValue() as? String == "Ready", "completed image cancels its loading deadline")
        print("PreviewLoadingTests: passed")
    }

    private static func testActionsEndHoverOwnership() {
        var completeFocus: ((Bool) -> Void)?
        let card = PreviewCardView(
            preview: .placeholder,
            imageHeight: 140,
            onFocus: { _, completion in completeFocus = completion }
        )
        let window = hoverTestWindow(size: card.bounds.size)
        window.contentView?.addSubview(card)
        DockCursorTracker.shared.updateFromAppKitPoint(screenPoint(in: card))
        card.mouseEntered(with: trackingEvent())
        expect(card.isHoverActive, "mouse entry should own hover before an action")
        expect(card.accessibilityPerformPress(), "hovered card should accept focus")
        expect(!card.isHoverActive, "in-flight focus must release hover ownership")
        completeFocus?(false)
        let showCount = WindowPeekController.shared.showCount
        card.updatePreview(.placeholder)
        expect(!card.isHoverActive, "failed focus must not restore a stale hover")
        expect(WindowPeekController.shared.showCount == showCount,
               "metadata after failed focus must not steal a peer's live peek")
    }

    private static func testHoverRejectsDisplacedTrackingEvents() {
        let window = hoverTestWindow(size: NSSize(width: 400, height: 126))
        let actualRow = compactCard()
        let displacedRow = compactCard()
        actualRow.clipsToBounds = false
        displacedRow.clipsToBounds = false
        window.contentView?.addSubview(actualRow)
        window.contentView?.addSubview(displacedRow)
        actualRow.setFrameOrigin(NSPoint(x: 0, y: 84))
        displacedRow.setFrameOrigin(.zero)
        expect(actualRow.visibleRect.height > actualRow.bounds.height && displacedRow.visibleRect.height > displacedRow.bounds.height,
               "regression fixture must reproduce AppKit visibleRect extending into sibling rows")
        actualRow.updateTrackingAreas()
        displacedRow.updateTrackingAreas()
        expect(actualRow.trackingAreas.allSatisfy { actualRow.bounds.contains($0.rect) && !$0.options.contains(.inVisibleRect) },
               "unclipped visibleRect must not expand row tracking into siblings")
        expect(displacedRow.trackingAreas.allSatisfy { displacedRow.bounds.contains($0.rect) && !$0.options.contains(.inVisibleRect) },
               "all row tracking rectangles must stay inside row bounds")
        DockCursorTracker.shared.updateFromAppKitPoint(screenPoint(in: displacedRow))
        displacedRow.mouseEntered(with: trackingEvent())
        expect(displacedRow.isHoverActive, "initial row should own hover")
        let actualPoint = screenPoint(in: actualRow)
        DockCursorTracker.shared.updateFromAppKitPoint(actualPoint)
        displacedRow.mouseMoved(with: trackingEvent())
        actualRow.synchronizeHover(at: actualPoint)
        expect(actualRow.isHoverActive && !displacedRow.isHoverActive,
               "current visible row must recover hover even when its enter event is missing")
        DockCursorTracker.shared.updateFromAppKitPoint(actualPoint)
        displacedRow.mouseEntered(with: trackingEvent())
        expect(actualRow.isHoverActive && !displacedRow.isHoverActive,
               "a late tracking event for a displaced row must not steal hover")
        expect(descendants(in: actualRow).contains { $0 is NSButton && !$0.isHidden },
               "only the actual row should expose its close button")
        expect(!descendants(in: displacedRow).contains { $0 is NSButton && !$0.isHidden },
               "the displaced row must release its close button")
        let showCount = WindowPeekController.shared.showCount
        for _ in 0..<10 { actualRow.synchronizeHover(at: actualPoint) }
        expect(WindowPeekController.shared.showCount == showCount,
               "stationary hover reconciliation must not restart peek work")
    }

    private static func testHoverRespectsClipAndInitialGate() {
        let window = hoverTestWindow(size: NSSize(width: 400, height: 84))
        let clip = NSClipView(frame: NSRect(x: 0, y: 0, width: 400, height: 84))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 168))
        window.contentView?.addSubview(clip)
        clip.documentView = document
        clip.scroll(to: .zero)
        let row = compactCard()
        document.addSubview(row)
        row.setFrameOrigin(NSPoint(x: 0, y: 63))
        row.updateTrackingAreas()
        expect(row.trackingAreas.allSatisfy { $0.rect == row.bounds.intersection(row.visibleRect) },
               "partly clipped rows must track only their visible intersection")
        let clippedPoint = window.convertPoint(toScreen: row.convert(NSPoint(x: 200, y: 32), to: nil))
        row.synchronizeHover(at: clippedPoint)
        expect(!row.isHoverActive, "clipped row area must not activate hover")
        let visiblePoint = window.convertPoint(toScreen: row.convert(NSPoint(x: 200, y: 7), to: nil))
        row.prepareForPanelPresentation(initialHoverSuppressionPoint: visiblePoint)
        row.synchronizeHover(at: visiblePoint)
        expect(!row.isHoverActive, "new panel must preserve initial stationary-pointer suppression")
        let movedPoint = CGPoint(x: visiblePoint.x + 3, y: visiblePoint.y)
        row.synchronizeHover(at: movedPoint, allowsActivation: false)
        expect(!row.isHoverActive, "mouse-button hold must not activate a row")
        row.synchronizeHover(at: movedPoint)
        expect(row.isHoverActive, "real pointer movement into the visible row must release the initial gate")
    }

    private static func testDesktopGroupTrackingBounds() {
        let window = hoverTestWindow(size: NSSize(width: 400, height: 126))
        let group = DesktopGroupView(title: nil, isCurrent: true, size: NSSize(width: 400, height: 42))
        group.clipsToBounds = false
        window.contentView?.addSubview(group)
        group.updateTrackingAreas()
        expect(group.trackingAreas.allSatisfy { group.bounds.contains($0.rect) && !$0.options.contains(.inVisibleRect) },
               "desktop group tracking must not extend into its siblings")
        DockCursorTracker.shared.updateFromAppKitPoint(window.convertPoint(toScreen: NSPoint(x: 200, y: 100)))
        group.mouseEntered(with: trackingEvent())
        expect(group.layer?.borderWidth == 1, "out-of-bounds group entry must not highlight the group")
        DockCursorTracker.shared.updateFromAppKitPoint(window.convertPoint(toScreen: NSPoint(x: 200, y: 21)))
        group.mouseEntered(with: trackingEvent())
        expect(group.layer?.borderWidth == 2, "entry inside the group must retain its highlight")
    }

    private static func compactCard() -> PreviewCardView {
        PreviewCardView(preview: .placeholder, imageHeight: 0,
                        compactSize: NSSize(width: 400, height: 42), showsCloseButtonOverride: true)
    }

    private static func hoverTestWindow(size: NSSize) -> NSWindow {
        PreviewHoverTestWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: size),
                               styleMask: .borderless, backing: .buffered, defer: false)
    }

    private static func screenPoint(in card: PreviewCardView) -> CGPoint {
        card.window!.convertPoint(toScreen: card.convert(NSPoint(x: card.bounds.midX, y: card.bounds.midY), to: nil))
    }

    private static func trackingEvent() -> NSEvent {
        NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                          windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
    }

    private static func testAccessibleCloseWithoutMouseHover() {
        var completeClose: ((Bool) -> Void)?
        var closeCount = 0
        let card = PreviewCardView(
            preview: .placeholder, imageHeight: 0,
            compactSize: NSSize(width: 400, height: 42),
            showsCloseButtonOverride: true,
            onClose: { _, completion in
                closeCount += 1
                completeClose = completion
            }
        )
        let close = card.accessibilityCustomActions()?.first { $0.name == "Close Window" }
        expect(close?.handler?() == true, "VoiceOver must close a row without revealing a hover-only button")
        expect(closeCount == 1, "accessible close should invoke the close callback")
        expect(close?.handler?() == false, "accessible close must coalesce repeated in-flight actions")
        completeClose?(false)
        expect(close?.handler?() == true, "accessible close must allow retry after a failure")
        completeClose?(false)
        let disabled = PreviewCardView(preview: .placeholder, imageHeight: 140, showsCloseButtonOverride: false)
        expect(disabled.accessibilityCustomActions()?.isEmpty != false,
               "disabled close-button setting should also disable the custom close action")
    }

    private static func testMinimizedSnapshotDelivery() {
        for compact in [false, true] {
            let card = minimizedCard(id: 31, compact: compact)
            let peer = minimizedCard(id: 32, compact: compact)
            let window = hoverTestWindow(size: NSSize(width: card.bounds.width * 2, height: card.bounds.height))
            window.contentView?.addSubview(card)
            window.contentView?.addSubview(peer)
            peer.setFrameOrigin(NSPoint(x: card.bounds.width, y: 0))
            let image = NSImage(size: NSSize(width: 240, height: 160))
            let initialCount = WindowPeekController.shared.snapshotIDs.count
            card.updateImage(image, animated: false)
            expect(WindowPeekController.shared.snapshotIDs.count == initialCount,
                   "background images must not start a minimized peek without hover")
            DockCursorTracker.shared.updateFromAppKitPoint(screenPoint(in: card))
            card.mouseEntered(with: trackingEvent())
            card.updateImage(image, animated: false)
            expect(WindowPeekController.shared.snapshotIDs.count == initialCount + 1,
                   "late images should update the hovered minimized snapshot, including compact cards")
            DockCursorTracker.shared.updateFromAppKitPoint(screenPoint(in: peer))
            card.updateImage(image, animated: false)
            expect(WindowPeekController.shared.snapshotIDs.count == initialCount + 1,
                   "a displaced pointer must not deliver a snapshot before its exit event")
            peer.mouseEntered(with: trackingEvent())
            card.updateImage(image, animated: false)
            expect(!card.isHoverActive && WindowPeekController.shared.snapshotIDs.count == initialCount + 1,
                   "late images must not restore a peer's expired hover")
            peer.updateImage(image, animated: false)
            expect(WindowPeekController.shared.snapshotIDs.last == 32,
                   "the current peer should accept its own image")
            peer.suspendForFocusTransition()
            let suspendedCount = WindowPeekController.shared.snapshotIDs.count
            peer.updateImage(image, animated: false)
            expect(WindowPeekController.shared.snapshotIDs.count == suspendedCount,
                   "focus suspension must block late snapshot delivery")
            card.prepareForPanelPresentation(initialHoverSuppressionPoint: nil)
            DockCursorTracker.shared.updateFromAppKitPoint(screenPoint(in: card))
            card.mouseEntered(with: trackingEvent())
            expect(card.accessibilityPerformPress(), "a minimized preview must retain its focus action")
            card.updateImage(image, animated: false)
            expect(WindowPeekController.shared.snapshotIDs.count == suspendedCount,
                   "a focus action must end snapshot delivery even when the action fails")
        }
    }

    private static func minimizedCard(id: CGWindowID, compact: Bool) -> PreviewCardView {
        let preview = WindowPreview(
            windowID: id, title: "Minimized", bounds: CGRect(x: 40, y: 40, width: 240, height: 160),
            isMinimized: true, isFullscreen: false, isFocused: false, desktop: nil, image: nil, app: .current
        )
        return PreviewCardView(
            preview: preview, imageHeight: 140,
            compactSize: compact ? NSSize(width: 400, height: 42) : nil
        )
    }

    private static func descendants(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(in: $0) }
    }

    private static func runLoop(for interval: TimeInterval) {
        let deadline = Date().addingTimeInterval(interval)
        while Date() < deadline {
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}

// Keep capture and desktop side effects out of this real AppKit card presentation test.
struct WindowPreview {
    let windowID: CGWindowID
    let title: String
    let bounds: CGRect
    let isMinimized: Bool
    let isFullscreen: Bool
    let isFocused: Bool
    let desktop: WindowDesktop?
    let image: NSImage?
    let app: NSRunningApplication

    func replacingImage(with image: NSImage?) -> WindowPreview {
        WindowPreview(windowID: windowID, title: title, bounds: bounds,
                      isMinimized: isMinimized, isFullscreen: isFullscreen,
                      isFocused: isFocused, desktop: desktop, image: image, app: app)
    }
}

struct WindowDesktop: Hashable {
    let id: UInt64
    let title: String
    let sortOrder: Int
    let isCurrent: Bool
}

final class WindowPeekController {
    static let shared = WindowPeekController()
    private(set) var showCount = 0
    private(set) var snapshotIDs = [CGWindowID]()
    func show(preview: WindowPreview) { showCount += 1 }
    func updateSnapshot(preview: WindowPreview) { snapshotIDs.append(preview.windowID) }
    func hide() {}
    func hide(windowID: CGWindowID) {}
}

// Exercise AppKit coordinate conversion without displaying a test window over the user's apps.
private final class PreviewHoverTestWindow: NSWindow {
    override var isVisible: Bool { true }
}
