import CoreGraphics

enum SettingsPreviewStageLayout {
    static let inset: CGFloat = 16
    static let footerHeight: CGFloat = 24

    struct DockPlacement: Equatable {
        let edge: DockSnapshotEdge
        let imageFrame: CGRect
        let finderFrame: CGRect
        let screenFrame: CGRect
        let visibleFrame: CGRect
    }

    struct Result: Equatable {
        let requiredSize: CGSize
        let previewFrame: CGRect
        let dockImageFrame: CGRect
        let dockVisibleFrame: CGRect
        let dockSourceVisibleRect: CGRect
    }

    static func requiredSize(maximumPreviewSize: CGSize, dock: DockPlacement?) -> CGSize {
        let scene = reservedScene(maximumPreviewSize: maximumPreviewSize, dock: dock)
        return CGSize(width: ceil(scene.width + inset * 2),
                      height: ceil(scene.height + inset * 2 + footerHeight))
    }

    static func calculate(
        stageBounds: CGRect,
        previewSize: CGSize,
        maximumPreviewSize: CGSize,
        dock: DockPlacement?
    ) -> Result {
        let maximumFrame = previewFrame(size: maximumPreviewSize, dock: dock)
        let visibleDock = dock.map { cropDock($0, beside: maximumFrame) } ?? .zero
        let scene = dock == nil ? maximumFrame : maximumFrame.union(visibleDock)
        let target = CGRect(x: stageBounds.minX + inset,
                            y: stageBounds.minY + inset + footerHeight,
                            width: max(0, stageBounds.width - inset * 2),
                            height: max(0, stageBounds.height - inset * 2 - footerHeight))
        let offset = CGPoint(x: target.midX - scene.midX, y: target.midY - scene.midY)
        let preview = dock == nil ? CGRect(x: maximumFrame.midX - previewSize.width / 2,
                                          y: maximumFrame.midY - previewSize.height / 2,
                                          width: previewSize.width, height: previewSize.height) :
            previewFrame(size: previewSize, dock: dock)
        return Result(
            requiredSize: requiredSize(maximumPreviewSize: maximumPreviewSize, dock: dock),
            previewFrame: preview.offsetBy(dx: offset.x, dy: offset.y),
            dockImageFrame: dock.map { $0.imageFrame.offsetBy(dx: offset.x, dy: offset.y) } ?? .zero,
            dockVisibleFrame: dock == nil ? .zero : visibleDock.offsetBy(dx: offset.x, dy: offset.y),
            dockSourceVisibleRect: dock.map {
                visibleDock.offsetBy(dx: -$0.imageFrame.minX, dy: -$0.imageFrame.minY)
            } ?? .zero
        )
    }

    private static func reservedScene(maximumPreviewSize: CGSize, dock: DockPlacement?) -> CGRect {
        let frame = previewFrame(size: maximumPreviewSize, dock: dock)
        guard let dock else { return frame }
        return frame.union(cropDock(dock, beside: frame))
    }

    private static func previewFrame(size: CGSize, dock: DockPlacement?) -> CGRect {
        guard let dock else { return CGRect(origin: .zero, size: size) }
        return PreviewAnchorLayout.frame(previewSize: size, anchor: dock.finderFrame,
                                         screenFrame: dock.screenFrame, visibleFrame: dock.visibleFrame)
    }

    private static func cropDock(_ dock: DockPlacement, beside preview: CGRect) -> CGRect {
        let alignment = preview.union(dock.finderFrame)
        let strip: CGRect
        switch dock.edge {
        case .bottom:
            strip = CGRect(x: alignment.minX, y: dock.imageFrame.minY,
                           width: alignment.width, height: dock.imageFrame.height)
        case .left, .right:
            strip = CGRect(x: dock.imageFrame.minX, y: alignment.minY,
                           width: dock.imageFrame.width, height: alignment.height)
        }
        let crop = strip.intersection(dock.imageFrame)
        return crop.isNull ? CGRect(origin: dock.imageFrame.origin, size: .zero) : crop
    }
}
