import ApplicationServices
import CoreGraphics
import Foundation

final class ConcurrentRemoteWindowScanState {
    private let lock = NSLock()
    private var windows: [AXUIElement]
    private var missingWindowIDs: Set<CGWindowID>
    private var pendingMappings = [Mapping]()
    private var scanIterationCount: UInt64 = 0

    init(windows: [AXUIElement], missingWindowIDs: Set<CGWindowID>) {
        self.windows = windows
        self.missingWindowIDs = missingWindowIDs
    }

    var isComplete: Bool {
        lock.lock()
        let isComplete = missingWindowIDs.isEmpty
        lock.unlock()
        return isComplete
    }

    func accept(
        element: AXUIElement,
        elementID: UInt64,
        windowID: CGWindowID
    ) {
        lock.lock()
        guard missingWindowIDs.remove(windowID) != nil else {
            lock.unlock()
            return
        }
        windows.append(element)
        pendingMappings.append(Mapping(
            elementID: elementID,
            windowID: windowID
        ))
        lock.unlock()
    }

    func addScanIterations(_ count: UInt64) {
        lock.lock()
        scanIterationCount += count
        lock.unlock()
    }

    var result: Result {
        lock.lock()
        let result = Result(
            windows: windows,
            pendingMappings: pendingMappings,
            scanIterationCount: scanIterationCount,
            missingWindowIDs: missingWindowIDs
        )
        lock.unlock()
        return result
    }

    struct Result {
        let windows: [AXUIElement]
        let pendingMappings: [Mapping]
        let scanIterationCount: UInt64
        let missingWindowIDs: Set<CGWindowID>
    }

    struct Mapping {
        let elementID: UInt64
        let windowID: CGWindowID
    }
}
