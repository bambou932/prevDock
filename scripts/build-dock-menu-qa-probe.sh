#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/dock-menu-qa"
BINARY="$BUILD_DIR/DockMenuQAProbe"
SWIFTC="${SWIFTC:-$(xcrun --find swiftc)}"
SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
COMPILER_ARCH="$("$SWIFTC" -print-target-info | sed -n 's/.*"triple": "\([^-]*\)-.*/\1/p' | head -n 1)"
ARCH="${ARCH:-$COMPILER_ARCH}"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

mkdir -p "$BUILD_DIR"
"$SWIFTC" \
  -O \
  -swift-version 5 \
  -warnings-as-errors \
  -sdk "$SDKROOT" \
  -target "$ARCH-apple-macosx$DEPLOYMENT_TARGET" \
  -framework AppKit \
  -framework ApplicationServices \
  "$ROOT_DIR/Tests/Fixtures/DockMenuQAProbe.swift" \
  -o "$BINARY"

echo "$BINARY"
