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
    case nativeDockMenu
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

    private struct GroupRowOption {
        let maximumHeight: CGFloat
        let size: CGSize
    }

    private struct GroupRowOptions {
        private let stride: Int
        private var values: [GroupRowOption?]

        init(groupCount: Int) {
            stride = groupCount + 1
            values = [GroupRowOption?](repeating: nil, count: stride * stride)
        }

        subscript(start: Int, end: Int) -> GroupRowOption? {
            get { values[start * stride + end] }
            set { values[start * stride + end] = newValue }
        }
    }

    private struct PackedGroupRowsState {
        let size: CGSize
        let rowCount: Int
        let previousGroupIndex: Int
    }

    static func plan(_ input: PreviewLayoutInput) -> PreviewLayoutDecision {
        guard isValid(input),
              let pixelRange = imageHeightPixelRange(for: input) else {
            return .nativeDockMenu
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

        guard candidateFits(pixelRange.lowerBound) else { return .nativeDockMenu }

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

        // Every ordered partition considered at a larger height remains no larger at a lower height.
        // The globally optimized fit predicate is therefore monotonic and binary search is exact.
        let selectedPlan = plan(at: lower)
        guard isCertified(selectedPlan, for: input.content) else {
            return .nativeDockMenu
        }
        return .thumbnails(selectedPlan)
    }

    private static func makePlan(for input: PreviewLayoutInput, imageHeight: CGFloat) -> PreviewLayoutPlan {
        let availableContentWidth = max(0, input.availablePanelSize.width - input.metrics.panelPadding * 2)
        let arrangement: PreviewLayoutArrangement
        let contentSize: CGSize

        switch input.content {
        case .ungrouped(let items):
            let rows = makeRows(
                items: items,
                imageHeight: imageHeight,
                availableWidth: availableContentWidth,
                metrics: input.metrics
            )
            arrangement = .rows(rows)
            contentSize = stackedSize(rows: rows, spacing: input.metrics.rowSpacing)
        case .grouped(let groups):
            let rows = makeGroupRows(
                groups: groups,
                imageHeight: imageHeight,
                availableWidth: availableContentWidth,
                metrics: input.metrics
            )
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

    private static func makeRows(
        items: [PreviewLayoutItem],
        imageHeight: CGFloat,
        availableWidth: CGFloat,
        metrics: PreviewLayoutMetrics
    ) -> [PreviewLayoutRow] {
        var rows = [PreviewLayoutRow]()
        var itemIDs = [UInt32]()
        var rowWidth: CGFloat = 0
        let cardHeight = imageHeight + metrics.cardVerticalChrome + metrics.cardVerticalPadding * 2

        for item in items {
            let cardWidth = width(for: item, imageHeight: imageHeight, metrics: metrics)
            let proposedWidth = itemIDs.isEmpty ? cardWidth : rowWidth + metrics.itemSpacing + cardWidth
            if !itemIDs.isEmpty && proposedWidth > availableWidth + geometryEpsilon {
                rows.append(PreviewLayoutRow(itemIDs: itemIDs, size: CGSize(width: rowWidth, height: cardHeight)))
                itemIDs = [item.id]
                rowWidth = cardWidth
            } else {
                itemIDs.append(item.id)
                rowWidth = proposedWidth
            }
        }

        if !itemIDs.isEmpty {
            rows.append(PreviewLayoutRow(itemIDs: itemIDs, size: CGSize(width: rowWidth, height: cardHeight)))
        }
        return rows
    }

    private static func makeGroupRows(
        groups: [PreviewLayoutGroup],
        imageHeight: CGFloat,
        availableWidth: CGFloat,
        metrics: PreviewLayoutMetrics
    ) -> [PreviewLayoutGroupRow] {
        let variantsByGroup = groups.map {
            groupPlanVariants(group: $0, imageHeight: imageHeight, metrics: metrics)
        }
        if let rows = optimallyPackedGroupRows(
            variantsByGroup: variantsByGroup,
            availableWidth: availableWidth,
            metrics: metrics
        ) {
            return rows
        }

        let narrowestPlans = variantsByGroup.compactMap { narrowestGroupPlan(in: $0) }
        return greedilyPackedGroupRows(
            plans: narrowestPlans,
            availableWidth: availableWidth,
            spacing: metrics.groupSpacing
        )
    }

    private static func groupPlanVariants(
        group: PreviewLayoutGroup,
        imageHeight: CGFloat,
        metrics: PreviewLayoutMetrics
    ) -> [PreviewLayoutGroupPlan] {
        guard !group.items.isEmpty else {
            return [makeGroupPlan(group: group, rows: [], metrics: metrics)]
        }

        if group.items.count == 1, let item = group.items.first {
            let row = PreviewLayoutRow(
                itemIDs: [item.id],
                size: CGSize(
                    width: width(for: item, imageHeight: imageHeight, metrics: metrics),
                    height: imageHeight + metrics.cardVerticalChrome + metrics.cardVerticalPadding * 2
                )
            )
            return [makeGroupPlan(group: group, rows: [row], metrics: metrics)]
        }

        let widths = group.items.map { width(for: $0, imageHeight: imageHeight, metrics: metrics) }
        let rowVariants = minimumWidthRowVariants(
            items: group.items,
            itemWidths: widths,
            cardHeight: imageHeight + metrics.cardVerticalChrome + metrics.cardVerticalPadding * 2,
            spacing: metrics.itemSpacing
        )
        var plans = [PreviewLayoutGroupPlan]()
        var narrowestWidth = CGFloat.greatestFiniteMagnitude
        for rows in rowVariants {
            let plan = makeGroupPlan(group: group, rows: rows, metrics: metrics)
            guard plan.size.width < narrowestWidth - geometryEpsilon else { continue }
            plans.append(plan)
            narrowestWidth = plan.size.width
        }
        return plans
    }

    private static func minimumWidthRowVariants(
        items: [PreviewLayoutItem],
        itemWidths: [CGFloat],
        cardHeight: CGFloat,
        spacing: CGFloat
    ) -> [[PreviewLayoutRow]] {
        let count = items.count
        var prefixWidths = [CGFloat](repeating: 0, count: count + 1)
        for index in 0..<count {
            prefixWidths[index + 1] = prefixWidths[index] + itemWidths[index]
        }

        var costs = Array(
            repeating: [CGFloat](repeating: .greatestFiniteMagnitude, count: count + 1),
            count: count + 1
        )
        var previous = Array(repeating: [Int](repeating: -1, count: count + 1), count: count + 1)
        costs[0][0] = 0
        for rowCount in 1...count {
            for end in rowCount...count {
                for start in (rowCount - 1)..<end {
                    let priorCost = costs[rowCount - 1][start]
                    guard priorCost < .greatestFiniteMagnitude else { continue }
                    let width = itemRowWidth(
                        prefixWidths: prefixWidths,
                        start: start,
                        end: end,
                        spacing: spacing
                    )
                    let candidate = max(priorCost, width)
                    if candidate < costs[rowCount][end] - geometryEpsilon ||
                        (abs(candidate - costs[rowCount][end]) <= geometryEpsilon && start > previous[rowCount][end]) {
                        costs[rowCount][end] = candidate
                        previous[rowCount][end] = start
                    }
                }
            }
        }

        return (1...count).map { rowCount in
            reconstructedRows(
                items: items,
                prefixWidths: prefixWidths,
                previous: previous,
                rowCount: rowCount,
                cardHeight: cardHeight,
                spacing: spacing
            )
        }
    }

    private static func reconstructedRows(
        items: [PreviewLayoutItem],
        prefixWidths: [CGFloat],
        previous: [[Int]],
        rowCount: Int,
        cardHeight: CGFloat,
        spacing: CGFloat
    ) -> [PreviewLayoutRow] {
        var ranges = [Range<Int>]()
        var end = items.count
        for currentRow in stride(from: rowCount, through: 1, by: -1) {
            let start = previous[currentRow][end]
            guard start >= 0 else { return [] }
            ranges.append(start..<end)
            end = start
        }
        return ranges.reversed().map { range in
            PreviewLayoutRow(
                itemIDs: range.map { items[$0].id },
                size: CGSize(
                    width: itemRowWidth(
                        prefixWidths: prefixWidths,
                        start: range.lowerBound,
                        end: range.upperBound,
                        spacing: spacing
                    ),
                    height: cardHeight
                )
            )
        }
    }

    private static func itemRowWidth(
        prefixWidths: [CGFloat],
        start: Int,
        end: Int,
        spacing: CGFloat
    ) -> CGFloat {
        prefixWidths[end] - prefixWidths[start] + CGFloat(max(0, end - start - 1)) * spacing
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

    private static func optimallyPackedGroupRows(
        variantsByGroup: [[PreviewLayoutGroupPlan]],
        availableWidth: CGFloat,
        metrics: PreviewLayoutMetrics
    ) -> [PreviewLayoutGroupRow]? {
        guard !variantsByGroup.isEmpty else { return [] }
        let rowOptions = groupRowOptions(
            variantsByGroup: variantsByGroup,
            availableWidth: availableWidth,
            spacing: metrics.groupSpacing
        )
        var best = [PackedGroupRowsState?](repeating: nil, count: variantsByGroup.count + 1)
        best[0] = PackedGroupRowsState(size: .zero, rowCount: 0, previousGroupIndex: -1)

        for end in 1...variantsByGroup.count {
            for start in 0..<end {
                guard let prefix = best[start],
                      let row = rowOptions[start, end] else {
                    continue
                }
                let spacing = prefix.rowCount == 0 ? 0 : metrics.groupSpacing
                let candidate = PackedGroupRowsState(
                    size: CGSize(
                        width: max(prefix.size.width, row.size.width),
                        height: prefix.size.height + spacing + row.size.height
                    ),
                    rowCount: prefix.rowCount + 1,
                    previousGroupIndex: start
                )
                if isBetter(candidate, than: best[end]) {
                    best[end] = candidate
                }
            }
        }
        return reconstructedGroupRows(
            variantsByGroup: variantsByGroup,
            rowOptions: rowOptions,
            states: best
        )
    }

    private static func groupRowOptions(
        variantsByGroup: [[PreviewLayoutGroupPlan]],
        availableWidth: CGFloat,
        spacing: CGFloat
    ) -> GroupRowOptions {
        if variantsByGroup.allSatisfy({ $0.count == 1 }) {
            return singleVariantGroupRowOptions(
                variantsByGroup: variantsByGroup,
                availableWidth: availableWidth,
                spacing: spacing
            )
        }

        let count = variantsByGroup.count
        let candidateHeights = uniqueSortedHeights(in: variantsByGroup)
        var options = GroupRowOptions(groupCount: count)
        for start in 0..<count {
            for end in (start + 1)...count {
                options[start, end] = bestGroupRowOption(
                    variantsByGroup: variantsByGroup,
                    start: start,
                    end: end,
                    candidateHeights: candidateHeights,
                    availableWidth: availableWidth,
                    spacing: spacing
                )
            }
        }
        return options
    }

    private static func singleVariantGroupRowOptions(
        variantsByGroup: [[PreviewLayoutGroupPlan]],
        availableWidth: CGFloat,
        spacing: CGFloat
    ) -> GroupRowOptions {
        var options = GroupRowOptions(groupCount: variantsByGroup.count)
        for start in variantsByGroup.indices {
            var width: CGFloat = 0
            var height: CGFloat = 0
            for index in start..<variantsByGroup.count {
                let plan = variantsByGroup[index][0]
                width += (index == start ? 0 : spacing) + plan.size.width
                guard width <= availableWidth + geometryEpsilon else { break }
                height = max(height, plan.size.height)
                options[start, index + 1] = GroupRowOption(
                    maximumHeight: height,
                    size: CGSize(width: width, height: height)
                )
            }
        }
        return options
    }

    private static func bestGroupRowOption(
        variantsByGroup: [[PreviewLayoutGroupPlan]],
        start: Int,
        end: Int,
        candidateHeights: [CGFloat],
        availableWidth: CGFloat,
        spacing: CGFloat
    ) -> GroupRowOption? {
        for maximumHeight in candidateHeights {
            var width: CGFloat = 0
            var height: CGFloat = 0
            var isComplete = true
            for groupIndex in start..<end {
                guard let plan = narrowestGroupPlan(
                    in: variantsByGroup[groupIndex],
                    maximumHeight: maximumHeight
                ) else {
                    isComplete = false
                    break
                }
                width += (groupIndex == start ? 0 : spacing) + plan.size.width
                height = max(height, plan.size.height)
            }
            guard isComplete else { continue }
            guard width <= availableWidth + geometryEpsilon else { continue }
            return GroupRowOption(
                maximumHeight: maximumHeight,
                size: CGSize(width: width, height: height)
            )
        }
        return nil
    }

    private static func reconstructedGroupRows(
        variantsByGroup: [[PreviewLayoutGroupPlan]],
        rowOptions: GroupRowOptions,
        states: [PackedGroupRowsState?]
    ) -> [PreviewLayoutGroupRow]? {
        var rows = [PreviewLayoutGroupRow]()
        var end = variantsByGroup.count
        while end > 0 {
            guard let state = states[end],
                  state.previousGroupIndex >= 0,
                  let option = rowOptions[state.previousGroupIndex, end] else {
                return nil
            }
            var plans = [PreviewLayoutGroupPlan]()
            plans.reserveCapacity(end - state.previousGroupIndex)
            for index in state.previousGroupIndex..<end {
                guard let plan = narrowestGroupPlan(
                    in: variantsByGroup[index],
                    maximumHeight: option.maximumHeight
                ) else {
                    return nil
                }
                plans.append(plan)
            }
            rows.append(PreviewLayoutGroupRow(groups: plans, size: option.size))
            end = state.previousGroupIndex
        }
        return rows.reversed()
    }

    private static func uniqueSortedHeights(
        in variantsByGroup: [[PreviewLayoutGroupPlan]]
    ) -> [CGFloat] {
        let sorted = variantsByGroup.flatMap { $0.map(\.size.height) }.sorted()
        var result = [CGFloat]()
        for height in sorted where result.last.map({ abs($0 - height) > geometryEpsilon }) ?? true {
            result.append(height)
        }
        return result
    }

    private static func narrowestGroupPlan(
        in variants: [PreviewLayoutGroupPlan],
        maximumHeight: CGFloat = .greatestFiniteMagnitude
    ) -> PreviewLayoutGroupPlan? {
        var selected: PreviewLayoutGroupPlan?
        for plan in variants where plan.size.height <= maximumHeight + geometryEpsilon {
            guard let current = selected else {
                selected = plan
                continue
            }
            if plan.size.width < current.size.width - geometryEpsilon ||
                (abs(plan.size.width - current.size.width) <= geometryEpsilon &&
                    plan.size.height < current.size.height - geometryEpsilon) {
                selected = plan
            }
        }
        return selected
    }

    private static func isBetter(
        _ candidate: PackedGroupRowsState,
        than current: PackedGroupRowsState?
    ) -> Bool {
        guard let current else { return true }
        if candidate.size.height < current.size.height - geometryEpsilon { return true }
        if abs(candidate.size.height - current.size.height) > geometryEpsilon { return false }
        if candidate.size.width < current.size.width - geometryEpsilon { return true }
        if abs(candidate.size.width - current.size.width) > geometryEpsilon { return false }
        return candidate.rowCount < current.rowCount
    }

    private static func greedilyPackedGroupRows(
        plans: [PreviewLayoutGroupPlan],
        availableWidth: CGFloat,
        spacing: CGFloat
    ) -> [PreviewLayoutGroupRow] {
        var rows = [PreviewLayoutGroupRow]()
        var rowPlans = [PreviewLayoutGroupPlan]()
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0

        for plan in plans {
            let proposedWidth = rowPlans.isEmpty ? plan.size.width : rowWidth + spacing + plan.size.width
            if !rowPlans.isEmpty && proposedWidth > availableWidth + geometryEpsilon {
                rows.append(PreviewLayoutGroupRow(
                    groups: rowPlans,
                    size: CGSize(width: rowWidth, height: rowHeight)
                ))
                rowPlans = [plan]
                rowWidth = plan.size.width
                rowHeight = plan.size.height
            } else {
                rowPlans.append(plan)
                rowWidth = proposedWidth
                rowHeight = max(rowHeight, plan.size.height)
            }
        }

        if !rowPlans.isEmpty {
            rows.append(PreviewLayoutGroupRow(groups: rowPlans, size: CGSize(width: rowWidth, height: rowHeight)))
        }
        return rows
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
            guard rows.allSatisfy({ isValid(size: $0.size) }) else { return false }
            return rows.flatMap(\.itemIDs) == expectedItems.map(\.id)
        case (.grouped(let expectedGroups), .groupRows(let rows)):
            guard rows.allSatisfy({ row in
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
              preferredPixelsValue <= CGFloat(Int.max) else {
            return nil
        }
        return Int(minimumPixelsValue)...Int(preferredPixelsValue)
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
