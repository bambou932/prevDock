# prevDock Agent Guide

This repository is a pure Swift 5 AppKit app. Build and test from the command line with `./scripts/build.sh`; do not open or rely on Xcode, Interface Builder, storyboards, XIBs, or SwiftUI.

## Source Layout

- `Sources/prevDock/App`: app lifecycle, menu bar entry, permission prompts.
- `Sources/prevDock/Dock`: Dock hit testing, label suppression, inactive-app labels, running-app matching.
- `Sources/prevDock/Preview`: preview panels, preview cards, live thumbnail cadence, hover peek UI.
- `Sources/prevDock/Settings`: user defaults and AppKit settings UI.
- `Sources/prevDock/Windowing`: window inventory, capture, focus, close, and SkyLight bridges.
- `Sources/prevDock/Support`: shared helpers that several features depend on.

Keep files near the feature that changes with them. Add a new folder only when a feature has its own lifecycle and likely changes independently.

## Coding Rules

- Keep methods compact. If a method needs blank-line-separated statement groups, split those groups into named sub-methods.
- Prefer guard clauses so the golden path stays unindented and easy to scan.
- Use comments sparingly for non-obvious behavior, private APIs, timing, or performance constraints. Do not comment simple assignments or obvious AppKit setup.
- Reuse AppKit objects where practical, coalesce capture work, and avoid broad polling or I/O on the main thread.
- Preserve low latency around Dock hover, thumbnail refresh, and window focusing paths.

## Git Workflow Rules

- Run `git status --short --branch` before editing files.
- Never make ordinary commits directly on `main` or `master`.
- Do work on purpose-named branches using one of these prefixes:
  - `feature/`
  - `fix/`
  - `hotfix/`
  - `release/`
  - `chore/`
  - `docs/`
  - `refactor/`
  - `test/`
  - `perf/`
- Do not put the tool or author name in the branch prefix. Use `feature/settings-polish`, not `codex/feature-settings-polish`.
- Keep branch descriptions lowercase and hyphen-separated, with dots only where useful for versions, such as `release/v0.2.0`.
- Do not commit unless the user explicitly asks for a commit.
- Stage only files related to the current task. Never stage unrelated user changes.
- Commit messages are free-form, but must not start with an author or tool prefix such as `Codex:`, `ChatGPT:`, `Assistant:`, `Agent:`, or the configured `git user.name`.
- Before every commit, run `./scripts/build.sh`. If the build fails, do not commit.
- Keep `main` buildable at all times. Changes should reach `main` through pull requests with the `build` check passing.
- Merge pull requests into `main` with merge commits. Do not use squash merge or rebase merge unless the user explicitly asks for that exception.
- Tags are release markers only. Create annotated SemVer tags like `v0.1.0` only after a successful build on `main`.
- Use the repository Git author config. Do not override the author as Codex, ChatGPT, OpenAI, or any bot identity.
