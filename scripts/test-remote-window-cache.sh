#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SWIFTC="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
SDKROOT="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

"$SWIFTC" \
  -swift-version 5 \
  -sdk "$SDKROOT" \
  -framework CoreGraphics \
  "$ROOT_DIR/Sources/prevDock/Windowing/RemoteWindowElementIDCache.swift" \
  "$ROOT_DIR/Tests/RemoteWindowElementIDCacheTests.swift" \
  -o "$TEST_DIR/remote-window-cache-tests"

"$TEST_DIR/remote-window-cache-tests"
