#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/swift-toolchain.sh"
source "$ROOT_DIR/scripts/test-sources.sh"
PRIVATE_FRAMEWORKS_DIR="$SDKROOT/System/Library/PrivateFrameworks"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

"$SWIFTC" \
  -O \
  -swift-version 5 \
  -sdk "$SDKROOT" -target "$SWIFT_TARGET" \
  -F "$PRIVATE_FRAMEWORKS_DIR" \
  -framework Cocoa \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -framework SkyLight \
  "$ROOT_DIR/Sources/prevDock/Windowing/RemoteWindowElementIDCache.swift" \
  "${REMOTE_WINDOW_RESOLVER_SOURCES[@]}" \
  "$ROOT_DIR/Tests/RemoteWindowElementResolverLiveTests.swift" \
  -o "$TEST_DIR/remote-window-cache-live-tests"

"$TEST_DIR/remote-window-cache-live-tests" "${1:-com.google.Chrome}"
