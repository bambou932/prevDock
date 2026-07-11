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
            ("96 point boundary and adjacent pixels", testMinimumHeightBoundary),
            ("multi-row height selects exact maximum", testMultiRowMaximum),
            ("empty content is deterministic", testEmptyContent),
            ("aspect ratios clamp at both extremes", testAspectRatioClamping),
            ("narrow cards honor the shared chrome minimum width", testMinimumCardWidth),
            ("maximum image width is respected", testMaximumImageWidth),
            ("all chrome padding and spacing metrics apply", testMetricGeometry),
            ("fifty mixed windows retain stable order", testFiftyMixedWindows),
            ("too many windows choose the native menu", testManyWindowsNativeMenuFallback),
            ("group headers and outer group rows are measured", testGroupedGeometry),
            ("group items wrap without scrolling", testGroupItemWrapping),
            ("group widths trade internal rows for a fitting outer row", testGroupedInternalOuterTradeoff),
            ("three mixed groups match an exhaustive global oracle", testThreeGroupGlobalOracle),
            ("three mixed groups select the deterministic maximum height", testThreeGroupMaximumAndDeterminism),
            ("grouped search returns the global maximum", testGroupedMaximumCertification),
            ("removal shape signatures retain fixed geometry", testRemovalShapeSignatures),
            ("available space honors all Dock edges", testAvailableSpaceAllDockEdges),
            ("available space clips frames and rejects invalid geometry", testAvailableSpaceClippingAndInvalidGeometry),
            ("planner sizing is independent of screen origin", testScreenOriginIndependence),
            ("Auto is default and legacy overflow values remain valid", testOverflowSettingCompatibility),
            ("invalid and duplicate inputs fail closed", testInvalidInputs),
            ("repeated planning is deterministic", testDeterminism),
            ("boundary matrix preserves containment and maximality", testBoundaryMatrix),
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

    private static func testPreferredHeightAndDefaultGeometry() throws {
        let input = PreviewLayoutInput(
            content: .ungrouped([item(1, 2)]),
            preferredImageHeight: 140,
            availablePanelSize: CGSize(width: 2_000, height: 2_000),
            backingScale: 2
        )
        let plan = try thumbnails(input)
        try expectNear(plan.imageHeight, 140)
        try expectNear(plan.contentSize.width, 292)
        try expectNear(plan.contentSize.height, 182)
        try expectEqual(plan.panelSize, CGSize(width: 304, height: 194))
        try expectEqual(plan.itemIDs, [1])
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
            content: .ungrouped([item(1)]),
            preferredImageHeight: 102,
            availablePanelSize: CGSize(width: 100, height: 100),
            backingScale: 2,
            metrics: zeroChromeMetrics()
        )
        let plan = try thumbnails(input)
        try expectNear(plan.imageHeight, 100)
        try assertLargestFit(input, plan: plan)
    }

    private static func testMinimumHeightBoundary() throws {
        let exact = exactHeightInput(availableSide: 96)
        try expectNear(thumbnails(exact).imageHeight, 96)

        let onePixelAbove = exactHeightInput(availableSide: 96.5, preferred: 96.5)
        try expectNear(thumbnails(onePixelAbove).imageHeight, 96.5)

        let onePixelBelow = exactHeightInput(availableSide: 95.5)
        try expectEqual(PreviewLayoutPlanner.plan(onePixelBelow), .nativeDockMenu)

        let fractionalMinimum = PreviewLayoutInput(
            content: .ungrouped([item(1)]),
            preferredImageHeight: 97,
            minimumImageHeight: 96.1,
            availablePanelSize: CGSize(width: 96.25, height: 96.25),
            backingScale: 2,
            metrics: zeroChromeMetrics()
        )
        try expectEqual(PreviewLayoutPlanner.plan(fractionalMinimum), .nativeDockMenu)
    }

    private static func testMultiRowMaximum() throws {
        let metrics = zeroChromeMetrics(itemSpacing: 5)
        let input = PreviewLayoutInput(
            content: .ungrouped([item(1), item(2), item(3)]),
            preferredImageHeight: 110,
            availablePanelSize: CGSize(width: 205, height: 200),
            backingScale: 2,
            metrics: metrics
        )
        let plan = try thumbnails(input)
        try expectNear(plan.imageHeight, 100)
        guard case .rows(let rows) = plan.arrangement else {
            throw TestFailure(description: "expected ungrouped rows")
        }
        try expectEqual(rows.map(\.itemIDs), [[1, 2], [3]])
        try expectEqual(rows.map(\.size), [CGSize(width: 205, height: 100), CGSize(width: 100, height: 100)])
        try assertLargestFit(input, plan: plan)
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

        let tooSmall = replacing(input, availablePanelSize: CGSize(width: 11.5, height: 12))
        try expectEqual(PreviewLayoutPlanner.plan(tooSmall), .nativeDockMenu)
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
        guard case .rows(let rows) = plan.arrangement else {
            throw TestFailure(description: "expected rows")
        }
        try expectEqual(rows.count, 1)
        try expectNear(rows[0].size.width, 345)
        try expectEqual(rows[0].itemIDs, [1, 2])
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

    private static func testMinimumCardWidth() throws {
        let input = PreviewLayoutInput(
            content: .ungrouped([item(1, 0.30)]),
            preferredImageHeight: 96,
            availablePanelSize: CGSize(width: 500, height: 500),
            backingScale: 2
        )
        let plan = try thumbnails(input)
        guard case .rows(let rows) = plan.arrangement, let row = rows.first else {
            throw TestFailure(description: "expected one narrow-card row")
        }
        try expectNear(row.size.width, input.metrics.minimumCardWidth)
        try expectNear(plan.contentSize.width, input.metrics.minimumCardWidth)
        try expectNear(plan.panelSize.width, input.metrics.minimumCardWidth + input.metrics.panelPadding * 2)

        let exactWidth = input.metrics.minimumCardWidth + input.metrics.panelPadding * 2
        _ = try thumbnails(replacing(input, availablePanelSize: CGSize(width: exactWidth, height: 500)))
        try expectEqual(
            PreviewLayoutPlanner.plan(replacing(
                input,
                availablePanelSize: CGSize(width: exactWidth - 0.5, height: 500)
            )),
            .nativeDockMenu
        )
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
            availablePanelSize: CGSize(width: 1_000, height: 1_000),
            backingScale: 1,
            metrics: metrics
        )
        let plan = try thumbnails(input)
        try expectEqual(plan.contentSize, CGSize(width: 224, height: 126))
        try expectEqual(plan.panelSize, CGSize(width: 238, height: 140))

        let wrapped = replacing(input, availablePanelSize: CGSize(width: 130, height: 1_000))
        let wrappedPlan = try thumbnails(wrapped)
        try expectEqual(wrappedPlan.contentSize, CGSize(width: 110, height: 258))
        try expectEqual(wrappedPlan.panelSize, CGSize(width: 124, height: 272))
    }

    private static func testFiftyMixedWindows() throws {
        let ratios: [CGFloat] = [0.30, 0.55, 1, 1.4, 2, 3.15]
        let items = (0..<50).map { item(UInt32($0 + 1), ratios[$0 % ratios.count]) }
        let input = PreviewLayoutInput(
            content: .ungrouped(items),
            preferredImageHeight: 180,
            availablePanelSize: CGSize(width: 2_540, height: 1_420),
            backingScale: 2
        )
        let plan = try thumbnails(input)
        try expectEqual(plan.itemIDs, items.map(\.id))
        try expectEqual(Set(plan.itemIDs).count, 50)
        try expect(plan.panelSize.width <= input.availablePanelSize.width, "panel exceeded available width")
        try expect(plan.panelSize.height <= input.availablePanelSize.height, "panel exceeded available height")
        try assertLargestFit(input, plan: plan)
    }

    private static func testManyWindowsNativeMenuFallback() throws {
        let items = (1...50).map { item(UInt32($0), 1.6) }
        let input = PreviewLayoutInput(
            content: .ungrouped(items),
            preferredImageHeight: 180,
            availablePanelSize: CGSize(width: 800, height: 500),
            backingScale: 2
        )
        try expectEqual(PreviewLayoutPlanner.plan(input), .nativeDockMenu)
    }

    private static func testGroupedGeometry() throws {
        let metrics = zeroChromeMetrics(groupPadding: 5, groupSpacing: 8, groupHeaderSpacing: 4)
        let groups = [
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
        let input = PreviewLayoutInput(
            content: .grouped(groups),
            preferredImageHeight: 100,
            availablePanelSize: CGSize(width: 350, height: 500),
            backingScale: 1,
            metrics: metrics
        )
        let plan = try thumbnails(input)
        guard case .groupRows(let rows) = plan.arrangement else {
            throw TestFailure(description: "expected group rows")
        }
        try expectEqual(rows.count, 1)
        try expectEqual(rows[0].groups.map(\.id), [.desktop(10), .unassigned])
        try expectEqual(rows[0].groups[0].size, CGSize(width: 210, height: 134))
        try expectEqual(rows[0].groups[1].size, CGSize(width: 110, height: 132))
        try expectEqual(rows[0].size, CGSize(width: 328, height: 134))
        try expectEqual(plan.contentSize, CGSize(width: 328, height: 134))
        try expectEqual(plan.itemIDs, [1, 2, 3])

        let wrappedInput = replacing(input, availablePanelSize: CGSize(width: 300, height: 500))
        let wrappedPlan = try thumbnails(wrappedInput)
        guard case .groupRows(let wrappedRows) = wrappedPlan.arrangement else {
            throw TestFailure(description: "expected group rows")
        }
        try expectEqual(wrappedRows.count, 1)
        try expectEqual(wrappedRows[0].groups[0].itemRows.map(\.itemIDs), [[1], [2]])
        try expectEqual(wrappedPlan.contentSize, CGSize(width: 228, height: 234))
    }

    private static func testGroupItemWrapping() throws {
        let metrics = zeroChromeMetrics(
            rowSpacing: 3,
            groupPadding: 5,
            groupSpacing: 8,
            groupHeaderSpacing: 4
        )
        let group = PreviewLayoutGroup(
            id: .desktop(1),
            items: [item(1), item(2)],
            headerSize: CGSize(width: 50, height: 20)
        )
        let input = PreviewLayoutInput(
            content: .grouped([group]),
            preferredImageHeight: 100,
            availablePanelSize: CGSize(width: 200, height: 300),
            backingScale: 1,
            metrics: metrics
        )
        let plan = try thumbnails(input)
        guard case .groupRows(let rows) = plan.arrangement,
              let groupPlan = rows.first?.groups.first else {
            throw TestFailure(description: "expected one group")
        }
        try expectEqual(groupPlan.itemRows.map(\.itemIDs), [[1], [2]])
        try expectEqual(groupPlan.size, CGSize(width: 110, height: 237))
        try expectEqual(plan.panelSize, CGSize(width: 110, height: 237))
    }

    private static func testGroupedInternalOuterTradeoff() throws {
        let groups = [
            PreviewLayoutGroup(
                id: .desktop(1),
                items: [item(1), item(2)],
                headerSize: CGSize(width: 50, height: 20)
            ),
            PreviewLayoutGroup(
                id: .desktop(2),
                items: [item(3), item(4)],
                headerSize: CGSize(width: 50, height: 20)
            )
        ]
        let input = PreviewLayoutInput(
            content: .grouped(groups),
            preferredImageHeight: 96,
            minimumImageHeight: 96,
            availablePanelSize: CGSize(width: 270, height: 330),
            backingScale: 1
        )
        let plan = try thumbnails(input)
        guard case .groupRows(let rows) = plan.arrangement else {
            throw TestFailure(description: "expected grouped tradeoff rows")
        }
        try expectEqual(rows.count, 1)
        try expectEqual(rows[0].groups.map(\.itemRows).map { $0.map(\.itemIDs) }, [
            [[1], [2]],
            [[3], [4]]
        ])
        try expectEqual(rows[0].groups.map(\.size), [
            CGSize(width: 118, height: 310),
            CGSize(width: 118, height: 310)
        ])
        try expectEqual(plan.contentSize, CGSize(width: 244, height: 310))
        try expectEqual(plan.panelSize, CGSize(width: 256, height: 322))
        try expectEqual(plan.itemIDs, [1, 2, 3, 4])
    }

    private static func testThreeGroupGlobalOracle() throws {
        let scenarios: [([PreviewLayoutGroup], [CGFloat])] = [
            (mixedThreeGroups(), [488, 500, 620]),
            ([
                PreviewLayoutGroup(
                    id: .desktop(10),
                    items: [item(10, 0.30), item(11, 3.15)],
                    headerSize: CGSize(width: 72, height: 18)
                ),
                PreviewLayoutGroup(
                    id: .desktop(11),
                    items: [item(12, 0.75), item(13, 1.4), item(14, 2.4)],
                    headerSize: CGSize(width: 90, height: 22)
                ),
                PreviewLayoutGroup(
                    id: .unassigned,
                    items: [item(15, 1.0), item(16, 0.55)],
                    headerSize: CGSize(width: 64, height: 20)
                )
            ], [420, 540, 700])
        ]
        for (groups, panelWidths) in scenarios {
            for panelWidth in panelWidths {
                let input = PreviewLayoutInput(
                    content: .grouped(groups),
                    preferredImageHeight: 96,
                    minimumImageHeight: 96,
                    availablePanelSize: CGSize(width: panelWidth, height: 2_000),
                    backingScale: 1
                )
                let plan = try thumbnails(input)
                let oracle = try exhaustiveGroupedContentSize(
                    groups: groups,
                    imageHeight: 96,
                    availableWidth: panelWidth - input.metrics.panelPadding * 2,
                    metrics: input.metrics
                )
                try expectEqual(plan.contentSize, oracle)
                try expectEqual(plan.itemIDs, groups.flatMap { $0.items.map(\.id) })
            }
        }
    }

    private static func testThreeGroupMaximumAndDeterminism() throws {
        let groups = mixedThreeGroups()
        let input = PreviewLayoutInput(
            content: .grouped(groups),
            preferredImageHeight: 110,
            minimumImageHeight: 96,
            availablePanelSize: CGSize(width: 500, height: 330),
            backingScale: 2
        )
        let expected = PreviewLayoutPlanner.plan(input)
        let plan = try thumbnails(input)
        try expectNear(plan.imageHeight, 98.5)
        try assertLargestFit(input, plan: plan)
        for _ in 0..<200 {
            try expectEqual(PreviewLayoutPlanner.plan(input), expected)
        }
    }

    private static func mixedThreeGroups() -> [PreviewLayoutGroup] {
        [
            PreviewLayoutGroup(
                id: .desktop(1),
                items: [item(1, 2.0), item(2, 0.5), item(3, 1.0)],
                headerSize: CGSize(width: 60, height: 20)
            ),
            PreviewLayoutGroup(
                id: .desktop(2),
                items: [item(4, 1.0), item(5, 1.0)],
                headerSize: CGSize(width: 60, height: 20)
            ),
            PreviewLayoutGroup(
                id: .desktop(3),
                items: [item(6, 0.5), item(7, 0.5), item(8, 0.5)],
                headerSize: CGSize(width: 60, height: 20)
            )
        ]
    }

    private static func testGroupedMaximumCertification() throws {
        let metrics = zeroChromeMetrics(
            rowSpacing: 0,
            groupPadding: 0,
            groupSpacing: 8,
            groupHeaderSpacing: 0,
            maximumImageWidth: 1_000
        )
        let groups = [
            PreviewLayoutGroup(id: .desktop(1), items: [item(1), item(2)], headerSize: nil),
            PreviewLayoutGroup(id: .desktop(2), items: [item(3, 0.30)], headerSize: nil)
        ]
        let input = PreviewLayoutInput(
            content: .grouped(groups),
            preferredImageHeight: 130,
            availablePanelSize: CGSize(width: 200, height: 202),
            backingScale: 2,
            metrics: metrics
        )
        let plan = try thumbnails(input)
        try expectNear(plan.imageHeight, 101)
        guard case .groupRows(let rows) = plan.arrangement else {
            throw TestFailure(description: "expected grouped discontinuity plan")
        }
        try expectEqual(rows.count, 1)
        try expectEqual(rows[0].groups[0].itemRows.map(\.itemIDs), [[1], [2]])
        try assertLargestFit(input, plan: plan)
    }

    private static func testRemovalShapeSignatures() throws {
        let rowSize = CGSize(width: 200, height: 120)
        let current = PreviewLayoutPlan(
            imageHeight: 96,
            arrangement: .rows([
                PreviewLayoutRow(itemIDs: [1, 2], size: rowSize),
                PreviewLayoutRow(itemIDs: [3, 4], size: rowSize)
            ]),
            contentSize: CGSize(width: 200, height: 240),
            panelSize: CGSize(width: 212, height: 252)
        )
        let identicalFixedGeometry = PreviewLayoutPlan(
            imageHeight: 96,
            arrangement: .rows([
                PreviewLayoutRow(itemIDs: [1, 2], size: rowSize),
                PreviewLayoutRow(itemIDs: [3], size: CGSize(width: 100, height: 120))
            ]),
            contentSize: current.contentSize,
            panelSize: current.panelSize
        )
        try expectEqual(
            current.shapeSignature(excluding: [4]),
            identicalFixedGeometry.shapeSignature()
        )

        let resizedRowHeight = PreviewLayoutPlan(
            imageHeight: 96,
            arrangement: .rows([
                PreviewLayoutRow(itemIDs: [1, 2], size: rowSize),
                PreviewLayoutRow(itemIDs: [3], size: CGSize(width: 100, height: 121))
            ]),
            contentSize: current.contentSize,
            panelSize: current.panelSize
        )
        try expect(
            current.shapeSignature(excluding: [4]) != resizedRowHeight.shapeSignature(),
            "fixed row-height changes must force a full Auto reflow"
        )

        let resizedPanel = PreviewLayoutPlan(
            imageHeight: 96,
            arrangement: identicalFixedGeometry.arrangement,
            contentSize: CGSize(width: 180, height: 240),
            panelSize: CGSize(width: 192, height: 252)
        )
        try expect(
            current.shapeSignature(excluding: [4]) != resizedPanel.shapeSignature(),
            "panel and content geometry changes must force a full Auto reflow"
        )

        let removedWholeRow = PreviewLayoutPlan(
            imageHeight: 96,
            arrangement: .rows([PreviewLayoutRow(itemIDs: [3, 4], size: rowSize)]),
            contentSize: CGSize(width: 200, height: 120),
            panelSize: CGSize(width: 212, height: 132)
        )
        try expect(
            current.shapeSignature(excluding: [1, 2]) != removedWholeRow.shapeSignature(),
            "empty rows must remain structural markers"
        )

        let currentGroup = PreviewLayoutGroupPlan(
            id: .desktop(1),
            itemRows: [PreviewLayoutRow(itemIDs: [1, 2], size: rowSize)],
            size: CGSize(width: 210, height: 154)
        )
        let resizedGroup = PreviewLayoutGroupPlan(
            id: .desktop(1),
            itemRows: [PreviewLayoutRow(itemIDs: [2], size: CGSize(width: 100, height: 120))],
            size: CGSize(width: 110, height: 154)
        )
        let groupedCurrent = PreviewLayoutPlan(
            imageHeight: 96,
            arrangement: .groupRows([
                PreviewLayoutGroupRow(groups: [currentGroup], size: currentGroup.size)
            ]),
            contentSize: currentGroup.size,
            panelSize: CGSize(width: 222, height: 166)
        )
        let groupedNext = PreviewLayoutPlan(
            imageHeight: 96,
            arrangement: .groupRows([
                PreviewLayoutGroupRow(groups: [resizedGroup], size: resizedGroup.size)
            ]),
            contentSize: resizedGroup.size,
            panelSize: CGSize(width: 122, height: 166)
        )
        try expect(
            groupedCurrent.shapeSignature(excluding: [1]) != groupedNext.shapeSignature(),
            "group and nested-row geometry changes must force a full Auto reflow"
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
        let negativeOriginScreen = CGRect(x: -2_560, y: 0, width: 2_560, height: 1_440).insetBy(dx: 10, dy: 10)
        let positiveOriginScreen = CGRect(x: 0, y: 0, width: 2_560, height: 1_440).insetBy(dx: 10, dy: 10)
        let content = PreviewLayoutContent.ungrouped((1...12).map { item(UInt32($0), 1.4) })
        let negativeInput = PreviewLayoutInput(
            content: content,
            preferredImageHeight: 180,
            availablePanelSize: negativeOriginScreen.size,
            backingScale: 2
        )
        let positiveInput = replacing(negativeInput, availablePanelSize: positiveOriginScreen.size)
        try expectEqual(PreviewLayoutPlanner.plan(negativeInput), PreviewLayoutPlanner.plan(positiveInput))

        let compactDisplay = replacing(positiveInput, availablePanelSize: CGSize(width: 1_492, height: 962))
        let compactPlan = try thumbnails(compactDisplay)
        try expect(compactPlan.panelSize.width <= 1_492, "compact panel exceeded width")
        try expect(compactPlan.panelSize.height <= 962, "compact panel exceeded height")
    }

    private static func testOverflowSettingCompatibility() throws {
        try expect(
            Bundle.main.bundleIdentifier != "io.github.bambou932.prevDock",
            "settings tests must not use the production preferences domain"
        )
        let defaults = UserDefaults.standard
        let key = PrevDockSettings.previewOverflowModeKey
        let originalValue = defaults.object(forKey: key)
        defer {
            if let originalValue {
                defaults.set(originalValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        PrevDockSettings.registerDefaults()
        try expectEqual(PrevDockSettings.defaultPreviewOverflowMode, .auto)
        try expectEqual(PrevDockSettings.previewOverflowMode, .auto)

        defaults.set(PreviewOverflowMode.scroll.rawValue, forKey: key)
        try expectEqual(PrevDockSettings.previewOverflowMode, .scroll)
        PrevDockSettings.previewOverflowMode = .wrap
        try expectEqual(defaults.string(forKey: key), PreviewOverflowMode.wrap.rawValue)
        try expectEqual(PrevDockSettings.previewOverflowMode, .wrap)

        try expectEqual(PreviewOverflowMode(rawValue: "auto"), .auto)
        try expectEqual(PreviewOverflowMode(rawValue: "scroll"), .scroll)
        try expectEqual(PreviewOverflowMode(rawValue: "wrap"), .wrap)
        try expectEqual(PreviewOverflowMode.allCases, [.auto, .wrap, .scroll])
    }

    private static func testInvalidInputs() throws {
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
            try expectEqual(PreviewLayoutPlanner.plan(replacing(valid, content: content)), .nativeDockMenu)
        }

        try expectEqual(
            PreviewLayoutPlanner.plan(replacing(valid, availablePanelSize: CGSize(width: -1, height: 500))),
            .nativeDockMenu
        )
        try expectEqual(PreviewLayoutPlanner.plan(replacing(valid, backingScale: 0)), .nativeDockMenu)
        try expectEqual(
            PreviewLayoutPlanner.plan(replacing(valid, preferredImageHeight: 95, minimumImageHeight: 96)),
            .nativeDockMenu
        )

        let headerOverflow = replacing(
            valid,
            content: .grouped([
                PreviewLayoutGroup(id: .desktop(1), items: [item(1)], headerSize: CGSize(width: 2_000, height: 20))
            ])
        )
        try expectEqual(PreviewLayoutPlanner.plan(headerOverflow), .nativeDockMenu)

        let derivedGeometryOverflow = PreviewLayoutInput(
            content: .grouped([
                PreviewLayoutGroup(id: .desktop(42), items: [item(42)], headerSize: nil)
            ]),
            preferredImageHeight: 140,
            availablePanelSize: CGSize(width: 1_000, height: 1_000),
            backingScale: 2,
            metrics: PreviewLayoutMetrics(groupPadding: .greatestFiniteMagnitude)
        )
        try expectEqual(PreviewLayoutPlanner.plan(derivedGeometryOverflow), .nativeDockMenu)
    }

    private static func testDeterminism() throws {
        var groups = [PreviewLayoutGroup]()
        for groupIndex in 0..<5 {
            let groupItems: [PreviewLayoutItem] = (0..<7).map { itemIndex in
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
            availablePanelSize: CGSize(width: 1_492, height: 962),
            backingScale: 2
        )
        let expected = PreviewLayoutPlanner.plan(input)
        for _ in 0..<100 {
            try expectEqual(PreviewLayoutPlanner.plan(input), expected)
        }
    }

    private static func testBoundaryMatrix() throws {
        let ratios: [CGFloat] = [0.30, 0.31, 0.75, 1, 1.77, 3.14, 3.15]
        for count in [1, 2, 3, 8, 17, 50] {
            let items = (0..<count).map { item(UInt32($0 + 1), ratios[$0 % ratios.count]) }
            for scale in [CGFloat(1), 1.5, 2] {
                for available in [
                    CGSize(width: 780, height: 500),
                    CGSize(width: 1_492, height: 962),
                    CGSize(width: 2_540, height: 1_420)
                ] {
                    let input = PreviewLayoutInput(
                        content: .ungrouped(items),
                        preferredImageHeight: 220,
                        availablePanelSize: available,
                        backingScale: scale
                    )
                    guard case .thumbnails(let plan) = PreviewLayoutPlanner.plan(input) else { continue }
                    try expect(plan.panelSize.width <= available.width + 0.000_001, "matrix width overflow")
                    try expect(plan.panelSize.height <= available.height + 0.000_001, "matrix height overflow")
                    try expectEqual(plan.itemIDs, items.map(\.id))
                    try expectEqual(Set(plan.itemIDs).count, items.count)
                    try expectNear(plan.imageHeight * scale, (plan.imageHeight * scale).rounded())
                    try assertLargestFit(input, plan: plan)
                }
            }
        }
    }

    private static func testPerformance() throws {
        let ratios: [CGFloat] = [0.30, 0.50, 0.75, 1, 1.33, 1.77, 2.4, 3.15]
        let items = (0..<50).map { item(UInt32($0 + 1), ratios[$0 % ratios.count]) }
        let ungroupedInput = PreviewLayoutInput(
            content: .ungrouped(items),
            preferredImageHeight: 338,
            availablePanelSize: CGSize(width: 2_540, height: 1_420),
            backingScale: 2
        )
        let benchmarks: [(name: String, input: PreviewLayoutInput)] = [
            ("ungrouped", ungroupedInput),
            ("50x1", performanceGroupedInput(distribution: Array(repeating: 1, count: 50), ratios: ratios)),
            ("49+1", performanceGroupedInput(distribution: [49, 1], ratios: ratios)),
            ("25x2", performanceGroupedInput(distribution: Array(repeating: 2, count: 25), ratios: ratios)),
            ("10x5", performanceGroupedInput(distribution: Array(repeating: 5, count: 10), ratios: ratios)),
            ("5x10", performanceGroupedInput(distribution: Array(repeating: 10, count: 5), ratios: ratios))
        ]
        let results = benchmarks.map { (name: $0.name, p95: plannerP95($0.input)) }
        let worstP95 = results.map(\.p95).max() ?? 0
        try expect(worstP95 < 5_000_000, "50-window planner worst p95 was \(Double(worstP95) / 1_000_000) ms")
        let summary = results.map {
            "\($0.name) \(String(format: "%.3f", Double($0.p95) / 1_000_000)) ms"
        }.joined(separator: ", ")
        print("INFO 50-window planner p95 \(summary)")
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
            availablePanelSize: CGSize(width: 2_540, height: 1_420),
            backingScale: 2
        )
    }

    private static func exhaustiveGroupedContentSize(
        groups: [PreviewLayoutGroup],
        imageHeight: CGFloat,
        availableWidth: CGFloat,
        metrics: PreviewLayoutMetrics
    ) throws -> CGSize {
        let variantsByGroup = groups.map {
            exhaustiveGroupSizes(group: $0, imageHeight: imageHeight, metrics: metrics)
        }
        var best: CGSize?

        func visit(groupIndex: Int, selected: [CGSize]) {
            guard groupIndex < variantsByGroup.count else {
                let outerPartitionCount = selected.count <= 1 ? 1 : 1 << (selected.count - 1)
                for partition in 0..<outerPartitionCount {
                    guard let candidate = exhaustiveOuterSize(
                        groups: selected,
                        partition: partition,
                        availableWidth: availableWidth,
                        spacing: metrics.groupSpacing
                    ) else {
                        continue
                    }
                    if oracleSize(candidate, isBetterThan: best) {
                        best = candidate
                    }
                }
                return
            }

            for variant in variantsByGroup[groupIndex] {
                visit(groupIndex: groupIndex + 1, selected: selected + [variant])
            }
        }

        visit(groupIndex: 0, selected: [])
        guard let best else {
            throw TestFailure(description: "exhaustive grouped oracle found no width-feasible layout")
        }
        return best
    }

    private static func exhaustiveGroupSizes(
        group: PreviewLayoutGroup,
        imageHeight: CGFloat,
        metrics: PreviewLayoutMetrics
    ) -> [CGSize] {
        let cardWidths = group.items.map { preview in
            let aspect = min(metrics.maximumAspectRatio, max(metrics.minimumAspectRatio, preview.aspectRatio))
            return max(
                metrics.minimumCardWidth,
                min(metrics.maximumImageWidth, imageHeight * aspect) + metrics.cardHorizontalPadding * 2
            )
        }
        let partitionCount = cardWidths.count <= 1 ? 1 : 1 << (cardWidths.count - 1)
        return (0..<partitionCount).map { partition in
            let rowWidths = exhaustiveItemRowWidths(
                cardWidths: cardWidths,
                partition: partition,
                spacing: metrics.itemSpacing
            )
            let headerWidth = group.headerSize?.width ?? 0
            let headerHeight = group.headerSize?.height ?? 0
            let headerSpacing = group.headerSize == nil || rowWidths.isEmpty ? 0 : metrics.groupHeaderSpacing
            let cardHeight = imageHeight + metrics.cardVerticalChrome + metrics.cardVerticalPadding * 2
            let rowsHeight = CGFloat(rowWidths.count) * cardHeight +
                CGFloat(max(0, rowWidths.count - 1)) * metrics.rowSpacing
            return CGSize(
                width: max(rowWidths.max() ?? 0, headerWidth) + metrics.groupPadding * 2,
                height: rowsHeight + headerHeight + headerSpacing + metrics.groupPadding * 2
            )
        }
    }

    private static func exhaustiveItemRowWidths(
        cardWidths: [CGFloat],
        partition: Int,
        spacing: CGFloat
    ) -> [CGFloat] {
        guard !cardWidths.isEmpty else { return [] }
        var rows = [CGFloat]()
        var currentWidth: CGFloat = 0
        for index in cardWidths.indices {
            currentWidth = currentWidth == 0 ? cardWidths[index] : currentWidth + spacing + cardWidths[index]
            let endsRow = index == cardWidths.count - 1 || partition & (1 << index) != 0
            if endsRow {
                rows.append(currentWidth)
                currentWidth = 0
            }
        }
        return rows
    }

    private static func exhaustiveOuterSize(
        groups: [CGSize],
        partition: Int,
        availableWidth: CGFloat,
        spacing: CGFloat
    ) -> CGSize? {
        guard !groups.isEmpty else { return .zero }
        var rowSizes = [CGSize]()
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        for index in groups.indices {
            rowWidth = rowWidth == 0 ? groups[index].width : rowWidth + spacing + groups[index].width
            rowHeight = max(rowHeight, groups[index].height)
            let endsRow = index == groups.count - 1 || partition & (1 << index) != 0
            if endsRow {
                guard rowWidth <= availableWidth + 0.000_001 else { return nil }
                rowSizes.append(CGSize(width: rowWidth, height: rowHeight))
                rowWidth = 0
                rowHeight = 0
            }
        }
        return CGSize(
            width: rowSizes.map(\.width).max() ?? 0,
            height: rowSizes.map(\.height).reduce(0, +) + CGFloat(max(0, rowSizes.count - 1)) * spacing
        )
    }

    private static func oracleSize(_ candidate: CGSize, isBetterThan current: CGSize?) -> Bool {
        guard let current else { return true }
        if candidate.height < current.height - 0.000_001 { return true }
        if abs(candidate.height - current.height) > 0.000_001 { return false }
        return candidate.width < current.width - 0.000_001
    }

    private static func exactHeightInput(
        availableSide: CGFloat,
        preferred: CGFloat = 96
    ) -> PreviewLayoutInput {
        PreviewLayoutInput(
            content: .ungrouped([item(1)]),
            preferredImageHeight: preferred,
            availablePanelSize: CGSize(width: availableSide, height: availableSide),
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

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(description: message) }
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T) throws {
        guard actual == expected else {
            throw TestFailure(description: "expected \(expected), got \(actual)")
        }
    }

    private static func expectNear(_ actual: CGFloat, _ expected: CGFloat, tolerance: CGFloat = 0.000_001) throws {
        guard abs(actual - expected) <= tolerance else {
            throw TestFailure(description: "expected \(expected), got \(actual)")
        }
    }
}
