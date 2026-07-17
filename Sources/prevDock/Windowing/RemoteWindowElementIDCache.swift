import CoreGraphics
import Foundation

final class RemoteWindowElementIDCache {
    private struct Key: Hashable {
        let pid: pid_t
        let windowID: CGWindowID
    }

    private let lock = NSLock()
    private var elementIDsByKey = [Key: UInt64]()
    private var revisionByPID = [pid_t: UInt64]()

    func revision(for pid: pid_t) -> UInt64 {
        lock.lock()
        let revision = revisionByPID[pid, default: 0]
        lock.unlock()
        return revision
    }

    func resolve<Element>(
        pid: pid_t,
        windowIDs: Set<CGWindowID>,
        elementForID: (UInt64) -> Element?,
        validates: (Element, CGWindowID) -> Bool,
        onRejected: (CGWindowID, UInt64) -> Void = { _, _ in },
        evictsRejected: Bool = true,
        shouldContinue: () -> Bool = { true }
    ) -> [CGWindowID: Element] {
        let candidates = cachedCandidates(pid: pid, windowIDs: windowIDs)
        var elements = [CGWindowID: Element]()

        for (windowID, elementID) in candidates {
            guard shouldContinue() else { break }
            guard let element = elementForID(elementID),
                  validates(element, windowID) else {
                if evictsRejected {
                    remove(pid: pid, windowID: windowID, ifElementIDEquals: elementID)
                }
                onRejected(windowID, elementID)
                continue
            }
            elements[windowID] = element
        }
        return elements
    }

    func record(elementID: UInt64, pid: pid_t, windowID: CGWindowID) {
        record(elementIDsByWindow: [windowID: elementID], pid: pid)
    }

    func record(elementIDsByWindow: [CGWindowID: UInt64], pid: pid_t) {
        lock.lock()
        elementIDsByWindow.forEach { windowID, elementID in
            elementIDsByKey[Key(pid: pid, windowID: windowID)] = elementID
        }
        bumpRevisionLocked(for: pid)
        lock.unlock()
    }

    @discardableResult
    func apply(
        pid: pid_t,
        expectedRevision: UInt64,
        retainingWindowIDs: Set<CGWindowID>,
        rejectedElementIDsByWindow: [CGWindowID: UInt64],
        recording elementIDsByWindow: [CGWindowID: UInt64]
    ) -> Bool {
        lock.lock()
        guard revisionByPID[pid, default: 0] == expectedRevision else {
            lock.unlock()
            return false
        }
        elementIDsByKey.keys
            .filter { $0.pid == pid && !retainingWindowIDs.contains($0.windowID) }
            .forEach { elementIDsByKey.removeValue(forKey: $0) }
        rejectedElementIDsByWindow.forEach { windowID, elementID in
            let key = Key(pid: pid, windowID: windowID)
            if elementIDsByKey[key] == elementID {
                elementIDsByKey.removeValue(forKey: key)
            }
        }
        elementIDsByWindow.forEach { windowID, elementID in
            elementIDsByKey[Key(pid: pid, windowID: windowID)] = elementID
        }
        bumpRevisionLocked(for: pid)
        lock.unlock()
        return true
    }

    func retain(windowIDs: Set<CGWindowID>, for pid: pid_t) {
        lock.lock()
        elementIDsByKey.keys
            .filter { $0.pid == pid && !windowIDs.contains($0.windowID) }
            .forEach { elementIDsByKey.removeValue(forKey: $0) }
        bumpRevisionLocked(for: pid)
        lock.unlock()
    }

    func remove(pid: pid_t, windowID: CGWindowID) {
        lock.lock()
        elementIDsByKey.removeValue(forKey: Key(pid: pid, windowID: windowID))
        bumpRevisionLocked(for: pid)
        lock.unlock()
    }

    func removeAll(for pid: pid_t) {
        lock.lock()
        elementIDsByKey.keys
            .filter { $0.pid == pid }
            .forEach { elementIDsByKey.removeValue(forKey: $0) }
        bumpRevisionLocked(for: pid)
        lock.unlock()
    }

    private func cachedCandidates(
        pid: pid_t,
        windowIDs: Set<CGWindowID>
    ) -> [(windowID: CGWindowID, elementID: UInt64)] {
        lock.lock()
        let candidates: [(windowID: CGWindowID, elementID: UInt64)] = elementIDsByKey.compactMap { key, elementID in
            guard key.pid == pid, windowIDs.contains(key.windowID) else { return nil }
            return (windowID: key.windowID, elementID: elementID)
        }
        lock.unlock()
        return candidates.sorted { $0.windowID < $1.windowID }
    }

    private func remove(
        pid: pid_t,
        windowID: CGWindowID,
        ifElementIDEquals elementID: UInt64
    ) {
        let key = Key(pid: pid, windowID: windowID)
        lock.lock()
        if elementIDsByKey[key] == elementID {
            elementIDsByKey.removeValue(forKey: key)
            bumpRevisionLocked(for: pid)
        }
        lock.unlock()
    }

    private func bumpRevisionLocked(for pid: pid_t) {
        revisionByPID[pid, default: 0] &+= 1
    }
}
