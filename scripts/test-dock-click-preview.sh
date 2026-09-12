#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/swift-toolchain.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

"$SWIFTC" -O -swift-version 5 -warnings-as-errors -sdk "$SDKROOT" -target "$SWIFT_TARGET" \
  "$ROOT_DIR/Sources/prevDock/Dock/DockClickPreviewState.swift" \
  "$ROOT_DIR/Tests/DockClickPreviewTests.swift" \
  -o "$TEST_DIR/dock-click-preview-tests"

"$TEST_DIR/dock-click-preview-tests"
