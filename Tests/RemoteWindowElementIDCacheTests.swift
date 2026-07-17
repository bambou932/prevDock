import CoreGraphics
import Darwin
import Foundation

@main
enum RemoteWindowElementIDCacheTests {
    private static var failureCount = 0

    static func main() {
        testValidMapping()
        testBatchRecord()
        testAtomicApply()
        testStaleApplyDoesNotOverwriteNewerState()
        testCancelledValidationStopsWithoutEviction()
        testCreationFailureRemovesMapping()
        testValidationFailureRemovesMapping()
        testCompareAndRemovePreservesNewerMapping()
        testProcessIsolation()
        testRetainRemovesClosedWindows()
        testSelectedWindowRemoval()
        testProcessRemoval()

        guard failureCount == 0 else {
            fputs("RemoteWindowElementIDCacheTests: \(failureCount) failure(s)\n", stderr)
            exit(1)
        }
        print("RemoteWindowElementIDCacheTests: passed")
    }

    private static func testBatchRecord() {
        let cache = RemoteWindowElementIDCache()
        cache.record(elementIDsByWindow: [110: 61, 111: 62], pid: 12)
        let elements = cache.resolve(
            pid: 12,
            windowIDs: [110, 111],
            elementForID: { $0 },
            validates: { _, _ in true }
        )

        expect(elements[110] == 61, "batch commit should publish the first mapping")
        expect(elements[111] == 62, "batch commit should publish the second mapping")
    }

    private static func testAtomicApply() {
        let cache = RemoteWindowElementIDCache()
        cache.record(elementIDsByWindow: [120: 70, 121: 71, 123: 73], pid: 13)
        cache.record(elementID: 74, pid: 13, windowID: 123)
        let expectedRevision = cache.revision(for: 13)
        let didApply = cache.apply(
            pid: 13,
            expectedRevision: expectedRevision,
            retainingWindowIDs: [120, 122, 123],
            rejectedElementIDsByWindow: [120: 70, 123: 73],
            recording: [122: 72]
        )
        let elements = cache.resolve(
            pid: 13,
            windowIDs: [120, 121, 122, 123],
            elementForID: { $0 },
            validates: { _, _ in true }
        )

        expect(didApply, "transaction should apply when the observed revision is current")
        expect(elements[120] == nil, "transaction should remove the rejected mapping")
        expect(elements[121] == nil, "transaction should prune windows outside the target snapshot")
        expect(elements[122] == 72, "transaction should record the completed scan mapping")
        expect(elements[123] == 74, "stale rejection must preserve a newer concurrent mapping")
    }

    private static func testStaleApplyDoesNotOverwriteNewerState() {
        let cache = RemoteWindowElementIDCache()
        cache.record(elementID: 80, pid: 14, windowID: 130)
        let expectedRevision = cache.revision(for: 14)
        cache.removeAll(for: 14)
        cache.record(elementID: 81, pid: 14, windowID: 131)

        let didApply = cache.apply(
            pid: 14,
            expectedRevision: expectedRevision,
            retainingWindowIDs: [130],
            rejectedElementIDsByWindow: [:],
            recording: [130: 82]
        )
        let elements = cache.resolve(
            pid: 14,
            windowIDs: [130, 131],
            elementForID: { $0 },
            validates: { _, _ in true }
        )

        expect(!didApply, "stale transaction should fail its revision check")
        expect(elements[130] == nil, "stale transaction must not revive a removed window")
        expect(elements[131] == 81, "stale transaction must preserve newer process state")
    }

    private static func testCancelledValidationStopsWithoutEviction() {
        let cache = RemoteWindowElementIDCache()
        cache.record(elementID: 63, pid: 12, windowID: 112)
        var validationCount = 0
        let cancelled = cache.resolve(
            pid: 12,
            windowIDs: [112],
            elementForID: { $0 },
            validates: { _, _ in
                validationCount += 1
                return true
            },
            shouldContinue: { false }
        )
        let retried = cache.resolve(
            pid: 12,
            windowIDs: [112],
            elementForID: { $0 },
            validates: { _, _ in true }
        )

        expect(cancelled.isEmpty, "cancelled validation should not return partial elements")
        expect(validationCount == 0, "cancelled validation should skip AX work")
        expect(retried[112] == 63, "cancellation should preserve an unvalidated mapping")
    }

    private static func testValidMapping() {
        let cache = RemoteWindowElementIDCache()
        cache.record(elementID: 41, pid: 10, windowID: 100)
        var resolvedElementIDs = [UInt64]()
        let elements = cache.resolve(
            pid: 10,
            windowIDs: [100],
            elementForID: { elementID in
                resolvedElementIDs.append(elementID)
                return "element-\(elementID)"
            },
            validates: { element, windowID in
                element == "element-41" && windowID == 100
            }
        )

        expect(resolvedElementIDs == [41], "valid mapping should resolve exactly once")
        expect(elements[100] == "element-41", "valid mapping should return its element")
    }

    private static func testCreationFailureRemovesMapping() {
        let cache = RemoteWindowElementIDCache()
        cache.record(elementID: 42, pid: 10, windowID: 101)
        var rejectionCount = 0
        _ = cache.resolve(
            pid: 10,
            windowIDs: [101],
            elementForID: { _ -> String? in nil },
            validates: { _, _ in true },
            onRejected: { _, _ in rejectionCount += 1 }
        )
        var secondLookupCount = 0
        _ = cache.resolve(
            pid: 10,
            windowIDs: [101],
            elementForID: { elementID in
                secondLookupCount += 1
                return "element-\(elementID)"
            },
            validates: { _, _ in true }
        )

        expect(rejectionCount == 1, "failed element creation should request a fallback")
        expect(secondLookupCount == 0, "failed element creation should evict the mapping")
    }

    private static func testValidationFailureRemovesMapping() {
        let cache = RemoteWindowElementIDCache()
        cache.record(elementID: 43, pid: 10, windowID: 102)
        var rejectionCount = 0
        let elements = cache.resolve(
            pid: 10,
            windowIDs: [102],
            elementForID: { elementID in "element-\(elementID)" },
            validates: { _, _ in false },
            onRejected: { _, _ in rejectionCount += 1 }
        )
        var secondLookupCount = 0
        _ = cache.resolve(
            pid: 10,
            windowIDs: [102],
            elementForID: { elementID in
                secondLookupCount += 1
                return "element-\(elementID)"
            },
            validates: { _, _ in true }
        )

        expect(elements.isEmpty, "invalid elements must not be returned")
        expect(rejectionCount == 1, "validation failure should request a fallback")
        expect(secondLookupCount == 0, "validation failure should evict the mapping")
    }

    private static func testCompareAndRemovePreservesNewerMapping() {
        let cache = RemoteWindowElementIDCache()
        cache.record(elementID: 44, pid: 10, windowID: 103)
        _ = cache.resolve(
            pid: 10,
            windowIDs: [103],
            elementForID: { elementID -> String? in
                cache.record(elementID: 45, pid: 10, windowID: 103)
                return elementID == 44 ? nil : "element-\(elementID)"
            },
            validates: { _, _ in true }
        )
        var resolvedElementIDs = [UInt64]()
        let elements = cache.resolve(
            pid: 10,
            windowIDs: [103],
            elementForID: { elementID in
                resolvedElementIDs.append(elementID)
                return "element-\(elementID)"
            },
            validates: { _, _ in true }
        )

        expect(resolvedElementIDs == [45], "stale failure must not remove a newer mapping")
        expect(elements[103] == "element-45", "newer mapping should remain usable")
    }

    private static func testProcessIsolation() {
        let cache = RemoteWindowElementIDCache()
        cache.record(elementID: 46, pid: 10, windowID: 104)
        cache.record(elementID: 47, pid: 11, windowID: 104)
        let first = cache.resolve(
            pid: 10,
            windowIDs: [104],
            elementForID: { $0 },
            validates: { _, _ in true }
        )
        let second = cache.resolve(
            pid: 11,
            windowIDs: [104],
            elementForID: { $0 },
            validates: { _, _ in true }
        )

        expect(first[104] == 46, "first process should use its own mapping")
        expect(second[104] == 47, "second process should use its own mapping")
    }

    private static func testRetainRemovesClosedWindows() {
        let cache = RemoteWindowElementIDCache()
        cache.record(elementID: 48, pid: 10, windowID: 105)
        cache.record(elementID: 49, pid: 10, windowID: 106)
        cache.retain(windowIDs: [105], for: 10)
        let elements = cache.resolve(
            pid: 10,
            windowIDs: [105, 106],
            elementForID: { $0 },
            validates: { _, _ in true }
        )

        expect(elements[105] == 48, "retained window should remain cached")
        expect(elements[106] == nil, "closed window should be pruned")
    }

    private static func testProcessRemoval() {
        let cache = RemoteWindowElementIDCache()
        cache.record(elementID: 50, pid: 10, windowID: 107)
        cache.record(elementID: 51, pid: 11, windowID: 107)
        cache.removeAll(for: 10)
        let removed = cache.resolve(
            pid: 10,
            windowIDs: [107],
            elementForID: { $0 },
            validates: { _, _ in true }
        )
        let preserved = cache.resolve(
            pid: 11,
            windowIDs: [107],
            elementForID: { $0 },
            validates: { _, _ in true }
        )

        expect(removed.isEmpty, "terminated process should lose every mapping")
        expect(preserved[107] == 51, "removing one process must preserve other processes")
    }

    private static func testSelectedWindowRemoval() {
        let cache = RemoteWindowElementIDCache()
        cache.record(elementID: 52, pid: 10, windowID: 108)
        cache.record(elementID: 53, pid: 10, windowID: 109)
        cache.record(elementID: 54, pid: 11, windowID: 108)
        cache.remove(pid: 10, windowID: 108)
        let firstProcess = cache.resolve(
            pid: 10,
            windowIDs: [108, 109],
            elementForID: { $0 },
            validates: { _, _ in true }
        )
        let secondProcess = cache.resolve(
            pid: 11,
            windowIDs: [108],
            elementForID: { $0 },
            validates: { _, _ in true }
        )

        expect(firstProcess[108] == nil, "selected window removal should evict only its mapping")
        expect(firstProcess[109] == 53, "selected window removal should preserve sibling windows")
        expect(secondProcess[108] == 54, "selected window removal should preserve other processes")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard !condition() else { return }
        failureCount += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}
