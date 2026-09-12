# prevDock

`prevDock` is a small macOS utility that shows Windows 11-style window previews when the pointer hovers over an app icon in the Dock.

Previews appear only for running apps with available windows. Apps with no windows and apps that are not running do not show an empty panel or a name-only prevDock label.

`0.1.0` is an early preview release, not a stable 1.0 release. The first public builds support Apple Silicon Macs running macOS 14 or later.

## Install

Homebrew installation:

```sh
brew tap bambou932/prevdock
brew install --cask prevdock
```

You can also download `prevDock-0.1.0-arm64.zip` from the GitHub Releases page.

### First launch on macOS

Preview builds are not Apple-notarized yet. macOS may block the first launch with a warning that Apple cannot verify the app.

Use either workaround:

- In Finder, open `/Applications`, Control-click `prevDock.app`, choose **Open**, then choose **Open** again.
- Or open **System Settings** > **Privacy & Security**, scroll to the security message for `prevDock`, then click **Open Anyway**.

After the first approved launch, macOS should remember the exception for that installed app.

## How it works

- Reads the Dock item under the pointer with macOS Accessibility APIs.
- Matches the Dock item to a running app by title or Dock item URL.
- Lists the app's visible and AX-discoverable windows through Accessibility, Quartz Window Services, and a remote-token fallback inspired by AltTab.
- Captures window thumbnails with the macOS SkyLight window capture path and displays a floating preview shelf.
- Shows minimized windows using an available capture or a retained snapshot. Hovering their cards displays the snapshot at the original window position without restoring or activating the real window; clicking the card restores and focuses it.
- Pins the preview shelf to the Dock item so it does not follow small mouse movements.
- Focuses the clicked preview window with Accessibility before activating the owning app.
- Optional **Dock app click previews** opens a multi-window app's preview shelf on a plain click, including before its window cache is ready. Apps with zero or one window keep their normal Dock behavior.
- Hides previews for native Dock actions and context menus. Hold Shift to bypass click previews for native Dock dragging or other modifier actions.
- Auto-fit keeps previews in one row, reducing their size to fit the screen. When thumbnails would become too small, it switches to a scrollable window list with hover preview, focus, and close controls.
- Keeps scroll position while windows change, and supports ordinary mouse-wheel scrolling in horizontal preview shelves.

macOS does not expose an official Dock hover API, so Dock detection depends on Accessibility and can vary a little by macOS version or Dock configuration.

## Build

For code ownership, symptom-to-file navigation and behavior that a refactor must preserve, start with [ARCHITECTURE.md](ARCHITECTURE.md). The [testing guide](TESTING.md) maps features to automated and real-app checks.

```sh
./scripts/build.sh
```

The build also runs the cache, capture scheduling, loading state, layout, and AppKit presentation regression tests. On a Mac with Accessibility and Screen Recording access, run `./scripts/test-window-preview-live.sh com.google.Chrome` to verify real window discovery and capture against a running app.

With Accessibility and Screen Recording access, `./scripts/test-dock-click-live.sh` checks real Dock interactions, including inactive/windowless hover, empty/stale caches, modifier clicks, and reopening an app with no windows. It also checks warm- and cold-cache minimized thumbnails, hover snapshots at the original position, and that only selection restores the window. It uses temporary fixture apps and an existing inactive Dock item when available, then restores prevDock's normal launch settings afterward.

Use `./scripts/test-dock-click-live.sh --windowless-only` for the focused last-window-close, empty hover, new-window, and reopen regression checks. Empty-hover checks also report the app's CPU time during the observation interval.

Builds use the active command-line toolchain selected by `xcode-select` or `DEVELOPER_DIR`. Xcode Command Line Tools are sufficient; the app and its tests target the minimum macOS version declared in `Resources/Info.plist` (14.0).

The app bundle is written to:

```text
build/prevDock.app
```

## Run

Open `build/prevDock.app`. The app appears in the menu bar as a small icon.

On first launch, grant:

- Accessibility
- Screen Recording

After granting permissions, restart `prevDock` if macOS asks for it.

## Settings

Choose **Settings...** from the menu bar icon. The native sidebar groups preferences into **General**, **Appearance**, **Layout**, **Permissions**, and **Updates**. Use **Command-1** through **Command-5** to switch pages, and **Command-W** to close the window. Reopening Settings returns to the last selected page in the current session.

Appearance displays a synthetic 4:3 Finder example at actual preview-card size. Title size, thumbnail height, close buttons, and Desktop grouping update immediately while the example area and controls stay in place. A separate service captures the real Dock around Finder and places it beside the example according to the Dock's position. It updates automatically while Appearance is visible and removes the image when the Dock is hidden.

Layout provides illustrated single-row and wrapped-row choices. Auto fit is available with Single Row; switching to Wrap preserves the preference for when you switch back.

The settings tests cover every control, keyboard navigation, light and dark appearances, and three window sizes. Run `./scripts/test-settings-window-layout.sh .build/settings-snapshots` to also save screenshots of all five pages in both appearances. The tests use isolated preferences and mocked permission, login, and update services.

## Updates

Open the menu bar icon, choose **Settings...**, then select **Updates** and use **Check for Updates…**. prevDock uses Sparkle to check for an update and continue into the download/install flow when an update is available. The Homebrew cask is marked as auto-updating because Sparkle can update the app outside `brew upgrade`.

Automatic update installation is off by default for the preview release. You can enable it in Settings.

## Release

Preview releases use SemVer-style versions before 1.0, such as `0.1.0`, `0.1.1`, and `0.2.0`.

```sh
scripts/release.sh 0.1.0
```

By default, the release script publishes an unnotarized preview build. Users may need the first-launch workaround above.

For a notarized release, run:

```sh
PREVDOCK_NOTARIZE=1 scripts/release.sh 0.1.0
```

Notarized releases require:

- a Developer ID Application certificate in the login keychain
- a stored `notarytool` keychain profile named `prevdock-notary`
- the Sparkle EdDSA private key generated by Sparkle's `generate_keys`

The release script builds, signs, zips, updates the appcast, publishes a GitHub pre-release, and updates the Homebrew tap. In notarized mode, it also submits to Apple's notary service and staples the ticket before zipping.

## Current limits

- Requires macOS 14 or later.
- Visible on-screen windows get real thumbnails.
- Minimized windows use snapshots without continuous capture. Some apps cannot provide an image while minimized; when no usable cached image is available, the card remains selectable but hover enlargement is unavailable.
- Live thumbnail refresh is throttled to avoid excessive capture work.

## License

prevDock is licensed under the GNU General Public License v3.0.

## Dock label note

macOS does not provide a supported API for disabling Dock hover labels. The optional **Hide native Dock labels** setting uses a best-effort event filter only while prevDock is running. It does not edit Dock preferences or restart the Dock, and it fails open if reliable Dock geometry is unavailable.
