#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if (( $# > 1 )) || [[ "${1:-}" != "" && "${1:-}" != "--build-only" && "${1:-}" != "--inspect" ]]; then
  echo "usage: $0 [--build-only|--inspect]" >&2
  exit 2
fi

source "$ROOT_DIR/scripts/swift-toolchain.sh"
source "$ROOT_DIR/scripts/test-sources.sh"
HARNESS_DIR="$ROOT_DIR/.build/settings-dock-snapshot-live"
APP_DIR="$HARNESS_DIR/SettingsDockSnapshotLiveTests.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
EXECUTABLE="$MACOS_DIR/SettingsDockSnapshotLiveTests"
mkdir -p "$MACOS_DIR"

"$SWIFTC" -O -swift-version 5 -warnings-as-errors -sdk "$SDKROOT" -target "$SWIFT_TARGET" \
  -framework Cocoa -framework ApplicationServices -framework CoreGraphics \
  -F "$SDKROOT/System/Library/PrivateFrameworks" -framework SkyLight \
  "${SETTINGS_MODEL_SOURCES[@]}" \
  "${PERMISSION_SOURCES[@]}" \
  "${PREVIEW_CARD_SOURCES[@]}" \
  "${DOCK_SNAPSHOT_MODEL_SOURCES[@]}" \
  "$ROOT_DIR/Sources/prevDock/Dock/DockSnapshotBackend.swift" \
  "$ROOT_DIR/Sources/prevDock/Dock/DockSnapshotService.swift" \
  "$ROOT_DIR/Sources/prevDock/Dock/DockAccessibility.swift" \
  "$ROOT_DIR/Sources/prevDock/Settings/SettingsPreviewStage.swift" \
  "$ROOT_DIR/Sources/prevDock/Settings/SettingsPreviewStageLayout.swift" \
  "$ROOT_DIR/Sources/prevDock/Preview/PreviewAnchorLayout.swift" \
  "$ROOT_DIR/Sources/prevDock/Preview/PreviewLayoutPlanner.swift" \
  "$ROOT_DIR/Sources/prevDock/Preview/PreviewPresentationLayout.swift" \
  "$ROOT_DIR/Sources/prevDock/Support/AccessibilityHelpers.swift" \
  "$ROOT_DIR/Sources/prevDock/Support/DockCursorTracker.swift" \
  "$ROOT_DIR/Sources/prevDock/Support/ScreenGeometry.swift" \
  "$ROOT_DIR/Sources/prevDock/Support/PrevDockColors.swift" \
  "$ROOT_DIR/Sources/prevDock/Windowing/WindowPreview.swift" \
  "$ROOT_DIR/Sources/prevDock/Windowing/SkyLightCapture.swift" \
  "$ROOT_DIR/Tests/SettingsDockSnapshotLiveTests.swift" \
  -o "$EXECUTABLE"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.bambou932.prevDock.tests.settings-dock-snapshot-live</string>
<key>CFBundleExecutable</key><string>SettingsDockSnapshotLiveTests</string>
<key>CFBundleName</key><string>prevDock Dock Snapshot Verification</string>
<key>CFBundleDisplayName</key><string>prevDock Dock Snapshot Verification</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>$DEPLOYMENT_TARGET</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force --sign - "$APP_DIR" >&2
if [[ "${1:-}" == "--build-only" ]]; then
  echo "$APP_DIR"
  exit 0
fi

REPORT_DIR="$(mktemp -d "$HARNESS_DIR/report.XXXXXX")"
STATE_FILE="$REPORT_DIR/desktop-state.plist"
HARNESS_PID=""
cleanup() {
  local result=$?
  trap - EXIT INT TERM HUP
  if [[ -n "$HARNESS_PID" ]] && kill -0 "$HARNESS_PID" 2>/dev/null; then
    kill -TERM "$HARNESS_PID" 2>/dev/null || true
    wait "$HARNESS_PID" 2>/dev/null || true
  fi
  if [[ -f "$STATE_FILE" ]]; then
    "$EXECUTABLE" --restore-desktop "$STATE_FILE" || result=1
  fi
  echo "Report: $REPORT_DIR" >&2
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

"$EXECUTABLE" "$REPORT_DIR" ${1:+"$1"} > "$REPORT_DIR/events.jsonl" &
HARNESS_PID=$!
echo "Harness PID: $HARNESS_PID; Report: $REPORT_DIR" >&2
if wait "$HARNESS_PID"; then
  HARNESS_PID=""
  cat "$REPORT_DIR/events.jsonl"
else
  RESULT=$?
  HARNESS_PID=""
  cat "$REPORT_DIR/events.jsonl"
  exit "$RESULT"
fi
