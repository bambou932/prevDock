#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/swift-toolchain.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

"$SWIFTC" \
  -swift-version 5 \
  -sdk "$SDKROOT" -target "$SWIFT_TARGET" \
  -framework CoreGraphics \
  "$ROOT_DIR/Sources/prevDock/Windowing/RemoteWindowElementIDCache.swift" \
  "$ROOT_DIR/Tests/RemoteWindowElementIDCacheTests.swift" \
  -o "$TEST_DIR/remote-window-cache-tests"

"$TEST_DIR/remote-window-cache-tests"
