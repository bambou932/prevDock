#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/swift-toolchain.sh"
source "$ROOT_DIR/scripts/test-sources.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

"$SWIFTC" -O -swift-version 5 -warnings-as-errors -sdk "$SDKROOT" -target "$SWIFT_TARGET" \
  -framework Cocoa -framework ApplicationServices \
  "${PERMISSION_SOURCES[@]}" \
  "${PERMISSION_VIEW_SOURCES[@]}" \
  "$ROOT_DIR/Tests/PermissionSettingsViewTests.swift" \
  -o "$TEST_DIR/permission-settings-view-tests"

"$TEST_DIR/permission-settings-view-tests"
