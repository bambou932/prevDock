# Code navigation

Read [AGENTS.md](AGENTS.md) first. This is one Swift 5 AppKit executable, assembled by `scripts/build.sh`; folders describe feature ownership, not separately compiled packages.

## Follow a user interaction

```text
AppDelegate
  ├─ StatusItemController → SettingsWindowController → SettingsContentView
  ├─ PermissionManager → PermissionStatusCache
  └─ DockHoverMonitor
       ├─ Dock input, target resolution, click and refresh controllers
       ├─ WindowInventory → WindowDiscovery / capture queues / caches
       └─ PreviewPanelController
            ├─ PreviewPanelLayout → PreviewLayoutPlanner
            ├─ PreviewPanelContentBuilder → PreviewCardView / DesktopGroupView
            └─ WindowPeekController

Preview card selection → WindowInventory façade → WindowCommands → AX / SkyLight
```

The Dock chooses **which app and when**. Windowing supplies **window identity, metadata, images and OS commands**. Preview decides **how to present that inventory**. Settings persist preferences and notify consumers. Their appearance example requests a read-only Dock snapshot through a separate Dock service; settings views never capture images themselves or alter other apps' windows.

## Choose the feature before editing

| Change or symptom | Starting point | Detailed map |
| --- | --- | --- |
| Launch, duplicate instances, first-run ordering | `App/Main.swift`, `App/AppDelegate.swift`, `App/SingleInstanceCoordinator.swift` | [App](Sources/prevDock/App/README.md) |
| Menu bar icon, menu commands, permission menu label | `App/StatusItemController.swift` | [App](Sources/prevDock/App/README.md) |
| Dock hover/click, native labels, inactive/windowless apps | `Dock/DockHoverMonitor.swift` | [Dock](Sources/prevDock/Dock/README.md) |
| Missing windows, cache, repeated loading, wrong selected window | `Windowing/WindowInventory.swift` | [Windowing](Sources/prevDock/Windowing/README.md) |
| Shelf size, single row/wrap, desktop grouping, compact list | `Preview/PreviewPanelLayout.swift`, `Preview/PreviewPanelContentBuilder.swift` | [Preview](Sources/prevDock/Preview/README.md) |
| Card hover, close action, loading UI, focus flicker | `Preview/PreviewCardView.swift`, `Preview/PreviewPanelController.swift` | [Preview](Sources/prevDock/Preview/README.md) |
| Enlarged hover, minimized snapshots, live capture cadence | `Preview/WindowPeekController.swift` | [Preview](Sources/prevDock/Preview/README.md) |
| Settings navigation, controls, appearance example | `Settings/SettingsContentView.swift`, `Settings/SettingsPreviewStage.swift` | [Settings](Sources/prevDock/Settings/README.md) |
| Saved defaults, old preference migration | `Settings/PrevDockSettings.swift`, `Settings/PreviewPreferences.swift` | [Settings](Sources/prevDock/Settings/README.md) |
| Permissions or status refresh | `App/PermissionManager.swift`, `Settings/PermissionSettingsView.swift` | [App](Sources/prevDock/App/README.md), [Settings](Sources/prevDock/Settings/README.md) |
| Coordinate conversion, Retina/multiple-display placement | `Support/ScreenGeometry.swift`, `Support/AccessibilityHelpers.swift` | Shared helpers below |
| Hover diagnostics | `App/HoverDebugPanelController.swift`, `Dock/DockHoverDiagnostics.swift` | [Dock](Sources/prevDock/Dock/README.md) |
| Signing, release artifacts, update feed | `scripts/build.sh`, `scripts/release.sh`, `App/UpdateController.swift` | [README](README.md), [testing](TESTING.md) |

Paths in the table are relative to `Sources/prevDock`, except `scripts`.

## Preserve these boundaries

- Keep AppKit view and interaction state on the main thread. Preserve existing queues, locks and callback delivery when moving code; changing the owning type does not grant permission to change the executing queue.
- Metadata cache, thumbnail cache and hover image ownership have distinct lifetimes. Keep process/window identities, capture signatures and invalidation generations intact.
- A delayed callback needs both a valid generation and the appropriate current user interaction. Cancellation of a request does not imply cancellation of an already running native capture.
- An empty app does not get a prevDock label or an empty panel. A swallowed Dock click must resolve to previews or recover the original native action.
- Focus transitions hide previews before the OS command and keep them suppressed until new user intent. Metadata updates cannot undo that suppression.
- Layout measurement and rendering use the same immutable window/group snapshot. Preserve scroll position and same-window hover ownership across reflow.
- A minimized hover uses an available snapshot at the original valid bounds. It does not restore or move the real window; window selection owns restoration.
- Read-only settings examples cannot invoke real window actions. Settings changes retain their defaults, migration rules, notification keys and refresh behavior.
- Keep private helpers next to their owner. Extract a collaborator only when it owns a coherent responsibility; expose values and narrow operations instead of sharing mutable controller fields.

## Shared helpers

`Support` contains helpers used across features: typed AX attribute access and coordinate conversion (`AccessibilityHelpers`), the primary-display reference (`ScreenGeometry`), the locked event-tap cursor snapshot (`DockCursorTracker`), and system highlight colors (`PrevDockColors`). Feature-specific logic belongs in its feature folder.

Quartz/AX coordinates use a top-origin reference, while AppKit uses a bottom-origin reference. Always convert through `AccessibilityHelpers` / `ScreenGeometry`; do not assume `NSScreen.main` is the primary display or that the primary screen starts at the pointer's screen origin.

## Find and verify code

Use `rg --files Sources/prevDock` to locate a feature and `rg -n 'SymbolName' Sources Tests scripts` to follow its call sites and tests. The feature maps list the important invariants and focused scripts.

`scripts/test.sh --list` lists the deterministic suites, and `scripts/test.sh preview-loading window-peek-refresh` runs a selected subset. `scripts/build.sh` runs every deterministic suite before building the app. Shared test source sets live in `scripts/test-sources.sh`; tests deliberately substitute some OS services, so do not replace their file sets with all project sources.

For direct settings UI checks, `./scripts/run-settings-ui-fixture.sh` builds the real views with isolated preferences and service stubs. Quit the fixture with Command-Q before rebuilding after edits. The [fixture guide](Tests/Fixtures/README.md) explains its controls, fixed screen geometry, and simulated services; use the real app to verify OS integration.

See [TESTING.md](TESTING.md) for real application and computer-use verification. Code movement and behavior changes should be reviewed separately. A newly found feature bug needs a reproduction and its own fix branch; do not hide it inside a refactor.
