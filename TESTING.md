# Verification

Run commands from the repository root. Read `AGENTS.md` and the feature map in `ARCHITECTURE.md` first. Deterministic tests substitute some OS services; a passing mock is not evidence that macOS permissions, Space switching or native focus worked on a real desktop.

## Commands

| Command | Purpose |
| --- | --- |
| `./scripts/build.sh` | Run all deterministic suites, compile the optimized app and sign `build/prevDock.app`. |
| `./scripts/test.sh --list` | List the deterministic suites in their execution order. |
| `./scripts/test.sh preview-loading window-peek-refresh` | Run a selected subset without rebuilding the app. |
| `./scripts/test-settings-window-layout.sh .build/settings-snapshots` | Save all settings pages in light and dark appearances while checking controls, keyboard navigation and three window sizes. |
| `./scripts/test.sh dock-snapshot-geometry dock-snapshot-service` | Check point/pixel crop geometry, hidden-state rejection, capture coalescing, loading deadlines and retry backoff without touching the Dock. |
| `./scripts/test-settings-dock-snapshot-live.sh` | Verify actual Dock capture at bottom/left/right with autohide on/off, then restore the saved Dock configuration and desktop. Requires existing Accessibility and Screen Recording access. |
| `./scripts/test-settings-dock-snapshot-live.sh --inspect` | Show the real capture service and Appearance stage for 90 seconds of computer-use inspection with the current Dock configuration. |
| `./scripts/run-settings-ui-fixture.sh --build-only` | Build the real settings UI with isolated preferences and simulated OS services, without launching it. |
| `./scripts/run-settings-ui-fixture.sh` | Build and open that settings fixture for direct UI checks; quit any running instance with Command-Q before rebuilding. |
| `./scripts/test-dock-click-live.sh` | Exercise real Dock/native-event interactions using temporary fixture apps; requires existing Accessibility and Screen Recording access. |
| `./scripts/test-dock-click-live.sh --windowless-only` | Focus on the last-window-close, empty-hover, new-window and reopening lifecycle. |
| `./scripts/test-dock-click-live.sh --window-updates-only` | Check an open shelf changing from 4→5→4 windows, the new thumbnail reaching `Ready` during live peek, and exact-window selection of the new card. |
| `./scripts/test-dock-click-live.sh --context-menu-only` | Isolate native Dock menu dismissal and preview recovery for inactive and already active apps. |
| `./scripts/test-dock-click-live.sh --inspect-window-updates` | Prepare the actual app's open four-window shelf for 90 seconds of manual/computer-use inspection, then restore the desktop. |
| `./scripts/test-window-preview-live.sh <bundle-id>` | Check discovery, metadata/image delivery, retained cache and live capture against a running app. |
| `./scripts/test-remote-window-cache-live.sh <bundle-id>` | Compare cold/warm remote AX resolution against a running app. |
| `./scripts/run-preview-window-fixture.sh 12` | Open disposable, titled windows with varied aspect ratios for direct desktop testing; supports 1–100 windows. |
| `codesign --verify --deep --strict build/prevDock.app` | Verify the complete app signature after building. |

Source groups used by tests live in `scripts/test-sources.sh`. Preserve deliberate stubs: adding all production sources to a test can both duplicate types and accidentally touch user settings or OS services. Keep desktop suites serial, including across agents.

See the [interactive fixture guide](Tests/Fixtures/README.md) for settings UI controls and restart steps. Its screen geometry is fixed at launch, login changes always succeed, and System Settings links are simulated. Fixture checks do not cover display changes or real service failures; use the built app for those checks and report untested paths explicitly.

For `--inspect-window-updates`, build `build/prevDock.app` first and wait for
`INSPECT ready` before taking over the pointer with the computer-use tool. This
mode uses the real app and four disposable fixture windows. During its 90-second
inspection period, send `SIGUSR1` to add a window or `SIGUSR2` to remove the last
one, targeting only the PID of bundle
`io.github.bambou932.prevDock.PreviewWindowFixture`. Keep the pointer on the Dock
item or an existing card to observe automatic updates; moving away can dismiss
the shelf normally. On normal completion, the test closes its fixtures, restores
whether prevDock was running, and restores the prior pointer position and
frontmost app. The inspection period is for direct observation and does not
replace the assertions in `--window-updates-only`.

## Direct computer-use checklist

Use the built app and disposable fixture windows. Record the OS, display arrangement, settings used, actual observed result and any unavailable environment. Restore settings, Dock configuration and focus afterward; quit the fixture. Do not close user documents to produce test cases.

| Feature | Direct action and expected observation |
| --- | --- |
| Startup and singleton | Open the built app twice; one menu bar item/process remains and normal previews still work. |
| Menu commands | Open settings, permissions, debug and update check from the menu; verify the selected window and dismiss it normally. |
| Settings navigation | Click all five pages, use Command-1–5, Tab/Shift-Tab, Command-comma and Command-W; reopen to the last selected page. Repeat shortcuts with the active non-Latin input method. |
| General preferences | Change switch delay, Dock-click previews and native-label suppression; inspect persisted control values and the corresponding Dock behavior, then restore. |
| Appearance | Change all title-size and window-height choices and close-button visibility; compare the sample with actual cards and restore preferences. |
| Layout | Check automatic single row with a few windows, compact list with many, manual horizontal overflow, wrapped rows and desktop grouping. Scroll to the final window and back; modify the window count while visible. |
| Settings sizing | Resize the window to its minimum and a larger size; controls stay reachable and the detail page scrolls. Verify light/dark appearance without changing unrelated preferences. |
| Permission UI | Verify existing granted/needed state, the relevant System Settings links, return-to-app refresh and keyboard-focus handoff. Do not claim real grant/revocation was tested if only mocked status was changed. |
| Login item | Toggle registration and verify the actual OS-backed state; restore the previous setting. A real sign-in launch requires a separate sign-out/restart session. |
| Updates | Toggle update preferences and restore them; invoke a check and inspect its completion/error dialog. Do not install a different build as part of a structural refactor. |
| Ordinary Dock hover | Hover a multi-window app and switch to another; observe correct anchored previews, order, image recovery and configured delay. Move away and verify dismissal. |
| Open shelf updates | Add/remove a fixture window while staying on the Dock item, then repeat while hovering an existing card. The list follows 4→5→4, the new thumbnail becomes `Ready` during peek, existing cards stay ordered, and selecting the new card focuses its exact window. |
| Dock click | Test enabled/disabled multi-window behavior, zero/one-window native behavior, a fresh cache, Shift-click and native context-menu recovery. |
| Empty/inactive app | Close only fixture windows or use an inactive Dock item; no prevDock empty panel or name-only label appears. Reopen/create a fixture window and verify recovery. |
| Card actions | Select by mouse and accessibility action; the exact window gains focus without the shelf/peek reappearing. Close a fixture card, including the last card. |
| Full-size hover | Hover a card, switch cards and leave; correct bounds/image appear, update and dismiss without changing the real target window. |
| Minimized windows | Minimize fixture windows before and after filling the cache. Check thumbnails and original-position hover; the real window stays minimized/inactive until selection. |
| Fullscreen/Spaces | Where available, use a disposable window on another Desktop and fullscreen; verify discovery, grouping, focus, return and intentional fullscreen-peek suppression. |
| Dock/display variants | Where available, verify left/right/bottom Dock placement, magnification, autohide, multiple displays and changed screen geometry. Geometry unit tests do not replace a physical multi-display run. |
| Diagnostics/resources | Open/close Hover Debug, observe changing diagnostics, then verify its timer is stopped. Observe idle and active-hover CPU/capture work separately. |

## Reporting

For Appearance, the single 4:3 sample must use production card dimensions at 1:1
logical-point scale. Preference changes update it immediately, without a refresh
button, stage resize, control movement or capture request. Compare the maximum
and minimum choices at the same scroll position. A side Dock may increase the
window's minimum width independently of the selected preview preferences.
While Dock pixels are hidden/unavailable, retain the reserved scene space and
show the appropriate status. After revealing the actual Dock, allow roughly one
second for metadata detection, then verify a fresh image replaces the status.

The live snapshot harness writes JSON events and stage PNGs under
`.build/settings-dock-snapshot-live/report.*`. Its standalone stage uses the
production capture service; it does not replace checks of the full settings
window. The separate settings UI fixture uses a Dock stub. Keep these evidence
types distinct. A saved `desktop-state.plist` is removed only after restoration;
the harness script retries restoration on exit if the file remains.

Keep local screenshots and logs under `.build/`. Report automated suites, direct actions and environment-only limitations separately. For a discovered bug, keep the reproduction and fix on a purpose-named `fix/` branch and rerun its regression plus the full build. Never infer correctness from an attempted click alone; read the resulting UI state.
