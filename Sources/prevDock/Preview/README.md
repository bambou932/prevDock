# Preview code map

This folder presents window metadata and images supplied by `Windowing`. Dock hit testing and the choice of which app to present belong to `Dock`. Read the repository `AGENTS.md` before changing either boundary.

## Ownership and file responsibilities

| File | Responsibility and state it owns |
| --- | --- |
| `PreviewPanelController.swift` | Public shelf entry points (`show`, `hide`, image updates), current app/window ordering, card ownership, focus suppression, removal/reflow generations, scroll and hover handoff. This is the starting point for presentation lifecycle changes. |
| `PreviewPanelSurface.swift` | The reusable nonactivating `NSPanel`, visual-effect backdrop, root view and stack. It configures native views; it does not decide when to show them. |
| `PreviewPanelLayout.swift` | Screen/Dock geometry, desktop grouping, manual row/group measurements, automatic-layout input and its single cached decision. It has no cards, focus callbacks or timers. |
| `PreviewAnchorLayout.swift` | Pure Dock-edge placement shared by the real panel and the settings example; preserves the 4-point gap and visible-screen clamping. |
| `PreviewPanelLayoutModels.swift` | Values passed between measurement, rendering and presentation comparison: desktop identities, row/group layouts and automatic presentation results. |
| `PreviewPanelContentBuilder.swift` | Synchronous assembly of cards, desktop groups and scroll containers. Each builder is short-lived and receives the controller's card factory; it does not retain presentation state or schedule work. |
| `PreviewLayoutPlanner.swift` | AppKit-independent automatic sizing, available-screen-space calculations, shape signatures and compact-list plans. |
| `PreviewPresentationLayout.swift` | Low-level AppKit row/scroll installation, exact plan-to-view ID validation, scroll restoration and horizontal wheel handling. Also defines card typography/chrome geometry. |
| `PreviewCardView.swift` | A live or sample card's image, title/status, action feedback, loading deadline, hover ownership and focus/close callbacks. The private hover coordinator stays beside the card state it coordinates. |
| `PreviewCloseButton.swift` | Circular close control drawing and pointer tracking. The card supplies its action and visibility. |
| `DesktopGroupView.swift` | Desktop group container, title badge, group hover highlight and clipping-aware tracking. |
| `PreviewInitialHoverGate.swift` | Shared initial stationary-pointer suppression for cards and desktop groups. |
| `PreviewHighlightCornerRadius.swift` | Bounded image-alpha sampling and the cache key for thumbnail highlight geometry. |
| `PreviewThumbnailPlaceholderViews.swift` | Loading/unavailable visuals and the neutral `WindowPreview.placeholder` used for sizing. |
| `PreviewMetrics.swift` | Preview sizes, content spacing, hover timing and the settings-to-size mapping shared by live and sample previews. |
| `WindowPeekController.swift` | Reusable full-size hover overlay/dimming panels, current hover target, single in-flight live capture, generation/backoff state and minimized-window static snapshots. |
| `LivePreviewCadence.swift` | Bounded live-capture cadence and Quartz-to-AppKit frame conversion. |

`PreviewPanelController` owns one `PreviewPanelSurface` and one `PreviewPanelLayout`. Its card factory registers every created card and supplies weak focus/close callbacks. `PreviewPanelContentBuilder` uses that factory synchronously; storing the builder on the controller would unnecessarily extend the factory's reference to its owner.

## Find a symptom

| Symptom | Start here, then follow the boundary |
| --- | --- |
| Shelf remains visible for an empty app | `PreviewPanelController.show` and `clearEmptyPresentation`; check the inventory delivered by `DockHoverMonitor`. |
| Clicking a card flashes the shelf or reopens it over the selected window | `beginFocusTransition`, `finishFocusTransition`, `resumePresentationForInteraction`; then the card's `beginAction`. |
| Wrong row is highlighted or hover survives a scroll/reflow | `PreviewCardView.synchronizeHover`, `contains`, `PreviewInitialHoverGate`; then controller `prepareAutoHoverTransfer` / `finishAutoHoverTransfer`. |
| Panel is clipped, placed on the wrong display or selects the wrong layout | `PreviewPanelLayout.availablePanelSize`, `positionedFrame`, `autoLayoutDecision`; then the pure planner. |
| Desktop groups reorder or differ between sizing and rendering | `PreviewPanelLayout.desktopGroups`, immutable `PreviewDesktopGroup` values, and builder `addAutoPreviewContent`. |
| Scroll position jumps or later windows are unreachable | `PreviewPresentationLayout.restoreScrollPosition` / scroll containers; then row/group viewport measurements in `PreviewPanelLayout`. |
| Thumbnail is stuck loading | `PreviewCardView.scheduleThumbnailLoadingDeadlineIfNeeded`, `updatePreview`, `updateImage`; then capture/cache delivery in `Windowing`. |
| Minimized thumbnail exists but enlarged hover does not appear | `WindowPeekController.showSnapshot` / `updateSnapshot` and `PreviewCardView.updateSnapshotPeekIfNeeded`; verify image and original bounds delivered by inventory. |
| Old image appears after switching or dismissing hover | `WindowPeekController.stopLiveRefresh` / `completeLiveRefresh`; preserve the capture generation and current target checks. |
| Preview size controls differ from the settings example | `PreviewMetrics`, `PreviewContentStyle` and `Settings/SettingsPreviewStage.swift`. |

## Behavioral invariants

- UI objects and presentation state remain on the main thread. Inventory and capture scheduling remain in `Windowing`; view helpers must not introduce AX polling or capture work.
- Automatic layout uses exactly the planned window IDs and immutable desktop-group snapshot. Measuring and rendering must use the same image height, card chrome and group metadata.
- The layout cache belongs to one controller and is cleared with an empty presentation. Repeated equal inputs reuse its decision; settings, geometry and item shape remain part of the input.
- An empty inventory hides the shelf and peek immediately. Old removal/reflow callbacks must not recreate the empty presentation.
- Pending focus and suppression after successful focus have different lifetimes. Metadata cannot release suppression; only a fresh interaction can resume presentation.
- Focus hides shelf and peek before invoking callbacks or the OS performer. A failed focus restores the shelf with stationary-pointer suppression, without restarting a peek.
- Card tracking uses `bounds.intersection(visibleRect)` and validates the current pointer. AppKit can report a `visibleRect` larger than an unclipped card.
- Reflow may hand off an existing hover only to the same surviving window under the pointer. Old card destruction must not hide a successfully transferred peek.
- Peek changes share one in-flight capture. Generation and window-ID checks reject outdated completions; hide does not pretend to cancel an uninterruptible capture.
- A minimized peek draws an existing image at its original valid frame. It does not restore/focus/move the real window or start a live-capture timer. A late image may update only the current minimized hover target.
- Samples cannot trigger real focus/close/peek actions. Settings additionally exclude decorative sample controls from keyboard navigation.
- Preserve the existing timing unless a separate behavior change is requested: zero peek delay, 45 ms hover-exit grace, 2 s loading fallback, 1.5 s action feedback, 140 ms automatic reflow, 160 ms removal plus its 20 ms completion margin, and the live cadence/backoff limits.

## Verification

Run the repository build with `./scripts/build.sh`. The focused scripts below are run from the repository root; some create AppKit windows or move the pointer, so coordinate actual desktop testing with other agents.

| Test/script | Coverage |
| --- | --- |
| `PreviewLayoutPlannerTests` / `scripts/test-preview-layout.sh` | Automatic fit, compact fallback, available screen geometry and grouped plans. |
| `PreviewPresentationTests` / `scripts/test-preview-presentation.sh` | Exact plan installation, card chrome, manual overflow and scroll hierarchy. |
| `PreviewLoadingTests` / `scripts/test-preview-loading.sh` | Loading deadline/recovery, hover bounds, accessibility actions, minimized late-image ownership and compact cards. |
| `PreviewPanelIntegrationTests` / `scripts/test-preview-panel.sh` | Focus suppression/failure, empty panels, removal/reflow, scroll restoration and actual AppKit hierarchy. |
| `WindowPeekRefreshTests` / `scripts/test-window-peek-refresh.sh` | In-flight capture coalescing, obsolete generations, hide/reopen, static minimized snapshots, late images and permission/geometry gates. |
| `SettingsWindowLayoutTests` / `scripts/test-settings-window-layout.sh` | Real sample cards within settings, first-display layout, native controls and decorative keyboard exclusion. |
| `DockClickLiveTests` / `scripts/test-dock-click-live.sh` | Fixture-backed Dock clicks, physical card selection, focus flicker, empty-app lifecycle, warm/cold minimized thumbnails, original peek bounds and restoration only after selection. |
| `WindowPreviewLiveTests` / `scripts/test-window-preview-live.sh` | Real window inventory, capture completion, cache retention and live thumbnail cadence. |
