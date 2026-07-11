import AppKit
import Darwin
import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private typealias TestCase = (name: String, body: () throws -> Void)

@main
private enum PreviewPresentationTests {
    static func main() {
        let tests: [TestCase] = [
            ("Auto installs every planned card once without scrolling", testAutoPresentation),
            ("grouped Auto installs every planned card without scrolling", testGroupedAutoPresentation),
            ("Auto rejects a mismatched card inventory before rendering", testAutoInventoryMismatch),
            ("legacy overflow decisions preserve exact boundaries", testLegacyOverflowBoundaries),
            ("Scroll preserves a plain row until horizontal overflow", testScrollPresentation),
            ("grouped Scroll preserves its container with and without overflow", testGroupedScrollPresentation),
            ("Wrap preserves rows until vertical overflow", testWrapPresentation),
            ("all content sizes feed exact card metrics into the planner", testContentSizeMetrics),
            ("narrow card chrome and loading geometry stay inside bounds", testNarrowCardGeometry)
        ]

        do {
            for test in tests {
                try test.body()
                print("PASS \(test.name)")
            }
            print("PASS \(tests.count) preview presentation tests")
        } catch {
            fputs("FAIL \(error)\n", stderr)
            exit(1)
        }
    }

    private static func testGroupedAutoPresentation() throws {
        let groups = [
            PreviewLayoutGroup(
                id: .desktop(1),
                items: [
                    PreviewLayoutItem(id: 1, aspectRatio: 1.6),
                    PreviewLayoutItem(id: 2, aspectRatio: 0.8)
                ],
                headerSize: NSSize(width: 80, height: 20)
            ),
            PreviewLayoutGroup(
                id: .desktop(2),
                items: [
                    PreviewLayoutItem(id: 3, aspectRatio: 1.2),
                    PreviewLayoutItem(id: 4, aspectRatio: 2.1)
                ],
                headerSize: NSSize(width: 96, height: 20)
            )
        ]
        let input = PreviewLayoutInput(
            content: .grouped(groups),
            preferredImageHeight: 120,
            availablePanelSize: NSSize(width: 520, height: 600),
            backingScale: 2
        )
        let plan = try thumbnailPlan(input)
        guard case .groupRows = plan.arrangement else {
            throw TestFailure(description: "expected grouped Auto rows")
        }

        let stack = verticalStack()
        stack.spacing = input.metrics.groupSpacing
        var constructionOrder = [UInt32]()
        let snapshot = PreviewPresentationLayout.installAutoGroupRows(
            plan: plan,
            availableItemIDs: Set(plan.itemIDs),
            in: stack
        ) { row in
            let itemIDs = row.groups.flatMap { group in
                group.itemRows.flatMap(\.itemIDs)
            }
            constructionOrder.append(contentsOf: itemIDs)
            return groupedFixtureRow(row, groupSpacing: input.metrics.groupSpacing)
        }

        let installed = try require(snapshot, "grouped Auto presentation rejected a valid plan")
        try expectEqual(installed.itemIDs, plan.itemIDs)
        try expectEqual(installed.measuredPanelSize, plan.panelSize)
        try expectEqual(constructionOrder, plan.itemIDs)
        try expectEqual(descendants(of: NSScrollView.self, in: stack).count, 0)
        let cards = descendants(of: TestItemView.self, in: stack)
        try expectEqual(cards.count, plan.itemIDs.count)
        try expectEqual(Set(cards.map(\.itemID)), Set(plan.itemIDs))
        try verifyAutoGeometry(stack: stack, plan: plan, panelPadding: input.metrics.panelPadding)

        guard case .groupRows(let rows) = plan.arrangement else { return }
        let fixtureGroups = descendants(of: TestGroupFixtureView.self, in: stack)
        let plannedGroups = rows.flatMap(\.groups)
        try expectEqual(fixtureGroups.count, plannedGroups.count)
        for (fixture, group) in zip(fixtureGroups, plannedGroups) {
            try expectSizeNear(fixture.intrinsicContentSize, group.size)
        }
    }

    private static func testAutoPresentation() throws {
        let items = [
            PreviewLayoutItem(id: 1, aspectRatio: 2.0),
            PreviewLayoutItem(id: 2, aspectRatio: 1.0),
            PreviewLayoutItem(id: 3, aspectRatio: 0.5),
            PreviewLayoutItem(id: 4, aspectRatio: 1.5),
            PreviewLayoutItem(id: 5, aspectRatio: 0.8)
        ]
        let input = PreviewLayoutInput(
            content: .ungrouped(items),
            preferredImageHeight: 120,
            availablePanelSize: NSSize(width: 360, height: 600),
            backingScale: 2
        )
        let plan = try thumbnailPlan(input)
        guard case .rows(let rows) = plan.arrangement else {
            throw TestFailure(description: "expected Auto rows")
        }
        try expect(rows.count > 1, "Auto fixture did not create multiple rows")

        let stack = verticalStack()
        let itemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var constructionOrder = [UInt32]()
        let snapshot = PreviewPresentationLayout.installAutoRows(
            plan: plan,
            availableItemIDs: Set(items.map(\.id)),
            in: stack
        ) { itemID in
            guard let item = itemByID[itemID] else { return nil }
            constructionOrder.append(itemID)
            return TestItemView(
                itemID: itemID,
                size: cardSize(item: item, imageHeight: plan.imageHeight, metrics: input.metrics)
            )
        }

        let installed = try require(snapshot, "Auto presentation rejected a valid plan")
        try expectEqual(installed.itemIDs, plan.itemIDs)
        try expectEqual(installed.measuredPanelSize, plan.panelSize)
        try expectEqual(constructionOrder, plan.itemIDs)
        try expectEqual(stack.arrangedSubviews.count, rows.count)
        try expectEqual(descendants(of: NSScrollView.self, in: stack).count, 0)

        let cardViews = descendants(of: TestItemView.self, in: stack)
        try expectEqual(cardViews.count, items.count)
        try expectEqual(Set(cardViews.map(\.itemID)), Set(items.map(\.id)))
        try expectEqual(Dictionary(grouping: cardViews, by: \.itemID).values.map(\.count).max(), 1)
        try verifyAutoGeometry(stack: stack, plan: plan, panelPadding: input.metrics.panelPadding)
    }

    private static func testLegacyOverflowBoundaries() throws {
        let widthBoundary: CGFloat = 500
        try expect(!PreviewLegacyOverflowPolicy.needsHorizontalScroll(
            contentWidth: widthBoundary - 1,
            availableWidth: widthBoundary
        ), "horizontal boundary - 1 scrolled")
        try expect(!PreviewLegacyOverflowPolicy.needsHorizontalScroll(
            contentWidth: widthBoundary,
            availableWidth: widthBoundary
        ), "horizontal boundary scrolled")
        try expect(PreviewLegacyOverflowPolicy.needsHorizontalScroll(
            contentWidth: widthBoundary + 1,
            availableWidth: widthBoundary
        ), "horizontal boundary + 1 did not scroll")

        let rowBoundary = 3
        try expect(!PreviewLegacyOverflowPolicy.needsWrappedVerticalScroll(
            rowCount: rowBoundary - 1,
            maximumVisibleRows: rowBoundary
        ), "Wrap boundary - 1 scrolled")
        try expect(!PreviewLegacyOverflowPolicy.needsWrappedVerticalScroll(
            rowCount: rowBoundary,
            maximumVisibleRows: rowBoundary
        ), "Wrap boundary scrolled")
        try expect(PreviewLegacyOverflowPolicy.needsWrappedVerticalScroll(
            rowCount: rowBoundary + 1,
            maximumVisibleRows: rowBoundary
        ), "Wrap boundary + 1 did not scroll")
    }

    private static func testAutoInventoryMismatch() throws {
        let input = PreviewLayoutInput(
            content: .ungrouped([
                PreviewLayoutItem(id: 1, aspectRatio: 1),
                PreviewLayoutItem(id: 2, aspectRatio: 1)
            ]),
            preferredImageHeight: 100,
            availablePanelSize: NSSize(width: 500, height: 500),
            backingScale: 2
        )
        let plan = try thumbnailPlan(input)
        let stack = verticalStack()
        var constructionCount = 0
        let snapshot = PreviewPresentationLayout.installAutoRows(
            plan: plan,
            availableItemIDs: [1, 2, 3],
            in: stack
        ) { itemID in
            constructionCount += 1
            return TestItemView(itemID: itemID, size: NSSize(width: 100, height: 100))
        }
        try expect(snapshot == nil, "Auto accepted extra card inventory")
        try expectEqual(constructionCount, 0)
        try expect(stack.arrangedSubviews.isEmpty, "Auto mutated the hierarchy after rejecting inventory")
    }

    private static func testScrollPresentation() throws {
        let plainStack = verticalStack()
        let plainRow = testRow(ids: [1, 2], cardSize: NSSize(width: 120, height: 100))
        let plainScroll = PreviewPresentationLayout.installLegacyRows(
            mode: .scroll,
            rowViews: [plainRow],
            contentSize: NSSize(width: 240, height: 100),
            viewportSize: NSSize(width: 240, height: 100),
            needsScroll: false,
            spacing: 0,
            in: plainStack
        )
        try expect(plainScroll == nil, "Scroll added a scroller for fitting content")
        try expectEqual(plainStack.arrangedSubviews.count, 1)
        try expectEqual(descendants(of: NSScrollView.self, in: plainStack).count, 0)

        let overflowStack = verticalStack()
        let overflowRow = testRow(ids: [1, 2, 3, 4], cardSize: NSSize(width: 180, height: 100))
        let scrollView = try require(PreviewPresentationLayout.installLegacyRows(
            mode: .scroll,
            rowViews: [overflowRow],
            contentSize: NSSize(width: 720, height: 100),
            viewportSize: NSSize(width: 360, height: 115),
            needsScroll: true,
            spacing: 0,
            in: overflowStack
        ), "Scroll omitted its horizontal scroller")
        try expect(scrollView.hasHorizontalScroller, "Scroll did not enable its horizontal scroller")
        try expect(!scrollView.hasVerticalScroller, "Scroll unexpectedly enabled a vertical scroller")
        try expectEqual(descendants(of: NSScrollView.self, in: overflowStack).count, 1)
        try expectEqual(descendants(of: TestItemView.self, in: scrollView).map(\.itemID), [1, 2, 3, 4])
    }

    private static func testGroupedScrollPresentation() throws {
        let contentSize = NSSize(width: 400, height: 120)
        let fittingStack = verticalStack()
        let fittingScroll = PreviewPresentationLayout.installHorizontalScrollContainer(
            rowView: testRow(ids: [1, 2], cardSize: NSSize(width: 200, height: 120)),
            contentSize: contentSize,
            viewportSize: contentSize,
            showsScroller: PreviewLegacyOverflowPolicy.needsHorizontalScroll(
                contentWidth: contentSize.width,
                availableWidth: contentSize.width
            ),
            in: fittingStack
        )
        try expect(!fittingScroll.hasHorizontalScroller, "grouped Scroll showed a fitting scroller")
        try expect(!fittingScroll.hasVerticalScroller, "grouped Scroll enabled a vertical scroller")
        try expectEqual(descendants(of: NSScrollView.self, in: fittingStack).count, 1)

        let overflowStack = verticalStack()
        let viewportSize = NSSize(width: contentSize.width - 1, height: 135)
        let overflowScroll = PreviewPresentationLayout.installHorizontalScrollContainer(
            rowView: testRow(ids: [1, 2], cardSize: NSSize(width: 200, height: 120)),
            contentSize: contentSize,
            viewportSize: viewportSize,
            showsScroller: PreviewLegacyOverflowPolicy.needsHorizontalScroll(
                contentWidth: contentSize.width,
                availableWidth: viewportSize.width
            ),
            in: overflowStack
        )
        try expect(overflowScroll.hasHorizontalScroller, "grouped Scroll omitted its overflow scroller")
        try expect(!overflowScroll.hasVerticalScroller, "grouped Scroll enabled a vertical scroller")
        try expectEqual(descendants(of: TestItemView.self, in: overflowScroll).map(\.itemID), [1, 2])
    }

    private static func testWrapPresentation() throws {
        let plainStack = verticalStack()
        let plainRows = [
            testRow(ids: [1, 2], cardSize: NSSize(width: 100, height: 80)),
            testRow(ids: [3], cardSize: NSSize(width: 100, height: 80))
        ]
        let plainScroll = PreviewPresentationLayout.installLegacyRows(
            mode: .wrap,
            rowViews: plainRows,
            contentSize: NSSize(width: 200, height: 160),
            viewportSize: NSSize(width: 200, height: 160),
            needsScroll: false,
            spacing: 0,
            in: plainStack
        )
        try expect(plainScroll == nil, "Wrap added a scroller below its row limit")
        try expectEqual(plainStack.arrangedSubviews.count, 2)
        try expectEqual(descendants(of: NSScrollView.self, in: plainStack).count, 0)

        let overflowStack = verticalStack()
        let overflowRows = (0..<5).map { index in
            testRow(ids: [UInt32(index + 1)], cardSize: NSSize(width: 200, height: 90))
        }
        let scrollView = try require(PreviewPresentationLayout.installLegacyRows(
            mode: .wrap,
            rowViews: overflowRows,
            contentSize: NSSize(width: 200, height: 450),
            viewportSize: NSSize(width: 215, height: 270),
            needsScroll: true,
            spacing: 0,
            in: overflowStack
        ), "Wrap omitted its vertical scroller")
        try expect(!scrollView.hasHorizontalScroller, "Wrap unexpectedly enabled a horizontal scroller")
        try expect(scrollView.hasVerticalScroller, "Wrap did not enable its vertical scroller")
        try expectEqual(descendants(of: NSScrollView.self, in: overflowStack).count, 1)
        try expectEqual(Set(descendants(of: TestItemView.self, in: scrollView).map(\.itemID)), Set(1...5))
    }

    private static func testContentSizeMetrics() throws {
        let expected: [(PreviewContentSize, PreviewContentStyle)] = [
            (.extraSmall, PreviewContentStyle(cardVerticalChrome: 24, titleFontSize: 12, statusFontSize: 10, appIconSize: 14)),
            (.small, PreviewContentStyle(cardVerticalChrome: 27, titleFontSize: 13, statusFontSize: 11, appIconSize: 16)),
            (.regular, PreviewContentStyle(cardVerticalChrome: 30, titleFontSize: 14, statusFontSize: 12, appIconSize: 18)),
            (.large, PreviewContentStyle(cardVerticalChrome: 34, titleFontSize: 16, statusFontSize: 13, appIconSize: 21)),
            (.extraLarge, PreviewContentStyle(cardVerticalChrome: 38, titleFontSize: 18, statusFontSize: 14, appIconSize: 24))
        ]
        for (contentSize, style) in expected {
            try expectEqual(contentSize.style, style)
            let metrics = PreviewLayoutMetrics(cardVerticalChrome: style.cardVerticalChrome)
            let input = PreviewLayoutInput(
                content: .ungrouped([PreviewLayoutItem(id: 1, aspectRatio: 1)]),
                preferredImageHeight: 96,
                availablePanelSize: NSSize(width: 500, height: 500),
                backingScale: 2,
                metrics: metrics
            )
            let plan = try thumbnailPlan(input)
            guard case .rows(let rows) = plan.arrangement, let row = rows.first else {
                throw TestFailure(description: "missing row for \(contentSize)")
            }
            try expectEqual(
                row.size.height,
                96 + style.cardVerticalChrome + metrics.cardVerticalPadding * 2
            )
        }
    }

    private static func testNarrowCardGeometry() throws {
        for contentSize in PreviewContentSize.allCases {
            let style = contentSize.style
            let minimumWidth = PreviewCardChromeLayout.minimumCardWidth(
                contentStyle: style,
                contentPadding: 6
            )
            let metrics = PreviewLayoutMetrics(
                cardVerticalChrome: style.cardVerticalChrome,
                minimumCardWidth: minimumWidth
            )
            let input = PreviewLayoutInput(
                content: .ungrouped([PreviewLayoutItem(id: 1, aspectRatio: 0.30)]),
                preferredImageHeight: 96,
                availablePanelSize: NSSize(width: 500, height: 500),
                backingScale: 2,
                metrics: metrics
            )
            let plan = try thumbnailPlan(input)
            guard case .rows(let rows) = plan.arrangement, let row = rows.first else {
                throw TestFailure(description: "missing narrow row for \(contentSize)")
            }
            try expectNear(row.size.width, minimumWidth)
            try verifyNarrowChromeConstraints(
                cardWidth: row.size.width,
                thumbnailWidth: 96 * 0.30,
                contentStyle: style
            )
        }

        let loadingSize = PreviewLoadingPlaceholderLayout.fittedSize(
            in: NSSize(width: 96 * 0.30, height: 96)
        )
        try expectSizeNear(loadingSize, NSSize(width: 28.8, height: 28))
    }

    private static func verifyNarrowChromeConstraints(
        cardWidth: CGFloat,
        thumbnailWidth: CGFloat,
        contentStyle: PreviewContentStyle
    ) throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: cardWidth, height: 150))
        let imageView = NSImageView()
        let appIconView = NSImageView()
        let titleLabel = NSTextField(labelWithString: "A long preview title")
        let statusLabel = NSTextField(labelWithString: "Minimized")
        container.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let subviews: [NSView] = [imageView, appIconView, titleLabel, statusLabel]
        for view in subviews {
            container.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate(
            PreviewCardChromeLayout.horizontalConstraints(
                container: container,
                imageView: imageView,
                appIconView: appIconView,
                titleLabel: titleLabel,
                statusLabel: statusLabel,
                thumbnailWidth: thumbnailWidth,
                contentStyle: contentStyle,
                contentPadding: 6
            ) + [
                container.widthAnchor.constraint(equalToConstant: cardWidth),
                container.heightAnchor.constraint(equalToConstant: 150),
                imageView.topAnchor.constraint(equalTo: container.topAnchor),
                imageView.heightAnchor.constraint(equalToConstant: 96),
                appIconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 110),
                appIconView.heightAnchor.constraint(equalToConstant: contentStyle.appIconSize),
                titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 108),
                titleLabel.heightAnchor.constraint(equalToConstant: 20),
                statusLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 108),
                statusLabel.heightAnchor.constraint(equalToConstant: 20)
            ]
        )
        container.layoutSubtreeIfNeeded()

        let imageAlignment = imageView.alignmentRect(forFrame: imageView.frame)
        let iconAlignment = appIconView.alignmentRect(forFrame: appIconView.frame)
        let titleAlignment = titleLabel.alignmentRect(forFrame: titleLabel.frame)
        let statusAlignment = statusLabel.alignmentRect(forFrame: statusLabel.frame)
        try expectNear(imageAlignment.width, thumbnailWidth, tolerance: 1)
        try expectNear(imageAlignment.midX, cardWidth / 2, tolerance: 1)
        try expectNear(iconAlignment.width, contentStyle.appIconSize, tolerance: 0.5)
        try expectNear(iconAlignment.minX, 14, tolerance: 0.5)
        try expectNear(statusAlignment.maxX, cardWidth - 14, tolerance: 0.5)
        try expect(
            titleAlignment.maxX <= statusAlignment.minX - PreviewCardChromeLayout.titleStatusSpacing + 0.000_001,
            "metadata constraints overlapped at \(cardWidth)pt"
        )
        try expect(
            subviews.allSatisfy { view in
                [view.frame.minX, view.frame.maxX, view.frame.width].allSatisfy(\.isFinite)
            },
            "narrow card produced non-finite AppKit geometry"
        )
    }

    private static func thumbnailPlan(_ input: PreviewLayoutInput) throws -> PreviewLayoutPlan {
        guard case .thumbnails(let plan) = PreviewLayoutPlanner.plan(input) else {
            throw TestFailure(description: "expected thumbnail plan")
        }
        return plan
    }

    private static func cardSize(
        item: PreviewLayoutItem,
        imageHeight: CGFloat,
        metrics: PreviewLayoutMetrics
    ) -> NSSize {
        let aspect = min(metrics.maximumAspectRatio, max(metrics.minimumAspectRatio, item.aspectRatio))
        return NSSize(
            width: max(
                metrics.minimumCardWidth,
                min(metrics.maximumImageWidth, imageHeight * aspect) + metrics.cardHorizontalPadding * 2
            ),
            height: imageHeight + metrics.cardVerticalChrome + metrics.cardVerticalPadding * 2
        )
    }

    private static func verticalStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .centerX
        return stack
    }

    private static func testRow(ids: [UInt32], cardSize: NSSize) -> NSStackView {
        PreviewPresentationLayout.makePreviewRow(views: ids.map {
            TestItemView(itemID: $0, size: cardSize)
        })
    }

    private static func groupedFixtureRow(
        _ row: PreviewLayoutGroupRow,
        groupSpacing: CGFloat
    ) -> NSStackView {
        let groupViews = row.groups.map(TestGroupFixtureView.init)
        let stack = NSStackView(views: groupViews)
        stack.orientation = .horizontal
        stack.spacing = groupSpacing
        stack.alignment = .top
        return stack
    }

    private static func verifyAutoGeometry(
        stack: NSStackView,
        plan: PreviewLayoutPlan,
        panelPadding: CGFloat
    ) throws {
        stack.frame = NSRect(origin: .zero, size: plan.contentSize)
        stack.layoutSubtreeIfNeeded()
        try expectSizeNear(stack.fittingSize, plan.contentSize)

        let panelSize = NSSize(
            width: stack.fittingSize.width + panelPadding * 2,
            height: stack.fittingSize.height + panelPadding * 2
        )
        try expectSizeNear(panelSize, plan.panelSize)
        let plannedRows = arrangementRows(plan.arrangement)
        try expectEqual(stack.arrangedSubviews.count, plannedRows.count)
        for (container, rowSize) in zip(stack.arrangedSubviews, plannedRows) {
            guard let row = container.subviews.compactMap({ $0 as? NSStackView }).first else {
                throw TestFailure(description: "Auto row container is missing its stack")
            }
            try expectSizeNear(row.fittingSize, rowSize)
        }
    }

    private static func arrangementRows(_ arrangement: PreviewLayoutArrangement) -> [NSSize] {
        switch arrangement {
        case .rows(let rows):
            return rows.map(\.size)
        case .groupRows(let rows):
            return rows.map(\.size)
        }
    }

    private static func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        var matches = view as? T == nil ? [] : [view as! T]
        for subview in view.subviews {
            matches.append(contentsOf: descendants(of: type, in: subview))
        }
        return matches
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw TestFailure(description: message) }
        return value
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
        tolerance: CGFloat = 0.001
    ) throws {
        try expect(
            abs(actual - expected) <= tolerance,
            "expected \(expected), got \(actual)"
        )
    }

    private static func expectSizeNear(
        _ actual: NSSize,
        _ expected: NSSize,
        tolerance: CGFloat = 0.001
    ) throws {
        try expect(
            abs(actual.width - expected.width) <= tolerance &&
                abs(actual.height - expected.height) <= tolerance,
            "expected size \(expected), got \(actual)"
        )
    }
}

private final class TestItemView: NSView {
    let itemID: UInt32
    private let itemSize: NSSize

    init(itemID: UInt32, size: NSSize) {
        self.itemID = itemID
        itemSize = size
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        itemSize
    }
}

private final class TestGroupFixtureView: NSView {
    private let plannedSize: NSSize

    init(plan: PreviewLayoutGroupPlan) {
        plannedSize = plan.size
        super.init(frame: NSRect(origin: .zero, size: plan.size))
        let itemIDs = plan.itemRows.flatMap(\.itemIDs)
        itemIDs.forEach { itemID in
            addSubview(TestItemView(itemID: itemID, size: NSSize(width: 1, height: 1)))
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        plannedSize
    }
}
