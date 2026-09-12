import AppKit

// Settings UI suites never scan or capture the user's Dock.
final class DockSnapshotService: DockSnapshotProviding {
    private final class Reference {
        weak var service: DockSnapshotService?
        init(_ service: DockSnapshotService) { self.service = service }
    }

    private static var instances = [Reference]()
    private static var state = DockSnapshotState.unavailable(.hidden)
    var onChange: ((DockSnapshotState) -> Void)?
    private(set) var isActive = false
    private(set) var refreshCount = 0

    init(contextProvider: @escaping () -> DockSnapshotContext?) {
        Self.instances.removeAll { $0.service == nil }
        Self.instances.append(Reference(self))
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        onChange?(active ? Self.state : .idle)
    }

    func refresh() {
        guard isActive else { return }
        refreshCount += 1
        onChange?(Self.state)
    }

    static func publish(_ state: DockSnapshotState) {
        self.state = state
        instances.removeAll { $0.service == nil }
        for reference in instances {
            guard let service = reference.service, service.isActive else { continue }
            service.onChange?(state)
        }
    }
}

extension DockSnapshotContext {
    static func current(window: NSWindow?) -> DockSnapshotContext? {
        guard let window else { return nil }
        let frame = ScreenGeometry.fixtureFrame
        let display = DockSnapshotDisplay(id: 1, name: "Fixture display", frame: frame,
                                          visibleFrame: frame, backingScaleFactor: 2)
        return DockSnapshotContext(windowNumber: window.windowNumber, preferredDisplayID: 1,
                                   displays: [display], referenceMaxY: frame.maxY, dockPID: 1)
    }
}
