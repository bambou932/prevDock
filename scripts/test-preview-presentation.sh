#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/preview-presentation-tests"
BINARY="$BUILD_DIR/PreviewPresentationTests"
SWIFTC="${SWIFTC:-$(xcrun --find swiftc)}"
SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
COMPILER_TRIPLE="$("$SWIFTC" -print-target-info | sed -n 's/.*"triple"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
TARGET_ARCH="${PREVDOCK_TEST_ARCH:-${COMPILER_TRIPLE%%-*}}"

if [[ -z "$TARGET_ARCH" || "$TARGET_ARCH" == "$COMPILER_TRIPLE" ]]; then
  echo "Could not determine the Swift compiler target architecture" >&2
  exit 2
fi

mkdir -p "$BUILD_DIR"

"$SWIFTC" \
  -O \
  -swift-version 5 \
  -warnings-as-errors \
  -sdk "$SDKROOT" \
  -target "$TARGET_ARCH-apple-macosx$DEPLOYMENT_TARGET" \
  -framework AppKit \
  "$ROOT_DIR/Sources/prevDock/Settings/PrevDockSettings.swift" \
  "$ROOT_DIR/Sources/prevDock/Preview/PreviewLayoutPlanner.swift" \
  "$ROOT_DIR/Sources/prevDock/Preview/PreviewPresentationLayout.swift" \
  "$ROOT_DIR/Tests/PreviewPresentationTests.swift" \
  -o "$BINARY"

"$BINARY"
