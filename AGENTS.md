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

