#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/release.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
TAP_DIR="$TEST_DIR/tap"
mkdir -p "$TAP_DIR/.git"
TEST_BRANCH="main"
TEST_TAG_STATUS=1
TEST_STATUS=""
SWIFT_TARGET_ARCH="arm64"
DEPLOYMENT_TARGET="$(plist_value :LSMinimumSystemVersion)"

# No test command can create commits, tags, repositories, or publish a release.
git() {
  case "${3:-}" in
    symbolic-ref) printf '%s\n' "$TEST_BRANCH" ;;
    show-ref) return "$TEST_TAG_STATUS" ;;
    status) printf '%s' "$TEST_STATUS" ;;
    add|diff|push) return 0 ;;
    *) echo "Unexpected git operation: $*" >&2; exit 99 ;;
  esac
}

gh() { echo "Unexpected GitHub operation: $*" >&2; exit 99; }

expect_failure() {
  local expected="$1"
  shift
  local status=0
  ( "$@" ) >"$TEST_DIR/output" 2>&1 || status="$?"
  if [[ "$status" != "$expected" ]]; then
    cat "$TEST_DIR/output" >&2
    echo "Expected status $expected, got $status for $*" >&2
    exit 1
  fi
}

ensure_release_state "0.2.0"
TEST_BRANCH="fix/example"
expect_failure 1 ensure_release_state "0.2.0"
TEST_BRANCH=""
expect_failure 1 ensure_release_state "0.2.0"
TEST_BRANCH="main"
TEST_TAG_STATUS=0
expect_failure 1 ensure_release_state "0.2.0"
TEST_TAG_STATUS=1
SWIFT_TARGET_ARCH="x86_64"
expect_failure 1 ensure_release_state "0.2.0"
SWIFT_TARGET_ARCH="arm64"
DEPLOYMENT_TARGET="99.0"
expect_failure 1 ensure_release_state "0.2.0"
DEPLOYMENT_TARGET="$(plist_value :LSMinimumSystemVersion)"

expect_failure 64 main "01.2.3"
expect_failure 64 main "1.2.3" "invalid"
expect_failure 64 main "1.2.3" "1" "extra"
ensure_tap_repo
TEST_STATUS=" M user-change"
expect_failure 1 write_cask "0.2.0" "test-checksum"
[[ ! -f "$TAP_DIR/Casks/prevdock.rb" ]]
TEST_STATUS=""
TEST_BRANCH="feature/user-work"
expect_failure 1 write_cask "0.2.0" "test-checksum"
[[ ! -f "$TAP_DIR/Casks/prevdock.rb" ]]
TEST_BRANCH="main"

GH_REPO="example/preview-app"
NOTARIZE=0
write_cask "0.2.0" "test-checksum"
grep -Fq 'https://github.com/example/preview-app/releases/download/' "$TAP_DIR/Casks/prevdock.rb"
grep -Fq 'homepage "https://github.com/example/preview-app"' "$TAP_DIR/Casks/prevdock.rb"
grep -Fq 'not Apple-notarized' "$TAP_DIR/Casks/prevdock.rb"
NOTARIZE=1
write_cask "0.2.0" "test-checksum"
if grep -Fq 'not Apple-notarized' "$TAP_DIR/Casks/prevdock.rb"; then
  echo "Notarized releases must not display unnotarized caveats" >&2
  exit 1
fi

echo "Release workflow tests passed"
