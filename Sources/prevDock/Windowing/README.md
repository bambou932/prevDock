# Windowing

This feature discovers application windows, supplies cached and fresh images, and
executes focus/close commands. `WindowInventory` remains the entry point used by
Dock and Preview. Read the repository [agent guide](../../../AGENTS.md) before
editing, and build through the command-line scripts.

## Find the responsible file

| File | Responsibility and useful entry points |
| --- | --- |
| `WindowPreview.swift` | Shared `WindowPreview`/`WindowDesktop` values, thumbnail refresh policy, and fresh/cached/unavailable capture results. No discovery or cache state. |
| `WindowInventory.swift` | Metadata refresh orchestration and the sole owner of preview/thumbnail caches, operation queues, capture generations, sequence numbers, failure backoff, and application eviction. Start at `refreshWindows`, `refreshThumbnails`, `captureFreshThumbnail`, or `finishThumbnailCapture`. Focus/close methods delegate to `WindowCommands`. |
| `WindowDiscovery.swift` | Synchronous AX and WindowServer discovery, supported-window filtering, focused-first ordering, desktop assignment, and merging partial discoveries with previous previews. Owns the shared remote-element resolver. `makePreviews` returns a candidate result; `WindowInventory` decides whether to commit it. `windowElement` resolves the AX target for commands. |
| `WindowAccessibility.swift` | Shared typed AX element/window-ID reads, application AX timeout setup, and WindowServer descriptions. It does not retain windows or mutate caches. |
| `WindowAccessibilityAttributes.swift` | Batched window attributes with a bounded single-attribute fallback and explicit distinction between missing optional attributes and failed reads. |
| `WindowCommands.swift` | The action queue, focus/close verification and retries, fullscreen exit before close, and previous-Space focus restoration. Successful close returns through `WindowInventory.removeClosedWindow` to invalidate caches before completion. |
| `WindowFocusRequest.swift` | Thread-safe focus cancellation and exactly-once completion. Cancellation also invalidates delayed raise/Space-restoration work after a request completed. |
| `WindowRefreshCoordinator.swift` | Thread-safe coalescing and cancellation of metadata requests by application/generation. It owns request lifecycle, not AX or image data. |
| `WindowInventorySnapshot.swift` | Pure merge of discovered previews and unresolved previous previews. A timeout does not imply that missing windows closed. |
| `WindowThumbnailCapturePolicy.swift` | Pure missing/stale capture decisions, retry backoff, and selection of missing captures plus a bounded stale batch. |
| `WindowThumbnailImage.swift` | Transparent-image rejection and cache downscaling. Keeps pixel processing separate from capture scheduling and validity checks. |
| `RemoteWindowElementResolver.swift` | Revalidates cached remote AX IDs, orchestrates bounded scans, and produces revision-checked cache commits. Cancelled results are discarded. |
| `RemoteWindowElementIDCache.swift` | Locked `(pid, windowID)` → remote element ID mappings with per-process revisions; AX validation happens outside its lock. |
| `RemoteWindowScanPlan.swift` | Scan limits and prioritized ranges estimated from known AX element mappings. Owns interpolation and mapping-search budget. |
| `RemoteWindowToken.swift` | Existing private AX token encoding, per-token element creation, and role/window-ID validation. Each scan worker owns its mutable token. |
| `ConcurrentRemoteWindowScanState.swift` | One scan's locked accepted windows, pending mappings, unresolved IDs, and iteration count; workers only interact through its methods/snapshot. |
| `WindowSpaceMembership.swift` | Pure policy distinguishing unavailable Space membership from a confirmed empty membership list. |
| `SkyLightCapture.swift` | Existing private WindowServer bridge: capture, single-window focus, levels, and display/Space queries. Keep the private API signatures and binary event layout together. |

## Follow a symptom

| Symptom | Read in this order |
| --- | --- |
| Window missing, wrong title/size, or incompatible application | `WindowDiscovery.makePreviews` → `axWindows` / `isDisplayable` → `WindowAccessibilityAttributes` → `RemoteWindowElementResolver.resolve`. |
| Windows disappear when an app is slow | `WindowInventory.performWindowRefresh` / `deliverCachedRefresh` → `WindowDiscovery.shouldRetainCachedPreview` → `WindowInventorySnapshot.merging` → scan cancellation/deadlines. |
| Thumbnail remains loading, blank, stale, or reappears after invalidation | `WindowThumbnailAttemptPolicy.decide` → `WindowInventory.thumbnailRefreshPlan` / `captureThumbnail` → `finishThumbnailCapture` → `WindowThumbnailImage` → `SkyLightCapture.capture`. The Preview feature owns the displayed loading state. |
| Minimized window has no image | Discovery bounds/AX status → missing-image capture policy → image alpha validation. Minimized windows may receive a first capture; existing minimized images do not get stale background refreshes. |
| Wrong window activates, focus flickers, or a cancelled action still runs | `WindowCommands.focusWindow` / `applySingleWindowFocus` / `verifyFocusedWindow` → `WindowFocusRequest` → delayed raise and Space-restoration guards. |
| Close button fails or removes the preview too early | `WindowCommands.closeWindow` → fullscreen/retry path → `windowPresence` / `verifyClosed` → `WindowInventory.removeClosedWindow`. |
| Too many captures or growing cache/resource use | `WindowInventory.captureThumbnail` / `queuedCaptureRequest` / `cancelBackgroundThumbnailCaptures` → `pruneApplicationCachesIfNeeded` / `cleanupCaptureStateIfIdle`. |
| Recovered AX windows become wrong after close/app termination | `RemoteWindowElementResolver.commit` → `RemoteWindowElementIDCache.apply` and revision bumps → discovery invalidation entry points. |
| Wrong desktop grouping or focus restored to another app | `WindowDiscovery`'s `WindowSpaceSnapshot` → `SkyLightCapture` Space queries → `WindowCommands` restoration generation and target/frontmost-app checks. |

## Ownership and invariants

- `WindowInventory.workQueue` (`prevDock.window-inventory`, user-initiated) owns
  metadata cache writes, capture bookkeeping, image cache commits, and eviction.
  Only the published preview snapshots, metadata timestamps, and access times
  cross its boundary through `cachedPreviewsLock`. No AX/capture work runs while
  this lock is held.
- Discovery runs synchronously on that same work queue. Its previous previews
  and AX elements are value snapshots of this application's queue-owned state;
  the image lookup closure also runs on this queue. Discovery cannot publish or
  mutate thumbnail state. Its candidate remote cache commit is accepted only
  after the refresh-generation checks pass. Command AX lookup retains its
  existing immediate remote commit path.
- The action queue (`prevDock.window-actions`, user-interactive) belongs to
  `WindowCommands`. Main-thread activation, focus restoration, and their delayed
  callbacks keep their original dispatch boundaries. Focus and close callbacks
  reach callers on the main queue; fresh thumbnail callbacks arrive on the
  inventory work queue. UI clients must continue to dispatch those image results.
- Background capture uses the original operation queue with at most two
  concurrent operations; live capture uses its separate user-interactive queue
  with one operation. Fresh/live work may satisfy a background request, while a
  fresh request does not reuse a background capture. Changing the background
  target cancels captures belonging to other targets.
- Capture acceptance requires permission, a current matching window signature,
  the current invalidation generation, and the newest capture sequence. Size
  uses the original `Double.bitPattern` geometry key; minimization is part of the
  request signature. Preserve these checks when moving capture code.
- Cache images keep the original point size and at most 1200 pixels on their
  longest edge. Live delivery retains the original captured image. Stale refresh
  starts at 1.5 seconds; application cache capacity is eight. Missing-image
  backoff remains 0.75/2/5/15 seconds for the same signature.
- Metadata's deadline is 1.5 seconds, ordinary AX timeout is 0.15 seconds, and
  remote AX timeout is 0.03 seconds. The remote prioritized pass has 0.10 seconds,
  fallback pass 0.35 seconds, known-mapping search 0.03 seconds, and untargeted
  scan 0.10 seconds. Keep the existing per-iteration cancellation/deadline checks,
  six-worker limit, 1000–20000 token range, padding, and prioritized radius.
- Remote cache locks protect map/revision changes, never AX IPC. A candidate
  resolution records the expected revision; an obsolete generation cannot
  repopulate a newer cache. Concurrent scan locks only protect result state.
- Standard AX windows remain first, followed by recovered windows with duplicate
  IDs removed. Keep the existing role/subrole, owner-PID, size, window-level,
  Firefox/VLC, and Space-membership fallbacks in their current order. Missing CG
  descriptions are not proof that an AX window closed.
- Focus still prefers the single-window SkyLight path, then application/AX
  fallback. Keep cancellation checks around side effects and the original
  0.05-second delayed raise, 0.1-second focus verification, and five-second Space
  restoration expiry. Close still verifies two consecutive closed observations
  before removing any cached window.

## Validation

Run from the repository root:

```sh
./scripts/test-window-refresh-coordinator.sh
./scripts/test-window-focus-request.sh
./scripts/test-window-inventory-snapshot.sh
./scripts/test-window-accessibility-attributes.sh
./scripts/test-window-thumbnail-capture-policy.sh
./scripts/test-window-space-membership.sh
./scripts/test-remote-window-cache.sh
./scripts/test-remote-window-scan-budget.sh
./scripts/build.sh
```

These targeted suites validate cancellation, generation/revision fencing,
partial-result retention, AX fallbacks, minimized/missing thumbnail decisions,
failure backoff, and scan budgets. They do not prove native window focusing or
cross-process capture works on every macOS version.

Live verification uses `./scripts/test-window-preview-live.sh <bundle-id>` and
`./scripts/test-remote-window-cache-live.sh <bundle-id>`. Check the live script/test
arguments before running them. Use an explicitly owned fixture for actions that
focus, minimize, or close windows, and coordinate one UI operator at a time.

Tests needing only shared preview values can compile `WindowPreview.swift`
without inventory services. Resolver tests need `RemoteWindowElementResolver`,
`RemoteWindowElementIDCache`, `RemoteWindowToken`, `RemoteWindowScanPlan`, and
`ConcurrentRemoteWindowScanState`, plus the existing AX bridge declarations or
test stubs. The shared script source groups own these compile inputs.
