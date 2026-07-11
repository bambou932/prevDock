#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SWIFTC="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
SDKROOT="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
TEST_DIR="$ROOT_DIR/build/PreviewSizeStageTests"
TEST_BINARY="$TEST_DIR/SettingsPreviewStageLayoutTests"

rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR/ModuleCache"

"$SWIFTC" \
  -O \
  -parse-as-library \
  -swift-version 5 \
  -sdk "$SDKROOT" \
  -module-cache-path "$TEST_DIR/ModuleCache" \
  -framework CoreGraphics \
  "$ROOT_DIR/Sources/prevDock/Dock/DockSnapshotGeometry.swift" \
  "$ROOT_DIR/Sources/prevDock/Settings/PrevDockSettings.swift" \
  "$ROOT_DIR/Sources/prevDock/Settings/SettingsPreviewStageLayout.swift" \
  "$ROOT_DIR/Sources/prevDock/Preview/PreviewSizing.swift" \
  "$ROOT_DIR/Tests/SettingsPreviewStageLayoutTests.swift" \
  -o "$TEST_BINARY"

"$TEST_BINARY"
