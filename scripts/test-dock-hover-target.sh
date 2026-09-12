#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/swift-toolchain.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

"$SWIFTC" -O -swift-version 5 -warnings-as-errors -sdk "$SDKROOT" -target "$SWIFT_TARGET" \
  -framework Cocoa -framework ApplicationServices \
  "$ROOT_DIR/Sources/prevDock/Support/ScreenGeometry.swift" \
  "$ROOT_DIR/Sources/prevDock/Support/AccessibilityHelpers.swift" \
  "$ROOT_DIR/Sources/prevDock/Dock/DockAccessibility.swift" \
  "$ROOT_DIR/Sources/prevDock/Dock/RunningAppMatcher.swift" \
  "$ROOT_DIR/Sources/prevDock/Dock/DockHoverTargetResolver.swift" \
  "$ROOT_DIR/Tests/DockHoverTargetTests.swift" \
  -o "$TEST_DIR/dock-hover-target-tests"

"$TEST_DIR/dock-hover-target-tests"
