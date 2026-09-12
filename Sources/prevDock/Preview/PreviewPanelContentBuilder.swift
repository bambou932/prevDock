import Cocoa

struct PreviewPanelContentBuilder {
    private let stackView: NSStackView
    private let layout: PreviewPanelLayout
    private let initialHoverSuppressionPoint: CGPoint?
    private let cardFactory: (WindowPreview, CGFloat, NSSize?) -> PreviewCardView

    init(
        stackView: NSStackView,
        layout: PreviewPanelLayout,
        initialHoverSuppressionPoint: CGPoint?,
        cardFactory: @escaping (WindowPreview, CGFloat, NSSize?) -> PreviewCardView
    ) {
        self.stackView = stackView
        self.layout = layout
        self.initialHoverSuppressionPoint = initialHoverSuppressionPoint
        self.cardFactory = cardFactory
    }

    private func makeCard(for preview: WindowPreview, imageHeight: CGFloat, compactSize: NSSize? = nil) -> PreviewCardView {
        cardFactory(preview, imageHeight, compactSize)
    }

    func installCompactListRows(previews: [WindowPreview], plan: PreviewCompactListPlan) {
        let rowSize = NSSize(width: plan.rowWidth, height: plan.rowHeight)
        let rows = previews.map { makeCard(for: $0, imageHeight: 0, compactSize: rowSize) }
        PreviewPresentationLayout.installLegacyRows(
            mode: .wrap,
            rowViews: rows,
            contentSize: plan.contentSize,
            viewportSize: plan.viewportSize,
            needsScroll: plan.needsScroll,
            spacing: 0,
            in: stackView
        )
    }

    func addPreviewContent(
        previews: [WindowPreview],
        app: NSRunningApplication,
        anchoredTo anchor: CGRect,
        imageHeight: CGFloat,
        overflowMode: PreviewOverflowMode,
        desktopGroupingEnabled: Bool,
        autoLayoutPlan: PreviewLayoutPlan?,
        autoDesktopGroups: [PreviewDesktopGroup]?
    ) {
        if let autoLayoutPlan {
            addAutoPreviewContent(
                plan: autoLayoutPlan,
                previews: previews,
                groups: autoDesktopGroups
            )
        } else if let groups = self.layout.desktopGroups(for: previews, enabled: desktopGroupingEnabled, anchoredTo: anchor) {
            stackView.spacing = PreviewMetrics.desktopGroupSpacing
            addGroupedPreviewContent(groups: groups, anchoredTo: anchor, imageHeight: imageHeight, overflowMode: overflowMode)
        } else if overflowMode == .scroll {
            if self.layout.needsHorizontalScroll(for: previews, anchoredTo: anchor, imageHeight: imageHeight) {
                addScrollableRow(previews: previews, anchoredTo: anchor, imageHeight: imageHeight)
            } else {
                addPreviewRow(previews: previews, imageHeight: imageHeight)
            }
        } else {
            addWrappedPreviewRows(previews: previews, anchoredTo: anchor, imageHeight: imageHeight)
        }
    }

    private func addAutoPreviewContent(
        plan: PreviewLayoutPlan,
        previews: [WindowPreview],
        groups: [PreviewDesktopGroup]?
    ) {
        let previewsByID = Dictionary(uniqueKeysWithValues: previews.map { ($0.windowID, $0) })
        switch plan.arrangement {
        case .rows:
            let snapshot = PreviewPresentationLayout.installAutoRows(
                plan: plan,
                availableItemIDs: Set(previewsByID.keys),
                in: stackView
            ) { [self] windowID in
                guard let preview = previewsByID[windowID] else {
                    assertionFailure("Auto preview layout referenced a missing window")
                    return nil
                }
                return makeCard(for: preview, imageHeight: plan.imageHeight)
            }
            assert(snapshot?.itemIDs == plan.itemIDs, "Auto preview hierarchy did not match its plan")
        case .groupRows:
            stackView.spacing = PreviewMetrics.desktopGroupSpacing
            guard let groups else {
                assertionFailure("Grouped Auto plan is missing its immutable group snapshot")
                return
            }
            let groupsByID = Dictionary(uniqueKeysWithValues: groups.map { (self.layout.layoutGroupID(for: $0.key), $0) })
            let snapshot = PreviewPresentationLayout.installAutoGroupRows(
                plan: plan,
                availableItemIDs: Set(previewsByID.keys),
                in: stackView
            ) { [self] row in
                var layoutRow = PreviewDesktopGroupLayoutRow()
                for groupPlan in row.groups {
                    guard let group = groupsByID[groupPlan.id] else {
                        assertionFailure("Auto preview group metadata changed during rendering")
                        return nil
                    }
                    let previewRows = groupPlan.itemRows.map {
                        resolvedPreviews(for: $0.itemIDs, in: previewsByID)
                    }
                    layoutRow.add(PreviewDesktopGroupLayout(
                        title: group.title,
                        isCurrent: group.isCurrent,
                        rows: previewRows,
                        rowHeight: groupPlan.itemRows.first?.size.height ?? 0,
                        size: groupPlan.size
                    ))
                }
                return makeDesktopGroupLayoutRow(layoutRow, imageHeight: plan.imageHeight)
            }
            assert(snapshot?.itemIDs == plan.itemIDs, "Grouped Auto hierarchy did not match its plan")
        }
    }

    private func resolvedPreviews(
        for windowIDs: [UInt32],
        in previewsByID: [CGWindowID: WindowPreview]
    ) -> [WindowPreview] {
        windowIDs.compactMap { windowID in
            guard let preview = previewsByID[windowID] else {
                assertionFailure("Auto preview layout referenced a missing window")
                return nil
            }
            return preview
        }
    }

    private func addPreviewRow(previews: [WindowPreview], imageHeight: CGFloat) {
        let row = makePreviewRow(previews: previews, imageHeight: imageHeight)
        let size = NSSize(
            width: self.layout.rowContentWidth(for: previews, imageHeight: imageHeight),
            height: self.layout.rowHeight(for: previews, imageHeight: imageHeight)
        )
        PreviewPresentationLayout.installLegacyRows(
            mode: .scroll,
            rowViews: [row],
            contentSize: size,
            viewportSize: size,
            needsScroll: false,
            spacing: PreviewMetrics.rowSpacing,
            in: stackView
        )
    }

    private func addWrappedPreviewRows(previews: [WindowPreview], anchoredTo anchor: CGRect, imageHeight: CGFloat) {
        let layout = self.layout.previewRowsLayout(for: previews, anchoredTo: anchor, imageHeight: imageHeight)
        let rowViews = layout.rows.map {
            makeCenteredPreviewRow(previews: $0, imageHeight: imageHeight, width: layout.contentSize.width)
        }
        PreviewPresentationLayout.installLegacyRows(
            mode: .wrap,
            rowViews: rowViews,
            contentSize: layout.contentSize,
            viewportSize: layout.viewportSize,
            needsScroll: layout.needsVerticalScroll,
            spacing: PreviewMetrics.rowSpacing,
            in: stackView
        )
    }

    private func addGroupedPreviewContent(
        groups: [PreviewDesktopGroup],
        anchoredTo anchor: CGRect,
        imageHeight: CGFloat,
        overflowMode: PreviewOverflowMode
    ) {
        if overflowMode == .scroll {
            addGroupedScrollableRow(groups: groups, anchoredTo: anchor, imageHeight: imageHeight)
            return
        }

        addWrappedGroups(groups, anchoredTo: anchor, imageHeight: imageHeight)
    }

    private func addGroupedScrollableRow(groups: [PreviewDesktopGroup], anchoredTo anchor: CGRect, imageHeight: CGFloat) {
        let groupSizes = groups.map { self.layout.groupedSingleRowSize(for: $0, anchoredTo: anchor, imageHeight: imageHeight) }
        let contentWidth = self.layout.groupedContentWidth(groupSizes)
        let viewportWidth = min(contentWidth, self.layout.maxContentWidth(anchoredTo: anchor))
        let contentHeight = groupSizes.map(\.height).max() ?? 0
        let scrollViewHeight = contentHeight + self.layout.groupedScrollBarHeight(contentWidth: contentWidth, anchoredTo: anchor)
        let groupStack = makeHorizontalStack(views: [], spacing: PreviewMetrics.desktopGroupSpacing)
        groupStack.alignment = .top
        for (index, group) in groups.enumerated() {
            groupStack.addArrangedSubview(makeDesktopGroupView(
                group: group,
                rows: [group.previews],
                size: groupSizes[index],
                imageHeight: imageHeight
            ))
        }
        PreviewPresentationLayout.installHorizontalScrollContainer(
            rowView: groupStack,
            contentSize: NSSize(width: contentWidth, height: contentHeight),
            viewportSize: NSSize(width: viewportWidth, height: scrollViewHeight),
            showsScroller: PreviewLegacyOverflowPolicy.needsHorizontalScroll(
                contentWidth: contentWidth,
                availableWidth: viewportWidth
            ),
            in: stackView
        )
    }

    private func addWrappedGroups(_ groups: [PreviewDesktopGroup], anchoredTo anchor: CGRect, imageHeight: CGFloat) {
        let wrapLayout = self.layout.groupedWrapLayout(for: groups, anchoredTo: anchor, imageHeight: imageHeight)
        let rowViews = wrapLayout.rows.map {
            makeCenteredDesktopGroupLayoutRow($0, imageHeight: imageHeight, width: wrapLayout.contentSize.width)
        }
        PreviewPresentationLayout.installLegacyRows(
            mode: .wrap,
            rowViews: rowViews,
            contentSize: wrapLayout.contentSize,
            viewportSize: wrapLayout.viewportSize,
            needsScroll: wrapLayout.needsVerticalScroll,
            spacing: PreviewMetrics.desktopGroupSpacing,
            in: stackView
        )
    }

    private func makeDesktopGroupView(
        group: PreviewDesktopGroup,
        rows: [[WindowPreview]],
        size: NSSize,
        imageHeight: CGFloat
    ) -> DesktopGroupView {
        let groupContentWidth = max(0, size.width - PreviewMetrics.desktopGroupPadding * 2)
        let groupRowHeight = self.layout.rowHeight(for: group.previews, imageHeight: imageHeight)
        let groupView = DesktopGroupView(
            title: group.title,
            isCurrent: group.isCurrent,
            size: size,
            initialHoverSuppressionPoint: initialHoverSuppressionPoint
        )
        rows.forEach {
            groupView.addContentRow(makeDesktopGroupContentRow(
                previews: $0,
                imageHeight: imageHeight,
                width: groupContentWidth,
                height: groupRowHeight
            ))
        }
        return groupView
    }

    private func makeCenteredPreviewRow(previews: [WindowPreview], imageHeight: CGFloat, width: CGFloat) -> NSView {
        makeCenteredRow(
            makePreviewRow(previews: previews, imageHeight: imageHeight),
            width: width,
            height: self.layout.rowHeight(for: previews, imageHeight: imageHeight)
        )
    }

    private func makeCenteredDesktopGroupLayoutRow(
        _ row: PreviewDesktopGroupLayoutRow,
        imageHeight: CGFloat,
        width: CGFloat
    ) -> NSView {
        makeCenteredRow(
            makeDesktopGroupLayoutRow(row, imageHeight: imageHeight),
            width: width,
            height: row.height
        )
    }

    private func makeCenteredRow(_ row: NSView, width: CGFloat, height: CGFloat) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width),
            container.heightAnchor.constraint(equalToConstant: height),
            row.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func makeDesktopGroupLayoutRow(
        _ row: PreviewDesktopGroupLayoutRow,
        imageHeight: CGFloat
    ) -> NSStackView {
        let rowStack = makeHorizontalStack(views: [], spacing: PreviewMetrics.desktopGroupSpacing)
        rowStack.alignment = .top
        row.layouts.forEach { layout in
            let groupView = DesktopGroupView(
                title: layout.title,
                isCurrent: layout.isCurrent,
                size: layout.size,
                initialHoverSuppressionPoint: initialHoverSuppressionPoint
            )
            let groupContentWidth = max(0, layout.size.width - PreviewMetrics.desktopGroupPadding * 2)
            layout.rows.forEach { row in
                groupView.addContentRow(makeDesktopGroupContentRow(
                    previews: row,
                    imageHeight: imageHeight,
                    width: groupContentWidth,
                    height: layout.rowHeight
                ))
            }
            rowStack.addArrangedSubview(groupView)
        }
        return rowStack
    }

    private func makeDesktopGroupContentRow(
        previews: [WindowPreview],
        imageHeight: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> NSView {
        makeCenteredRow(
            makePreviewRow(previews: previews, imageHeight: imageHeight),
            width: width,
            height: height
        )
    }

    private func addScrollableRow(previews: [WindowPreview], anchoredTo anchor: CGRect, imageHeight: CGFloat) {
        let contentWidth = self.layout.rowContentWidth(for: previews, imageHeight: imageHeight)
        let rowHeight = self.layout.rowHeight(for: previews, imageHeight: imageHeight)
        let contentSize = NSSize(width: contentWidth, height: rowHeight)
        let viewportSize = NSSize(
            width: min(contentWidth, self.layout.maxContentWidth(anchoredTo: anchor)),
            height: rowHeight + PreviewMetrics.scrollBarHeight
        )
        let row = makePreviewRow(previews: previews, imageHeight: imageHeight)
        let scrollView = PreviewPresentationLayout.installLegacyRows(
            mode: .scroll,
            rowViews: [row],
            contentSize: contentSize,
            viewportSize: viewportSize,
            needsScroll: true,
            spacing: PreviewMetrics.rowSpacing,
            in: stackView
        )
        assert(scrollView != nil, "Scrollable preview row was not installed")
    }

    private func makePreviewRow() -> NSStackView {
        PreviewLayoutViews.makePreviewRow()
    }

    private func makePreviewRow(previews: [WindowPreview], imageHeight: CGFloat) -> NSStackView {
        let rowStack = makePreviewRow()
        previews.forEach { rowStack.addArrangedSubview(makeCard(for: $0, imageHeight: imageHeight)) }
        return rowStack
    }

    private func makeHorizontalStack(views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = spacing
        return stack
    }

    private func makeVerticalStack(views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = spacing
        stack.alignment = .centerX
        stack.distribution = .gravityAreas
        return stack
    }
}
