# 0084. Gentle mode throttles the build, not the test run

- **Date:** 2026-10-24
- **Status:** accepted

## Context

Running `./scripts/check` uses every core for a minute or more, which makes the machine hard to
use meanwhile. macOS cannot pin a process to N cores, so the options are fewer parallel jobs and a
lower scheduling priority. The machine has 18 logical cores (6 performance, 12 efficiency).

## Decision

`--gentle` (first argument of `check` or `test`) or `SEARCHER_GENTLE=1` runs `swift build` with
`--jobs` set to half the logical CPUs, under `taskpolicy -c utility`. The test run is unchanged.
`test` builds the tests first in that mode, so the build part of a test run is gentle too.

## Alternatives measured

Each was tried on the full test step; the failures repeated unless noted.

- `taskpolicy -c utility` on the test run: `walksRunOnBlockingCallThreadsWithThrottledDiskReadsAtUtilityPriority`
  failed 3 of 3 runs. It compares a utility thread's priority with a default-QoS thread's, and under
  the policy the process default drops to utility too.
- `taskpolicy -c background` (efficiency cores, throttled I/O): the same test failed, plus
  `busyBlockIsReportedOnceWithItsStack`. The parallel test phase took 50 s against 26 s.
- `nice -n 10` on the test run: `throttlingDiskReadsKeepsTheThreadsPriority` and
  `footprintGrowsWithTouchedMemory` failed.
- Capping Swift Testing with `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=9`:
  `aLocalChangeEventUnderAFolderDropsItsSize` failed in 2 of 4 runs and `footprintGrowsWithTouchedMemory`
  in 2 of 4. `swift test --num-workers` does not apply to Swift Testing.

## Measurements

Full `./scripts/check`, other builds running on the machine, so only roughly comparable:

- Normal: 3:53 cold, 1:52 and 1:12 warm.
- Gentle: 2:51, 3:18, 1:26 and 2:18, all passing.
- Peak CPU busy, sampled with `top`: about 100% normal, about 70% gentle (the unthrottled test
  phase). The build phase alone sampled near 22%.

## Consequences

The test phase still uses all cores. Lowering that needs tests that do not compare thread
priorities or rely on timing under load.
