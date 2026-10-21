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

## Amendment: comparing runs in CI (M0.16a)

`Bench compare <previous> <current>` reads two saved `bench.json` files, matches cases by name and
reports each case whose median is more than 10% above the previous median. The median is used, not
the p95: the p95 of 20 runs is the second slowest and, for the 5-run idle cases, the slowest, so a
single noisy run on a shared runner would trip it. The budget check keeps using the p95. A case
that is new, missing from this run or measured in a different unit is stated and not compared. A
missing or unreadable previous report is stated and the comparison is skipped. The comparison never
fails on a slowdown; the only failure is a case over its own budget, which `./scripts/bench`
already fails on.

CI keeps `.build/bench.json` as the `bench-report` artifact on every push, including a run that
failed on budget. The next run downloads the newest one from its own branch, else from `main`, with
the preinstalled `gh` CLI, so no third-party action is needed.
