# 0016. Sparse seeded fixtures and a `top` sample for machine load

- **Date:** 2026-10-20
- **Status:** accepted

## Context

The bench runner (decision 0008) needs the generated workloads W1–W3 from
[performance.md](../performance.md) to repeat across runs and machines, without costing minutes or
gigabytes each run. It also has to record what else was using the CPU, because the spikes showed a
busy machine moves the numbers (S4 had to be rerun on an idle machine).

## Decision

Fixtures are generated from a SplitMix64 generator with its own range helper, so the names don't
depend on how the standard library maps a random number into a range. Each entry's path, size and
modification date (spread over 2022–2025, so a date sort doesn't fall through to the name) come
from the seed. Files are made with `ftruncate`, so they report their sizes (about 238 GB in all) but
take almost no disk blocks.

A fixture lives at `$TMPDIR/searcher-bench/<workload>-<seed>-<digest>`, where the digest is 8 hex
digits of FNV-1a over the whole entry list. A change to the generator gives a new name, so it builds
a new fixture instead of timing the old shape. Before building, the runner removes every other
`<workload>-<seed>-*` folder and every partial folder for that workload and seed. A build goes
into a hidden partial folder in the same parent and is renamed into place, so a build killed before
the rename never sits at the final path.
`.metadata_never_index` is the first entry of every fixture and is not counted in the workload, so
W2 holds 100,001 entries.

Machine load comes from `top -l 2 -s 1 -o cpu -stats pid,cpu,command`, reading the second sample
only, because the first sample's CPU column is not a rate. The runner and `top` itself are left
out. A busy machine is warned about and recorded in `.build/bench.json`; only `--check-idle` fails.

Unit tests build only W1 on disk. W2 and W3 are checked on their entry lists, which go through the
same writer, because building them on disk in a debug test run added 16 s to a 3 s suite.

## Alternatives considered

- **Files with real contents** — rejected: W2 alone would be about 250 GB of writes. Listing and
  sorting read only metadata, which sparse files report the same way.
- **`Int.random(in:using:)`** — rejected because its algorithm is not part of the standard
  library's contract, and a change would rebuild every fixture with different names, so numbers
  from before and after wouldn't compare.
- **Reusing `<workload>-<seed>` whenever it exists** — rejected because a change to the generator
  would keep timing the old folder with no warning.
- **The build time as every modification date** — rejected because sorting W2 by date (B8) would
  compare equal dates and fall through to the name tiebreak.
- **`ps -o %cpu`** — rejected because it reports CPU averaged over the process lifetime, not over
  the last second.
- **`host_processor_info` or `proc_pid_rusage` sampling in-process** — rejected as more code for
  the same numbers `top` prints.

## Consequences

A fixture is reused for as long as `$TMPDIR` keeps it and its entry list is unchanged. A bench
case that changes a fixture (a watching or file-operation case) must build its own copy, or later
runs time a different folder. A tool that copies a fixture without keeping holes (a backup, `cp`
to another volume) writes the full apparent size. `top` cuts command names to 16 characters.
