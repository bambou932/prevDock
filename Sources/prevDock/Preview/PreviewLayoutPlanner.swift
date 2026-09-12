import CoreGraphics
import Foundation

struct PreviewLayoutItem: Equatable {
    let id: UInt32
    let aspectRatio: CGFloat
}

enum PreviewLayoutGroupID: Hashable {
    case desktop(UInt64)
    case unassigned
}

enum PreviewPanelDockEdge: CaseIterable {
    case bottom
    case top
    case left
    case right
}

enum PreviewPanelAvailableSpace {
    static func size(
        visibleFrame: CGRect,
        screenFrame: CGRect,
        dockAnchor: CGRect,
        dockEdge: PreviewPanelDockEdge,
        edgeInset: CGFloat = 10,
        dockGap: CGFloat = 4
    ) -> CGSize {
        guard isValid(frame: visibleFrame),
              isValid(frame: screenFrame),
              isValid(anchor: dockAnchor),
              isFiniteNonnegative(edgeInset),
              isFiniteNonnegative(dockGap) else {
            return .zero
        }

        let bounds = visibleFrame.intersection(screenFrame)
        guard !bounds.isNull,
              bounds.width >= edgeInset * 2,
              bounds.height >= edgeInset * 2 else {
            return .zero
        }

        let minimumX = bounds.minX + edgeInset
        let maximumX = bounds.maxX - edgeInset
        let minimumY = bounds.minY + edgeInset
        let maximumY = bounds.maxY - edgeInset
        switch dockEdge {
        case .bottom:
            let panelMinimumY = max(minimumY, dockAnchor.maxY + dockGap)
            return CGSize(width: maximumX - minimumX, height: max(0, maximumY - panelMinimumY))
        case .top:
            let panelMaximumY = min(maximumY, dockAnchor.minY - dockGap)
            return CGSize(width: maximumX - minimumX, height: max(0, panelMaximumY - minimumY))
        case .left:
            let panelMinimumX = max(minimumX, dockAnchor.maxX + dockGap)
            return CGSize(width: max(0, maximumX - panelMinimumX), height: maximumY - minimumY)
        case .right:
            let panelMaximumX = min(maximumX, dockAnchor.minX - dockGap)
            return CGSize(width: max(0, panelMaximumX - minimumX), height: maximumY - minimumY)
        }
    }

    private static func isValid(frame: CGRect) -> Bool {
        frame.origin.x.isFinite &&
            frame.origin.y.isFinite &&
            frame.width.isFinite &&
            frame.height.isFinite &&
            frame.width > 0 &&
            frame.height > 0
    }

    private static func isValid(anchor: CGRect) -> Bool {
        anchor.origin.x.isFinite &&
            anchor.origin.y.isFinite &&
            anchor.width.isFinite &&
            anchor.height.isFinite &&
            anchor.width >= 0 &&
            anchor.height >= 0
    }

    private static func isFiniteNonnegative(_ value: CGFloat) -> Bool {
        value.isFinite && value >= 0
    }
}

struct PreviewLayoutGroup: Equatable {
    let id: PreviewLayoutGroupID
    let items: [PreviewLayoutItem]
    let headerSize: CGSize?
}

enum PreviewLayoutContent: Equatable {
    case ungrouped([PreviewLayoutItem])
    case grouped([PreviewLayoutGroup])
}

struct PreviewLayoutMetrics: Equatable {
    let panelPadding: CGFloat
    let cardHorizontalPadding: CGFloat
    let cardVerticalPadding: CGFloat
    let cardVerticalChrome: CGFloat
    let itemSpacing: CGFloat
    let rowSpacing: CGFloat
    let groupPadding: CGFloat
    let groupSpacing: CGFloat
    let groupHeaderSpacing: CGFloat
    let minimumCardWidth: CGFloat
    let maximumImageWidth: CGFloat
    let minimumAspectRatio: CGFloat
    let maximumAspectRatio: CGFloat

    init(
        panelPadding: CGFloat = 6,
        cardHorizontalPadding: CGFloat = 6,
        cardVerticalPadding: CGFloat = 6,
        cardVerticalChrome: CGFloat = 30,
        itemSpacing: CGFloat = 0,
        rowSpacing: CGFloat = 0,
        groupPadding: CGFloat = 5,
        groupSpacing: CGFloat = 8,
        groupHeaderSpacing: CGFloat = 4,
        minimumCardWidth: CGFloat = 59,
        maximumImageWidth: CGFloat = 520,
        minimumAspectRatio: CGFloat = 0.30,
        maximumAspectRatio: CGFloat = 3.15
    ) {
        self.panelPadding = panelPadding
        self.cardHorizontalPadding = cardHorizontalPadding
        self.cardVerticalPadding = cardVerticalPadding
        self.cardVerticalChrome = cardVerticalChrome
        self.itemSpacing = itemSpacing
        self.rowSpacing = rowSpacing
        self.groupPadding = groupPadding
        self.groupSpacing = groupSpacing
        self.groupHeaderSpacing = groupHeaderSpacing
        self.minimumCardWidth = minimumCardWidth
        self.maximumImageWidth = maximumImageWidth
        self.minimumAspectRatio = minimumAspectRatio
        self.maximumAspectRatio = maximumAspectRatio
    }
}

struct PreviewLayoutInput: Equatable {
    let content: PreviewLayoutContent
    let preferredImageHeight: CGFloat
    let minimumImageHeight: CGFloat
    let availablePanelSize: CGSize
    let backingScale: CGFloat
    let metrics: PreviewLayoutMetrics

    init(
        content: PreviewLayoutContent,
        preferredImageHeight: CGFloat,
        minimumImageHeight: CGFloat = 96,
        availablePanelSize: CGSize,
        backingScale: CGFloat,
        metrics: PreviewLayoutMetrics = PreviewLayoutMetrics()
    ) {
        self.content = content
        self.preferredImageHeight = preferredImageHeight
        self.minimumImageHeight = minimumImageHeight
        self.availablePanelSize = availablePanelSize
        self.backingScale = backingScale
        self.metrics = metrics
    }
}

enum PreviewLayoutDecision: Equatable {
    case thumbnails(PreviewLayoutPlan)
    case compactList
}

struct PreviewLayoutPlan: Equatable {
    let imageHeight: CGFloat
    let arrangement: PreviewLayoutArrangement
    let contentSize: CGSize
    let panelSize: CGSize

    var itemIDs: [UInt32] {
        arrangement.itemIDs
    }
}

struct PreviewLayoutShapeSignature: Equatable {
    let imageHeight: CGFloat
    let contentSize: CGSize
    let panelSize: CGSize
    let arrangement: Arrangement

    enum Arrangement: Equatable {
        case rows([Row])
        case groupRows([GroupRow])
    }

    struct Row: Equatable {
        let itemCount: Int
        let height: CGFloat
    }

    struct GroupRow: Equatable {
        let groups: [Group]
        let size: CGSize
    }

    struct Group: Equatable {
        let id: PreviewLayoutGroupID
        let itemRows: [Row]
        let size: CGSize
    }
}

extension PreviewLayoutPlan {
    func shapeSignature(excluding excludedItemIDs: Set<UInt32> = []) -> PreviewLayoutShapeSignature {
        let signatureArrangement: PreviewLayoutShapeSignature.Arrangement
        switch arrangement {
        case .rows(let rows):
            signatureArrangement = .rows(rowSignatures(in: rows, excluding: excludedItemIDs))
        case .groupRows(let rows):
            let groupRows = rows.map { row in
                let groups = row.groups.map { group in
                    PreviewLayoutShapeSignature.Group(
                        id: group.id,
                        itemRows: rowSignatures(in: group.itemRows, excluding: excludedItemIDs),
                        size: group.size
                    )
                }
                return PreviewLayoutShapeSignature.GroupRow(groups: groups, size: row.size)
            }
            signatureArrangement = .groupRows(groupRows)
        }
        return PreviewLayoutShapeSignature(
            imageHeight: imageHeight,
            contentSize: contentSize,
            panelSize: panelSize,
            arrangement: signatureArrangement
        )
    }

    private func rowSignatures(
        in rows: [PreviewLayoutRow],
        excluding excludedItemIDs: Set<UInt32>
    ) -> [PreviewLayoutShapeSignature.Row] {
        rows.map { row in
            PreviewLayoutShapeSignature.Row(
                itemCount: row.itemIDs.filter { !excludedItemIDs.contains($0) }.count,
                height: row.size.height
            )
        }
    }
}

enum PreviewLayoutArrangement: Equatable {
    case rows([PreviewLayoutRow])
    case groupRows([PreviewLayoutGroupRow])

    fileprivate var itemIDs: [UInt32] {
        switch self {
        case .rows(let rows):
            return rows.flatMap(\.itemIDs)
        case .groupRows(let rows):
            return rows.flatMap { row in
                row.groups.flatMap { $0.itemRows.flatMap(\.itemIDs) }
            }
        }
    }
}

struct PreviewLayoutRow: Equatable {
    let itemIDs: [UInt32]
    let size: CGSize
}

struct PreviewLayoutGroupRow: Equatable {
    let groups: [PreviewLayoutGroupPlan]
    let size: CGSize
}

struct PreviewLayoutGroupPlan: Equatable {
    let id: PreviewLayoutGroupID
    let itemRows: [PreviewLayoutRow]
    let size: CGSize
}

enum PreviewLayoutPlanner {
    private static let geometryEpsilon: CGFloat = 0.000_001

    static func plan(_ input: PreviewLayoutInput) -> PreviewLayoutDecision {
        guard isValid(input),
              let pixelRange = imageHeightPixelRange(for: input) else {
            return .compactList
        }

        var plans = [Int: PreviewLayoutPlan]()
        func plan(at pixelHeight: Int) -> PreviewLayoutPlan {
            if let cached = plans[pixelHeight] { return cached }
            let plan = makePlan(for: input, imageHeight: CGFloat(pixelHeight) / input.backingScale)
            plans[pixelHeight] = plan
            return plan
        }
        func candidateFits(_ pixelHeight: Int) -> Bool {
            fits(plan(at: pixelHeight), in: input.availablePanelSize)
        }

        guard candidateFits(pixelRange.lowerBound) else { return .compactList }

        var lower = pixelRange.lowerBound
        var upper = pixelRange.upperBound
        while lower < upper {
            let middle = lower + (upper - lower + 1) / 2
            if candidateFits(middle) {
                lower = middle
            } else {
                upper = middle - 1
            }
        }

        // Single-row card widths and heights never increase as image height decreases.
        // The fit predicate is therefore monotonic and binary search is exact.
        let selectedPlan = plan(at: lower)
        guard isCertified(selectedPlan, for: input.content) else {
            return .compactList
        }
        return .thumbnails(selectedPlan)
    }

    private static func makePlan(for input: PreviewLayoutInput, imageHeight: CGFloat) -> PreviewLayoutPlan {
        let arrangement: PreviewLayoutArrangement
        let contentSize: CGSize

        switch input.content {
        case .ungrouped(let items):
            let rows = makeSingleRow(items: items, imageHeight: imageHeight, metrics: input.metrics)
            arrangement = .rows(rows)
            contentSize = stackedSize(rows: rows, spacing: input.metrics.rowSpacing)
        case .grouped(let groups):
            let rows = makeSingleGroupRow(groups: groups, imageHeight: imageHeight, metrics: input.metrics)
            arrangement = .groupRows(rows)
            contentSize = stackedGroupSize(rows: rows, spacing: input.metrics.groupSpacing)
        }

        let panelChrome = input.metrics.panelPadding * 2
        return PreviewLayoutPlan(
            imageHeight: imageHeight,
            arrangement: arrangement,
            contentSize: contentSize,
            panelSize: CGSize(width: contentSize.width + panelChrome, height: contentSize.height + panelChrome)
        )
    }

    private static func makeSingleRow(
        items: [PreviewLayoutItem],
        imageHeight: CGFloat,
        metrics: PreviewLayoutMetrics
    ) -> [PreviewLayoutRow] {
        guard !items.isEmpty else { return [] }
        let cardHeight = imageHeight + metrics.cardVerticalChrome + metrics.cardVerticalPadding * 2
        let cardWidths = items.map { width(for: $0, imageHeight: imageHeight, metrics: metrics) }
        let spacing = CGFloat(max(0, items.count - 1)) * metrics.itemSpacing
        return [PreviewLayoutRow(
            itemIDs: items.map(\.id),
            size: CGSize(width: cardWidths.reduce(0, +) + spacing, height: cardHeight)
        )]
    }

    private static func makeSingleGroupRow(
        groups: [PreviewLayoutGroup],
        imageHeight: CGFloat,
        metrics: PreviewLayoutMetrics
    ) -> [PreviewLayoutGroupRow] {
        guard !groups.isEmpty else { return [] }
        let plans = groups.map { group in
            makeGroupPlan(
                group: group,
                rows: makeSingleRow(items: group.items, imageHeight: imageHeight, metrics: metrics),
                metrics: metrics
            )
        }
        let spacing = CGFloat(max(0, plans.count - 1)) * metrics.groupSpacing
        let size = CGSize(
            width: plans.map(\.size.width).reduce(0, +) + spacing,
            height: plans.map(\.size.height).max() ?? 0
        )
        return [PreviewLayoutGroupRow(groups: plans, size: size)]
    }

    private static func makeGroupPlan(
        group: PreviewLayoutGroup,
        rows: [PreviewLayoutRow],
        metrics: PreviewLayoutMetrics
    ) -> PreviewLayoutGroupPlan {
        let rowsSize = stackedSize(rows: rows, spacing: metrics.rowSpacing)
        let headerWidth = group.headerSize?.width ?? 0
        let headerHeight = group.headerSize?.height ?? 0
        let headerSpacing = group.headerSize == nil || rows.isEmpty ? 0 : metrics.groupHeaderSpacing
        let groupChrome = metrics.groupPadding * 2
        return PreviewLayoutGroupPlan(
            id: group.id,
            itemRows: rows,
            size: CGSize(
                width: max(rowsSize.width, headerWidth) + groupChrome,
                height: rowsSize.height + headerHeight + headerSpacing + groupChrome
            )
        )
    }

    private static func stackedSize(rows: [PreviewLayoutRow], spacing: CGFloat) -> CGSize {
        CGSize(
            width: rows.map(\.size.width).max() ?? 0,
            height: rows.map(\.size.height).reduce(0, +) + CGFloat(max(0, rows.count - 1)) * spacing
        )
    }

    private static func stackedGroupSize(rows: [PreviewLayoutGroupRow], spacing: CGFloat) -> CGSize {
        CGSize(
            width: rows.map(\.size.width).max() ?? 0,
            height: rows.map(\.size.height).reduce(0, +) + CGFloat(max(0, rows.count - 1)) * spacing
        )
    }

    private static func width(
        for item: PreviewLayoutItem,
        imageHeight: CGFloat,
        metrics: PreviewLayoutMetrics
    ) -> CGFloat {
        let aspectRatio = min(metrics.maximumAspectRatio, max(metrics.minimumAspectRatio, item.aspectRatio))
        let imageWidth = min(metrics.maximumImageWidth, imageHeight * aspectRatio)
        return max(metrics.minimumCardWidth, imageWidth + metrics.cardHorizontalPadding * 2)
    }

    private static func fits(_ plan: PreviewLayoutPlan, in availableSize: CGSize) -> Bool {
        plan.panelSize.width <= availableSize.width + geometryEpsilon &&
            plan.panelSize.height <= availableSize.height + geometryEpsilon
    }

    private static func isCertified(
        _ plan: PreviewLayoutPlan,
        for content: PreviewLayoutContent
    ) -> Bool {
        guard isFinitePositive(plan.imageHeight),
              isValid(size: plan.contentSize),
              isValid(size: plan.panelSize) else {
            return false
        }

        switch (content, plan.arrangement) {
        case (.ungrouped(let expectedItems), .rows(let rows)):
            let expectedRowCount = expectedItems.isEmpty ? 0 : 1
            guard rows.count == expectedRowCount,
                  rows.allSatisfy({ isValid(size: $0.size) }) else {
                return false
            }
            return rows.flatMap(\.itemIDs) == expectedItems.map(\.id)
        case (.grouped(let expectedGroups), .groupRows(let rows)):
            let expectedRowCount = expectedGroups.isEmpty ? 0 : 1
            guard rows.count == expectedRowCount,
                  rows.allSatisfy({ row in
                isValid(size: row.size) && row.groups.allSatisfy { group in
                    isValid(size: group.size) && group.itemRows.allSatisfy { isValid(size: $0.size) }
                }
            }) else {
                return false
            }
            let actualGroups = rows.flatMap(\.groups)
            guard actualGroups.count == expectedGroups.count else { return false }
            for (expected, actual) in zip(expectedGroups, actualGroups) {
                guard expected.id == actual.id,
                      actual.itemRows.count == (expected.items.isEmpty ? 0 : 1),
                      actual.itemRows.flatMap(\.itemIDs) == expected.items.map(\.id) else {
                    return false
                }
            }
            return true
        default:
            return false
        }
    }

    private static func imageHeightPixelRange(for input: PreviewLayoutInput) -> ClosedRange<Int>? {
        let minimumPixelsValue = ceil(input.minimumImageHeight * input.backingScale)
        let preferredPixelsValue = floor(input.preferredImageHeight * input.backingScale)
        guard minimumPixelsValue <= preferredPixelsValue,
              let minimumPixels = Int(exactly: minimumPixelsValue),
              let preferredPixels = Int(exactly: preferredPixelsValue) else {
            return nil
        }
        return minimumPixels...preferredPixels
    }

    private static func isValid(_ input: PreviewLayoutInput) -> Bool {
        guard isFinitePositive(input.preferredImageHeight),
              isFinitePositive(input.minimumImageHeight),
              isFinitePositive(input.backingScale),
              isFiniteNonnegative(input.availablePanelSize.width),
              isFiniteNonnegative(input.availablePanelSize.height),
              isValid(input.metrics) else {
            return false
        }

        switch input.content {
        case .ungrouped(let items):
            return hasValidUniqueItems(items)
        case .grouped(let groups):
            let groupIDs = groups.map(\.id)
            let items = groups.flatMap(\.items)
            return Set(groupIDs).count == groupIDs.count &&
                groups.allSatisfy { $0.headerSize.map(isValid(size:)) ?? true } &&
                hasValidUniqueItems(items)
        }
    }

    private static func isValid(_ metrics: PreviewLayoutMetrics) -> Bool {
        let nonnegativeValues = [
            metrics.panelPadding,
            metrics.cardHorizontalPadding,
            metrics.cardVerticalPadding,
            metrics.cardVerticalChrome,
            metrics.itemSpacing,
            metrics.rowSpacing,
            metrics.groupPadding,
            metrics.groupSpacing,
            metrics.groupHeaderSpacing
        ]
        return nonnegativeValues.allSatisfy(isFiniteNonnegative) &&
            isFinitePositive(metrics.minimumCardWidth) &&
            isFinitePositive(metrics.maximumImageWidth) &&
            isFinitePositive(metrics.minimumAspectRatio) &&
            metrics.maximumAspectRatio.isFinite &&
            metrics.maximumAspectRatio >= metrics.minimumAspectRatio
    }

    private static func hasValidUniqueItems(_ items: [PreviewLayoutItem]) -> Bool {
        let itemIDs = items.map(\.id)
        return Set(itemIDs).count == itemIDs.count &&
            items.allSatisfy { isFinitePositive($0.aspectRatio) }
    }

    private static func isValid(size: CGSize) -> Bool {
        isFiniteNonnegative(size.width) && isFiniteNonnegative(size.height)
    }

    private static func isFinitePositive(_ value: CGFloat) -> Bool {
        value.isFinite && value > 0
    }

    private static func isFiniteNonnegative(_ value: CGFloat) -> Bool {
        value.isFinite && value >= 0
    }
}


struct PreviewCompactListPlan: Equatable {
    let rowHeight: CGFloat
    let rowWidth: CGFloat
    let contentSize: CGSize
    let viewportSize: CGSize
    let panelSize: CGSize
    let needsScroll: Bool

    static func make(
        itemCount: Int,
        rowHeight: CGFloat,
        preferredWidth: CGFloat,
        availablePanelSize: CGSize,
        panelPadding: CGFloat,
        scrollerWidth: CGFloat
    ) -> PreviewCompactListPlan {
        let chrome = panelPadding * 2
        let availableWidth = max(1, availablePanelSize.width - chrome)
        let availableHeight = max(1, availablePanelSize.height - chrome)
        let contentHeight = CGFloat(max(0, itemCount)) * rowHeight
        // Whole rows make the number of reachable windows clear without cutting a title in half.
        let visibleRows = min(12, max(1, floor(availableHeight / rowHeight)))
        let viewportHeight = min(contentHeight, availableHeight, visibleRows * rowHeight)
        let needsScroll = contentHeight > viewportHeight
        let viewportWidth = min(preferredWidth, availableWidth)
        let rowWidth = max(1, viewportWidth - (needsScroll ? scrollerWidth : 0))
        return PreviewCompactListPlan(
            rowHeight: rowHeight,
            rowWidth: rowWidth,
            contentSize: CGSize(width: rowWidth, height: contentHeight),
            viewportSize: CGSize(width: viewportWidth, height: viewportHeight),
            panelSize: CGSize(width: viewportWidth + chrome, height: viewportHeight + chrome),
            needsScroll: needsScroll
        )
    }
}
