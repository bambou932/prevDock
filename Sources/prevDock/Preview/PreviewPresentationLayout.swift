import AppKit

struct PreviewContentStyle: Equatable {
    let cardVerticalChrome: CGFloat
    let titleFontSize: CGFloat
    let statusFontSize: CGFloat
    let appIconSize: CGFloat
}

enum PreviewCardChromeLayout {
    static let labelHorizontalInset: CGFloat = 8
    static let iconTitleSpacing: CGFloat = 5
    static let titleStatusSpacing: CGFloat = 8

    static func minimumCardWidth(contentStyle: PreviewContentStyle, contentPadding: CGFloat) -> CGFloat {
        contentPadding * 2 +
            labelHorizontalInset * 2 +
            contentStyle.appIconSize +
            iconTitleSpacing +
            titleStatusSpacing
    }

    static func horizontalConstraints(
        container: NSView,
        imageView: NSView,
        appIconView: NSView,
        titleLabel: NSView,
        statusLabel: NSView,
        thumbnailWidth: CGFloat,
        contentStyle: PreviewContentStyle,
        contentPadding: CGFloat
    ) -> [NSLayoutConstraint] {
        [
            imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            imageView.widthAnchor.constraint(equalToConstant: thumbnailWidth),
            appIconView.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: contentPadding + labelHorizontalInset
            ),
            appIconView.widthAnchor.constraint(equalToConstant: contentStyle.appIconSize),
            titleLabel.leadingAnchor.constraint(
                equalTo: appIconView.trailingAnchor,
                constant: iconTitleSpacing
            ),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: statusLabel.leadingAnchor,
                constant: -titleStatusSpacing
            ),
            statusLabel.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -(contentPadding + labelHorizontalInset)
            )
        ]
    }
}

enum PreviewLoadingPlaceholderLayout {
    static let preferredSize = NSSize(width: 140, height: 28)

    static func fittedSize(in thumbnailSize: NSSize) -> NSSize {
        NSSize(
            width: min(preferredSize.width, max(0, thumbnailSize.width)),
            height: min(preferredSize.height, max(0, thumbnailSize.height))
        )
    }
}

extension PreviewContentSize {
    var style: PreviewContentStyle {
        switch self {
        case .extraSmall:
            return PreviewContentStyle(cardVerticalChrome: 24, titleFontSize: 12, statusFontSize: 10, appIconSize: 14)
        case .small:
            return PreviewContentStyle(cardVerticalChrome: 27, titleFontSize: 13, statusFontSize: 11, appIconSize: 16)
        case .regular:
            return PreviewContentStyle(cardVerticalChrome: 30, titleFontSize: 14, statusFontSize: 12, appIconSize: 18)
        case .large:
            return PreviewContentStyle(cardVerticalChrome: 34, titleFontSize: 16, statusFontSize: 13, appIconSize: 21)
        case .extraLarge:
            return PreviewContentStyle(cardVerticalChrome: 38, titleFontSize: 18, statusFontSize: 14, appIconSize: 24)
        }
    }
}

struct PreviewAutoPresentationSnapshot: Equatable {
    let itemIDs: [UInt32]
    let measuredPanelSize: NSSize
}

enum PreviewLegacyOverflowPolicy {
    static func needsHorizontalScroll(contentWidth: CGFloat, availableWidth: CGFloat) -> Bool {
        contentWidth > availableWidth
    }

    static func needsWrappedVerticalScroll(rowCount: Int, maximumVisibleRows: Int) -> Bool {
        rowCount > maximumVisibleRows
    }
}

enum PreviewPresentationLayout {
    static func measuredPanelSize(for plan: PreviewLayoutPlan) -> NSSize {
        plan.panelSize
    }

    static func makePreviewRow(views: [NSView] = [], spacing: CGFloat = 0) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = spacing
        row.alignment = .bottom
        row.distribution = .gravityAreas
        return row
    }

    static func installAutoRows(
        plan: PreviewLayoutPlan,
        availableItemIDs: Set<UInt32>,
        in stack: NSStackView,
        makeItemView: (UInt32) -> NSView?
    ) -> PreviewAutoPresentationSnapshot? {
        guard case .rows(let rows) = plan.arrangement,
              hasExactUniqueItems(plan.itemIDs, availableItemIDs: availableItemIDs) else {
            return nil
        }

        var installedIDs = [UInt32]()
        var installedRows = [NSView]()
        for row in rows {
            guard let rowView = makeAutoRow(
                row,
                contentWidth: plan.contentSize.width,
                makeItemView: makeItemView
            ) else {
                return nil
            }
            installedIDs.append(contentsOf: row.itemIDs)
            installedRows.append(rowView)
        }
        guard installedIDs == plan.itemIDs else { return nil }

        installedRows.forEach(stack.addArrangedSubview)
        return PreviewAutoPresentationSnapshot(
            itemIDs: installedIDs,
            measuredPanelSize: measuredPanelSize(for: plan)
        )
    }

    static func installAutoGroupRows(
        plan: PreviewLayoutPlan,
        availableItemIDs: Set<UInt32>,
        in stack: NSStackView,
        makeGroupRowView: (PreviewLayoutGroupRow) -> NSView?
    ) -> PreviewAutoPresentationSnapshot? {
        guard case .groupRows(let rows) = plan.arrangement,
              hasExactUniqueItems(plan.itemIDs, availableItemIDs: availableItemIDs) else {
            return nil
        }

        var installedRows = [NSView]()
        for row in rows {
            guard let rowView = makeGroupRowView(row) else { return nil }
            installedRows.append(makeCenteredRow(
                rowView,
                width: plan.contentSize.width,
                height: row.size.height
            ))
        }
        installedRows.forEach(stack.addArrangedSubview)
        return PreviewAutoPresentationSnapshot(
            itemIDs: plan.itemIDs,
            measuredPanelSize: measuredPanelSize(for: plan)
        )
    }

    @discardableResult
    static func installHorizontalScrollContainer(
        rowView: NSView,
        contentSize: NSSize,
        viewportSize: NSSize,
        showsScroller: Bool,
        in stack: NSStackView
    ) -> NSScrollView {
        let scrollView = makeHorizontalScrollView(
            rowView: rowView,
            contentSize: contentSize,
            viewportSize: viewportSize,
            showsScroller: showsScroller
        )
        stack.addArrangedSubview(scrollView)
        return scrollView
    }

    @discardableResult
    static func installLegacyRows(
        mode: PreviewOverflowMode,
        rowViews: [NSView],
        contentSize: NSSize,
        viewportSize: NSSize,
        needsScroll: Bool,
        spacing: CGFloat,
        in stack: NSStackView
    ) -> NSScrollView? {
        guard needsScroll else {
            rowViews.forEach(stack.addArrangedSubview)
            return nil
        }

        let scrollView: NSScrollView
        switch mode {
        case .scroll:
            guard rowViews.count == 1, let row = rowViews.first else { return nil }
            scrollView = makeHorizontalScrollView(
                rowView: row,
                contentSize: contentSize,
                viewportSize: viewportSize,
                showsScroller: true
            )
        case .wrap:
            scrollView = makeVerticalScrollView(
                rowViews: rowViews,
                contentSize: contentSize,
                viewportSize: viewportSize,
                spacing: spacing
            )
        case .auto:
            return nil
        }
        stack.addArrangedSubview(scrollView)
        return scrollView
    }

    private static func hasExactUniqueItems(
        _ itemIDs: [UInt32],
        availableItemIDs: Set<UInt32>
    ) -> Bool {
        itemIDs.count == availableItemIDs.count &&
            Set(itemIDs).count == itemIDs.count &&
            Set(itemIDs) == availableItemIDs
    }

    private static func makeAutoRow(
        _ row: PreviewLayoutRow,
        contentWidth: CGFloat,
        makeItemView: (UInt32) -> NSView?
    ) -> NSView? {
        var itemViews = [NSView]()
        for itemID in row.itemIDs {
            guard let view = makeItemView(itemID) else { return nil }
            itemViews.append(view)
        }
        return makeCenteredRow(
            makePreviewRow(views: itemViews),
            width: contentWidth,
            height: row.size.height
        )
    }

    private static func makeHorizontalScrollView(
        rowView: NSView,
        contentSize: NSSize,
        viewportSize: NSSize,
        showsScroller: Bool
    ) -> NSScrollView {
        let scrollView = makeScrollView(
            horizontalScroller: showsScroller,
            verticalScroller: false
        )
        let documentView = NSView(frame: NSRect(origin: .zero, size: contentSize))
        rowView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(rowView)
        NSLayoutConstraint.activate([
            rowView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            rowView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            rowView.topAnchor.constraint(equalTo: documentView.topAnchor),
            rowView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            rowView.heightAnchor.constraint(equalToConstant: contentSize.height)
        ])
        install(documentView: documentView, viewportSize: viewportSize, in: scrollView)
        return scrollView
    }

    private static func makeVerticalScrollView(
        rowViews: [NSView],
        contentSize: NSSize,
        viewportSize: NSSize,
        spacing: CGFloat
    ) -> NSScrollView {
        let scrollView = makeScrollView(
            horizontalScroller: false,
            verticalScroller: true
        )
        let documentView = PreviewPresentationDocumentView(frame: NSRect(origin: .zero, size: contentSize))
        let rowsStack = NSStackView(views: rowViews)
        rowsStack.orientation = .vertical
        rowsStack.spacing = spacing
        rowsStack.alignment = .centerX
        rowsStack.distribution = .gravityAreas
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
            rowsStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])
        install(documentView: documentView, viewportSize: viewportSize, in: scrollView)
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return scrollView
    }

    private static func makeScrollView(
        horizontalScroller: Bool,
        verticalScroller: Bool
    ) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = horizontalScroller
        scrollView.hasVerticalScroller = verticalScroller
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.scrollerKnobStyle = .light
        if horizontalScroller {
            scrollView.horizontalScroller?.controlSize = .small
        }
        if verticalScroller {
            scrollView.verticalScroller?.controlSize = .small
        }
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        return scrollView
    }

    private static func install(
        documentView: NSView,
        viewportSize: NSSize,
        in scrollView: NSScrollView
    ) {
        scrollView.documentView = documentView
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalToConstant: viewportSize.width),
            scrollView.heightAnchor.constraint(equalToConstant: viewportSize.height)
        ])
    }

    private static func makeCenteredRow(_ row: NSView, width: CGFloat, height: CGFloat) -> NSView {
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
}

private final class PreviewPresentationDocumentView: NSView {
    override var isFlipped: Bool {
        true
    }
}
