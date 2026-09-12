import CoreGraphics
import Darwin
import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private typealias TestCase = (name: String, body: () throws -> Void)

@main
private enum PreviewLayoutPlannerTests {
    static func main() {
        let tests: [TestCase] = [
            ("preferred height and default card geometry", testPreferredHeightAndDefaultGeometry),
            ("preferred height floors to a device pixel", testPreferredHeightFloorsToDevicePixel),
            ("largest fitting device-pixel height", testLargestFittingDevicePixelHeight),
            ("96 point width boundary and adjacent pixels", testMinimumWidthBoundary),
            ("96 point height boundary and adjacent pixels", testMinimumHeightBoundary),
            ("Auto never wraps ungrouped windows", testUngroupedNeverWraps),
            ("compact overflow preserves readable rows within every Dock edge", testCompactListGeometry),
            ("empty content is deterministic", testEmptyContent),
            ("one window produces exactly one row", testOneWindow),
            ("aspect ratios clamp at both extremes", testAspectRatioClamping),
            ("narrow cards honor the shared chrome minimum width", testMinimumCardWidth),
            ("maximum image width is respected", testMaximumImageWidth),
            ("all single-row chrome and spacing metrics apply", testMetricGeometry),
            ("mixed extreme ratios select the exact maximum", testMixedRatioMaximum),
            ("fifty windows retain stable single-row order", testFiftyWindowOrder),
            ("fifty windows choose the compact list when unreadable", testFiftyWindowFallback),
            ("group headers and one outer row are measured", testGroupedGeometry),
            ("groups and group items never wrap", testGroupedNeverWraps),
            ("grouped content selects the exact maximum", testGroupedMaximum),
            ("empty groups preserve their header geometry", testEmptyGroupGeometry),
            ("removal shape signatures retain fixed geometry", testRemovalShapeSignatures),
            ("available space honors all Dock edges", testAvailableSpaceAllDockEdges),
            ("available space clips frames and rejects invalid geometry", testAvailableSpaceClippingAndInvalidGeometry),
            ("planner sizing is independent of screen origin", testScreenOriginIndependence),
            ("one-row Auto preference preserves legacy selections", testAutoFitSettingCompatibility),
            ("invalid and duplicate inputs fail closed", testInvalidInputs),
            ("repeated planning is deterministic", testDeterminism),
            ("boundary matrix preserves one-row containment and maximality", testBoundaryMatrix),
            ("fifty-window p95 stays below five milliseconds", testPerformance)
        ]

        do {
            for test in tests {
                try test.body()
                print("PASS \(test.name)")
            }
            print("PASS \(tests.count) preview layout planner tests")
        } catch {
            fputs("FAIL \(error)\n", stderr)
            exit(1)
        }
    }

    private static func testCompactListGeometry() throws {
        let screen = CGRect(x: -1280, y: 400, width: 1280, height: 800)
        let anchors: [PreviewPanelDockEdge: CGRect] = [
            .bottom: CGRect(x: -700, y: 400, width: 56, height: 60),
            .top: CGRect(x: -700, y: 1140, width: 56, height: 60),
            .left: CGRect(x: -1280, y: 760, width: 60, height: 56),
            .right: CGRect(x: -60, y: 760, width: 60, height: 56)
        ]
        for edge in PreviewPanelDockEdge.allCases {
            let available = PreviewPanelAvailableSpace.size(
                visibleFrame: screen, screenFrame: screen,
                dockAnchor: anchors[edge]!, dockEdge: edge
            )
            for count in [1, 8, 50, 200] {
                for rowHeight: CGFloat in [36, 42, 50] {
                    let plan = PreviewCompactListPlan.make(
                        itemCount: count, rowHeight: rowHeight, preferredWidth: 400,
                        availablePanelSize: available, panelPadding: 6, scrollerWidth: 15
                    )
                    try expect(plan.panelSize.width <= available.width, "list escaped screen width")
                    try expect(plan.panelSize.height <= available.height, "list escaped screen height")
                    try expectNear(plan.contentSize.height, CGFloat(count) * rowHeight)
                    try expectNear(plan.viewportSize.height.truncatingRemainder(dividingBy: rowHeight), 0)
                    try expectNear(plan.rowWidth, plan.viewportSize.width - (plan.needsScroll ? 15 : 0))
                    try expectEqual(plan.needsScroll, plan.contentSize.height > plan.viewportSize.height)
                }
            }
        }
    }

    private static func testPreferredHeightAndDefaultGeometry() throws {
        let input = PreviewLayoutInput(
            content: .ungrouped([item(1, 2)]),
            preferredImageHeight: 140,
            availablePanelSize: CGSize(width: 2_000, height: 2_000),
            backingScale: 2
        )
        let plan = try thumbnails(input)
        try expectNear(plan.imageHeight, 140)
        try expectEqual(plan.contentSize, CGSize(width: 292, height: 182))
        try expectEqual(plan.panelSize, CGSize(width: 304, height: 194))
        try expectEqual(plan.itemIDs, [1])
        try assertSingleRow(input.content, plan: plan)
    }

    private static func testPreferredHeightFloorsToDevicePixel() throws {
        let input = PreviewLayoutInput(
            content: .ungrouped([item(1)]),
            preferredImageHeight: 140.49,
            availablePanelSize: CGSize(width: 1_000, height: 1_000),
            backingScale: 2,
            metrics: zeroChromeMetrics()
        )
        let plan = try thumbnails(input)
        try expectNear(plan.imageHeight, 140)
        try expectNear(plan.imageHeight * input.backingScale, (plan.imageHeight * input.backingScale).rounded())
    }

    private static func testLargestFittingDevicePixelHeight() throws {
        let input = PreviewLayoutInput(
            content: .ungrouped([item(1), item(2, 2)]),
            preferredImageHeight: 110,
            availablePanelSize: CGSize(width: 301, height: 500),
            backingScale: 2,
            metrics: zeroChromeMetrics()
        )
        let plan = try thumbnails(input)
        try expectNear(plan.imageHeight, 100)
        try expectEqual(plan.contentSize, CGSize(width: 300, height: 100))
        try assertLargestFit(input, plan: plan)
        try assertSingleRow(input.content, plan: plan)
    }

    private static func testMinimumWidthBoundary() throws {
        let metrics = zeroChromeMetrics(itemSpacing: 1)
        let exact = PreviewLayoutInput(
            content: .ungrouped([item(1), item(2)]),
            preferredImageHeight: 96,
            availablePanelSize: CGSize(width: 193, height: 500),
            backingScale: 2,
            metrics: metrics
        )
        let plan = try thumbnails(exact)
        try expectNear(plan.imageHeight, 96)
        try expectEqual(plan.contentSize.width, 193)
        try assertSingleRow(exact.content, plan: plan)

        let onePixelAbove = replacing(exact, availablePanelSize: CGSize(width: 193.5, height: 500))
        try expectNear(thumbnails(onePixelAbove).imageHeight, 96)

        let onePixelBelow = replacing(exact, availablePanelSize: CGSize(width: 192.5, height: 500))
        try expectEqual(PreviewLayoutPlanner.plan(onePixelBelow), .compactList)

        let taller = replacing(
            exact,
            preferredImageHeight: 96.5,
            minimumImageHeight: 96.5,
            availablePanelSize: CGSize(width: 194, height: 500)
        )
        try expectNear(thumbnails(taller).imageHeight, 96.5)
    }

    private static func testMinimumHeightBoundary() throws {
        let exact = exactHeightInput(availableHeight: 96)
        try expectNear(thumbnails(exact).imageHeight, 96)

        let onePixelAbove = exactHeightInput(availableHeight: 96.5, preferred: 96.5)
        try expectNear(thumbnails(onePixelAbove).imageHeight, 96.5)

        let onePixelBelow = exactHeightInput(availableHeight: 95.5)
        try expectEqual(PreviewLayoutPlanner.plan(onePixelBelow), .compactList)

        let fractionalMinimum = PreviewLayoutInput(
            content: .ungrouped([item(1)]),
            preferredImageHeight: 97,
            minimumImageHeight: 96.1,
            availablePanelSize: CGSize(width: 1_000, height: 96.25),
            backingScale: 2,
            metrics: zeroChromeMetrics()
        )
        try expectEqual(PreviewLayoutPlanner.plan(fractionalMinimum), .compactList)
    }

    private static func testUngroupedNeverWraps() throws {
        let metrics = zeroChromeMetrics(itemSpacing: 5)
        let constrained = PreviewLayoutInput(
            content: .ungrouped([item(1), item(2), item(3)]),
            preferredImageHeight: 96,
            availablePanelSize: CGSize(width: 205, height: 1_000),
            backingScale: 2,
            metrics: metrics
        )
        try expectEqual(PreviewLayoutPlanner.plan(constrained), .compactList)

        let exact = replacing(constrained, availablePanelSize: CGSize(width: 298, height: 96))
        let plan = try thumbnails(exact)
        guard case .rows(let rows) = plan.arrangement else {
            throw TestFailure(description: "expected ungrouped rows")
        }
        try expectEqual(rows.map(\.itemIDs), [[1, 2, 3]])
        try expectEqual(rows.map(\.size), [CGSize(width: 298, height: 96)])
    }

    private static func testEmptyContent() throws {
        let input = PreviewLayoutInput(
            content: .ungrouped([]),
            preferredImageHeight: 150.25,
            availablePanelSize: CGSize(width: 12, height: 12),
            backingScale: 2
        )
        let first = try thumbnails(input)
        let second = try thumbnails(input)
        try expectEqual(first, second)
        try expectNear(first.imageHeight, 150)
        try expectEqual(first.contentSize, .zero)
        try expectEqual(first.panelSize, CGSize(width: 12, height: 12))
        try expectEqual(first.itemIDs, [])
        try assertSingleRow(input.content, plan: first)

        let tooSmall = replacing(input, availablePanelSize: CGSize(width: 11.5, height: 12))
        try expectEqual(PreviewLayoutPlanner.plan(tooSmall), .compactList)
    }

    private static func testOneWindow() throws {
        let input = PreviewLayoutInput(
            content: .ungrouped([item(42, 1.77)]),
            preferredImageHeight: 180,
            availablePanelSize: CGSize(width: 1_000, height: 500),
            backingScale: 2
        )
        let plan = try thumbnails(input)
        try expectEqual(plan.itemIDs, [42])
        try assertSingleRow(input.content, plan: plan)
    }

    private static func testAspectRatioClamping() throws {
        let metrics = zeroChromeMetrics(maximumImageWidth: 10_000)
        let input = PreviewLayoutInput(
            content: .ungrouped([item(1, 0.1), item(2, 4)]),
            preferredImageHeight: 100,
            availablePanelSize: CGSize(width: 1_000, height: 1_000),
            backingScale: 1,
            metrics: metrics
        )
        let plan = try thumbnails(input)
        try expectEqual(plan.contentSize, CGSize(width: 345, height: 100))
        try expectEqual(plan.itemIDs, [1, 2])
        try assertSingleRow(input.content, plan: plan)
    }

    private static func testMinimumCardWidth() throws {
        let input = PreviewLayoutInput(
            content: .ungrouped([item(1, 0.30)]),
            preferredImageHeight: 96,
            availablePanelSize: CGSize(width: 500, height: 500),
            backingScale: 2
        )
        let plan = try thumbnails(input)
        try expectNear(plan.contentSize.width, input.metrics.minimumCardWidth)
        try expectNear(plan.panelSize.width, input.metrics.minimumCardWidth + input.metrics.panelPadding * 2)

        let exactWidth = input.metrics.minimumCardWidth + input.metrics.panelPadding * 2
        _ = try thumbnails(replacing(input, availablePanelSize: CGSize(width: exactWidth, height: 500)))
        try expectEqual(
            PreviewLayoutPlanner.plan(replacing(
                input,
                availablePanelSize: CGSize(width: exactWidth - 0.5, height: 500)
            )),
            .compactList
        )
    }

    private static func testMaximumImageWidth() throws {
        let metrics = zeroChromeMetrics(maximumImageWidth: 250)
        let input = PreviewLayoutInput(
            content: .ungrouped([item(1, 3.15)]),
            preferredImageHeight: 200,
            availablePanelSize: CGSize(width: 500, height: 500),
            backingScale: 2,
            metrics: metrics
        )
        let plan = try thumbnails(input)
        try expectNear(plan.contentSize.width, 250)
        try expectNear(plan.imageHeight, 200)
    }

    private static func testMetricGeometry() throws {
        let metrics = PreviewLayoutMetrics(
            panelPadding: 7,
            cardHorizontalPadding: 5,
            cardVerticalPadding: 3,
            cardVerticalChrome: 20,
            itemSpacing: 4,
            rowSpacing: 6,
            groupPadding: 9,
            groupSpacing: 11,
            groupHeaderSpacing: 2,
            maximumImageWidth: 1_000
        )
        let input = PreviewLayoutInput(
            content: .ungrouped([item(1), item(2)]),
            preferredImageHeight: 100,
            minimumImageHeight: 100,
            availablePanelSize: CGSize(width: 238, height: 140),
            backingScale: 1,
            metrics: metrics
        )
        let plan = try thumbnails(input)
        try expectEqual(plan.contentSize, CGSize(width: 224, height: 126))
        try expectEqual(plan.panelSize, CGSize(width: 238, height: 140))

        let tooNarrow = replacing(input, availablePanelSize: CGSize(width: 237, height: 500))
        try expectEqual(PreviewLayoutPlanner.plan(tooNarrow), .compactList)
    }

    private static func testMixedRatioMaximum() throws {
        let metrics = zeroChromeMetrics(itemSpacing: 2, maximumImageWidth: 10_000)
        let input = PreviewLayoutInput(
            content: .ungrouped([item(1, 0.30), item(2), item(3, 3.15)]),
            preferredImageHeight: 110,
            availablePanelSize: CGSize(width: 449, height: 500),
            backingScale: 2,
            metrics: metrics
        )
        let plan = try thumbnails(input)
        try expectNear(plan.imageHeight, 100)
        try expectEqual(plan.contentSize, CGSize(width: 449, height: 100))
        try expectEqual(plan.itemIDs, [1, 2, 3])
        try assertLargestFit(input, plan: plan)
    }

    private static func testFiftyWindowOrder() throws {
        let ratios: [CGFloat] = [0.30, 0.55, 1, 1.4, 2, 3.15]
        let items = (0..<50).map { item(UInt32($0 + 1), ratios[$0 % ratios.count]) }
        let input = PreviewLayoutInput(
            content: .ungrouped(items),
            preferredImageHeight: 180,
            availablePanelSize: CGSize(width: 100_000, height: 500),
            backingScale: 2
        )
        let plan = try thumbnails(input)
        try expectEqual(plan.itemIDs, items.map(\.id))
        try expectEqual(Set(plan.itemIDs).count, 50)
        try expectNear(plan.imageHeight, 180)
        try assertSingleRow(input.content, plan: plan)
    }

    private static func testFiftyWindowFallback() throws {
        let items = (1...50).map { item(UInt32($0), 1.6) }
        let input = PreviewLayoutInput(
            content: .ungrouped(items),
            preferredImageHeight: 180,
            availablePanelSize: CGSize(width: 2_540, height: 1_420),
            backingScale: 2
        )
        try expectEqual(PreviewLayoutPlanner.plan(input), .compactList)
    }

    private static func testGroupedGeometry() throws {
        let metrics = zeroChromeMetrics(groupPadding: 5, groupSpacing: 8, groupHeaderSpacing: 4)
        let groups = geometryGroups()
        let input = PreviewLayoutInput(
            content: .grouped(groups),
            preferredImageHeight: 100,
            availablePanelSize: CGSize(width: 328, height: 500),
            backingScale: 1,
            metrics: metrics
        )
        let plan = try thumbnails(input)
        guard case .groupRows(let rows) = plan.arrangement else {
            throw TestFailure(description: "expected group rows")
        }
        try expectEqual(rows.count, 1)
        try expectEqual(rows[0].groups.map(\.id), [.desktop(10), .unassigned])
        try expectEqual(rows[0].groups[0].itemRows.map(\.itemIDs), [[1, 2]])
        try expectEqual(rows[0].groups[1].itemRows.map(\.itemIDs), [[3]])
        try expectEqual(rows[0].groups[0].size, CGSize(width: 210, height: 134))
        try expectEqual(rows[0].groups[1].size, CGSize(width: 110, height: 132))
        try expectEqual(rows[0].size, CGSize(width: 328, height: 134))
        try expectEqual(plan.contentSize, CGSize(width: 328, height: 134))
        try expectEqual(plan.itemIDs, [1, 2, 3])
    }

    private static func testGroupedNeverWraps() throws {
        let metrics = zeroChromeMetrics(groupPadding: 5, groupSpacing: 8, groupHeaderSpacing: 4)
        let input = PreviewLayoutInput(
            content: .grouped(geometryGroups()),
            preferredImageHeight: 100,
            availablePanelSize: CGSize(width: 300, height: 1_000),
            backingScale: 1,
            metrics: metrics
        )
        try expectEqual(PreviewLayoutPlanner.plan(input), .compactList)

        let minimumFit = replacing(
            input,
            preferredImageHeight: 96,
            availablePanelSize: CGSize(width: 316, height: 1_000)
        )
        let plan = try thumbnails(minimumFit)
        try expectEqual(plan.contentSize.width, 316)
        try assertSingleRow(minimumFit.content, plan: plan)
    }

    private static func testGroupedMaximum() throws {
        let metrics = zeroChromeMetrics(groupPadding: 5, groupSpacing: 8, groupHeaderSpacing: 4)
        let groups = [
            PreviewLayoutGroup(
                id: .desktop(1),
                items: [item(1), item(2, 2)],
                headerSize: CGSize(width: 50, height: 20)
            ),
            PreviewLayoutGroup(
                id: .desktop(2),
                items: [item(3, 0.5)],
                headerSize: CGSize(width: 50, height: 18)
            )
        ]
        let input = PreviewLayoutInput(
            content: .grouped(groups),
            preferredImageHeight: 110,
            availablePanelSize: CGSize(width: 378, height: 500),
            backingScale: 2,
            metrics: metrics
        )
        let plan = try thumbnails(input)
        try expectNear(plan.imageHeight, 100)
        try expectEqual(plan.contentSize, CGSize(width: 378, height: 134))
        try expectEqual(plan.itemIDs, [1, 2, 3])
        try assertLargestFit(input, plan: plan)
        try assertSingleRow(input.content, plan: plan)
    }

    private static func testEmptyGroupGeometry() throws {
        let group = PreviewLayoutGroup(
            id: .desktop(7),
            items: [],
            headerSize: CGSize(width: 50, height: 20)
        )
        let input = PreviewLayoutInput(
            content: .grouped([group]),
            preferredImageHeight: 140,
            availablePanelSize: CGSize(width: 72, height: 42),
            backingScale: 2
        )
        let plan = try thumbnails(input)
        try expectEqual(plan.contentSize, CGSize(width: 60, height: 30))
        try expectEqual(plan.panelSize, CGSize(width: 72, height: 42))
        try expectEqual(plan.itemIDs, [])
        try assertSingleRow(input.content, plan: plan)
    }

    private static func testRemovalShapeSignatures() throws {
        let rowSize = CGSize(width: 300, height: 120)
        let current = PreviewLayoutPlan(
            imageHeight: 96,
            arrangement: .rows([PreviewLayoutRow(itemIDs: [1, 2, 3], size: rowSize)]),
            contentSize: rowSize,
            panelSize: CGSize(width: 312, height: 132)
        )
        let identicalFixedGeometry = PreviewLayoutPlan(
            imageHeight: 96,
            arrangement: .rows([PreviewLayoutRow(itemIDs: [1, 2], size: rowSize)]),
            contentSize: current.contentSize,
            panelSize: current.panelSize
        )
        try expectEqual(current.shapeSignature(excluding: [3]), identicalFixedGeometry.shapeSignature())

        let resized = PreviewLayoutPlan(
            imageHeight: 96,
            arrangement: .rows([PreviewLayoutRow(itemIDs: [1, 2], size: CGSize(width: 200, height: 120))]),
            contentSize: CGSize(width: 200, height: 120),
            panelSize: CGSize(width: 212, height: 132)
        )
        try expect(
            current.shapeSignature(excluding: [3]) != resized.shapeSignature(),
            "single-row geometry changes must force a full Auto reflow"
        )
    }

    private static func testAvailableSpaceAllDockEdges() throws {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let bottomVisibleFrame = CGRect(x: 0, y: 70, width: 1_440, height: 830)
        let bottomAnchor = CGRect(x: 688, y: 0, width: 64, height: 64)
        let normalBottom = PreviewPanelAvailableSpace.size(
            visibleFrame: bottomVisibleFrame,
            screenFrame: screen,
            dockAnchor: bottomAnchor,
            dockEdge: .bottom
        )
        try expectEqual(normalBottom, CGSize(width: 1_420, height: 810))

        let autoHideBottom = PreviewPanelAvailableSpace.size(
            visibleFrame: screen,
            screenFrame: screen,
            dockAnchor: bottomAnchor,
            dockEdge: .bottom
        )
        try expectEqual(autoHideBottom, CGSize(width: 1_420, height: 822))

        let top = PreviewPanelAvailableSpace.size(
            visibleFrame: screen,
            screenFrame: screen,
            dockAnchor: CGRect(x: 688, y: 836, width: 64, height: 64),
            dockEdge: .top
        )
        try expectEqual(top, CGSize(width: 1_420, height: 822))

        let left = PreviewPanelAvailableSpace.size(
            visibleFrame: screen,
            screenFrame: screen,
            dockAnchor: CGRect(x: 0, y: 418, width: 64, height: 64),
            dockEdge: .left
        )
        try expectEqual(left, CGSize(width: 1_362, height: 880))

        let right = PreviewPanelAvailableSpace.size(
            visibleFrame: screen,
            screenFrame: screen,
            dockAnchor: CGRect(x: 1_376, y: 418, width: 64, height: 64),
            dockEdge: .right
        )
        try expectEqual(right, CGSize(width: 1_362, height: 880))

        let customInsets = PreviewPanelAvailableSpace.size(
            visibleFrame: screen,
            screenFrame: screen,
            dockAnchor: bottomAnchor,
            dockEdge: .bottom,
            edgeInset: 20,
            dockGap: 6
        )
        try expectEqual(customInsets, CGSize(width: 1_400, height: 810))

        let negativeScreen = CGRect(x: -2_560, y: -200, width: 2_560, height: 1_440)
        let negativeOrigin = PreviewPanelAvailableSpace.size(
            visibleFrame: negativeScreen,
            screenFrame: negativeScreen,
            dockAnchor: CGRect(x: -1_312, y: -200, width: 64, height: 64),
            dockEdge: .bottom
        )
        try expectEqual(negativeOrigin, CGSize(width: 2_540, height: 1_362))
    }

    private static func testAvailableSpaceClippingAndInvalidGeometry() throws {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let clipped = PreviewPanelAvailableSpace.size(
            visibleFrame: CGRect(x: -100, y: -100, width: 1_200, height: 1_000),
            screenFrame: screen,
            dockAnchor: CGRect(x: 0, y: 360, width: 50, height: 80),
            dockEdge: .left
        )
        try expectEqual(clipped, CGSize(width: 936, height: 780))

        let noRoom = PreviewPanelAvailableSpace.size(
            visibleFrame: screen,
            screenFrame: screen,
            dockAnchor: CGRect(x: 14, y: 360, width: 40, height: 80),
            dockEdge: .right
        )
        try expectEqual(noRoom, CGSize(width: 0, height: 780))

        let invalidFrames = [
            CGRect(x: CGFloat.nan, y: 0, width: 1_000, height: 800),
            CGRect(x: 0, y: 0, width: 0, height: 800),
            CGRect(x: 0, y: 0, width: -1, height: 800)
        ]
        for invalidFrame in invalidFrames {
            let size = PreviewPanelAvailableSpace.size(
                visibleFrame: invalidFrame,
                screenFrame: screen,
                dockAnchor: .zero,
                dockEdge: .bottom
            )
            try expectEqual(size, .zero)
        }

        let disjoint = PreviewPanelAvailableSpace.size(
            visibleFrame: CGRect(x: 2_000, y: 0, width: 1_000, height: 800),
            screenFrame: screen,
            dockAnchor: .zero,
            dockEdge: .bottom
        )
        try expectEqual(disjoint, .zero)
    }

    private static func testScreenOriginIndependence() throws {
        let content = PreviewLayoutContent.ungrouped((1...5).map { item(UInt32($0), 1.4) })
        let negativeInput = PreviewLayoutInput(
            content: content,
            preferredImageHeight: 180,
            availablePanelSize: CGSize(width: 1_492, height: 962),
            backingScale: 2
        )
        let positiveInput = replacing(negativeInput, availablePanelSize: CGSize(width: 1_492, height: 962))
        try expectEqual(PreviewLayoutPlanner.plan(negativeInput), PreviewLayoutPlanner.plan(positiveInput))

        let plan = try thumbnails(negativeInput)
        try expect(plan.panelSize.width <= 1_492, "panel exceeded width")
        try expect(plan.panelSize.height <= 962, "panel exceeded height")
        try assertSingleRow(content, plan: plan)
    }

    private static func testAutoFitSettingCompatibility() throws {
        try expect(
            Bundle.main.bundleIdentifier != "io.github.bambou932.prevDock",
            "settings tests must not use the production preferences domain"
        )
        let defaults = UserDefaults.standard
        let modeKey = PrevDockSettings.previewOverflowModeKey
        let autoFitKey = PrevDockSettings.previewAutoFitEnabledKey
        let originalMode = defaults.object(forKey: modeKey)
        let originalAutoFit = defaults.object(forKey: autoFitKey)
        var changedKeys = [String]()
        let observer = NotificationCenter.default.addObserver(
            forName: PrevDockSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { notification in
            if let key = notification.object as? String {
                changedKeys.append(key)
            }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            restore(originalMode, forKey: modeKey, in: defaults)
            restore(originalAutoFit, forKey: autoFitKey, in: defaults)
        }

        defaults.removeObject(forKey: modeKey)
        defaults.removeObject(forKey: autoFitKey)
        PrevDockSettings.registerDefaults()
        try expectEqual(PrevDockSettings.previewOverflowMode, .scroll)
        try expectEqual(PrevDockSettings.previewAutoFitEnabled, true)

        PrevDockSettings.previewOverflowMode = .wrap
        try expectEqual(defaults.object(forKey: autoFitKey) as? Bool, true)
        try expectEqual(PrevDockSettings.previewAutoFitEnabled, true)
        PrevDockSettings.previewOverflowMode = .wrap
        PrevDockSettings.previewOverflowMode = .scroll
        try expectEqual(PrevDockSettings.previewAutoFitEnabled, true)
        PrevDockSettings.previewAutoFitEnabled = false
        PrevDockSettings.previewAutoFitEnabled = false
        try expectEqual(changedKeys, [modeKey, modeKey, autoFitKey])

        defaults.set(PreviewOverflowMode.scroll.rawValue, forKey: modeKey)
        defaults.removeObject(forKey: autoFitKey)
        try expectEqual(PrevDockSettings.previewAutoFitEnabled, false)

        defaults.set(PreviewOverflowMode.wrap.rawValue, forKey: modeKey)
        defaults.removeObject(forKey: autoFitKey)
        try expectEqual(PrevDockSettings.previewAutoFitEnabled, false)
        PrevDockSettings.previewOverflowMode = .scroll
        try expectEqual(defaults.object(forKey: autoFitKey) as? Bool, false)
        try expectEqual(PrevDockSettings.previewAutoFitEnabled, false)

        defaults.set(true, forKey: autoFitKey)
        PrevDockSettings.previewOverflowMode = .wrap
        try expectEqual(PrevDockSettings.previewAutoFitEnabled, true)
        PrevDockSettings.previewOverflowMode = .scroll
        try expectEqual(PrevDockSettings.previewAutoFitEnabled, true)

        defaults.set("auto", forKey: modeKey)
        defaults.removeObject(forKey: autoFitKey)
        PrevDockSettings.registerDefaults()
        try expectEqual(defaults.string(forKey: modeKey), PreviewOverflowMode.scroll.rawValue)
        try expectEqual(defaults.object(forKey: autoFitKey) as? Bool, true)

        PrevDockSettings.previewAutoFitEnabled = false
        try expectEqual(defaults.object(forKey: autoFitKey) as? Bool, false)
        try expectEqual(PreviewOverflowMode.allCases, [.scroll, .wrap])
    }

    private static func testInvalidInputs() throws {
        let integerBoundary = PreviewLayoutInput(
            content: .ungrouped([item(1)]),
            preferredImageHeight: CGFloat(Int.max),
            availablePanelSize: CGSize(width: 1_000, height: 1_000),
            backingScale: 1
        )
        try expectEqual(PreviewLayoutPlanner.plan(integerBoundary), .compactList)
        let valid = PreviewLayoutInput(
            content: .ungrouped([item(1)]),
            preferredImageHeight: 140,
            availablePanelSize: CGSize(width: 1_000, height: 1_000),
            backingScale: 2
        )
        let invalidContents: [PreviewLayoutContent] = [
            .ungrouped([item(1), item(1)]),
            .ungrouped([item(1, .nan)]),
            .ungrouped([item(1, .infinity)]),
            .ungrouped([item(1, 0)]),
            .grouped([
                PreviewLayoutGroup(id: .desktop(1), items: [item(1)], headerSize: nil),
                PreviewLayoutGroup(id: .desktop(1), items: [item(2)], headerSize: nil)
            ]),
            .grouped([
                PreviewLayoutGroup(id: .desktop(1), items: [item(1)], headerSize: nil),
                PreviewLayoutGroup(id: .desktop(2), items: [item(1)], headerSize: nil)
            ]),
            .grouped([
                PreviewLayoutGroup(
                    id: .desktop(1),
                    items: [item(1)],
                    headerSize: CGSize(width: CGFloat.nan, height: 20)
                )
            ])
        ]
        for content in invalidContents {
            try expectEqual(PreviewLayoutPlanner.plan(replacing(valid, content: content)), .compactList)
        }

        try expectEqual(
            PreviewLayoutPlanner.plan(replacing(valid, availablePanelSize: CGSize(width: -1, height: 500))),
            .compactList
        )
        try expectEqual(PreviewLayoutPlanner.plan(replacing(valid, backingScale: 0)), .compactList)
        try expectEqual(
            PreviewLayoutPlanner.plan(replacing(valid, preferredImageHeight: 95, minimumImageHeight: 96)),
            .compactList
        )

        let headerOverflow = replacing(
            valid,
            content: .grouped([
                PreviewLayoutGroup(id: .desktop(1), items: [item(1)], headerSize: CGSize(width: 2_000, height: 20))
            ])
        )
        try expectEqual(PreviewLayoutPlanner.plan(headerOverflow), .compactList)

        let derivedGeometryOverflow = PreviewLayoutInput(
            content: .grouped([
                PreviewLayoutGroup(id: .desktop(42), items: [item(42)], headerSize: nil)
            ]),
            preferredImageHeight: 140,
            availablePanelSize: CGSize(width: 1_000, height: 1_000),
            backingScale: 2,
            metrics: PreviewLayoutMetrics(groupPadding: .greatestFiniteMagnitude)
        )
        try expectEqual(PreviewLayoutPlanner.plan(derivedGeometryOverflow), .compactList)
    }

    private static func testDeterminism() throws {
        var groups = [PreviewLayoutGroup]()
        for groupIndex in 0..<10 {
            let groupItems: [PreviewLayoutItem] = (0..<5).map { itemIndex in
                item(UInt32(groupIndex * 10 + itemIndex), CGFloat(itemIndex + 3) / 4)
            }
            groups.append(PreviewLayoutGroup(
                id: .desktop(UInt64(groupIndex)),
                items: groupItems,
                headerSize: CGSize(width: CGFloat(60 + groupIndex * 7), height: 20)
            ))
        }
        let input = PreviewLayoutInput(
            content: .grouped(groups),
            preferredImageHeight: 210,
            availablePanelSize: CGSize(width: 100_000, height: 1_000),
            backingScale: 2
        )
        let expected = PreviewLayoutPlanner.plan(input)
        let plan = try thumbnails(input)
        try assertSingleRow(input.content, plan: plan)
        for _ in 0..<200 {
            try expectEqual(PreviewLayoutPlanner.plan(input), expected)
        }
    }

    private static func testBoundaryMatrix() throws {
        let ratios: [CGFloat] = [0.30, 0.31, 0.75, 1, 1.77, 3.14, 3.15]
        for count in [0, 1, 2, 8, 17, 50] {
            let items = (0..<count).map { item(UInt32($0 + 1), ratios[$0 % ratios.count]) }
            for scale in [CGFloat(1), 1.5, 2] {
                for available in [
                    CGSize(width: 780, height: 500),
                    CGSize(width: 1_492, height: 962),
                    CGSize(width: 2_540, height: 1_420),
                    CGSize(width: 100_000, height: 1_420)
                ] {
                    let input = PreviewLayoutInput(
                        content: .ungrouped(items),
                        preferredImageHeight: 220,
                        availablePanelSize: available,
                        backingScale: scale
                    )
                    let decision = PreviewLayoutPlanner.plan(input)
                    try expectEqual(PreviewLayoutPlanner.plan(input), decision)
                    guard case .thumbnails(let plan) = decision else { continue }
                    try expect(plan.panelSize.width <= available.width + 0.000_001, "matrix width overflow")
                    try expect(plan.panelSize.height <= available.height + 0.000_001, "matrix height overflow")
                    try expectEqual(plan.itemIDs, items.map(\.id))
                    try expectEqual(Set(plan.itemIDs).count, items.count)
                    try expectNear(plan.imageHeight * scale, (plan.imageHeight * scale).rounded())
                    try assertSingleRow(input.content, plan: plan)
                    try assertLargestFit(input, plan: plan)
                }
            }
        }

        for count in [1, 2, 8, 50] {
            let items = (0..<count).map { item(UInt32($0 + 1), ratios[$0 % ratios.count]) }
            for scale in [CGFloat(1), 2] {
                let measuring = PreviewLayoutInput(
                    content: .ungrouped(items),
                    preferredImageHeight: 96,
                    availablePanelSize: CGSize(width: 100_000, height: 1_000),
                    backingScale: scale
                )
                let requiredSize = try thumbnails(measuring).panelSize
                let exact = replacing(measuring, availablePanelSize: requiredSize)
                _ = try thumbnails(exact)
                let onePixelNarrower = replacing(
                    measuring,
                    availablePanelSize: CGSize(width: requiredSize.width - 1 / scale, height: requiredSize.height)
                )
                try expectEqual(PreviewLayoutPlanner.plan(onePixelNarrower), .compactList)
            }
        }
    }

    private static func testPerformance() throws {
        let ratios: [CGFloat] = [0.30, 0.50, 0.75, 1, 1.33, 1.77, 2.4, 3.15]
        let items = (0..<50).map { item(UInt32($0 + 1), ratios[$0 % ratios.count]) }
        let fitInput = PreviewLayoutInput(
            content: .ungrouped(items),
            preferredImageHeight: 338,
            availablePanelSize: CGSize(width: 100_000, height: 1_000),
            backingScale: 2
        )
        let fallbackInput = replacing(fitInput, availablePanelSize: CGSize(width: 2_540, height: 1_420))
        let groupedInput = performanceGroupedInput(distribution: Array(repeating: 1, count: 50), ratios: ratios)
        let results = [
            (name: "fit", p95: plannerP95(fitInput)),
            (name: "fallback", p95: plannerP95(fallbackInput)),
            (name: "50x1 grouped", p95: plannerP95(groupedInput))
        ]
        let worstP95 = results.map(\.p95).max() ?? 0
        try expect(worstP95 < 5_000_000, "50-window planner worst p95 was \(Double(worstP95) / 1_000_000) ms")
        let summary = results.map {
            "\($0.name) \(String(format: "%.3f", Double($0.p95) / 1_000_000)) ms"
        }.joined(separator: ", ")
        print("INFO 50-window planner p95 \(summary)")
    }

    private static func geometryGroups() -> [PreviewLayoutGroup] {
        [
            PreviewLayoutGroup(
                id: .desktop(10),
                items: [item(1), item(2)],
                headerSize: CGSize(width: 50, height: 20)
            ),
            PreviewLayoutGroup(
                id: .unassigned,
                items: [item(3)],
                headerSize: CGSize(width: 80, height: 18)
            )
        ]
    }

    private static func performanceGroupedInput(
        distribution: [Int],
        ratios: [CGFloat]
    ) -> PreviewLayoutInput {
        var itemOffset = 0
        let groups = distribution.enumerated().map { groupIndex, itemCount in
            let start = itemOffset
            itemOffset += itemCount
            let items = (0..<itemCount).map { itemIndex in
                let index = start + itemIndex
                return item(UInt32(index + 1), ratios[index % ratios.count])
            }
            return PreviewLayoutGroup(
                id: .desktop(UInt64(groupIndex)),
                items: items,
                headerSize: CGSize(width: 90, height: 20)
            )
        }
        return PreviewLayoutInput(
            content: .grouped(groups),
            preferredImageHeight: 338,
            availablePanelSize: CGSize(width: 100_000, height: 1_000),
            backingScale: 2
        )
    }

    private static func exactHeightInput(
        availableHeight: CGFloat,
        preferred: CGFloat = 96
    ) -> PreviewLayoutInput {
        PreviewLayoutInput(
            content: .ungrouped([item(1)]),
            preferredImageHeight: preferred,
            availablePanelSize: CGSize(width: 1_000, height: availableHeight),
            backingScale: 2,
            metrics: zeroChromeMetrics()
        )
    }

    private static func plannerP95(_ input: PreviewLayoutInput) -> UInt64 {
        for _ in 0..<50 { _ = PreviewLayoutPlanner.plan(input) }
        var durations = [UInt64]()
        for _ in 0..<500 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = PreviewLayoutPlanner.plan(input)
            durations.append(DispatchTime.now().uptimeNanoseconds - start)
        }
        durations.sort()
        return durations[Int(Double(durations.count - 1) * 0.95)]
    }

    private static func zeroChromeMetrics(
        itemSpacing: CGFloat = 0,
        rowSpacing: CGFloat = 0,
        groupPadding: CGFloat = 0,
        groupSpacing: CGFloat = 0,
        groupHeaderSpacing: CGFloat = 0,
        maximumImageWidth: CGFloat = 10_000
    ) -> PreviewLayoutMetrics {
        PreviewLayoutMetrics(
            panelPadding: 0,
            cardHorizontalPadding: 0,
            cardVerticalPadding: 0,
            cardVerticalChrome: 0,
            itemSpacing: itemSpacing,
            rowSpacing: rowSpacing,
            groupPadding: groupPadding,
            groupSpacing: groupSpacing,
            groupHeaderSpacing: groupHeaderSpacing,
            minimumCardWidth: 1,
            maximumImageWidth: maximumImageWidth
        )
    }

    private static func item(_ id: UInt32, _ aspectRatio: CGFloat = 1) -> PreviewLayoutItem {
        PreviewLayoutItem(id: id, aspectRatio: aspectRatio)
    }

    private static func thumbnails(_ input: PreviewLayoutInput) throws -> PreviewLayoutPlan {
        guard case .thumbnails(let plan) = PreviewLayoutPlanner.plan(input) else {
            throw TestFailure(description: "expected thumbnails for \(input)")
        }
        return plan
    }

    private static func assertSingleRow(
        _ content: PreviewLayoutContent,
        plan: PreviewLayoutPlan
    ) throws {
        switch (content, plan.arrangement) {
        case (.ungrouped(let items), .rows(let rows)):
            try expectEqual(rows.count, items.isEmpty ? 0 : 1)
            try expectEqual(rows.flatMap(\.itemIDs), items.map(\.id))
        case (.grouped(let groups), .groupRows(let rows)):
            try expectEqual(rows.count, groups.isEmpty ? 0 : 1)
            let plannedGroups = rows.flatMap(\.groups)
            try expectEqual(plannedGroups.map(\.id), groups.map(\.id))
            for (group, planned) in zip(groups, plannedGroups) {
                try expectEqual(planned.itemRows.count, group.items.isEmpty ? 0 : 1)
                try expectEqual(planned.itemRows.flatMap(\.itemIDs), group.items.map(\.id))
            }
        default:
            throw TestFailure(description: "content and arrangement types did not match")
        }
    }

    private static func assertLargestFit(_ input: PreviewLayoutInput, plan: PreviewLayoutPlan) throws {
        let selectedPixel = Int((plan.imageHeight * input.backingScale).rounded())
        let preferredPixel = Int(floor(input.preferredImageHeight * input.backingScale))
        guard selectedPixel < preferredPixel else { return }

        for pixel in (selectedPixel + 1)...preferredPixel {
            let height = CGFloat(pixel) / input.backingScale
            let exactInput = replacing(input, preferredImageHeight: height, minimumImageHeight: height)
            if case .thumbnails = PreviewLayoutPlanner.plan(exactInput) {
                throw TestFailure(description: "height \(height) fits above selected maximum \(plan.imageHeight)")
            }
        }
    }

    private static func replacing(
        _ input: PreviewLayoutInput,
        content: PreviewLayoutContent? = nil,
        preferredImageHeight: CGFloat? = nil,
        minimumImageHeight: CGFloat? = nil,
        availablePanelSize: CGSize? = nil,
        backingScale: CGFloat? = nil
    ) -> PreviewLayoutInput {
        PreviewLayoutInput(
            content: content ?? input.content,
            preferredImageHeight: preferredImageHeight ?? input.preferredImageHeight,
            minimumImageHeight: minimumImageHeight ?? input.minimumImageHeight,
            availablePanelSize: availablePanelSize ?? input.availablePanelSize,
            backingScale: backingScale ?? input.backingScale,
            metrics: input.metrics
        )
    }

    private static func restore(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(description: message) }
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T) throws {
        guard actual == expected else {
            throw TestFailure(description: "expected \(expected), got \(actual)")
        }
    }

    private static func expectNear(
        _ actual: CGFloat,
        _ expected: CGFloat,
        tolerance: CGFloat = 0.000_001
    ) throws {
        guard abs(actual - expected) <= tolerance else {
            throw TestFailure(description: "expected \(expected), got \(actual)")
        }
    }
}
