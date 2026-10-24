# 0083. Keep test runs from beeping

- **Date:** 2026-10-24
- **Status:** accepted

## Context

Test runs played the Mac's alert sound. Finding the callers with lldb (a breakpoint on `NSBeep`
and `AudioServicesPlayAlertSound` in `swiftpm-testing-helper`) showed that none came from the app's
injectable `beep` closures. All of them were AppKit's own beep for a key nobody handled:

- Tab and Shift-Space sent to a table that sits in no window. `NSControl.keyDown` forwards the key
  up the responder chain, finds nothing and beeps.
- Cmd-A sent straight to a field editor. With no main menu to take the key first, the editor passes
  the command to its window, which beeps.
- Cmd-Opt-Shift-T, which no command takes, so the table's own `beep` ran for real.

## Decision

Tests that pass keys on to AppKit use `KeyCatchingWindow`, which records what reaches the end of the
responder chain where a real window beeps. The test with an unbound key injects a `beep` that counts.

A guard fails any test that still plays the alert sound. `Sources/BeepInterpose` is a dylib that
replaces `NSBeep` and `AudioServicesPlayAlertSound` (dyld interposing). Its replacements play
nothing and call a reporter that `TestSupport` registers when a test bundle loads; the reporter
records a Swift Testing issue with the call stack, so it fails the test that beeped, serial or
parallel, with no window or focus involved. `scripts/test` builds the dylib and inserts it with
`DYLD_INSERT_LIBRARIES`, on the `swift test` calls only. A test bundle run without it (a bare
`swift test`) prints a warning, and `BeepGuardTests` fails: that test beeps inside
`withKnownIssue`, so it is the real signal that the guard is off. A beep outside a test's task is
reported against «unknown» but still fails the run, with the first frames of its stack.

CI (GitHub macOS runners, Xcode toolchain) is unverified until its first run: the dylib's
experimental flags and the `DYLD_INSERT_LIBRARIES` path there have not been tried.

## Alternatives considered

- **Interpose from the test bundle**, with a `__DATA,__interpose` section or
  `dyld_dynamic_interpose`. Rejected: dyld applies a section only to images loaded at launch, and
  the dynamic call changed nothing for AppKit's calls. Tried both; the beep still played.
- **`dlopen` the dylib from the bundle.** Rejected for the same reason: loaded late, not applied.
- **Swizzle `NSSound.beep`.** Rejected: Swift calls the C function `NSBeep` directly, so there is
  no method to swizzle, and AppKit's own beeps never go through it.
- **One shared seam for the app's `beep` closures.** Not needed: Quick Look beeps through the
  table's closure, which leaves two declarations (`ListingTableView`, `GoToFolderSheet`). The
  third occurrence is the point to share them.

## Consequences

The guard needs `./scripts/test` (and so `./scripts/check`); a bare `swift test` plays beeps again.
`scripts/test` runs the toolchain's `swift` and not `/usr/bin/swift`, because the system shim
drops `DYLD_*` variables. The dylib is a test-only target, built with two experimental flags
(`SymbolLinkageMarkers`, `Extern`) that never reach the app.
