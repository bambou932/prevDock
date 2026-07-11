#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/preview-layout-tests"
BINARY="$BUILD_DIR/PreviewLayoutPlannerTests"
SWIFTC="${SWIFTC:-$(xcrun --find swiftc)}"
SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"

mkdir -p "$BUILD_DIR"

"$SWIFTC" \
  -O \
  -swift-version 5 \
  -warnings-as-errors \
  -sdk "$SDKROOT" \
  "$ROOT_DIR/Sources/prevDock/Settings/PrevDockSettings.swift" \
  "$ROOT_DIR/Sources/prevDock/Preview/PreviewLayoutPlanner.swift" \
  "$ROOT_DIR/Tests/PreviewLayoutPlannerTests.swift" \
  -o "$BINARY"

"$BINARY"
