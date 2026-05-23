#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
APPCAST="$ROOT_DIR/appcast.xml"
GH_REPO="${PREVDOCK_GITHUB_REPO:-bambou932/prevDock}"
TAP_REPO="${PREVDOCK_HOMEBREW_TAP:-bambou932/homebrew-prevdock}"
TAP_DIR="${PREVDOCK_TAP_DIR:-$ROOT_DIR/../homebrew-prevdock}"
NOTARY_PROFILE="${PREVDOCK_NOTARY_PROFILE:-prevdock-notary}"
SPARKLE_VERSION="2.9.2"
SPARKLE_SIGN_UPDATE="$ROOT_DIR/.build/sparkle/$SPARKLE_VERSION/bin/sign_update"

usage() {
  echo "Usage: scripts/release.sh <version> [build]" >&2
  exit 64
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print $1" "$INFO_PLIST"
}

set_plist_value() {
  /usr/libexec/PlistBuddy -c "Set $1 $2" "$INFO_PLIST"
}

ensure_clean_tree() {
  if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
    echo "Release requires a clean git tree." >&2
    exit 1
  fi
}

developer_id_identity() {
  if [[ -n "${PREVDOCK_SIGNING_IDENTITY:-}" ]]; then
    echo "$PREVDOCK_SIGNING_IDENTITY"
    return
  fi

  security find-identity -v -p codesigning |
    sed -n 's/.*"\(Developer ID Application:.*\)".*/\1/p' |
    head -n 1
}

ensure_release_prerequisites() {
  require_command gh
  require_command git
  require_command xcrun
  require_command shasum
  require_command ditto

  gh auth status >/dev/null

  local identity
  identity="$(developer_id_identity)"
  if [[ -z "$identity" ]]; then
    echo "No Developer ID Application certificate found. Install one or set PREVDOCK_SIGNING_IDENTITY." >&2
    exit 1
  fi

  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --limit 1 >/dev/null 2>&1; then
    echo "No usable notarytool profile named '$NOTARY_PROFILE'. Run:" >&2
    echo "xcrun notarytool store-credentials $NOTARY_PROFILE" >&2
    exit 1
  fi

  export PREVDOCK_SIGNING_IDENTITY="$identity"
}

release_notes_file() {
  local version="$1"
  local notes="$ROOT_DIR/docs/release-notes/v$version.md"
  if [[ -f "$notes" ]]; then
    echo "$notes"
    return
  fi

  mkdir -p "$(dirname "$notes")"
  {
    echo "# prevDock $version Preview"
    echo
    echo "Preview release for prevDock."
  } >"$notes"
  echo "$notes"
}

build_notarized_zip() {
  local version="$1"
  local app_dir
  local release_dir="$ROOT_DIR/build/release"
  local notarization_zip="$release_dir/prevDock-$version-notarization.zip"
  local final_zip="$release_dir/prevDock-$version-arm64.zip"

  app_dir="$("$ROOT_DIR/scripts/build.sh")"

  rm -rf "$release_dir"
  mkdir -p "$release_dir"
  ditto -c -k --keepParent "$app_dir" "$notarization_zip"
  xcrun notarytool submit "$notarization_zip" --keychain-profile "$NOTARY_PROFILE" --wait >&2
  xcrun stapler staple "$app_dir" >&2
  xcrun stapler validate "$app_dir" >&2
  ditto -c -k --keepParent "$app_dir" "$final_zip"
  echo "$final_zip"
}

sparkle_signature_attributes() {
  local zip_path="$1"
  if [[ ! -x "$SPARKLE_SIGN_UPDATE" ]]; then
    echo "Sparkle sign_update tool not found. Run scripts/build.sh first." >&2
    exit 1
  fi
  "$SPARKLE_SIGN_UPDATE" "$zip_path"
}

write_appcast() {
  local version="$1"
  local zip_path="$2"
  local signature_attributes="$3"
  local pub_date
  pub_date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

  cat >"$APPCAST" <<APPCAST_XML
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>prevDock Updates</title>
    <description>Preview releases for prevDock.</description>
    <language>en</language>
    <item>
      <title>prevDock $version Preview</title>
      <pubDate>$pub_date</pubDate>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$GH_REPO/releases/tag/v$version</sparkle:releaseNotesLink>
      <enclosure
        url="https://github.com/$GH_REPO/releases/download/v$version/$(basename "$zip_path")"
        sparkle:version="$(plist_value :CFBundleVersion)"
        sparkle:shortVersionString="$version"
        $signature_attributes
        type="application/octet-stream"/>
    </item>
  </channel>
</rss>
APPCAST_XML
}

ensure_github_repo() {
  if gh repo view "$GH_REPO" >/dev/null 2>&1; then
    if ! git -C "$ROOT_DIR" remote get-url origin >/dev/null 2>&1; then
      git -C "$ROOT_DIR" remote add origin "https://github.com/$GH_REPO.git"
    fi
    return
  fi

  gh repo create "$GH_REPO" --public --source "$ROOT_DIR" --remote origin
}

publish_github_release() {
  local version="$1"
  local zip_path="$2"
  local notes="$3"

  ensure_github_repo
  git -C "$ROOT_DIR" push -u origin main
  git -C "$ROOT_DIR" push origin "v$version"
  gh release create "v$version" "$zip_path" \
    --repo "$GH_REPO" \
    --title "prevDock $version Preview" \
    --notes-file "$notes" \
    --prerelease
}

ensure_tap_repo() {
  if [[ -d "$TAP_DIR/.git" ]]; then
    git -C "$TAP_DIR" config user.name "bambou932"
    git -C "$TAP_DIR" config user.email "bambou932@gmail.com"
    return
  fi

  if gh repo view "$TAP_REPO" >/dev/null 2>&1; then
    gh repo clone "$TAP_REPO" "$TAP_DIR"
    git -C "$TAP_DIR" config user.name "bambou932"
    git -C "$TAP_DIR" config user.email "bambou932@gmail.com"
    return
  fi

  mkdir -p "$TAP_DIR"
  git -C "$TAP_DIR" init -b main
  git -C "$TAP_DIR" config user.name "bambou932"
  git -C "$TAP_DIR" config user.email "bambou932@gmail.com"
  gh repo create "$TAP_REPO" --public --source "$TAP_DIR" --remote origin
}

write_cask() {
  local version="$1"
  local sha256="$2"

  ensure_tap_repo
  mkdir -p "$TAP_DIR/Casks"
  cat >"$TAP_DIR/Casks/prevdock.rb" <<CASK
cask "prevdock" do
  version "$version"
  sha256 "$sha256"

  url "https://github.com/bambou932/prevDock/releases/download/v#{version}/prevDock-#{version}-arm64.zip",
      verified: "github.com/bambou932/prevDock/"
  name "prevDock"
  desc "Dock hover window previews for macOS"
  homepage "https://github.com/bambou932/prevDock"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "prevDock.app"

  uninstall quit: "io.github.bambou932.prevDock"

  zap trash: [
    "~/Library/Preferences/io.github.bambou932.prevDock.plist",
  ]
end
CASK

  git -C "$TAP_DIR" add Casks/prevdock.rb
  if ! git -C "$TAP_DIR" diff --cached --quiet; then
    git -C "$TAP_DIR" commit -m "Update prevDock to $version"
  fi
  git -C "$TAP_DIR" push -u origin main
}

main() {
  local version="${1:-}"
  [[ -n "$version" ]] || usage
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage

  cd "$ROOT_DIR"
  ensure_clean_tree
  ensure_release_prerequisites

  local current_version current_build build
  current_version="$(plist_value :CFBundleShortVersionString)"
  current_build="$(plist_value :CFBundleVersion)"
  build="${2:-}"
  if [[ -z "$build" ]]; then
    if [[ "$version" == "$current_version" ]]; then
      build="$current_build"
    else
      build="$((current_build + 1))"
    fi
  fi

  set_plist_value :CFBundleShortVersionString "$version"
  set_plist_value :CFBundleVersion "$build"

  local notes zip_path signature sha256
  notes="$(release_notes_file "$version")"
  zip_path="$(build_notarized_zip "$version")"
  signature="$(sparkle_signature_attributes "$zip_path")"
  sha256="$(shasum -a 256 "$zip_path" | awk '{print $1}')"
  write_appcast "$version" "$zip_path" "$signature"

  git add "$INFO_PLIST" "$APPCAST" "$notes"
  git commit -m "Release v$version"
  git tag -a "v$version" -m "prevDock $version"
  publish_github_release "$version" "$zip_path" "$notes"
  write_cask "$version" "$sha256"
}

main "$@"
