#!/usr/bin/env bash

# Test seams share these file groups without linking the real app lifecycle or OS services.
: "${ROOT_DIR:?Set ROOT_DIR before sourcing test-sources.sh}"

SETTINGS_MODEL_SOURCES=(
  "$ROOT_DIR/Sources/prevDock/Settings/PreviewPreferences.swift"
  "$ROOT_DIR/Sources/prevDock/Settings/PrevDockSettings.swift"
)

PERMISSION_SOURCES=(
  "$ROOT_DIR/Sources/prevDock/App/PermissionStatusCache.swift"
  "$ROOT_DIR/Sources/prevDock/App/PermissionManager.swift"
)

PERMISSION_VIEW_SOURCES=(
  "$ROOT_DIR/Sources/prevDock/Settings/PermissionSettingsView.swift"
  "$ROOT_DIR/Sources/prevDock/Settings/PermissionRowView.swift"
)

DOCK_SNAPSHOT_MODEL_SOURCES=(
  "$ROOT_DIR/Sources/prevDock/Dock/DockSnapshotTypes.swift"
  "$ROOT_DIR/Sources/prevDock/Dock/DockSnapshotGeometry.swift"
)

PREVIEW_CARD_SOURCES=(
  "$ROOT_DIR/Sources/prevDock/Preview/PreviewMetrics.swift"
  "$ROOT_DIR/Sources/prevDock/Preview/PreviewInitialHoverGate.swift"
  "$ROOT_DIR/Sources/prevDock/Preview/PreviewHighlightCornerRadius.swift"
  "$ROOT_DIR/Sources/prevDock/Preview/PreviewThumbnailPlaceholderViews.swift"
  "$ROOT_DIR/Sources/prevDock/Preview/PreviewCloseButton.swift"
  "$ROOT_DIR/Sources/prevDock/Preview/DesktopGroupView.swift"
  "$ROOT_DIR/Sources/prevDock/Preview/PreviewCardView.swift"
)

SETTINGS_WINDOW_SOURCES=(
  "$ROOT_DIR/Sources/prevDock/Settings/SettingsWindowController.swift"
  "$ROOT_DIR/Sources/prevDock/Settings/SettingsContentView.swift"
  "$ROOT_DIR/Sources/prevDock/Settings/SettingsPane.swift"
  "$ROOT_DIR/Sources/prevDock/Settings/SettingsSidebarView.swift"
  "$ROOT_DIR/Sources/prevDock/Settings/SettingsPageView.swift"
  "$ROOT_DIR/Sources/prevDock/Settings/SettingsUI.swift"
  "$ROOT_DIR/Sources/prevDock/Settings/SettingsLayoutOptionButton.swift"
  "$ROOT_DIR/Sources/prevDock/Settings/SettingsPreviewStage.swift"
  "$ROOT_DIR/Sources/prevDock/Settings/SettingsPreviewStageLayout.swift"
  "$ROOT_DIR/Sources/prevDock/Preview/PreviewAnchorLayout.swift"
  "$ROOT_DIR/Sources/prevDock/Dock/DockSnapshotTypes.swift"
  "${PERMISSION_VIEW_SOURCES[@]}"
)

SETTINGS_FIXTURE_SOURCES=(
  "$ROOT_DIR/Tests/Fixtures/SettingsServiceStubs.swift"
  "$ROOT_DIR/Tests/Fixtures/SettingsDockSnapshotStub.swift"
)

REMOTE_WINDOW_RESOLVER_SOURCES=(
  "$ROOT_DIR/Sources/prevDock/Windowing/RemoteWindowElementResolver.swift"
  "$ROOT_DIR/Sources/prevDock/Windowing/RemoteWindowToken.swift"
  "$ROOT_DIR/Sources/prevDock/Windowing/RemoteWindowScanPlan.swift"
  "$ROOT_DIR/Sources/prevDock/Windowing/ConcurrentRemoteWindowScanState.swift"
)
