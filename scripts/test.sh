#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Keep AppKit suites serial: they share the desktop even with isolated preferences.
TEST_NAMES=(
  remote-window-cache
  window-refresh-coordinator
  window-space-membership
  window-thumbnail-capture-policy
  dock-hover-suppression
  dock-click-preview
  dock-hover-target
  dock-preview-refresh
  dock-snapshot-geometry
  dock-snapshot-service
  release-workflow
  permission-status-cache
  permission-settings-view
  app-startup
  settings-window-layout
  settings-booleans
  remote-window-scan-budget
  window-accessibility-attributes
  window-inventory-snapshot
  window-focus-request
  window-peek-refresh
  preview-loading
  preview-layout
  preview-presentation
  preview-panel
)

if [[ "${1:-}" == "--list" ]]; then
  printf '%s\n' "${TEST_NAMES[@]}"
  exit 0
fi

if (( $# > 0 )); then
  for requested in "$@"; do
    found=false
    for available in "${TEST_NAMES[@]}"; do
      if [[ "$requested" == "$available" ]]; then found=true; break; fi
    done
    if [[ "$found" != true ]]; then
      echo "Unknown test: $requested. Use $0 --list." >&2
      exit 64
    fi
  done
  TEST_NAMES=("$@")
fi

for name in "${TEST_NAMES[@]}"; do
  "$ROOT_DIR/scripts/test-$name.sh"
done
