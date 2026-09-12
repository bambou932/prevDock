#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/swift-toolchain.sh"
source "$ROOT_DIR/scripts/test-sources.sh"
BUILD_DIR="$ROOT_DIR/.build/preview-presentation-tests"
BINARY="$BUILD_DIR/PreviewPresentationTests"
mkdir -p "$BUILD_DIR"

"$SWIFTC" \
  -O \
  -swift-version 5 \
  -warnings-as-errors \
  -sdk "$SDKROOT" \
  -target "$SWIFT_TARGET" \
  -framework AppKit \
  "${SETTINGS_MODEL_SOURCES[@]}" \
  "$ROOT_DIR/Sources/prevDock/Preview/PreviewLayoutPlanner.swift" \
  "$ROOT_DIR/Sources/prevDock/Preview/PreviewPresentationLayout.swift" \
  "$ROOT_DIR/Tests/PreviewPresentationTests.swift" \
  -o "$BINARY"

"$BINARY"
