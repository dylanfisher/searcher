# 0064. Run the interface tests one at a time

- **Date:** 2026-10-22
- **Status:** accepted

## Context

About 280 `@MainActor` tests in `InterfaceTests` share one main thread. SwiftPM runs them in
parallel, so each test's settle wait (the 5 s deadlines in `Sources/TestSupport/Settle.swift`)
also counts time spent waiting for other tests' main-thread work. Under load (a game running,
other builds) a different test missed its deadline on each run.

## Decision

`scripts/test` runs everything except `InterfaceTests` in parallel, then runs `InterfaceTests`
with `--no-parallel`. A focused run (any arguments) is a single call. A failure in either fails the script.

## Alternatives considered

- **Longer settle deadlines** — rejected: hides slow tests and still fails under heavier load.
- **Serial for the whole suite** — rejected: the other targets gain nothing from it and lose
  their parallel speed.

## Consequences

Measured with `--no-parallel` on `InterfaceTests` alone under 8 CPU burners: 3 of 3 runs passed
in 28 to 32 s. Parallel took about 12 s unloaded, so the test step costs about 18 s more. The
folder-size tests that wait on timed chains should move to event-driven waits later, which would
let the target go back to parallel.
