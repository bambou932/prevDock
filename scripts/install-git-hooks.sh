#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

chmod +x "$ROOT_DIR/.githooks/pre-commit"
chmod +x "$ROOT_DIR/.githooks/commit-msg"
chmod +x "$ROOT_DIR/.githooks/pre-push"

git -C "$ROOT_DIR" config core.hooksPath .githooks

echo "Installed prevDock Git hooks from .githooks."
