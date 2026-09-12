# Settings

| File | Owns |
| --- | --- |
| `PrevDockSettings.swift` | Preference keys, defaults, normalization, migration and change notifications. |
| `PreviewPreferences.swift` | Persisted enum values for layout, title size and thumbnail height. |
| `SettingsWindowController.swift` | Native settings window, opening/focus behavior and keyboard menu. |
| `SettingsContentView.swift` | Selected page, page cache, controls, preference bindings and callbacks. |
| `SettingsPane.swift` | Five-page order, titles, subtitles and SF Symbols. |
| `SettingsSidebarView.swift` | Sidebar selection and keyboard focus. |
| `SettingsPageView.swift` | Scrollable page shell and section sizing. |
| `SettingsUI.swift` | Shared labels, stacks, rows, groups and card appearance. |
| `SettingsLayoutOptionButton.swift` | Single-row/wrap option drawing and accessibility. |
| `SettingsPreviewStage.swift` | Actual-size synthetic card, Dock snapshot presentation, and Appearance-only snapshot lifecycle. |
| `SettingsPreviewStageLayout.swift` | Fixed maximum-size scene reservation and 1:1 Dock crop placement. |
| `PermissionSettingsView.swift` | Permission summary, active-page state and bounded monitoring. |
| `PermissionRowView.swift` | Each permission's status, request/review actions and keyboard-focus handoff. |

Preserve enum raw values and preference keys: existing users may have legacy `auto` layout or the old Dock click key. Do not register a boolean default before code has distinguished an absent preference from an explicit `false`. Switching away from automatic single-row layout preserves the inferred preference for a later switch back.

The native keyboard menu supports Command-W/comma/1–5, including non-Latin input methods, and defers while a sheet is attached. Page switching moves focus out of the old page before removing it. Permission monitoring stops when the page/window closes or permissions are granted; opening settings is not a reason to start permanent polling.

The appearance card uses one synthetic 4:3 Finder image and the production card metrics at 1:1 logical-point size. Its controls remain decorative and cannot focus, close or peek a real window. Preference changes update it immediately; no refresh button is needed. The real Dock image is supplied automatically by a separate Dock snapshot service; it never enters the window-thumbnail cache or the input monitor.

Reserve the largest thumbnail, title and desktop-group geometry before applying selected preferences. Changing preview preferences must not resize the stage, move the controls below it or recapture the Dock. A wider left/right Dock can increase the settings window's minimum width and the Appearance page's width limit. Hidden Dock pixels are removed while the last geometry can still reserve space. The snapshot service is active only while Appearance is attached to a visible, non-minimized window; being the key window is not required.

Relevant checks: `scripts/test-settings-booleans.sh`, `scripts/test-settings-window-layout.sh`, `scripts/test-permission-settings-view.sh`, `scripts/test-app-startup.sh`. Save light/dark page snapshots with `scripts/test-settings-window-layout.sh .build/settings-snapshots`. See [testing](../../../TESTING.md) for actual UI actions and environment limits.
