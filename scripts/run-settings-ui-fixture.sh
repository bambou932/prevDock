#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if (( $# > 1 )) || [[ "${1:-}" != "" && "${1:-}" != "--build-only" ]]; then
  echo "usage: $0 [--build-only]" >&2
  exit 2
fi

source "$ROOT_DIR/scripts/swift-toolchain.sh"
source "$ROOT_DIR/scripts/test-sources.sh"
APP_DIR="$ROOT_DIR/.build/settings-ui-fixture/SettingsUIFixture.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
mkdir -p "$MACOS_DIR"

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
  "$ROOT_DIR/Tests/Fixtures/SettingsUIFixture.swift" \
  -o "$MACOS_DIR/SettingsUIFixture"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.bambou932.prevDock.tests.settings-ui</string>
<key>CFBundleExecutable</key><string>SettingsUIFixture</string>
<key>CFBundleName</key><string>prevDock Settings Fixture</string>
<key>CFBundleDisplayName</key><string>prevDock Settings Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>$DEPLOYMENT_TARGET</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force --sign - "$APP_DIR" >/dev/null

if [[ "${1:-}" != "--build-only" ]]; then
  open "$APP_DIR"
fi
echo "$APP_DIR"
