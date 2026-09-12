#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/swift-toolchain.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

"$SWIFTC" -O -swift-version 5 -warnings-as-errors -sdk "$SDKROOT" -target "$SWIFT_TARGET" \
  "$ROOT_DIR/Sources/prevDock/Windowing/WindowFocusRequest.swift" \
  "$ROOT_DIR/Tests/WindowFocusRequestTests.swift" \
  -o "$TEST_DIR/window-focus-request-tests"

"$TEST_DIR/window-focus-request-tests"
