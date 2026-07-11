import Cocoa
import Darwin
import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private typealias TestCase = (name: String, body: () throws -> Void)

@main
private enum NativeDockMenuLifecycleTests {
    static func main() {
        let tests: [TestCase] = [
            ("missing CG snapshot remains unknown", testMissingSnapshot),
            ("empty popup snapshot is definitely absent", testEmptySnapshot),
            ("AX uncertainty is not counted as absence", testAccessibilityUncertainty),
            ("anchor-connected menu component includes submenus", testConnectedComponent),
            ("fresh connected containment recovers a new submenu", testFreshConnectedContainment),
            ("unrelated Dock menu is excluded by target anchor", testUnrelatedMenu),
            ("baseline CGWindowID reuse is reclassified from current evidence", testBaselineIDReuse),
            ("stale certified CGWindowID reuse cannot stay visible", testCertifiedIDReuse),
            ("connection distance has an exact boundary", testConnectionBoundary),
            ("geometry classification is symmetric for every Dock edge", testDockEdgeSymmetry),
            ("preflight only performs AXShowMenu after definite absence", testPreflightGate),
            ("only started actions carry a completion generation", testTrackedActionGeneration),
            ("one hover suppresses a second logical AX action", testRepeatedActionGate),
            ("connected-popup refresh is bounded to the first miss", testConnectedRefreshGate),
            ("focused-item absence falls back to the full AX tree", testFocusedProbeFallback),
            ("pending menu corridor does not cover the whole screen", testPendingMenuCorridor),
            ("action completion gates safe absence", testCompletionGate),
            ("completion time extends the post-action quiet window", testCompletionQuietWindow),
            ("unknown visibility polling backs off to one second", testBackoff),
            ("dismissal latch is scoped to one hover session", testHoverSessionLatch),
            ("late promotion requires matching action and hover generations", testLatePromotionGate)
        ]

        do {
            for test in tests {
                try test.body()
                print("PASS \(test.name)")
            }
            print("PASS \(tests.count) native Dock menu lifecycle tests")
        } catch {
            fputs("FAIL \(error)\n", stderr)
            exit(1)
        }
    }

    private static func testMissingSnapshot() throws {
        let result = DockPopupMenuSessionClassifier.visibility(
            popupFrames: nil,
            accessibility: .unknown,
            anchoredTo: anchor
        )
        try expectEqual(result, .unknown)
    }

    private static func testEmptySnapshot() throws {
        for accessibility in accessibilityStates {
            let result = DockPopupMenuSessionClassifier.visibility(
                popupFrames: [:],
                accessibility: accessibility,
                anchoredTo: anchor
            )
            try expectEqual(result, .absent)
        }
    }

    private static func testAccessibilityUncertainty() throws {
        let frames: [CGWindowID: CGRect] = [1: CGRect(x: 100, y: 148, width: 180, height: 240)]
        try expectEqual(
            DockPopupMenuSessionClassifier.visibility(
                popupFrames: frames,
                accessibility: .unknown,
                anchoredTo: anchor
            ),
            .unknown
        )
        try expectEqual(
            DockPopupMenuSessionClassifier.visibility(
                popupFrames: frames,
                accessibility: .absent,
                anchoredTo: anchor
            ),
            .absent
        )
    }

    private static func testConnectedComponent() throws {
        let root = CGRect(x: 100, y: 148, width: 180, height: 240)
        let submenu = CGRect(x: 300, y: 180, width: 170, height: 210)
        let shadow = CGRect(x: 478, y: 180, width: 12, height: 210)
        let unrelated = CGRect(x: 900, y: 800, width: 160, height: 200)
        let frames: [CGWindowID: CGRect] = [1: root, 2: submenu, 3: shadow, 4: unrelated]
        let result = DockPopupMenuSessionClassifier.visibility(
            popupFrames: frames,
            accessibility: .visible(submenu),
            anchoredTo: anchor
        )
        try expectEqual(result, .visible([1, 2, 3]))
    }

    private static func testFreshConnectedContainment() throws {
        let root = CGRect(x: 100, y: 148, width: 180, height: 240)
        let submenu = CGRect(x: 300, y: 180, width: 170, height: 210)
        let point = CGPoint(x: 440, y: 240)
        let frames: [CGWindowID: CGRect] = [1: root, 2: submenu]
        try expectEqual(
            DockPopupMenuSessionClassifier.connectedContainment(
                of: point,
                popupFrames: frames,
                anchoredTo: anchor,
                intersecting: [1]
            ),
            .contains([1, 2])
        )
        try expectEqual(
            DockPopupMenuSessionClassifier.connectedContainment(
                of: point,
                popupFrames: frames,
                anchoredTo: anchor,
                intersecting: [99]
            ),
            .outside
        )
        try expectEqual(
            DockPopupMenuSessionClassifier.connectedContainment(
                of: point,
                popupFrames: nil,
                anchoredTo: anchor,
                intersecting: [1]
            ),
            .unknown
        )
    }

    private static func testUnrelatedMenu() throws {
        let targetPopup = CGRect(x: 100, y: 148, width: 180, height: 220)
        let otherMenu = CGRect(x: 900, y: 600, width: 180, height: 220)
        let result = DockPopupMenuSessionClassifier.visibility(
            popupFrames: [1: targetPopup, 2: otherMenu],
            accessibility: .visible(otherMenu),
            anchoredTo: anchor
        )
        try expectEqual(result, .absent)
    }

    private static func testBaselineIDReuse() throws {
        let reusedID: CGWindowID = 77
        let currentMenu = CGRect(x: 100, y: 148, width: 180, height: 220)
        let result = DockPopupMenuSessionClassifier.visibility(
            popupFrames: [reusedID: currentMenu],
            accessibility: .visible(currentMenu),
            anchoredTo: anchor
        )
        try expectEqual(result, .visible([reusedID]))
    }

    private static func testCertifiedIDReuse() throws {
        let reusedID: CGWindowID = 88
        let nonMenuPopup = CGRect(x: 100, y: 148, width: 120, height: 40)
        let result = DockPopupMenuSessionClassifier.visibility(
            popupFrames: [reusedID: nonMenuPopup],
            accessibility: .absent,
            anchoredTo: anchor
        )
        try expectEqual(result, .absent)
    }

    private static func testConnectionBoundary() throws {
        let boundary = CGRect(x: anchor.maxX + 48, y: anchor.minY, width: 20, height: 20)
        let outside = boundary.offsetBy(dx: 0.5, dy: 0)
        try expectEqual(
            DockPopupMenuSessionClassifier.connectedWindowIDs(
                popupFrames: [1: boundary],
                anchoredTo: anchor
            ),
            [1]
        )
        try expectEqual(
            DockPopupMenuSessionClassifier.connectedWindowIDs(
                popupFrames: [1: outside],
                anchoredTo: anchor
            ),
            []
        )
    }

    private static func testDockEdgeSymmetry() throws {
        let anchors = [
            CGRect(x: 100, y: 100, width: 48, height: 48),
            CGRect(x: 500, y: 800, width: 48, height: 48),
            CGRect(x: -900, y: 300, width: 48, height: 48),
            CGRect(x: 1800, y: -200, width: 48, height: 48)
        ]
        let offsets = [
            CGVector(dx: 0, dy: 40),
            CGVector(dx: 0, dy: -220),
            CGVector(dx: 40, dy: 0),
            CGVector(dx: -220, dy: 0)
        ]
        for (index, pair) in zip(anchors, offsets).enumerated() {
            let (testAnchor, offset) = pair
            let menu = CGRect(
                x: testAnchor.minX + offset.dx,
                y: testAnchor.minY + offset.dy,
                width: offset.dx == 0 ? 180 : 220,
                height: offset.dy == 0 ? 180 : 220
            )
            let result = DockPopupMenuSessionClassifier.visibility(
                popupFrames: [CGWindowID(index + 1): menu],
                accessibility: .visible(menu),
                anchoredTo: testAnchor
            )
            try expect(result != .absent, "Dock edge \(index) lost its adjacent menu")
        }
    }

    private static func testCompletionGate() throws {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let safeAfter = now.addingTimeInterval(-1)
        try expect(!NativeDockMenuLifecyclePolicy.absenceIsEligible(
            actionGeneration: 1,
            actionCompleted: false,
            now: now,
            safeAfter: safeAfter
        ), "an unfinished action accepted absence")
        try expect(NativeDockMenuLifecyclePolicy.absenceIsEligible(
            actionGeneration: 1,
            actionCompleted: true,
            now: now,
            safeAfter: safeAfter
        ), "a completed action rejected safe absence")
        try expect(!NativeDockMenuLifecyclePolicy.absenceIsEligible(
            actionGeneration: nil,
            actionCompleted: false,
            now: now,
            safeAfter: now.addingTimeInterval(1)
        ), "absence before safeAfter was accepted")
    }

    private static func testPreflightGate() throws {
        try expectEqual(
            NativeDockMenuLifecyclePolicy.preflightDecision(visibility: .absent),
            .performAction
        )
        try expectEqual(
            NativeDockMenuLifecyclePolicy.preflightDecision(visibility: .unknown),
            .wait
        )
        try expectEqual(
            NativeDockMenuLifecyclePolicy.preflightDecision(visibility: .visible([42])),
            .adoptVisibleMenu([42])
        )
    }

    private static func testTrackedActionGeneration() throws {
        try expectEqual(
            NativeDockMenuLifecyclePolicy.trackedActionGeneration(
                generation: 9,
                actionStarted: false
            ),
            nil
        )
        try expectEqual(
            NativeDockMenuLifecyclePolicy.trackedActionGeneration(
                generation: 9,
                actionStarted: true
            ),
            9
        )
    }

    private static func testRepeatedActionGate() throws {
        try expect(NativeDockMenuLifecyclePolicy.shouldSuppressRepeatedAction(
            attemptTargetKey: "app:1",
            attemptHoverSession: 3,
            attemptGeneration: 7,
            targetKey: "app:1",
            currentHoverSession: 3,
            requestGeneration: 8
        ), "same hover accepted a second logical action")
        try expect(!NativeDockMenuLifecyclePolicy.shouldSuppressRepeatedAction(
            attemptTargetKey: "app:1",
            attemptHoverSession: 3,
            attemptGeneration: 7,
            targetKey: "app:1",
            currentHoverSession: 3,
            requestGeneration: 7
        ), "same-generation stale-element retry was blocked")
        try expect(!NativeDockMenuLifecyclePolicy.shouldSuppressRepeatedAction(
            attemptTargetKey: "app:1",
            attemptHoverSession: 3,
            attemptGeneration: 7,
            targetKey: "app:1",
            currentHoverSession: 4,
            requestGeneration: 8
        ), "leave and re-entry could not start a new action")
        try expect(!NativeDockMenuLifecyclePolicy.shouldSuppressRepeatedAction(
            attemptTargetKey: "app:1",
            attemptHoverSession: 3,
            attemptGeneration: 7,
            targetKey: "app:2",
            currentHoverSession: 3,
            requestGeneration: 8
        ), "another target inherited the prior attempt")
    }

    private static func testConnectedRefreshGate() throws {
        try expect(NativeDockMenuLifecyclePolicy.shouldRefreshConnectedPopup(
            hasKnownMenu: true,
            cachedContainsPoint: false,
            overTarget: false,
            overOtherDockTarget: false,
            awaitingFirstMenu: false,
            wasOutside: false
        ), "first known-menu containment miss skipped its refresh")
        let blockedInputs = [
            (false, false, false, false, false, false),
            (true, true, false, false, false, false),
            (true, false, true, false, false, false),
            (true, false, false, true, false, false),
            (true, false, false, false, true, false),
            (true, false, false, false, false, true)
        ]
        for input in blockedInputs {
            try expect(!NativeDockMenuLifecyclePolicy.shouldRefreshConnectedPopup(
                hasKnownMenu: input.0,
                cachedContainsPoint: input.1,
                overTarget: input.2,
                overOtherDockTarget: input.3,
                awaitingFirstMenu: input.4,
                wasOutside: input.5
            ), "non-miss state triggered a connected-popup refresh")
        }
    }

    private static func testFocusedProbeFallback() throws {
        try expect(NativeDockMenuLifecyclePolicy.focusedProbeRequiresTreeFallback(.absent),
                   "focused-item absence skipped the app tree")
        try expect(!NativeDockMenuLifecyclePolicy.focusedProbeRequiresTreeFallback(.unknown),
                   "unknown focused probe was downgraded")
        try expect(!NativeDockMenuLifecyclePolicy.focusedProbeRequiresTreeFallback(.visible(anchor)),
                   "visible focused menu was reprobed")
    }

    private static func testPendingMenuCorridor() throws {
        try expect(NativeDockMenuLifecyclePolicy.isInsidePendingMenuCorridor(
            CGPoint(x: anchor.midX, y: anchor.maxY + 80),
            anchor: anchor
        ), "adjacent pending menu was outside the corridor")
        try expect(!NativeDockMenuLifecyclePolicy.isInsidePendingMenuCorridor(
            CGPoint(x: anchor.midX + 500, y: anchor.midY + 500),
            anchor: anchor
        ), "screen-center movement stayed inside the pending menu corridor")
    }

    private static func testCompletionQuietWindow() throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let started = now.addingTimeInterval(-3)
        let completed = now.addingTimeInterval(-0.25)
        let safeAfter = NativeDockMenuLifecyclePolicy.safeAfter(
            actionStartedAt: started,
            actionCompletedAt: completed,
            quietInterval: 1.33,
            now: now
        )
        try expectNear(safeAfter.timeIntervalSinceReferenceDate, 1_001.08)
    }

    private static func testBackoff() throws {
        let base: TimeInterval = 0.08
        try expectNear(
            NativeDockMenuLifecyclePolicy.visibilityBackoff(
                unknownObservations: 0,
                baseInterval: base
            ),
            0.08
        )
        try expectNear(
            NativeDockMenuLifecyclePolicy.visibilityBackoff(
                unknownObservations: 1,
                baseInterval: base
            ),
            0.16
        )
        try expectNear(
            NativeDockMenuLifecyclePolicy.visibilityBackoff(
                unknownObservations: 10_000,
                baseInterval: base
            ),
            1
        )
    }

    private static func testHoverSessionLatch() throws {
        try expect(NativeDockMenuLifecyclePolicy.shouldLatchDismissal(
            sourceHoverSession: 10,
            currentHoverSession: 10
        ), "same hover did not latch")
        try expect(!NativeDockMenuLifecyclePolicy.shouldLatchDismissal(
            sourceHoverSession: 10,
            currentHoverSession: 11
        ), "leave and re-entry kept the old latch")
    }

    private static func testLatePromotionGate() throws {
        try expect(NativeDockMenuLifecyclePolicy.canPromoteLateMenu(
            requestGeneration: 7,
            cleanupGeneration: 7,
            activeFailedGeneration: 7,
            sourceHoverSession: 3,
            currentHoverSession: 3
        ), "matching late menu could not promote")
        for mismatch in [
            (6, Optional(7), Optional(7), 3, 3),
            (7, Optional(6), Optional(7), 3, 3),
            (7, Optional(7), Optional(6), 3, 3),
            (7, Optional(7), Optional(7), 3, 4)
        ] {
            try expect(!NativeDockMenuLifecyclePolicy.canPromoteLateMenu(
                requestGeneration: mismatch.0,
                cleanupGeneration: mismatch.1,
                activeFailedGeneration: mismatch.2,
                sourceHoverSession: mismatch.3,
                currentHoverSession: mismatch.4
            ), "mismatched generation promoted a late menu")
        }
    }

    private static let anchor = CGRect(x: 100, y: 100, width: 48, height: 48)
    private static let accessibilityStates: [DockAccessibilityMenuProbe] = [
        .visible(CGRect(x: 100, y: 148, width: 180, height: 220)),
        .absent,
        .unknown
    ]

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(description: message) }
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T) throws {
        guard actual == expected else {
            throw TestFailure(description: "expected \(expected), got \(actual)")
        }
    }

    private static func expectNear(_ actual: Double, _ expected: Double) throws {
        guard abs(actual - expected) < 0.000_001 else {
            throw TestFailure(description: "expected \(expected), got \(actual)")
        }
    }
}
