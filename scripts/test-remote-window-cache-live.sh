#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SWIFTC="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
SDKROOT="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
PRIVATE_FRAMEWORKS_DIR="$SDKROOT/System/Library/PrivateFrameworks"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

"$SWIFTC" \
  -O \
  -swift-version 5 \
  -sdk "$SDKROOT" \
  -F "$PRIVATE_FRAMEWORKS_DIR" \
  -framework Cocoa \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -framework SkyLight \
  "$ROOT_DIR/Sources/prevDock/Windowing/RemoteWindowElementIDCache.swift" \
  "$ROOT_DIR/Sources/prevDock/Windowing/RemoteWindowElementResolver.swift" \
  "$ROOT_DIR/Tests/RemoteWindowElementResolverLiveTests.swift" \
  -o "$TEST_DIR/remote-window-cache-live-tests"

"$TEST_DIR/remote-window-cache-live-tests" "${1:-com.google.Chrome}"
