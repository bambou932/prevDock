#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/swift-toolchain.sh"
source "$ROOT_DIR/scripts/test-sources.sh"
BUILD_DIR="$ROOT_DIR/.build/preview-panel-tests"
mkdir -p "$BUILD_DIR"

"$SWIFTC" -O -swift-version 5 -sdk "$SDKROOT" -target "$SWIFT_TARGET" \
  -F "$SDKROOT/System/Library/PrivateFrameworks" \
  -framework Cocoa -framework ApplicationServices -framework CoreGraphics \
  -framework SkyLight \
  "$ROOT_DIR"/Sources/prevDock/Windowing/*.swift \
  "$ROOT_DIR"/Sources/prevDock/Preview/*.swift \
  "${PERMISSION_SOURCES[@]}" \
  "${SETTINGS_MODEL_SOURCES[@]}" \
  "$ROOT_DIR/Sources/prevDock/Support/AccessibilityHelpers.swift" \
  "$ROOT_DIR/Sources/prevDock/Support/ScreenGeometry.swift" \
  "$ROOT_DIR/Sources/prevDock/Support/DockCursorTracker.swift" \
  "$ROOT_DIR/Sources/prevDock/Support/PrevDockColors.swift" \
  "$ROOT_DIR/Tests/PreviewPanelIntegrationTests.swift" \
  -o "$BUILD_DIR/PreviewPanelIntegrationTests"

"$BUILD_DIR/PreviewPanelIntegrationTests" "$BUILD_DIR/snapshots"
