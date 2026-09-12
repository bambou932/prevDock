import AppKit
import Darwin

@main
enum PermissionSettingsViewTests {
    static func main() {
        _ = NSApplication.shared
        let view = PermissionSettingsView()
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: PermissionManager.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        publish(accessibility: false, recording: false)
        expect(labels(in: view).contains { $0.contains("Accessibility and Screen Recording are not granted") },
               "central revocation should update the idle permission view")
        publish(accessibility: true, recording: true)
        expect(labels(in: view).contains { $0.hasPrefix("Ready") },
               "central grant should update the idle permission view")
        publish(accessibility: true, recording: false)
        expect(labels(in: view).contains { $0.contains("Screen Recording is not granted") },
               "partial revocation should identify the remaining permission")
        expect(notifications == 3, "the permission view must not republish central state changes")
        verifyNarrowLayouts()
        verifyFocusTransfer()
        verifyInactivePageUpdates()
        print("PermissionSettingsViewTests: passed")
    }

    private static func verifyNarrowLayouts() {
        for width: CGFloat in [500, 560, 660] {
            let (window, view) = makeWindow(width: width)
            var lightColors = [CGColor]()
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                for state in [(false, false), (true, false), (false, true), (true, true)] {
                    publish(accessibility: state.0, recording: state.1)
                    window.contentView?.layoutSubtreeIfNeeded()
                    verifyContentBounds(view)
                    verifyTrailingAlignment(view)
                    let buttons = descendants(in: view).compactMap { $0 as? NSButton }
                    let requests = buttons.filter { $0.title == "Request Access" && !$0.isHiddenOrHasHiddenAncestor }
                    let expectedRequests = (state.0 ? 0 : 1) + (state.1 ? 0 : 1)
                    expect(requests.count == expectedRequests, "only missing permissions should show Request Access")
                    expect(buttons.filter { $0.title == "Review Settings" }.count == 2 - expectedRequests,
                           "granted permissions should retain a Review Settings action")
                }
                let cards = view.arrangedSubviews.filter { $0.layer?.cornerRadius == 10 }
                expect(cards.count == 2, "each permission should have one card")
                let colors = cards.compactMap { $0.layer?.backgroundColor }
                if appearance == .aqua {
                    lightColors = colors
                } else {
                    expect(colors.count == 2 && colors != lightColors,
                           "permission card colors should respond to appearance changes")
                }
            }
        }
    }

    private static func verifyTrailingAlignment(_ view: PermissionSettingsView) {
        for card in view.arrangedSubviews where card.layer?.cornerRadius == 10 {
            guard let button = descendants(in: card).compactMap({ $0 as? NSButton }).first(where: {
                $0.title == "Review Settings" || $0.title == "Open Settings"
            }) else { fail("permission card must retain its Settings action") }
            let rect = card.convert(button.alignmentRect(forFrame: button.frame), from: button.superview)
            expect(abs(rect.maxX - (card.bounds.maxX - 16)) <= 0.5,
                   "Settings actions must align to the card trailing inset: \(rect.maxX), card \(card.bounds)")
        }
    }

    private static func verifyContentBounds(_ view: PermissionSettingsView) {
        expect(view.bounds.width >= 499, "permission layout should use the available page width")
        expect(view.bounds.height > 100 && view.bounds.height <= 500,
               "all permission content should fit the standard page height")
        for child in descendants(in: view) where child is NSControl && !child.isHiddenOrHasHiddenAncestor {
            let rect = view.convert(child.alignmentRect(forFrame: child.frame), from: child.superview)
            expect(rect.width > 0 && rect.height > 0, "permission controls must have a visible size")
            expect(rect.minX >= -0.5 && rect.maxX <= view.bounds.maxX + 0.5,
                   "permission controls must fit a narrow page without horizontal clipping")
            expect(rect.minY >= -0.5 && rect.maxY <= view.bounds.maxY + 0.5,
                   "permission controls must fit inside the page vertically: \(type(of: child)) \(rect) in \(view.bounds)")
        }
    }

    private static func verifyFocusTransfer() {
        let (window, view) = makeWindow(width: 500)
        publish(accessibility: false, recording: false)
        let buttons = descendants(in: view).compactMap { $0 as? NSButton }
        guard let request = buttons.first(where: { $0.accessibilityLabel() == "Request Accessibility access" }),
              let settings = buttons.first(where: { $0.accessibilityLabel() == "Open Accessibility settings" }) else {
            fail("permission actions should expose distinct accessibility labels")
        }
        expect(window.makeFirstResponder(request), "request action should support keyboard focus")
        publish(accessibility: true, recording: false)
        expect(window.firstResponder === settings,
               "granting a permission must transfer focus before hiding its request action")
    }

    private static func verifyInactivePageUpdates() {
        let view = PermissionSettingsView()
        view.setPageActive(false)
        publish(accessibility: true, recording: true)
        expect(labels(in: view).contains { $0.hasPrefix("Ready") },
               "inactive pages should still receive central status changes without monitoring")
        view.setPageActive(true)
        publish(accessibility: false, recording: false)
        expect(labels(in: view).contains { $0.contains("Accessibility and Screen Recording are not granted") },
               "returning to Permissions should preserve its notification subscription")
    }

    private static func makeWindow(width: CGFloat) -> (NSWindow, PermissionSettingsView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView()
        let view = PermissionSettingsView()
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        window.contentView = host
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor)
        ])
        return (window, view)
    }

    private static func descendants(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(in: $0) }
    }

    private static func publish(accessibility: Bool, recording: Bool) {
        NotificationCenter.default.post(
            name: PermissionManager.didChangeNotification,
            object: PermissionManager.Status(
                accessibilityGranted: accessibility,
                screenRecordingGranted: recording
            )
        )
    }

    private static func labels(in view: NSView) -> [String] {
        let current = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return current + view.subviews.flatMap(labels)
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}
