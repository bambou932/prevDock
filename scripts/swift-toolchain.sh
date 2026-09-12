#!/usr/bin/env bash

# Source after ROOT_DIR is set so the app and its tests use the same deployment target.
: "${ROOT_DIR:?Set ROOT_DIR before sourcing swift-toolchain.sh}"
SWIFTC="${SWIFTC:-$(xcrun --find swiftc)}"
SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT_DIR/Resources/Info.plist")}"
SWIFT_HOST_TRIPLE="$("$SWIFTC" -print-target-info | sed -n 's/.*"triple"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
SWIFT_TARGET_ARCH="${PREVDOCK_TARGET_ARCH:-${SWIFT_HOST_TRIPLE%%-*}}"

case "$SWIFT_TARGET_ARCH" in
  arm64|x86_64) ;;
  *) echo "Unsupported Swift target architecture: $SWIFT_TARGET_ARCH" >&2; return 2 ;;
esac

if ! [[ "$DEPLOYMENT_TARGET" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "Invalid macOS deployment target: $DEPLOYMENT_TARGET" >&2
  return 2
fi

SWIFT_TARGET="$SWIFT_TARGET_ARCH-apple-macosx$DEPLOYMENT_TARGET"
