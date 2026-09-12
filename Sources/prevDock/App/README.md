# App lifecycle

| File | Owns |
| --- | --- |
| `Main.swift` | Shared NSApplication, accessory activation policy, delegate lifetime. |
| `AppDelegate.swift` | Startup ordering, feature wiring, settings/permission/workspace observers and termination cleanup. |
| `StatusItemController.swift` | Menu bar item, icon, menu targets and permission label; delegates feature actions through callbacks. |
| `PermissionManager.swift` | Accessibility/Screen Recording probes, requests and System Settings links. |
| `PermissionStatusCache.swift` | Locked permission snapshot, bounded refresh and main-thread probes. |
| `SingleInstanceCoordinator.swift` | Process lock and handling an existing instance. |
| `LaunchAtLoginController.swift` | SMAppService registration and persisted first-install retry state. |
| `UpdateController.swift` | Sparkle lifecycle, update preferences and availability observation. |
| `HoverDebugPanelController.swift` | Debug panel visibility and its visible-only timer; diagnostic reading lives in `DockHoverDiagnostics`. |

Startup must claim a single instance before starting services. Determine whether preferences existed before registering defaults or constructing Sparkle. Construct the updater lazily when wiring its menu item so its own preferences do not turn a fresh install into an existing one.

On Screen Recording revocation, discard cached images before hiding/restarting presentation. Capture workers read a bounded permission snapshot; they never synchronously wait for the main thread to probe permission.

Keep the menu callback's asynchronous dispatch when opening ordinary settings. Permission setup has separate persisted first-run state and focuses the relevant settings page. Automatic first-run login registration and permission UI each retain their existing guard conditions.

Relevant checks: `scripts/test-app-startup.sh`, `scripts/test-permission-status-cache.sh`, `scripts/test-permission-settings-view.sh`, `scripts/test-settings-window-layout.sh`. Real menu commands, settings links, single-instance launch and login registration are covered by the [computer-use checklist](../../../TESTING.md).
