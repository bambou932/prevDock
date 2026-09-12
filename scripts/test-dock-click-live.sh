#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/swift-toolchain.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

"$ROOT_DIR/scripts/run-preview-window-fixture.sh" 4 --build-only >&2
CONTROLLER_APP="$TEST_DIR/DockClickController.app"
ditto "$ROOT_DIR/.build/preview-window-fixture/PreviewWindowFixture.app" "$CONTROLLER_APP"
plutil -replace CFBundleIdentifier -string io.github.bambou932.prevDock.DockClickController "$CONTROLLER_APP/Contents/Info.plist"
plutil -replace CFBundleName -string DockClickController "$CONTROLLER_APP/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string DockClickController "$CONTROLLER_APP/Contents/Info.plist"
codesign --force --sign - "$CONTROLLER_APP" >&2
"$SWIFTC" -O -parse-as-library -swift-version 5 -warnings-as-errors -sdk "$SDKROOT" -target "$SWIFT_TARGET" \
  -framework Cocoa -framework ApplicationServices \
  "$ROOT_DIR/Tests/DockClickLiveTests.swift" \
  -o "$TEST_DIR/dock-click-live-tests"

"$TEST_DIR/dock-click-live-tests" "$ROOT_DIR" "$CONTROLLER_APP" "$@"
