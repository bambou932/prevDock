#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/swift-toolchain.sh"
APP_DIR="$ROOT_DIR/build/prevDock.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
PRIVATE_FRAMEWORKS_DIR="$SDKROOT/System/Library/PrivateFrameworks"
MODULE_CACHE_DIR="$ROOT_DIR/build/ModuleCache"
SIGNING_IDENTITY="${PREVDOCK_SIGNING_IDENTITY:-}"
SPARKLE_VERSION="2.9.2"
SPARKLE_ARCHIVE="Sparkle-$SPARKLE_VERSION.tar.xz"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/$SPARKLE_ARCHIVE"
SPARKLE_SHA256="1cb340cbbef04c6c0d162078610c25e2221031d794a3449d89f2f56f4df77c95"
SPARKLE_DIR="$ROOT_DIR/.build/sparkle/$SPARKLE_VERSION"
SPARKLE_FRAMEWORK="$SPARKLE_DIR/Sparkle.framework"

"$ROOT_DIR/scripts/test.sh" >&2

ensure_sparkle() {
  if [[ -d "$SPARKLE_FRAMEWORK" && -x "$SPARKLE_DIR/bin/sign_update" &&
        -x "$SPARKLE_DIR/bin/generate_keys" ]]; then
    return
  fi

  local archive="$ROOT_DIR/.build/sparkle/$SPARKLE_ARCHIVE"
  mkdir -p "$SPARKLE_DIR"
  curl --fail --location --silent --show-error "$SPARKLE_URL" --output "$archive"

  local actual_sha
  actual_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
  if [[ "$actual_sha" != "$SPARKLE_SHA256" ]]; then
    echo "Sparkle checksum mismatch: expected $SPARKLE_SHA256, got $actual_sha" >&2
    exit 1
  fi

  tar -xJf "$archive" -C "$SPARKLE_DIR" Sparkle.framework bin/sign_update bin/generate_keys
}

ensure_sparkle

rm -rf "$APP_DIR" "$MODULE_CACHE_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR" "$MODULE_CACHE_DIR"

cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
plutil -replace LSMinimumSystemVersion -string "$DEPLOYMENT_TARGET" "$CONTENTS_DIR/Info.plist"
find "$ROOT_DIR/Resources" -mindepth 1 ! -name Info.plist -exec cp -R {} "$RESOURCES_DIR" \;
ditto "$SPARKLE_FRAMEWORK" "$FRAMEWORKS_DIR/Sparkle.framework"

SWIFT_SOURCES=()
while IFS= read -r source; do
  SWIFT_SOURCES+=("$source")
done < <(find "$ROOT_DIR/Sources/prevDock" -type f -name '*.swift' | sort)

"$SWIFTC" \
  -O \
  -swift-version 5 \
  -sdk "$SDKROOT" -target "$SWIFT_TARGET" \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -F "$SPARKLE_DIR" \
  -F "$PRIVATE_FRAMEWORKS_DIR" \
  -framework Cocoa \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -framework ServiceManagement \
  -framework SkyLight \
  -framework Sparkle \
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  "${SWIFT_SOURCES[@]}" \
  -o "$MACOS_DIR/prevDock"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(.*\)".*/\1/p' | head -n 1)"
fi

if [[ -n "$SIGNING_IDENTITY" ]] && security find-identity -v -p codesigning | grep -Fq "$SIGNING_IDENTITY"; then
  codesign --force --deep --options runtime --sign "$SIGNING_IDENTITY" "$FRAMEWORKS_DIR/Sparkle.framework" >/dev/null
  codesign --force --deep --options runtime --sign "$SIGNING_IDENTITY" "$APP_DIR" >/dev/null
else
  codesign --force --deep --sign - "$FRAMEWORKS_DIR/Sparkle.framework" >/dev/null
  codesign --force --deep --sign - "$APP_DIR" >/dev/null
fi

echo "$APP_DIR"
