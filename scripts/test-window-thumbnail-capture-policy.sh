#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/swift-toolchain.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
OUTPUT="$TEST_DIR/window-thumbnail-capture-policy-tests"

"$SWIFTC" -swift-version 5 -sdk "$SDKROOT" -target "$SWIFT_TARGET" \
  "$ROOT_DIR/Sources/prevDock/Windowing/WindowThumbnailCapturePolicy.swift" \
  "$ROOT_DIR/Tests/WindowThumbnailCapturePolicyTests.swift" \
  -o "$OUTPUT"

"$OUTPUT"
