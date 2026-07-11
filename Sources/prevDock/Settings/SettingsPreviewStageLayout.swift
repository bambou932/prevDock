import CoreGraphics

enum SettingsPreviewStageLayout {
    static let stageInset: CGFloat = 12
    static let dockGap: CGFloat = 4

    struct Result: Equatable {
        let sceneFrame: CGRect
        let previewFrame: CGRect
        let dockImageFrame: CGRect
        let dockVisibleRect: CGRect
        let dockSourceVisibleRect: CGRect
    }

    static func calculate(
        stageBounds: CGRect,
        previewSize: CGSize,
        dockImageSize: CGSize,
        geometry: DockSnapshotGeometry
    ) -> Result {
        let previewSize = usableSize(previewSize)
        let imageSize = usableSize(dockImageSize, fallback: geometry.imageSize)
        let sceneSize = sceneSize(
            previewSize: previewSize,
            dockImageSize: imageSize,
            edge: geometry.edge
        )
        let sceneFrame = centeredFrame(size: sceneSize, in: stageBounds)
        let previewFrame = previewFrame(
            in: sceneFrame,
            size: previewSize,
            dockImageSize: imageSize,
            edge: geometry.edge
        )
        let dockVisibleRect = dockVisibleRect(
            in: sceneFrame,
            previewSize: previewSize,
            dockImageSize: imageSize,
            edge: geometry.edge
        )
        let dockImageFrame = dockImageFrame(
            alignedTo: dockVisibleRect,
            imageSize: imageSize,
            edge: geometry.edge
        )
        let sourceBounds = CGRect(origin: .zero, size: imageSize)
        let dockSourceVisibleRect = usableIntersection(
            dockVisibleRect.offsetBy(dx: -dockImageFrame.minX, dy: -dockImageFrame.minY),
            sourceBounds
        )
        return Result(
            sceneFrame: sceneFrame,
            previewFrame: previewFrame,
            dockImageFrame: dockImageFrame,
            dockVisibleRect: dockVisibleRect,
            dockSourceVisibleRect: dockSourceVisibleRect
        )
    }

    static func sceneSize(
        previewSize: CGSize,
        dockImageSize: CGSize,
        edge: DockSnapshotEdge
    ) -> CGSize {
        let previewSize = usableSize(previewSize)
        let imageSize = usableSize(dockImageSize)
        switch edge {
        case .bottom, .top:
            return CGSize(
                width: previewSize.width,
                height: previewSize.height + dockGap + imageSize.height
            )
        case .left, .right:
            return CGSize(
                width: previewSize.width + dockGap + imageSize.width,
                height: previewSize.height
            )
        }
    }

    private static func previewFrame(
        in sceneFrame: CGRect,
        size: CGSize,
        dockImageSize: CGSize,
        edge: DockSnapshotEdge
    ) -> CGRect {
        switch edge {
        case .bottom:
            return CGRect(
                x: sceneFrame.minX,
                y: sceneFrame.minY + dockImageSize.height + dockGap,
                width: size.width,
                height: size.height
            )
        case .top, .right:
            return CGRect(origin: sceneFrame.origin, size: size)
        case .left:
            return CGRect(
                x: sceneFrame.minX + dockImageSize.width + dockGap,
                y: sceneFrame.minY,
                width: size.width,
                height: size.height
            )
        }
    }

    private static func dockVisibleRect(
        in sceneFrame: CGRect,
        previewSize: CGSize,
        dockImageSize: CGSize,
        edge: DockSnapshotEdge
    ) -> CGRect {
        switch edge {
        case .bottom:
            return CGRect(
                x: sceneFrame.minX,
                y: sceneFrame.minY,
                width: previewSize.width,
                height: dockImageSize.height
            )
        case .top:
            return CGRect(
                x: sceneFrame.minX,
                y: sceneFrame.minY + previewSize.height + dockGap,
                width: previewSize.width,
                height: dockImageSize.height
            )
        case .left:
            return CGRect(
                x: sceneFrame.minX,
                y: sceneFrame.minY,
                width: dockImageSize.width,
                height: previewSize.height
            )
        case .right:
            return CGRect(
                x: sceneFrame.minX + previewSize.width + dockGap,
                y: sceneFrame.minY,
                width: dockImageSize.width,
                height: previewSize.height
            )
        }
    }

    private static func dockImageFrame(
        alignedTo visibleRect: CGRect,
        imageSize: CGSize,
        edge: DockSnapshotEdge
    ) -> CGRect {
        switch edge {
        case .bottom, .top:
            return CGRect(origin: visibleRect.origin, size: imageSize)
        case .left, .right:
            return CGRect(
                x: visibleRect.minX,
                y: visibleRect.maxY - imageSize.height,
                width: imageSize.width,
                height: imageSize.height
            )
        }
    }

    private static func centeredFrame(size: CGSize, in bounds: CGRect) -> CGRect {
        let bounds = usableBounds(bounds)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func usableBounds(_ bounds: CGRect) -> CGRect {
        guard bounds.origin.x.isFinite,
              bounds.origin.y.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite else {
            return .zero
        }
        return bounds.standardized
    }

    private static func usableSize(_ size: CGSize, fallback: CGSize = .zero) -> CGSize {
        let fallback = normalizedSize(fallback)
        let normalized = normalizedSize(size)
        return CGSize(
            width: normalized.width > 0 ? normalized.width : fallback.width,
            height: normalized.height > 0 ? normalized.height : fallback.height
        )
    }

    private static func normalizedSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: size.width.isFinite ? max(0, size.width) : 0,
            height: size.height.isFinite ? max(0, size.height) : 0
        )
    }

    private static func usableIntersection(_ lhs: CGRect, _ rhs: CGRect) -> CGRect {
        let intersection = lhs.intersection(rhs)
        return isUsable(intersection) ? intersection : .zero
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        !rect.isNull &&
            !rect.isInfinite &&
            rect.origin.x.isFinite &&
            rect.origin.y.isFinite &&
            rect.width.isFinite &&
            rect.height.isFinite &&
            rect.width > 0 &&
            rect.height > 0
    }
}
