#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/swift-toolchain.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

"$SWIFTC" \
  -swift-version 5 \
  -sdk "$SDKROOT" -target "$SWIFT_TARGET" \
  "$ROOT_DIR/Sources/prevDock/Windowing/WindowRefreshCoordinator.swift" \
  "$ROOT_DIR/Tests/WindowRefreshCoordinatorTests.swift" \
  -o "$TEST_DIR/window-refresh-coordinator-tests"

"$TEST_DIR/window-refresh-coordinator-tests"
