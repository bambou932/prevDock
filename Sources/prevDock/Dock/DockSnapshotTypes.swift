import AppKit
import CoreGraphics

enum DockSnapshotEdge: String, CaseIterable {
    case bottom, left, right
}

struct DockSnapshotGeometry: Equatable {
    let edge: DockSnapshotEdge
    let imageSize: CGSize
    let dockRectInImage: CGRect
    let finderRectInImage: CGRect
}

struct DockSnapshot {
    let image: NSImage
    let geometry: DockSnapshotGeometry
    let dockRect: CGRect
    let finderRect: CGRect
    let screenFrame: CGRect
    let screenVisibleFrame: CGRect
    let displayID: UInt32
    let displayName: String
    let backingScaleFactor: CGFloat
}

enum DockSnapshotUnavailableReason: Equatable {
    case hidden, permissions, unavailable, captureFailed
}

enum DockSnapshotState {
    case idle
    case loading
    case available(DockSnapshot)
    case unavailable(DockSnapshotUnavailableReason)
}

protocol DockSnapshotProviding: AnyObject {
    var onChange: ((DockSnapshotState) -> Void)? { get set }
    func setActive(_ active: Bool)
    func refresh()
}

struct DockSnapshotDisplay: Equatable {
    let id: UInt32
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect
    let backingScaleFactor: CGFloat
}

struct DockSnapshotContext: Equatable {
    let windowNumber: Int
    let preferredDisplayID: UInt32?
    let displays: [DockSnapshotDisplay]
    let referenceMaxY: CGFloat
    let dockPID: Int32?

    func appKitRect(_ quartzRect: CGRect) -> CGRect {
        CGRect(x: quartzRect.minX, y: referenceMaxY - quartzRect.maxY,
               width: quartzRect.width, height: quartzRect.height)
    }
}

struct DockSnapshotMetadata: Equatable {
    let context: DockSnapshotContext
    let display: DockSnapshotDisplay
    let windowID: CGWindowID
    let edge: DockSnapshotEdge
    let windowBounds: CGRect
    let dockRect: CGRect
    let finderRect: CGRect

    func matchesCapture(_ other: DockSnapshotMetadata) -> Bool {
        context == other.context && display == other.display && windowID == other.windowID &&
            edge == other.edge && quantized(windowBounds) == quantized(other.windowBounds) &&
            quantized(dockRect) == quantized(other.dockRect) && quantized(finderRect) == quantized(other.finderRect)
    }

    private func quantized(_ rect: CGRect) -> CGRect {
        let scale = max(1, display.backingScaleFactor)
        return CGRect(x: (rect.minX * scale).rounded(), y: (rect.minY * scale).rounded(),
                      width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
    }
}

enum DockSnapshotProbeResult {
    case visible(DockSnapshotMetadata)
    case hidden
    case unavailable
}

protocol DockSnapshotBackendProviding: AnyObject {
    // Implementations finish on the main queue; probe and capture must not block each other.
    func probe(context: DockSnapshotContext, completion: @escaping (DockSnapshotProbeResult) -> Void)
    func capture(metadata: DockSnapshotMetadata, completion: @escaping (DockSnapshot?) -> Void)
}
