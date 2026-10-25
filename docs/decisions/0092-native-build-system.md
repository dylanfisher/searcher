# 0092. Build with the native build system; run only the tests a change needs

- **Date:** 2026-10-24
- **Status:** accepted

## Context

A `./scripts/check` on an unchanged tree took about 30 s, and a test run after a one-line edit
often took over 20 s of building. Two causes, measured with Swift 6.4 from Command Line Tools:

- **swiftbuild rebuilds every module on about half of all runs.** SwiftPM writes the toolchain
  into each build request as `TOOLCHAINS`, and with Command Line Tools it picks
  `org.swift.CommandLineTools` or `com.apple.dt.toolchain.XcodeDefault` at random. Each switch is
  a new build description, and all 13 modules recompile (about 20 s for the test build, 6 s for
  `swift build`). Back-to-back `swift build --build-tests` runs with nothing changed took 0.4 s
  or 21 s at roughly even odds. The `TOOLCHAINS` environment variable, `--toolchain` with the
  Command Line Tools path, and `--toolchain` through a symlink all left it random.
- **The steps of check built with different flags.** `typecheck` and `bundle` built without the
  testing plugin path that `test` passes, so each run of check rebuilt between them.

The suite itself takes about 90 s (19 s parallel, 70 s for the serial interface tests).

## Decision

- **`--build-system native`, with one set of flags for every build and test**, defined in
  `swift_cmd` in `scripts/gentle` and used by check, test, bundle and bench. The native system
  adds the Testing framework only to test targets, and `TestSupport` imports it too, so the
  flags add its folder (`-F` and an rpath). Measured: a no-op `swift test` or build takes 0.5 to
  1 s on every run, and a test run after editing one Interface file takes 1.7 s to build.
  SwiftPM prints a deprecation warning for it on every call; `swift_cmd` drops that one line.
- **A passing whole run is recorded.** `scripts/test` keys it on a git tree of `Package.swift`,
  `Sources`, `Tests` and the two test scripts as they are on disk (untracked files included),
  plus `swift --version`, and skips the next whole run with the same key. A check with nothing
  changed took 4.8 s. `SEARCHER_RETEST=1` runs it anyway.
- **`scripts/test --changed [ref]` runs only the tests for the files changed since ref**
  (default `HEAD`, plus uncommitted and untracked files). A test file runs its own `@Test`
  functions; a source file runs its mirror in `Tests` (map.md, Naming), or its whole test target
  when it has none. `TestSupport`, `BrowserTestSupport`, `BeepInterpose`, `Package.swift` and the
  test scripts run the whole suite. Docs and the app target run nothing. Swift Testing names a
  free function `<target>.<name>()`, without its file, so the script reads the function names
  from the file; over the whole suite the names it reads match `swift test list` exactly
  (1,805).

## Alternatives considered

- **Keep swiftbuild and unify only the flags** — rejected: the random toolchain ID still
  rebuilds everything on half of all runs.
- **Run the tests of every target that depends on a changed module** — rejected for
  `--changed`: a Base edit would run most of the suite. Check runs the whole suite once at the
  end, which catches what the narrow run misses.

## Consequences

- The native build system is deprecated and may be removed from a later SwiftPM. Going back is
  one line in `scripts/gentle`, once swiftbuild picks the toolchain deterministically.
- Native builds go to `.build/arm64-apple-macosx`, not `.build/out`; the first run after this
  change is a cold build.
- A test that passed once on a key is not rerun for that key, so a flaky test shows up only when
  the inputs change or with `SEARCHER_RETEST=1`.
- CI selects Xcode, where the Testing framework sits in the platform folder. `scripts/gentle`
  reads that path from `xcrun`.
