import CoreGraphics

enum PreviewAnchorLayout {
    static let dockGap: CGFloat = 4

    static func frame(
        previewSize: CGSize,
        anchor: CGRect,
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGRect {
        let width = previewSize.width
        let height = previewSize.height
        let origin: CGPoint
        switch edge(for: anchor, in: screenFrame) {
        case .bottom:
            origin = CGPoint(x: anchor.midX - width / 2, y: anchor.maxY + dockGap)
        case .top:
            origin = CGPoint(x: anchor.midX - width / 2, y: anchor.minY - height - dockGap)
        case .left:
            origin = CGPoint(x: anchor.maxX + dockGap, y: anchor.midY - height / 2)
        case .right:
            origin = CGPoint(x: anchor.minX - width - dockGap, y: anchor.midY - height / 2)
        }
        return CGRect(
            x: clamp(origin.x, min: visibleFrame.minX + 10, max: visibleFrame.maxX - width - 10),
            y: clamp(origin.y, min: visibleFrame.minY + 10, max: visibleFrame.maxY - height - 10),
            width: width,
            height: height
        )
    }

    private static func edge(for anchor: CGRect, in frame: CGRect) -> Edge {
        let distances: [(Edge, CGFloat)] = [
            (.bottom, abs(anchor.minY - frame.minY)),
            (.top, abs(frame.maxY - anchor.maxY)),
            (.left, abs(anchor.minX - frame.minX)),
            (.right, abs(frame.maxX - anchor.maxX))
        ]
        return distances.min { $0.1 < $1.1 }?.0 ?? .bottom
    }

    private static func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.max(min, Swift.min(max, value))
    }

    private enum Edge { case bottom, top, left, right }
}
