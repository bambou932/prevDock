#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/swift-toolchain.sh"
source "$ROOT_DIR/scripts/test-sources.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

"$SWIFTC" \
  -O \
  -swift-version 5 \
  -sdk "$SDKROOT" -target "$SWIFT_TARGET" \
  -framework ApplicationServices \
  -framework CoreGraphics \
  "$ROOT_DIR/Sources/prevDock/Windowing/RemoteWindowElementIDCache.swift" \
  "${REMOTE_WINDOW_RESOLVER_SOURCES[@]}" \
  "$ROOT_DIR/Tests/RemoteWindowScanBudgetTests.swift" \
  -o "$TEST_DIR/remote-window-scan-budget-tests"

"$TEST_DIR/remote-window-scan-budget-tests"
