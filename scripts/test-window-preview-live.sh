#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/swift-toolchain.sh"
source "$ROOT_DIR/scripts/test-sources.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

"$SWIFTC" -O -swift-version 5 -sdk "$SDKROOT" -target "$SWIFT_TARGET" \
  -F "$SDKROOT/System/Library/PrivateFrameworks" \
  -framework Cocoa -framework ApplicationServices -framework CoreGraphics -framework SkyLight \
  "$ROOT_DIR"/Sources/prevDock/Windowing/*.swift \
  "${PERMISSION_SOURCES[@]}" \
  "$ROOT_DIR/Sources/prevDock/Support/AccessibilityHelpers.swift" \
  "$ROOT_DIR/Sources/prevDock/Support/ScreenGeometry.swift" \
  "${SETTINGS_MODEL_SOURCES[@]}" \
  "$ROOT_DIR/Tests/WindowPreviewLiveTests.swift" \
  -o "$TEST_DIR/window-preview-live-tests"

"$TEST_DIR/window-preview-live-tests" "${1:-com.google.Chrome}" "${@:2}"
