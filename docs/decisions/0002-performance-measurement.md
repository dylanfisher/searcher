# 0002. Measure performance budgets with an in-house release harness and in-app timing

- **Date:** 2026-10-20
- **Status:** accepted

## Context

Speed is the main requirement, so every interaction has a budget (B1–B11 in
[performance.md](../performance.md)). The development machine has Command Line Tools only
(decision 0001), so Instruments and `xctrace` are not available. `swift test` builds in debug mode, where timings are several times off. CI can't
reach Dylan's NAS.

## Decision

Non-UI budgets run in a small in-house benchmark harness built in release mode, on generated
workloads, reporting median and p95. UI budgets are timed by the app itself in a bench mode, and a
main-thread watchdog logs stalls over 50 ms. CI fails when a harness p95 exceeds its budget.
The UI bench reports only until its p95s stay within 10% across three consecutive CI runs, then
fails the same way, because frame timing on shared CI runners is noisier than listing time.

## Alternatives considered

- **`xctrace` and Instruments** — rejected because they need full Xcode, which slows the agent
  loop and CI setup for little gain over in-app timing. Revisit if a spike needs deep profiling.
- **package-benchmark** — rejected as a new dependency; the harness needed is small.
- **Timings inside Swift Testing** — rejected because debug builds give misleading numbers.
- **Fail on any slowdown against `main`** — rejected because CI runner noise would cause false
  failures; slowdowns within budget are reported only.

## Consequences

Budgets are checked on every CI run without extra tools. SMB and external-disk numbers are only
checked by hand at milestones. In-app timing has to be built in Milestone 0, before features.
