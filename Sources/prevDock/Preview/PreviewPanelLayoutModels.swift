import Cocoa

enum AutoPreviewLayoutDecision {
    case thumbnails(plan: PreviewLayoutPlan, groups: [PreviewDesktopGroup]?)
    case compactList
}

struct PreviewDesktopGroup {
    let key: PreviewDesktopGroupKey
    let title: String
    let isCurrent: Bool
    let sortOrder: Int
    let previews: [WindowPreview]

    init(identity: PreviewDesktopGroupIdentity, previews: [WindowPreview]) {
        key = identity.key
        title = identity.title
        isCurrent = identity.isCurrent
        sortOrder = identity.sortOrder
        self.previews = previews
    }
}

struct PreviewRowsLayout {
    let rows: [[WindowPreview]]
    let contentSize: NSSize
    let viewportSize: NSSize
    let needsVerticalScroll: Bool

    init(
        rows: [[WindowPreview]],
        contentSize: NSSize,
        viewportSize: NSSize? = nil,
        needsVerticalScroll: Bool = false
    ) {
        self.rows = rows
        self.contentSize = contentSize
        self.viewportSize = viewportSize ?? contentSize
        self.needsVerticalScroll = needsVerticalScroll
    }
}

struct PreviewDesktopGroupLayout {
    let title: String?
    let isCurrent: Bool
    let rows: [[WindowPreview]]
    let rowHeight: CGFloat
    let size: NSSize

    var previewRowCount: Int {
        rows.count
    }

    func visibleHeight(maxPreviewRows: Int) -> CGFloat {
        let rowCount = min(rows.count, maxPreviewRows)
        guard rowCount > 0 else { return 0 }
        let titleHeight = title == nil ? 0 : PreviewMetrics.desktopGroupLabelHeight + PreviewMetrics.desktopGroupHeaderSpacing
        let rowsHeight = CGFloat(rowCount) * rowHeight + CGFloat(max(0, rowCount - 1)) * PreviewMetrics.rowSpacing
        return titleHeight + rowsHeight + PreviewMetrics.desktopGroupPadding * 2
    }
}

struct PreviewDesktopGroupWrapLayout {
    let rows: [PreviewDesktopGroupLayoutRow]
    let contentSize: NSSize
    let viewportSize: NSSize
    let needsVerticalScroll: Bool

    init(
        rows: [PreviewDesktopGroupLayoutRow],
        contentSize: NSSize? = nil,
        viewportSize: NSSize? = nil,
        needsVerticalScroll: Bool = false
    ) {
        let contentSize = contentSize ?? Self.contentSize(for: rows)
        self.rows = rows
        self.contentSize = contentSize
        self.viewportSize = viewportSize ?? contentSize
        self.needsVerticalScroll = needsVerticalScroll
    }

    var size: NSSize {
        viewportSize
    }

    var visibleHeight: CGFloat {
        Self.visibleContentHeight(for: rows)
    }

    var needsScrollbar: Bool {
        contentSize.height > visibleHeight
    }

    func constrainedToVerticalScroll(viewportSize: NSSize) -> PreviewDesktopGroupWrapLayout {
        PreviewDesktopGroupWrapLayout(
            rows: rows,
            contentSize: contentSize,
            viewportSize: viewportSize,
            needsVerticalScroll: true
        )
    }

    private static func contentSize(for rows: [PreviewDesktopGroupLayoutRow]) -> NSSize {
        let height = rows.map(\.height).reduce(0, +) +
            CGFloat(max(0, rows.count - 1)) * PreviewMetrics.desktopGroupSpacing
        return NSSize(width: rows.map(\.width).max() ?? 0, height: height)
    }

    private static func visibleContentHeight(for rows: [PreviewDesktopGroupLayoutRow]) -> CGFloat {
        var remainingRows = PreviewMetrics.maxVisiblePreviewRows
        var visibleRowCount = 0
        var height: CGFloat = 0

        for row in rows {
            guard remainingRows > 0 else { break }
            let rowPreviewCount = row.previewRowCount
            let rowHeight = rowPreviewCount <= remainingRows ? row.height : row.visibleHeight(maxPreviewRows: remainingRows)
            height += rowHeight
            remainingRows -= min(rowPreviewCount, remainingRows)
            visibleRowCount += 1
        }

        return height + CGFloat(max(0, visibleRowCount - 1)) * PreviewMetrics.desktopGroupSpacing
    }
}

struct PreviewDesktopGroupLayoutRow {
    private(set) var layouts = [PreviewDesktopGroupLayout]()
    private(set) var width: CGFloat = 0
    private(set) var height: CGFloat = 0

    var isEmpty: Bool {
        layouts.isEmpty
    }

    var previewRowCount: Int {
        layouts.map(\.previewRowCount).max() ?? 0
    }

    func visibleHeight(maxPreviewRows: Int) -> CGFloat {
        layouts.map { $0.visibleHeight(maxPreviewRows: maxPreviewRows) }.max() ?? 0
    }

    func shouldWrap(adding layout: PreviewDesktopGroupLayout, availableWidth: CGFloat) -> Bool {
        !isEmpty && width(adding: layout) > availableWidth
    }

    mutating func add(_ layout: PreviewDesktopGroupLayout) {
        width = width(adding: layout)
        height = max(height, layout.size.height)
        layouts.append(layout)
    }

    private func width(adding layout: PreviewDesktopGroupLayout) -> CGFloat {
        isEmpty ? layout.size.width : width + PreviewMetrics.desktopGroupSpacing + layout.size.width
    }
}

struct PreviewDesktopGroupIdentity {
    let key: PreviewDesktopGroupKey
    let title: String
    let isCurrent: Bool
    let sortOrder: Int

    static let unknown = PreviewDesktopGroupIdentity(
        key: .unknown,
        title: "Other",
        isCurrent: false,
        sortOrder: Int.max
    )
}

enum PreviewDesktopGroupKey: Hashable {
    case desktop(UInt64)
    case unknown
}
