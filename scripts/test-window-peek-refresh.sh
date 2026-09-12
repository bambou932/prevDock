#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/swift-toolchain.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

"$SWIFTC" \
  -swift-version 5 \
  -sdk "$SDKROOT" -target "$SWIFT_TARGET" \
  -framework Cocoa \
  -framework QuartzCore \
  "$ROOT_DIR/Sources/prevDock/Preview/WindowPeekController.swift" \
  "$ROOT_DIR/Sources/prevDock/Support/ScreenGeometry.swift" \
  "$ROOT_DIR/Sources/prevDock/Support/PrevDockColors.swift" \
  "$ROOT_DIR/Tests/WindowPeekRefreshTests.swift" \
  -o "$TEST_DIR/window-peek-refresh-tests"

"$TEST_DIR/window-peek-refresh-tests"
