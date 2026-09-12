import Darwin
import Foundation

@main
enum WindowInventorySnapshotTests {
    private struct Window: Equatable {
        let id: Int
        let title: String
        let imageToken: Int?
    }

    static func main() {
        let old = [Window(id: 1, title: "Closed", imageToken: 11),
                   Window(id: 2, title: "Unresolved", imageToken: 22),
                   Window(id: 3, title: "Old title", imageToken: 33)]
        let fresh = [Window(id: 3, title: "Renamed", imageToken: 44),
                     Window(id: 4, title: "New", imageToken: nil)]
        let partial = merge(fresh, old, unresolved: [2, 3, 99])
        expect(partial == fresh + [old[1]],
               "partial scans retain only confirmed unresolved windows, including their image identity")
        expect(!partial.contains { $0.id == 1 }, "closed windows must still be removed during a partial scan")
        expect(!partial.contains { $0.id == 99 }, "a never-seen unresolved ID must not fabricate a preview")
        expect(merge(fresh, old, unresolved: []) == fresh,
               "a completed snapshot must replace stale metadata and images")
        expect(merge([], old, unresolved: []).isEmpty,
               "successful empty snapshots must clear every closed window")
        expect(merge(fresh, old, unresolved: nil) == fresh + old.prefix(2),
               "unavailable WindowServer snapshots preserve previous windows without overriding fresh records")
        expect(merge([], old + old, unresolved: [2]) == [old[1]],
               "retention must not duplicate window identity")
        expect(merge([], [], unresolved: [99]).isEmpty,
               "an incomplete initial scan must not invent a cached image")
        testProcessScopedIdentity()
        testDestroyedWindowRetention()
        testCurrentWindowBypassesOldElementValidation()
        testInterruptedRetentionDoesNotPublish()
        print("WindowInventorySnapshotTests: passed")
    }

    private struct ProcessWindowID: Hashable {
        let pid: Int
        let windowID: Int
    }

    private static func testProcessScopedIdentity() {
        let oldOwner = ProcessWindowID(pid: 10, windowID: 42)
        let newOwner = ProcessWindowID(pid: 20, windowID: 42)
        let merged = WindowInventorySnapshot.merging(
            discovered: [newOwner], previous: [oldOwner], unresolvedIDs: [newOwner], identifier: { $0 }
        )
        expect(merged == [newOwner], "numeric window ID reuse must not retain another process's cached preview")
    }

    private static func testDestroyedWindowRetention() {
        let closed = Window(id: 1, title: "AX element destroyed, CG window retained", imageToken: 11)
        let offSpace = Window(id: 2, title: "Temporarily unreachable", imageToken: 22)
        let unknown = Window(id: 3, title: "No saved AX element", imageToken: 33)
        let removed = Window(id: 4, title: "Absent from WindowServer", imageToken: 44)
        var validated = [Int]()
        let merged = WindowInventorySnapshot.merging(
            discovered: [], previous: [closed, offSpace, unknown, removed, closed],
            unresolvedIDs: [1, 2, 3], identifier: { $0.id }
        ) { window in
            validated.append(window.id)
            return window != closed
        }
        expect(merged == [offSpace, unknown],
               "a destroyed AX window must not survive an unresolved CG ID, while uncertainty preserves prior previews")
        expect(validated == [1, 2, 3],
               "validation runs once only for unresolved prior windows that could otherwise survive")
        expect(WindowInventorySnapshot.merging(
            discovered: [], previous: [closed], unresolvedIDs: Optional<Set<Int>>.none,
            identifier: { $0.id }, shouldRetain: { _ in false }
        ).isEmpty, "definitive destruction must also override an unavailable WindowServer snapshot")
    }

    private static func testCurrentWindowBypassesOldElementValidation() {
        let previous = Window(id: 1, title: "Old destroyed AX element", imageToken: 11)
        let replacement = Window(id: 1, title: "New AX window with reused CG ID", imageToken: 22)
        var validationCount = 0
        let merged = WindowInventorySnapshot.merging(
            discovered: [replacement], previous: [previous], unresolvedIDs: [1], identifier: { $0.id }
        ) { _ in
            validationCount += 1
            return false
        }
        expect(merged == [replacement], "a discovered replacement must win over its old invalid AX element")
        expect(validationCount == 0, "ordinary discovered windows must not incur extra AX retention reads")
    }

    private enum RetentionFailure: Error {
        case cancelled
        case deadline
    }

    private static func testInterruptedRetentionDoesNotPublish() {
        let previous = [Window(id: 1, title: "Closed", imageToken: 11),
                        Window(id: 2, title: "Retained", imageToken: 22),
                        Window(id: 3, title: "Not examined", imageToken: 33)]
        for failure in [RetentionFailure.cancelled, .deadline] {
            var cached = previous
            var validated = [Int]()
            let next = try? WindowInventorySnapshot.merging(
                discovered: [], previous: previous, unresolvedIDs: [1, 2, 3], identifier: { $0.id }
            ) { window in
                validated.append(window.id)
                if window.id == 2 { throw failure }
                return false
            }
            if let next { cached = next }
            expect(next == nil && cached == previous,
                   "interrupted validation must not publish a partially pruned inventory")
            expect(validated == [1, 2], "interruption must stop validation before additional AX reads")
        }
    }

    private static func merge(_ fresh: [Window], _ old: [Window], unresolved: Set<Int>?) -> [Window] {
        WindowInventorySnapshot.merging(discovered: fresh, previous: old, unresolvedIDs: unresolved, identifier: { $0.id })
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
