import Cocoa

final class PreviewPanelLayout {
    private var cachedAutoLayoutInput: PreviewLayoutInput?
    private var cachedAutoLayoutDecision: PreviewLayoutDecision?

    func clearCache() {
        cachedAutoLayoutInput = nil
        cachedAutoLayoutDecision = nil
    }

    func compactListPlan(itemCount: Int, anchoredTo anchor: CGRect) -> PreviewCompactListPlan {
        PreviewCompactListPlan.make(
            itemCount: itemCount,
            rowHeight: max(36, PreviewMetrics.cardVerticalChrome + PreviewMetrics.cardContentPadding * 2),
            preferredWidth: 400 + (PreviewMetrics.titleFontSize - 14) * 12,
            availablePanelSize: availablePanelSize(anchoredTo: anchor),
            panelPadding: PreviewMetrics.panelPadding,
            scrollerWidth: PreviewMetrics.scrollBarHeight
        )
    }

    func autoLayoutDecision(
        previews: [WindowPreview],
        anchoredTo anchor: CGRect,
        preferredImageHeight: CGFloat,
        desktopGroupingEnabled: Bool
    ) -> AutoPreviewLayoutDecision {
        let screen = ScreenGeometry.screen(containing: anchor) ?? NSScreen.main
        let availablePanelSize = availablePanelSize(anchoredTo: anchor)
        let metrics = autoLayoutMetrics()
        let groups = desktopGroups(
            for: previews,
            enabled: desktopGroupingEnabled,
            anchoredTo: anchor
        )
        let content = autoLayoutContent(
            previews: previews,
            groups: groups,
            availablePanelSize: availablePanelSize,
            metrics: metrics
        )
        let input = PreviewLayoutInput(
            content: content,
            preferredImageHeight: preferredImageHeight,
            minimumImageHeight: PreviewMetrics.minimumReadableImageHeight,
            availablePanelSize: availablePanelSize,
            backingScale: max(1, screen?.backingScaleFactor ?? 1),
            metrics: metrics
        )
        let decision = cachedAutoLayoutInput == input ? cachedAutoLayoutDecision : nil
        let selectedDecision = decision ?? PreviewLayoutPlanner.plan(input)
        cachedAutoLayoutInput = input
        cachedAutoLayoutDecision = selectedDecision
        switch selectedDecision {
        case .thumbnails(let plan):
            return .thumbnails(plan: plan, groups: groups)
        case .compactList:
            return .compactList
        }
    }

    func availablePanelSize(anchoredTo anchor: CGRect) -> NSSize {
        let screen = ScreenGeometry.screen(containing: anchor) ?? NSScreen.main
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return PreviewPanelAvailableSpace.size(
            visibleFrame: screen?.visibleFrame ?? screenFrame,
            screenFrame: screenFrame,
            dockAnchor: anchor,
            dockEdge: autoLayoutDockEdge(for: anchor, in: screenFrame)
        )
    }

    private func autoLayoutDockEdge(for anchor: CGRect, in frame: CGRect) -> PreviewPanelDockEdge {
        switch dockEdge(for: anchor, in: frame) {
        case .bottom:
            return .bottom
        case .top:
            return .top
        case .left:
            return .left
        case .right:
            return .right
        }
    }

    private func autoLayoutContent(
        previews: [WindowPreview],
        groups: [PreviewDesktopGroup]?,
        availablePanelSize: NSSize,
        metrics: PreviewLayoutMetrics
    ) -> PreviewLayoutContent {
        guard let groups else {
            return .ungrouped(previews.map { layoutItem(for: $0) })
        }

        let maximumHeaderWidth = max(
            0,
            availablePanelSize.width - metrics.panelPadding * 2 - metrics.groupPadding * 2
        )
        return .grouped(groups.map { group in
            PreviewLayoutGroup(
                id: layoutGroupID(for: group.key),
                items: group.previews.map { layoutItem(for: $0) },
                headerSize: autoGroupHeaderSize(title: group.title, maximumWidth: maximumHeaderWidth)
            )
        })
    }

    private func layoutItem(for preview: WindowPreview) -> PreviewLayoutItem {
        PreviewLayoutItem(
            id: preview.windowID,
            aspectRatio: PreviewCardView.layoutAspectRatio(for: preview)
        )
    }

    func layoutGroupID(for key: PreviewDesktopGroupKey) -> PreviewLayoutGroupID {
        switch key {
        case .desktop(let id):
            return .desktop(id)
        case .unknown:
            return .unassigned
        }
    }

    private func autoGroupHeaderSize(title: String, maximumWidth: CGFloat) -> NSSize {
        let font = PreviewMetrics.desktopGroupLabelFont
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        let naturalWidth = textWidth +
            PreviewMetrics.desktopGroupLabelHorizontalPadding +
            PreviewMetrics.desktopGroupLabelTextSlack
        return NSSize(
            width: min(naturalWidth, maximumWidth),
            height: PreviewMetrics.desktopGroupLabelHeight
        )
    }

    private func autoLayoutMetrics() -> PreviewLayoutMetrics {
        PreviewLayoutMetrics(
            panelPadding: PreviewMetrics.panelPadding,
            cardHorizontalPadding: PreviewMetrics.cardContentPadding,
            cardVerticalPadding: PreviewMetrics.cardContentPadding,
            cardVerticalChrome: PreviewMetrics.cardVerticalChrome,
            itemSpacing: PreviewMetrics.rowSpacing,
            rowSpacing: PreviewMetrics.rowSpacing,
            groupPadding: PreviewMetrics.desktopGroupPadding,
            groupSpacing: PreviewMetrics.desktopGroupSpacing,
            groupHeaderSpacing: PreviewMetrics.desktopGroupHeaderSpacing,
            minimumCardWidth: PreviewMetrics.minimumCardWidth,
            maximumImageWidth: PreviewMetrics.maxImageWidth,
            minimumAspectRatio: PreviewMetrics.minAspectRatio,
            maximumAspectRatio: PreviewMetrics.maxAspectRatio
        )
    }

    private func layoutRows(for previews: [WindowPreview], anchoredTo anchor: CGRect, imageHeight: CGFloat) -> [[WindowPreview]] {
        layoutRows(for: previews, availableWidth: maxContentWidth(anchoredTo: anchor), imageHeight: imageHeight)
    }

    func previewRowsLayout(for previews: [WindowPreview], anchoredTo anchor: CGRect, imageHeight: CGFloat) -> PreviewRowsLayout {
        let maxHeight = min(
            maxPreviewStackHeight(imageHeight: imageHeight),
            maxContentHeight(anchoredTo: anchor)
        )
        let rows = layoutRows(for: previews, anchoredTo: anchor, imageHeight: imageHeight)
        let contentSize = previewRowsContentSize(rows, imageHeight: imageHeight)
        guard contentSize.height > maxHeight else {
            return PreviewRowsLayout(rows: rows, contentSize: contentSize)
        }

        let scrollRows = layoutRows(
            for: previews,
            availableWidth: verticalScrollContentWidth(anchoredTo: anchor),
            imageHeight: imageHeight
        )
        let scrollContentSize = previewRowsContentSize(scrollRows, imageHeight: imageHeight)
        return PreviewRowsLayout(
            rows: scrollRows,
            contentSize: scrollContentSize,
            viewportSize: verticalScrollViewportSize(contentSize: scrollContentSize, maxHeight: maxHeight),
            needsVerticalScroll: true
        )
    }

    private func layoutRows(for previews: [WindowPreview], availableWidth: CGFloat, imageHeight: CGFloat) -> [[WindowPreview]] {
        let widths = previews.map { PreviewCardView.cardSize(for: $0, imageHeight: imageHeight).width }
        let maxItemsPerRow = adaptiveMaxItemsPerRow(itemWidths: widths, availableWidth: availableWidth)
        return layoutRows(
            for: previews,
            widths: widths,
            availableWidth: availableWidth,
            maxItemsPerRow: maxItemsPerRow
        )
    }

    private func layoutRows(
        for previews: [WindowPreview],
        widths: [CGFloat],
        availableWidth: CGFloat,
        maxItemsPerRow: Int
    ) -> [[WindowPreview]] {
        var rows = [[WindowPreview]]()
        var row = [WindowPreview]()
        var rowWidth: CGFloat = 0
        let maxItemsPerRow = max(1, maxItemsPerRow)

        for (preview, width) in zip(previews, widths) {
            let nextWidth = row.isEmpty ? width : rowWidth + PreviewMetrics.rowSpacing + width
            if !row.isEmpty && (row.count >= maxItemsPerRow || nextWidth > availableWidth) {
                rows.append(row)
                row = [preview]
                rowWidth = width
            } else {
                row.append(preview)
                rowWidth = nextWidth
            }
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }

    private func adaptiveMaxItemsPerRow(itemWidths: [CGFloat], availableWidth: CGFloat) -> Int {
        guard let minimumWidth = itemWidths.min(), minimumWidth > 0 else { return 1 }
        let fitCount = Int(floor((availableWidth + PreviewMetrics.rowSpacing) / (minimumWidth + PreviewMetrics.rowSpacing)))
        return max(1, fitCount)
    }

    func measuredSize(
        previews: [WindowPreview],
        app: NSRunningApplication,
        anchoredTo anchor: CGRect,
        imageHeight: CGFloat,
        overflowMode: PreviewOverflowMode,
        desktopGroupingEnabled: Bool,
        autoLayoutPlan: PreviewLayoutPlan?
    ) -> NSSize {
        if let autoLayoutPlan {
            return PreviewPresentationLayout.measuredPanelSize(for: autoLayoutPlan)
        }
        let panelChrome = PreviewMetrics.panelPadding * 2
        if let groups = desktopGroups(for: previews, enabled: desktopGroupingEnabled, anchoredTo: anchor) {
            return groupedMeasuredSize(groups: groups, anchoredTo: anchor, imageHeight: imageHeight, overflowMode: overflowMode)
        }
        if overflowMode == .scroll {
            let scrollerHeight = needsHorizontalScroll(for: previews, anchoredTo: anchor, imageHeight: imageHeight) ?
                PreviewMetrics.scrollBarHeight : 0
            return NSSize(
                width: min(rowContentWidth(for: previews, imageHeight: imageHeight) + panelChrome, maxPanelWidth(anchoredTo: anchor)),
                height: rowHeight(for: previews, imageHeight: imageHeight) + scrollerHeight + panelChrome
            )
        }
        let layout = previewRowsLayout(for: previews, anchoredTo: anchor, imageHeight: imageHeight)
        let width = min(layout.viewportSize.width + panelChrome, maxPanelWidth(anchoredTo: anchor))
        let height = layout.viewportSize.height + panelChrome
        return NSSize(width: width, height: height)
    }

    func desktopGroups(for previews: [WindowPreview], enabled: Bool, anchoredTo anchor: CGRect) -> [PreviewDesktopGroup]? {
        guard enabled else { return nil }
        guard previews.contains(where: { $0.desktop != nil }) else { return nil }
        let focusedDesktopID = focusedDesktopID(anchoredTo: anchor)
        guard shouldGroupDesktopPreviews(previews, focusedDesktopID: focusedDesktopID) else { return nil }
        var previewsByKey = [PreviewDesktopGroupKey: [WindowPreview]]()
        var identitiesByKey = [PreviewDesktopGroupKey: PreviewDesktopGroupIdentity]()

        for preview in previews {
            let identity = desktopGroupIdentity(for: preview.desktop, focusedDesktopID: focusedDesktopID)
            previewsByKey[identity.key, default: []].append(preview)
            identitiesByKey[identity.key] = identity
        }

        let knownKeys = Set(identitiesByKey.keys.filter { $0 != .unknown })
        guard !knownKeys.isEmpty else { return nil }
        return sortedDesktopGroupIdentities(Array(identitiesByKey.values)).compactMap { identity in
            guard let previews = previewsByKey[identity.key] else { return nil }
            return PreviewDesktopGroup(identity: identity, previews: previews)
        }
    }

    private func desktopGroupIdentity(for desktop: WindowDesktop?, focusedDesktopID: UInt64?) -> PreviewDesktopGroupIdentity {
        guard let desktop else { return .unknown }
        return PreviewDesktopGroupIdentity(
            key: .desktop(desktop.id),
            title: desktop.title,
            isCurrent: isFocusedDesktop(desktop, focusedDesktopID: focusedDesktopID),
            sortOrder: desktop.sortOrder
        )
    }

    private func shouldGroupDesktopPreviews(_ previews: [WindowPreview], focusedDesktopID: UInt64?) -> Bool {
        guard let focusedDesktopID else {
            return !previews.allSatisfy { $0.desktop?.isCurrent == true }
        }
        return !previews.allSatisfy { $0.desktop?.id == focusedDesktopID }
    }

    private func isFocusedDesktop(_ desktop: WindowDesktop, focusedDesktopID: UInt64?) -> Bool {
        guard let focusedDesktopID else { return desktop.isCurrent }
        return desktop.id == focusedDesktopID
    }

    private func focusedDesktopID(anchoredTo anchor: CGRect) -> UInt64? {
        SkyLightCapture.currentDesktopID(displayIdentifier: displayIdentifier(anchoredTo: anchor))
    }

    private func displayIdentifier(anchoredTo anchor: CGRect) -> String? {
        let screen = ScreenGeometry.screen(containing: anchor) ?? NSScreen.main
        guard let displayID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID.uint32Value)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private func sortedDesktopGroupIdentities(_ identities: [PreviewDesktopGroupIdentity]) -> [PreviewDesktopGroupIdentity] {
        identities.sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            if lhs.key == .unknown { return false }
            if rhs.key == .unknown { return true }
            return lhs.sortOrder < rhs.sortOrder
        }
    }

    private func groupedMeasuredSize(
        groups: [PreviewDesktopGroup],
        anchoredTo anchor: CGRect,
        imageHeight: CGFloat,
        overflowMode: PreviewOverflowMode
    ) -> NSSize {
        let panelChrome = PreviewMetrics.panelPadding * 2
        let contentSize = groupedContentSize(
            groups: groups,
            anchoredTo: anchor,
            imageHeight: imageHeight,
            overflowMode: overflowMode
        )
        return NSSize(
            width: min(contentSize.width + panelChrome, maxPanelWidth(anchoredTo: anchor)),
            height: contentSize.height + panelChrome
        )
    }

    private func groupedContentSize(
        groups: [PreviewDesktopGroup],
        anchoredTo anchor: CGRect,
        imageHeight: CGFloat,
        overflowMode: PreviewOverflowMode
    ) -> NSSize {
        if overflowMode == .scroll {
            return groupedScrollContentSize(groups: groups, anchoredTo: anchor, imageHeight: imageHeight)
        }
        return groupedWrapContentSize(groups: groups, anchoredTo: anchor, imageHeight: imageHeight)
    }

    private func groupedScrollContentSize(
        groups: [PreviewDesktopGroup],
        anchoredTo anchor: CGRect,
        imageHeight: CGFloat
    ) -> NSSize {
        let groupSizes = groups.map { groupedSingleRowSize(for: $0, anchoredTo: anchor, imageHeight: imageHeight) }
        let contentWidth = groupedContentWidth(groupSizes)
        let contentHeight = groupSizes.map(\.height).max() ?? 0
        return NSSize(
            width: min(contentWidth, maxContentWidth(anchoredTo: anchor)),
            height: contentHeight + groupedScrollBarHeight(contentWidth: contentWidth, anchoredTo: anchor)
        )
    }

    private func groupedWrapContentSize(groups: [PreviewDesktopGroup], anchoredTo anchor: CGRect, imageHeight: CGFloat) -> NSSize {
        groupedWrapLayout(for: groups, anchoredTo: anchor, imageHeight: imageHeight).size
    }

    func groupedWrapLayout(
        for groups: [PreviewDesktopGroup],
        anchoredTo anchor: CGRect,
        imageHeight: CGFloat
    ) -> PreviewDesktopGroupWrapLayout {
        let layout = groupedWrapLayout(
            for: groups,
            availableWidth: maxContentWidth(anchoredTo: anchor),
            imageHeight: imageHeight
        )
        let availableHeight = maxContentHeight(anchoredTo: anchor)
        guard layout.needsScrollbar || layout.contentSize.height > availableHeight else { return layout }
        let scrollLayout = groupedWrapLayout(
            for: groups,
            availableWidth: verticalScrollContentWidth(anchoredTo: anchor),
            imageHeight: imageHeight
        )
        return scrollLayout.constrainedToVerticalScroll(
            viewportSize: verticalScrollViewportSize(
                contentSize: scrollLayout.contentSize,
                maxHeight: min(scrollLayout.visibleHeight, availableHeight)
            )
        )
    }

    func groupedWrapLayout(
        for groups: [PreviewDesktopGroup],
        availableWidth: CGFloat,
        imageHeight: CGFloat
    ) -> PreviewDesktopGroupWrapLayout {
        let layouts = groupedLayouts(for: groups, availableWidth: availableWidth, imageHeight: imageHeight)
        return wrapGroupedLayouts(layouts, availableWidth: availableWidth)
    }

    private func groupedLayouts(
        for groups: [PreviewDesktopGroup],
        availableWidth: CGFloat,
        imageHeight: CGFloat
    ) -> [PreviewDesktopGroupLayout] {
        let maxGroupWidth = maxGroupedContentWidth(availableWidth: availableWidth)
        return groups.map { group in
            let rows = layoutRows(for: group.previews, availableWidth: maxGroupWidth, imageHeight: imageHeight)
            let groupRowHeight = rowHeight(for: group.previews, imageHeight: imageHeight)
            let rowWidths = rows.map { rowContentWidth(for: $0, imageHeight: imageHeight) }
            return PreviewDesktopGroupLayout(
                title: group.title,
                isCurrent: group.isCurrent,
                rows: rows,
                rowHeight: groupRowHeight,
                size: groupedSize(
                    rowWidths: rowWidths,
                    rowHeight: groupRowHeight,
                    rowCount: rows.count,
                    title: group.title,
                    isCurrent: group.isCurrent,
                    maxTitleWidth: maxGroupWidth
                )
            )
        }
    }

    private func wrapGroupedLayouts(
        _ layouts: [PreviewDesktopGroupLayout],
        availableWidth: CGFloat
    ) -> PreviewDesktopGroupWrapLayout {
        var rows = [PreviewDesktopGroupLayoutRow]()
        var row = PreviewDesktopGroupLayoutRow()

        for layout in layouts {
            if row.shouldWrap(adding: layout, availableWidth: availableWidth) {
                rows.append(row)
                row = PreviewDesktopGroupLayoutRow()
            }
            row.add(layout)
        }

        if !row.isEmpty {
            rows.append(row)
        }
        return PreviewDesktopGroupWrapLayout(rows: rows)
    }

    func groupedSingleRowSize(for group: PreviewDesktopGroup, anchoredTo anchor: CGRect, imageHeight: CGFloat) -> NSSize {
        groupedSize(
            rowWidths: [rowContentWidth(for: group.previews, imageHeight: imageHeight)],
            rowHeight: rowHeight(for: group.previews, imageHeight: imageHeight),
            title: group.title,
            isCurrent: group.isCurrent,
            maxTitleWidth: maxGroupedContentWidth(anchoredTo: anchor)
        )
    }

    private func groupedSize(
        rowWidths: [CGFloat],
        rowHeight: CGFloat,
        rowCount: Int = 1,
        title: String?,
        isCurrent: Bool,
        maxTitleWidth: CGFloat
    ) -> NSSize {
        DesktopGroupView.fittingSize(
            rowWidths: rowWidths,
            rowHeight: rowHeight,
            rowCount: rowCount,
            title: title,
            isCurrent: isCurrent,
            maxTitleWidth: maxTitleWidth
        )
    }

    func groupedContentWidth(_ sizes: [NSSize]) -> CGFloat {
        sizes.map(\.width).reduce(0, +) + CGFloat(max(0, sizes.count - 1)) * PreviewMetrics.desktopGroupSpacing
    }

    func groupedScrollBarHeight(contentWidth: CGFloat, anchoredTo anchor: CGRect) -> CGFloat {
        PreviewLegacyOverflowPolicy.needsHorizontalScroll(
            contentWidth: contentWidth,
            availableWidth: maxContentWidth(anchoredTo: anchor)
        ) ? PreviewMetrics.scrollBarHeight : 0
    }

    private func maxGroupedContentWidth(anchoredTo anchor: CGRect) -> CGFloat {
        maxGroupedContentWidth(availableWidth: maxContentWidth(anchoredTo: anchor))
    }

    private func maxGroupedContentWidth(availableWidth: CGFloat) -> CGFloat {
        max(0, availableWidth - PreviewMetrics.desktopGroupPadding * 2)
    }

    func rowContentWidth(for previews: [WindowPreview], imageHeight: CGFloat) -> CGFloat {
        previews.map { PreviewCardView.cardSize(for: $0, imageHeight: imageHeight).width }.reduce(0, +) +
            CGFloat(max(0, previews.count - 1)) * PreviewMetrics.rowSpacing
    }

    func rowHeight(for previews: [WindowPreview], imageHeight: CGFloat) -> CGFloat {
        previews.map { PreviewCardView.cardSize(for: $0, imageHeight: imageHeight).height }.max() ?? 0
    }

    func needsHorizontalScroll(for previews: [WindowPreview], anchoredTo anchor: CGRect, imageHeight: CGFloat) -> Bool {
        PreviewLegacyOverflowPolicy.needsHorizontalScroll(
            contentWidth: rowContentWidth(for: previews, imageHeight: imageHeight),
            availableWidth: maxContentWidth(anchoredTo: anchor)
        )
    }

    private func previewRowsContentSize(_ rows: [[WindowPreview]], imageHeight: CGFloat) -> NSSize {
        let heights = rows.map { rowHeight(for: $0, imageHeight: imageHeight) }
        return NSSize(
            width: rows.map { rowContentWidth(for: $0, imageHeight: imageHeight) }.max() ?? 0,
            height: stackedHeight(heights, spacing: PreviewMetrics.rowSpacing)
        )
    }

    private func stackedHeight(_ heights: [CGFloat], spacing: CGFloat) -> CGFloat {
        heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * spacing
    }

    private func maxPreviewStackHeight(imageHeight: CGFloat) -> CGFloat {
        let rowHeight = PreviewCardView.cardSize(for: .placeholder, imageHeight: imageHeight).height
        let rowCount = PreviewMetrics.maxVisiblePreviewRows
        return CGFloat(rowCount) * rowHeight + CGFloat(max(0, rowCount - 1)) * PreviewMetrics.rowSpacing
    }

    private func verticalScrollViewportSize(contentSize: NSSize, maxHeight: CGFloat) -> NSSize {
        NSSize(
            width: contentSize.width + PreviewMetrics.scrollBarHeight,
            height: min(contentSize.height, maxHeight)
        )
    }

    private func verticalScrollContentWidth(anchoredTo anchor: CGRect) -> CGFloat {
        max(0, maxContentWidth(anchoredTo: anchor) - PreviewMetrics.scrollBarHeight)
    }

    private func maxPanelWidth(anchoredTo anchor: CGRect) -> CGFloat {
        availablePanelSize(anchoredTo: anchor).width
    }

    func maxContentWidth(anchoredTo anchor: CGRect) -> CGFloat {
        max(0, maxPanelWidth(anchoredTo: anchor) - PreviewMetrics.panelPadding * 2)
    }

    private func maxContentHeight(anchoredTo anchor: CGRect) -> CGFloat {
        max(0, availablePanelSize(anchoredTo: anchor).height - PreviewMetrics.panelPadding * 2)
    }

    func positionedFrame(width: CGFloat, height: CGFloat, anchoredTo anchor: CGRect) -> NSRect {
        let screen = ScreenGeometry.screen(containing: anchor) ?? NSScreen.main
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return PreviewAnchorLayout.frame(
            previewSize: CGSize(width: width, height: height), anchor: anchor,
            screenFrame: screenFrame, visibleFrame: screen?.visibleFrame ?? screenFrame
        )
    }

    private func dockEdge(for anchor: CGRect, in frame: CGRect) -> PreviewDockEdge {
        let distances: [(PreviewDockEdge, CGFloat)] = [
            (.bottom, abs(anchor.minY - frame.minY)),
            (.top, abs(frame.maxY - anchor.maxY)),
            (.left, abs(anchor.minX - frame.minX)),
            (.right, abs(frame.maxX - anchor.maxX))
        ]
        return distances.min { $0.1 < $1.1 }?.0 ?? .bottom
    }
}

private enum PreviewDockEdge {
    case bottom
    case top
    case left
    case right
}
