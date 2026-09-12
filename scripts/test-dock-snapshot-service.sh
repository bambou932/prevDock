#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/swift-toolchain.sh"
source "$ROOT_DIR/scripts/test-sources.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

"$SWIFTC" -O -swift-version 5 -warnings-as-errors -sdk "$SDKROOT" -target "$SWIFT_TARGET" \
  -framework Cocoa \
  "${DOCK_SNAPSHOT_MODEL_SOURCES[@]}" \
  "$ROOT_DIR/Sources/prevDock/Dock/DockSnapshotService.swift" \
  "$ROOT_DIR/Tests/DockSnapshotServiceTests.swift" \
  -o "$TEST_DIR/dock-snapshot-service-tests"

"$TEST_DIR/dock-snapshot-service-tests"
