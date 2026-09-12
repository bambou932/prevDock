#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/swift-toolchain.sh"
source "$ROOT_DIR/scripts/test-sources.sh"
TEST_DIR="$(mktemp -d)"
TEST_IDENTIFIER="io.github.bambou932.prevDock.tests.settings-layout.$(uuidgen)"
TEST_APP="$TEST_DIR/SettingsWindowLayoutTests.app"
mkdir -p "$TEST_APP/Contents/MacOS"
trap 'rm -rf "$TEST_DIR"' EXIT
cat > "$TEST_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$TEST_IDENTIFIER</string>
<key>CFBundleExecutable</key><string>settings-window-layout-tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST

"$SWIFTC" -O -swift-version 5 -warnings-as-errors -sdk "$SDKROOT" -target "$SWIFT_TARGET" \
  -framework Cocoa -framework ApplicationServices \
  "${SETTINGS_WINDOW_SOURCES[@]}" \
  "${SETTINGS_MODEL_SOURCES[@]}" \
  "${PREVIEW_CARD_SOURCES[@]}" \
  "$ROOT_DIR/Sources/prevDock/Preview/PreviewLayoutPlanner.swift" \
  "$ROOT_DIR/Sources/prevDock/Preview/PreviewPresentationLayout.swift" \
  "$ROOT_DIR/Sources/prevDock/Support/AccessibilityHelpers.swift" \
  "$ROOT_DIR/Sources/prevDock/Support/DockCursorTracker.swift" \
  "$ROOT_DIR/Sources/prevDock/Support/PrevDockColors.swift" \
  "${SETTINGS_FIXTURE_SOURCES[@]}" \
  "$ROOT_DIR/Tests/SettingsWindowLayoutTests.swift" \
  -o "$TEST_APP/Contents/MacOS/settings-window-layout-tests"

"$TEST_APP/Contents/MacOS/settings-window-layout-tests" "$@"
