# Dock interaction guide

This folder converts Dock input into preview requests. Start with the symptom table below, then read the owning state object. The application and settings connect to `DockHoverMonitor`; other features should not manipulate its input registrations or pending refreshes.

## Entry points by symptom

| Symptom | Start here | Follow through |
| --- | --- | --- |
| Dock hover opens late, closes too early, or returns after focusing | `DockHoverMonitor.updateHover`, `targetAfterSwitchDelay`, `handleFocusTransitionStarted` | `DockHoverSuppressionState`, `DockHoverScheduler` |
| A click activates an app instead of showing previews | `DockHoverMonitor.handleMouseDown`, `handleDockAppClick` | `DockInputMonitor`, `DockClickPreviewController`, `DockClickPreviewState` |
| A click disappears, a drag leaks through, or a click is processed twice | `DockInputMonitor.mouseDownEventCallback`, `handleMouseDown` | `DockMouseDownDeduplicator`, `DockHoverSuppressionState` |
| A stale app/window list replaces the current preview | `DockPreviewRefreshController` request consumers and thumbnail generation | `DockClickPreviewController.resolveDockClick`, `Windowing/WindowInventory` |
| A newly opened window is missing or its thumbnail stays loading during peek | `DockHoverMonitor.refreshVisiblePreviewThumbnails`, `refreshPreviewThumbnails` | `DockPreviewRefreshController.refreshThumbnails`, `Windowing/WindowThumbnailCapturePolicy` |
| A closed/windowless app briefly shows an empty shelf | `DockHoverMonitor.refreshPresentation` | `DockPreviewRefreshController`, `Preview/PreviewPanelController` |
| A Dock icon is missed or matched to the wrong running app | `DockHoverTargetCache`, `DockHoverTargetResolver` | `DockHoverTargetScan`, `RunningAppMatcher` |
| Native Dock names still appear or input is blocked outside Dock | `DockMouseEventSuppressor` | `DockGeometryCache.isInNativeLabelSuppressionStrip` |
| Dock moves, auto-hides, changes display, or restarts | `DockGeometryCache` lifecycle observers and fallback strips | `DockScreenLocator`, `DockHoverTargetResolver.invalidateDockCache` |
| Context-menu dismissal or the next left click misbehaves | `DockContextMenuController` | `DockHoverSuppressionState`, `DockHoverMonitor.handleDockAppClick` |

## File responsibilities and ownership

| File | Responsibility and owned state |
| --- | --- |
| `DockHoverMonitor.swift` | Main interaction coordinator: accepted/pending hover target, anchor, switch delay, exit grace, suppression, settings/Space observers, and focus-return context. Coordinates presentation in the same order as native input. |
| `DockInputMonitor.swift` | Installs, repairs, and removes the event tap and AppKit monitors. Normalizes mouse-down values, deduplicates tap/AppKit delivery, and passes semantic input through narrow handlers. Owns registration tokens and retry timestamps. |
| `DockHoverScheduler.swift` | Owns the one-shot common-mode timer and coalesces movement wakeups on the main queue. The monitor chooses the next interval; the scheduler does not decide hover policy. |
| `DockClickPreviewController.swift` | Owns the pending swallowed click and action generation. Validates metadata, retries within the original deadline, checks the frontmost app, emits presentation decisions, and restores native reopen/activation when required. |
| `DockClickPreviewState.swift` | Pure policy for cached window counts, incomplete discovery, deadlines, and action/frontmost ownership. |
| `DockPreviewRefreshController.swift` | Owns metadata, warmup, and click-validation subscriptions; request identifiers; thumbnail target generations; refresh timestamps; per-PID warmup throttling; and Space epochs. Delivers valid results to the presentation owner. |
| `DockHoverTarget.swift` | Immutable app/Dock-item identity, display metadata, and anchor. Its key deliberately distinguishes running PIDs from non-running Dock items. |
| `DockHoverTargetCache.swift` | Owns the short positive/negative pointer-resolution cache. Clicks use its fresh lookup; hover uses bounded reuse. Excludes points inside the preview. |
| `DockHoverTargetResolver.swift` | Resolves a Dock AX hit chain into an item, shares one deadline across field reads, and caches the Dock process/AX root. `DockHoverTargetScan.Access` is the existing test boundary. |
| `DockHoverSuppressionState.swift` | Timed hover/context-menu/click holds and swallowed mouse-down/drag/up pairing. `MouseDownKind` keeps AppKit and CG modifier rules together. |
| `DockMouseDownDeduplicator.swift` | Bounded history of `(button kind, CG timestamp)` pairs; delayed AppKit delivery cannot repeat an event already seen by the tap. |
| `DockContextMenuController.swift` | Bounded native Dock/DockHelper menu visibility lookup and AX cancellation. Owns its short visibility cache. |
| `DockGeometryCache.swift` | Dock geometry, interaction/label strips, provisional auto-hide entry regions, recent confirmed items, and display/Dock-process invalidation. |
| `DockMouseEventSuppressor.swift` | Separate mouse-movement tap used only for native Dock-label suppression. Updates the shared cursor before notifying the hover monitor. |
| `DockScreenLocator.swift` | Cached Dock anchor with display-visible-frame fallback. |
| `RunningAppMatcher.swift` | Matches bundle identity/path first, then unambiguous normalized titles. A known bundle with no running process is authoritative. |
| `DockAccessibility.swift` | Shared AX scan duration and per-object timeout. Child elements require their own timeout. |
| `DockSnapshotTypes.swift` | Settings-facing snapshot/state/provider contracts and immutable display/capture metadata. Geometry uses points; image-local rects use a bottom-left origin. |
| `DockSnapshotGeometry.swift` | Dock-only candidate validation, three-edge crop geometry, native-pixel metadata comparison, alpha validation, and a copied crop that releases the original framebuffer. |
| `DockSnapshotBackend.swift` | Settings-only AX element ownership and metadata probes on a utility queue, plus one-window SkyLight capture on an independent utility queue. Does not share mutable hover caches. |
| `DockSnapshotService.swift` | Appearance-scoped monitoring, content refresh intent, one in-flight probe/capture each, generations, capture validation, loading deadline, and retry backoff. |
| `DockHoverDiagnostics.swift` | Read-only diagnostic snapshot and formatting, called through `text(at:)` by the debug panel in `App`. It does not own hover decisions or expose its internal snapshot models. |

## Interaction and callback order

`DockInputMonitor` passes a normalized event to the monitor. Only the suppressible event-tap path can intercept an eligible left click; AppKit fallback delivery remains native. A click transaction emits an initial cached presentation, registers authoritative metadata validation, then resolves to a preview, retained cached preview, or native reopen. The monitor handles presentation/suppression before the click controller performs native fallback.

The hover tick repairs input delivery, invalidates obsolete clicks, synchronizes card hover effects, and chooses between an existing preview, a held click preview, suppression, and a new Dock target. Warmup still runs before the switch-delay decision. Metadata and thumbnail callbacks return through the refresh owner, then the monitor checks the current target and visible presentation.

An open shelf discovers added/removed windows through the existing roughly
one-second metadata cadence for the currently previewed app. The refresh owner
allows at most one hover metadata subscription; click validation retains its
existing priority. Hiding or changing the target cancels obsolete subscriptions.
This path does not require cache invalidation or a new polling timer.

Thumbnail checks retain their 450 ms cadence. During a live peek,
`maximumStaleCount` is zero: missing images can fill in, including a new window's
first thumbnail, while new stale-image captures are excluded. Outside live peek
the default remains two stale candidates per batch. Existing capture coalescing,
failure backoff, target-generation rejection, and the limits of two background
operations and one live operation remain in Windowing. Compact lists still request no background
thumbnails. Changing the stale limit does not cancel a capture already started.

Input, timer, click, and refresh objects release their own resources. Handlers retain the monitor weakly. The monitor's deinitializer only removes its own notification observers, so destroying an unstarted monitor does not initialize lazy collaborators during deallocation.

## Invariants to preserve

- Keep UI decisions and state changes on the main thread. Event-tap callbacks that arrive elsewhere retain the existing main-queue handoff; do not add capture, filesystem work, or broad scans to this path.
- Preserve modifier and button behavior: ordinary left click is eligible, Control-left/right opens the native menu, and Command/Option/Shift/Function clicks remain native. A swallowed down also owns its matching drag and up. The event tap fails open when unavailable; the AppKit path cannot claim it suppressed an event.
- A confirmed complete cache of zero or one window leaves a Dock click native. Cold/incomplete discovery may intercept, but its 0.75-second deadline cannot extend. Completion must match both action generation and the initiating frontmost PID. Only a complete snapshot captured since the click can authoritatively restore native behavior for fewer than two windows.
- Metadata, warmup, and click-validation callbacks consume their own identifiers. Click validation replaces the hover metadata subscription and prevents a competing same-target hover refresh. Cancellation must not let a late completion consume a newer subscription.
- Thumbnail callbacks also match their target generation. Leaving and returning to the same PID is a new generation. Repeating the same current target is not. Monitor restart always resets the background target.
- Space changes advance the metadata epoch, invalidate click work, reset hover, clear thumbnail failure backoff, and wake the monitor in that order. A warmup started on an earlier epoch cannot mark the new Space fresh.
- Warmup cancellation of an active request releases its PID throttle; completed warmup does not. Retain the 3-second warmup interval and 32-entry pruning threshold.
- A valid empty window list stays hidden and still counts as fresh metadata. A hidden empty shelf alone is not a reason to rescan every 80 ms. A non-running Dock item also has no prevDock label panel.
- Preserve 80 ms active ticks, 1-second idle watchdog, 450 ms thumbnail cadence, 200 ms exit grace, 250 ms pending-target click fallback, 120 ms positive hit caching, and 200 ms negative caching. The global-movement-monitor fallback keeps fast ticks when movement delivery is unavailable.
- Preserve a failed focus transition's return target and click hold. A completed selection must hide both shelf and peek before focus restoration; keyboard app/window/Space navigation cancels pending focus.
- Geometry and label suppression have different scopes: broad fallback/provisional interaction strips may prompt hit testing, but only confirmed Dock geometry/items may swallow mouse movement.

## Validation record

The 2026-09-08 refactor uses `.build/architecture-refactor/baseline` as its behavior reference. The original monitor was 1,373 lines. Its input, scheduling, pointer cache, native menu, refresh ownership, and click transaction bodies were moved into the owners above; policy predicates, timeout values, callback rejection, and native fallback ordering were retained. `DockClickPreviewState`, `DockHoverSuppressionState`, `DockMouseDownDeduplicator`, `DockFocusNavigation`, `DockGeometryCache`, `DockHoverTargetResolver`, `DockMouseEventSuppressor`, `DockScreenLocator`, `RunningAppMatcher`, and `DockAccessibility` remain byte-identical to that baseline.

- Production typecheck: latest Dock sources plus baseline sources for other features passed Swift 5 with warnings as errors and the macOS 14 deployment target. Log: `.build/architecture-refactor/dock-typecheck.log`.
- `DockPreviewRefreshTests` typecheck passed. Its queued-callback fixtures exercise metadata replacement, click/hover arbitration, thumbnail PID round trips, canceled warmup throttling, and Space epoch changes without opening apps or manipulating input. Runtime execution is reserved for the root verification sequence.
- Existing focused suites: `scripts/test-dock-click-preview.sh`, `scripts/test-dock-hover-suppression.sh`, and `scripts/test-dock-hover-target.sh`. The target suite defines its own `DockHoverTarget` stub; do not also compile the production model into it.
- Root verification must run the full build and real Dock scenarios through `scripts/test-dock-click-live.sh`, including cold/warm clicks, modifiers/context menus, exact-window selection, empty/non-running apps, quick focus return, and warm/cold minimized previews. No actual UI interaction or live tests were performed by this refactor worker.

For the subsequent new-window thumbnail fix, run
`./scripts/test-dock-click-live.sh --window-updates-only` to verify 4→5→4 window
updates, a new card reaching `Ready` during live peek, and selection of the added
window. `--inspect-window-updates` instead prepares the real shelf for 90 seconds
of computer-use inspection with fixture `SIGUSR1`/`SIGUSR2` window changes and
restoration on normal completion. See [TESTING.md](../../../TESTING.md) for that procedure.

For a real-machine report, start with the symptom entry above and `DockHoverDiagnostics.text(at:)`; collect the diagnostic state before changing timing or suppression rules.

## Appearance Dock snapshot

The Appearance page injects a `DockSnapshotProviding` service. `setActive` scopes
its one-second, common-run-loop metadata timer to the displayed settings page;
leaving the page, closing/minimizing the window, or detaching the view stops it.
It does not depend on the settings window remaining key. Layout and preference
slider changes redraw the sample without requesting screen pixels. Application,
permission, Space, and display notifications coalesce content refreshes through
the service's internal `refresh` API; recovery needs no refresh button.

The backend caches Dock/Finder AX elements independently from hover hit testing.
Each AX object has the existing 25 ms messaging timeout, with a 120 ms traversal
deadline and at most 192 discovered nodes. Failed element/window discovery is
retried no more often than every five seconds. A valid cached window association
uses a targeted CG metadata lookup; a missing/replaced window may trigger a
bounded fallback lookup of visible Dock-owned windows. Permissions use the
shared `PermissionManager` snapshot, never a separate capture-worker preflight.

Unchanged metadata does not capture an image. New visible geometry, a revealed
Dock, or a coalesced content refresh requests one `.best` SkyLight capture of the
identified Dock window. Capture and metadata run independently so a slow native
capture cannot prevent hidden-state detection. The service retains at most one
running operation of each kind and one pending metadata intent. A completed
image is withheld until a fresh metadata probe confirms the same context,
window, native-pixel geometry, and visibility. Hidden/unknown/permission loss
clears pixels and advances the generation, rejecting a late result even when
the Dock later returns to the same coordinates. The stage may retain geometry
values solely to keep its outer frame fixed.

Loading falls back after two seconds; failed image capture retries automatically
after at least five seconds. The synchronous private capture call itself cannot
be canceled, so obsolete results are discarded and replacement captures wait
for its completion. Auto-hide is a preference, not proof that the Dock is hidden:
hidden status requires off-screen/visibility geometry or window-state evidence.
Neither fallback interaction strips nor a screen-wide screenshot are used as
Dock image data. Snapshot pixels stay in memory and are released on deactivation.

Run `./scripts/test-dock-snapshot-geometry.sh` for three-edge, Retina/negative
display, cropped-buffer/alpha, candidate ownership, and pixel-precision checks.
Run `./scripts/test-dock-snapshot-service.sh` for a fake-clock/backend verification
of unchanged probes, hidden/permission/context rejection, reactivation during an
old capture, pending refresh coalescing, deadlines, and retry backoff. These
deterministic suites do not capture the desktop, open windows, or alter preferences.
Actual Dock behavior still requires the opt-in live snapshot harness described
in `TESTING.md`; desktop runs must be serialized with other live verification.
