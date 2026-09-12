#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/swift-toolchain.sh"
source "$ROOT_DIR/scripts/test-sources.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

"$SWIFTC" -O -swift-version 5 -warnings-as-errors -sdk "$SDKROOT" -target "$SWIFT_TARGET" \
  "${SETTINGS_MODEL_SOURCES[@]}" \
  "$ROOT_DIR/Tests/SettingsBooleanTests.swift" \
  -o "$TEST_DIR/settings-boolean-tests"

"$TEST_DIR/settings-boolean-tests"
for value in YES NO; do
  arguments=()
  for key in previewAutoFitEnabled previewCloseButtonEnabled previewDesktopGroupingEnabled \
    dockAppClickPreviewEnabled nativeDockLabelSuppressionEnabled launchAtLoginDefaultApplied \
    launchAtLoginDefaultPending permissionSetupShown; do
    arguments+=("-$key" "$value")
  done
  if [[ "$value" == YES ]]; then scenario=argv-yes; else scenario=argv-no; fi
  "$TEST_DIR/settings-boolean-tests" "$scenario" -previewOverflowMode scroll "${arguments[@]}"
done
"$TEST_DIR/settings-boolean-tests" legacy-yes -dockContextClickPreviewEnabled YES
"$TEST_DIR/settings-boolean-tests" legacy-overridden -dockContextClickPreviewEnabled YES -dockAppClickPreviewEnabled NO
