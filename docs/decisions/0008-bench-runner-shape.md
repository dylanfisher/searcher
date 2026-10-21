# 0008. Nearest-rank statistics and per-workload budget IDs in the bench runner

- **Date:** 2026-10-20
- **Status:** accepted

## Context

The bench runner (decision 0002) checks the p95 of 20 runs against the budgets in
[performance.md](../performance.md). Two budgets, B2 and B5, have one number per workload, and
scripts need to ask for one number by ID (`Bench --print-budget B10`). The runner's logic has to be
testable with `swift test`, but it ships as an executable target.

## Decision

Median and p95 are nearest-rank: the value at rank ⌈p × n / 100⌉ of the sorted runs, so every
reported number is a time that was measured. A budget with one number per workload gets one ID per
workload, `B2.W1` and `B2.W2`; asking for `B2` alone fails and lists the known IDs. Argument parsing
lives in `BenchArguments` beside `main.swift`, and `BenchTests` imports the `Bench` executable
with `@testable` instead of splitting it into a library and a thin executable.

## Alternatives considered

- **Interpolated percentiles and a two-middle median** — rejected because they report times no run
  took, and with 20 runs the p95 would blend the two slowest.
- **One ID per row with a list of numbers** — rejected because `--print-budget` has to print one
  number, and a caller would need to know the workload order.
- **A separate `BenchKit` library target** — rejected as an extra target and map row for code only
  the runner uses; SwiftPM tests executable targets directly on macOS.

## Consequences

A new per-workload budget in performance.md needs a matching `Bn.Wm` entry in `Budget.swift`;
`BudgetTests` names the mismatch. If the runner ever needs to run on Linux CI, check that
`@testable import` of an executable still works there.

## Amendment: runs per case (M0.18)

A case may set its own run count; the default stays 20. The two idle cases (CPU over 5 s with and
without the watchdog) run 5 times each, because 20 runs of both took 200 s and the full bench
passed 10 minutes. Their p95 over 5 runs is the slowest run, so they are reported, never budgeted.
