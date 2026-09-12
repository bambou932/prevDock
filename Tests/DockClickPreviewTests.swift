import Foundation

@main
enum DockClickPreviewTests {
    static func main() {
        testInitialCacheDecisions()
        testColdDiscovery()
        testPartialDiscovery()
        testCachedPreviewsSurviveFailure()
        testActionOwnership()
        print("Dock click preview tests passed")
    }

    private static func testInitialCacheDecisions() {
        check(DockClickPreviewState.shouldIntercept(completeCachedWindowCount: nil), "cold, stale, and incomplete caches need async discovery")
        for count in [0, 1] {
            check(!DockClickPreviewState.shouldIntercept(completeCachedWindowCount: count), "known single-window and windowless applications remain native")
        }
        check(DockClickPreviewState.shouldIntercept(completeCachedWindowCount: 2), "known multiple windows open previews")
    }

    private static func testColdDiscovery() {
        let state = makeState(hasPreviews: false)
        check(state.resolution(windowCount: 2, isComplete: true, now: 100.1) == .showPreview, "a cold click must show discovered windows")
        for count in [0, 1] {
            check(state.resolution(windowCount: count, isComplete: true, now: 100.1) == .restoreNativeClick, "confirmed fewer than two windows restores the native click")
        }
        check(state.timeoutResolution == .restoreNativeClick, "a hung discovery cannot swallow a cold click indefinitely")
        check(state.deadline == 100.75, "native fallback retains its bounded deadline")
    }

    private static func testPartialDiscovery() {
        let state = makeState(hasPreviews: false)
        check(state.resolution(windowCount: 1, isComplete: false, now: 100.1) == .retry, "one partially discovered window must not activate a multi-window application")
        check(state.resolution(windowCount: 0, isComplete: false, now: 100.74) == .retry, "temporary discovery failure may retry within its deadline")
        check(state.resolution(windowCount: 2, isComplete: false, now: 100.3) == .showPreview, "two usable windows are enough to present while remaining windows resolve")
        check(state.resolution(windowCount: 1, isComplete: false, now: 100.75) == .restoreNativeClick, "partial discovery cannot extend the original timeout")
    }

    private static func testCachedPreviewsSurviveFailure() {
        let state = makeState(hasPreviews: true)
        check(state.resolution(windowCount: 0, isComplete: false, now: 100.1) == .keepPreview, "failed refresh must not activate an application with usable cached previews")
        check(state.resolution(windowCount: 1, isComplete: false, now: 101) == .keepPreview, "partial metadata must not discard cached preview choices")
        check(state.timeoutResolution == .keepPreview, "a refresh timeout keeps an already visible preview")
        check(state.resolution(windowCount: 1, isComplete: true, now: 100.1) == .restoreNativeClick, "a complete snapshot still detects windows closed since caching")
    }

    private static func testActionOwnership() {
        let state = makeState(hasPreviews: false)
        check(state.isCurrent(actionGeneration: 7, frontmostPID: 42), "the initiating click owns its completion")
        check(!state.isCurrent(actionGeneration: 8, frontmostPID: 42), "a later mouse-down or Space change invalidates the prior click")
        check(!state.isCurrent(actionGeneration: 7, frontmostPID: 43), "application switching must prevent a late focus steal")
        check(!state.isCurrent(actionGeneration: 7, frontmostPID: nil), "an unknown frontmost application must not restore a stale click")
    }

    private static func makeState(hasPreviews: Bool) -> DockClickPreviewState {
        DockClickPreviewState(actionGeneration: 7, frontmostPID: 42, startedAt: 100, hasUsablePreviews: hasPreviews)
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
