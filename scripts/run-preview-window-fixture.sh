#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/preview-window-fixture"
APP_DIR="$BUILD_DIR/PreviewWindowFixture.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
EXECUTABLE="$MACOS_DIR/PreviewWindowFixture"
PLIST="$CONTENTS_DIR/Info.plist"
SWIFTC="${SWIFTC:-$(xcrun --find swiftc)}"
SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
COMPILER_ARCH="$("$SWIFTC" -print-target-info | sed -n 's/.*"triple": "\([^-]*\)-.*/\1/p' | head -n 1)"
ARCH="${ARCH:-$COMPILER_ARCH}"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
COUNT="${1:-12}"

if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || (( COUNT < 1 || COUNT > 100 )); then
  echo "usage: $0 [window-count: 1...100] [--build-only]" >&2
  exit 2
fi

mkdir -p "$MACOS_DIR"

"$SWIFTC" \
  -O \
  -swift-version 5 \
  -warnings-as-errors \
  -sdk "$SDKROOT" \
  -target "$ARCH-apple-macosx$DEPLOYMENT_TARGET" \
  -framework AppKit \
  "$ROOT_DIR/Tests/Fixtures/PreviewWindowFixture.swift" \
  -o "$EXECUTABLE"

cp "$ROOT_DIR/Resources/Info.plist" "$PLIST"
plutil -replace CFBundleExecutable -string PreviewWindowFixture "$PLIST"
plutil -replace CFBundleIdentifier -string io.github.bambou932.prevDock.PreviewWindowFixture "$PLIST"
plutil -replace CFBundleName -string "prevDock Preview Fixture" "$PLIST"
plutil -insert CFBundleDisplayName -string "prevDock Preview Fixture" "$PLIST"
plutil -replace LSUIElement -bool false "$PLIST"
plutil -remove SUFeedURL "$PLIST" 2>/dev/null || true
plutil -remove SUPublicEDKey "$PLIST" 2>/dev/null || true
plutil -remove SUAllowsAutomaticUpdates "$PLIST" 2>/dev/null || true
plutil -remove SUAutomaticallyUpdate "$PLIST" 2>/dev/null || true
codesign --force --deep --sign - "$APP_DIR" >/dev/null

if [[ "${2:-}" == "--build-only" ]]; then
  echo "$APP_DIR"
  exit 0
fi

open -n "$APP_DIR" --args "$COUNT"
echo "$APP_DIR"
