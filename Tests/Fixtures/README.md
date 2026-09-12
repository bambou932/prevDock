# Interactive UI fixtures

Only one agent should operate the desktop at a time. Coordinate before opening
fixtures or moving the pointer, changing focus, or resizing a window.

## Settings UI

Build without launching:

```sh
./scripts/run-settings-ui-fixture.sh --build-only
```

Build and open:

```sh
./scripts/run-settings-ui-fixture.sh
```

The stable app path is `.build/settings-ui-fixture/SettingsUIFixture.app`, and its
bundle identifier is `io.github.bambou932.prevDock.tests.settings-ui`. A computer
use tool can open that path or select **prevDock Settings Fixture** after launch.
The app remains running when its settings window closes; click its Dock icon or
choose **Settings…** to reopen it. Quit with **Command-Q** when finished.

After changing source, quit the running fixture with **Command-Q**, then rerun
the build-and-open command. Closing its window is insufficient: the script's
`open` command reactivates an existing process, which would still use the old
code. A fresh process also resets the fixture preferences and simulated state.

This fixture runs the actual `SettingsWindowController`, settings pages, and
sample preview cards. Use it to inspect light/dark appearance, click controls,
test Tab navigation and Command-1 through Command-5 page shortcuts, resize down
to the supported minimum, and verify close/reopen behavior. The **Fixture** menu
changes only the fixture's appearance, simulated permission status, or simulated
update-check completion.

`SettingsServiceStubs.swift` is shared with the deterministic settings layout
suite. Login, permission requests, System Settings links, Sparkle updates, and
window peek actions use those in-process stubs. For example, **Check for
Updates…** stays busy until **Fixture → Finish Simulated Update Check** is chosen;
permission buttons record requests but do not grant real access. Toggle the
simulated granted states in **Fixture** to inspect both permission layouts.

`SettingsDockSnapshotStub.swift` also keeps the appearance example independent
of the real Dock. It starts with a hidden-Dock message; deterministic tests can
publish snapshot/status values to verify exact-size placement and transitions.
The fixture does not start AX scans, capture timers or a real Dock image cache.

The screen-geometry stub keeps the main-screen frame captured at launch; it does
not track display changes or validate actual multi-display placement. Login
changes always succeed, and simulated System Settings links always report
success. These stubs do not exercise registration failures, real permission
links, or updater error handling.

Preferences use only the fixture's separate bundle domain, cleared before each
launch and on normal quit. A forced termination may leave that test domain until
the next launch. No real prevDock preferences, login items, TCC permissions, or
update settings are changed. The Settings **Updates** page deliberately shows the
same fixed `1.2.3 (45)` version as the layout tests.

A successful interaction here validates the real view/control behavior with
simulated services. It does not establish actual permission prompting, login
registration, update delivery, Dock events, window capture, or focus behavior.
Use the real app and the backend/live suites in [TESTING.md](../../TESTING.md) for
those checks, and record environment-dependent or error paths left untested.

## Preview windows

`./scripts/run-preview-window-fixture.sh [window-count] [--build-only]` builds a
separate app with owned windows for cross-process Dock, capture, minimize, focus,
and close verification. Its backend interactions are distinct from the settings
fixture's simulated services.
