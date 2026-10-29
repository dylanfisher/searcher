# 0134. Link the app against the current SDK

- **Date:** 2026-10-28
- **Status:** accepted
- **Amends:** [0092](0092-native-build-system.md) (the build's environment)

## Context

After [0133](0133-flat-translucent-bars.md), Dylan, 2026-10-28: "did you try adding the
translucent effect to the header and breadcrumb area? i don't see it". His screenshot
(`tmp/shots/fb-1028c-1.jpg`) shows an opaque white toolbar, an opaque list header with a row cut
off under it, and an opaque path bar row. It also shows no Liquid Glass anywhere: Back and
Forward sit in no capsule and the sidebar doesn't float, unlike Finder's window on the same Mac
(`tmp/shots/fb-1028b-2.jpg`).

`vtool -show-build` on the app's executable read `minos 14.0, sdk 14.0`, though the SDK in use is
27.0. AppKit gives an app the look of the SDK it was linked against, so Searcher ran as a
macOS 14 app: no glass, no scroll edge effects, opaque bars. The test runner,
`swiftpm-testing-helper`, is linked against SDK 27, so the tests saw the macOS 26 look and passed.

The cause: `scripts/gentle` runs the toolchain's `swift` directly, not through `xcrun`, since
0092. The link step passes the SDK to clang as `--sysroot`, and clang reads the SDK's version for
the linker's `-platform_version` only from `-isysroot` or `SDKROOT`. With neither, it records the
deployment target as the SDK version. `xcrun` sets `SDKROOT`, which is why a link run through
`xcrun swiftc` records 27.0.

## Decision

- **`scripts/gentle` exports `SDKROOT`** as `xcrun --show-sdk-path`, so every build, test run and
  bundle links against the SDK it compiles with.
- **`scripts/bundle` checks the executable's SDK** against `xcrun --show-sdk-version`. A change to
  the environment alone doesn't relink, so an executable linked before this change is removed and
  linked again; one still linked against another SDK after that fails the bundle, and with it
  `scripts/check`.

## Alternatives considered

- **Pass `-Xlinker -platform_version`** with the versions spelled out — rejected: it repeats the
  deployment target from `Package.swift` and the SDK version from the SDK.
- **Run `swift` through `xcrun`** — rejected: 0092 found the toolchain choice already fragile, and
  `SDKROOT` is the one variable the link needs.

## Consequences

- Searcher draws with the macOS 26 look it was designed for in 0128, 0132 and 0133: the
  toolbar's glass, the floating sidebar and the scroll edge effects under the toolbar and over
  the status bar.
- A view dump of a list in a test window, linked against SDK 27, shows what the system builds:
  a hard scroll edge effect (`NSHardPocketView`) over the toolbar and the column header together,
  and another under the status bar. The style of the header's effect has no public setting;
  `preferredScrollEdgeEffectStyle` (macOS 26.1) is on split view item and title bar accessories
  only. The look of the bars still needs a check by hand: screen capture was refused to the agent
  that found this.
