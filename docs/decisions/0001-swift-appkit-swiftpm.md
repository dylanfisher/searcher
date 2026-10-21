# 0001. Swift and AppKit, built with SwiftPM only

- **Date:** 2026-10-20
- **Status:** accepted

## Context

Searcher is a Finder replacement for power users: multiple windows, tiling layouts, and a
dual-pane mode, with speed as the main requirement. It ships by direct download, not the Mac App
Store, because a sandboxed file manager can't browse the disk without per-folder grants. Minimum
target is macOS 14. The development machine has Command Line Tools only, not full Xcode.

## Decision

Swift 6 with AppKit for the core UI and SwiftUI only for peripheral UI. Plain C targets are added
for hot paths once a benchmark shows the win. The project is a SwiftPM package with no
`.xcodeproj`; tiers are SwiftPM targets, so the build enforces dependency direction.

## Alternatives considered

- **All SwiftUI** — rejected because `List`/`Table` lag behind `NSTableView` on very large
  directories, and custom split/tiling layouts and key handling need AppKit anyway.
- **Committed `.xcodeproj`** — rejected because agents edit `project.pbxproj` badly and it causes
  merge conflicts; it also requires full Xcode.
- **XcodeGen or Tuist** — rejected for now as a new dependency that buys little until we need
  asset catalogs or extensions.
- **XCTest** — rejected in favor of Swift Testing, which ships with the toolchain.
- **SwiftLint** — not added; `swift format lint` ships with the toolchain and covers style. Revisit
  if we need rules it lacks.

## Consequences

- The `.app` bundle has to be assembled by a script. `scripts/bundle` builds and signs it;
  notarization is not set up yet.
- Under Command Line Tools, a cold `swift test` can't find the Swift Testing macro plugin.
  `scripts/test` passes `-plugin-path` explicitly when the plugin directory exists. Remove that
  once a toolchain release fixes it.
- `-warnings-as-errors` is an unsafe flag, so this package can't be used as a dependency of
  another package. It is an app, so that doesn't matter.
