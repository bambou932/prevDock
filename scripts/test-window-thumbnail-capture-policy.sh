#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${TMPDIR:-/tmp}/prevdock-window-thumbnail-capture-policy-tests"

xcrun swiftc \
  "$ROOT_DIR/Sources/prevDock/Windowing/WindowThumbnailCapturePolicy.swift" \
  "$ROOT_DIR/Tests/WindowThumbnailCapturePolicyTests.swift" \
  -o "$OUTPUT"

"$OUTPUT"
