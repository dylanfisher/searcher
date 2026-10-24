# 0074. Queue bench: W8 to a disk image in the CI run's first launch, copy rate held to S7

- **Date:** 2026-10-23
- **Status:** accepted

## Context

M4.12 asks the UI bench to copy W8 (10 GB: 4 × 2 GB plus 20,000 files of ~100 KB) through the
queue with the operations panel open, and to time 500 ↓ presses on W2 while it runs (B6) and every
main-thread stall from the copy's start to its end (B10, "never > 50 ms"). It also asks for a 1 GB
copy through `FileCopier` on a disk image, in MB/s against spike S7, a 2 GB W8 for CI, and a
free-space check before anything is written. Copies within one APFS volume clone
([0058](0058-copy-engine.md)), so the copy has to cross volumes. `Budget.swift` holds the budget
table's numbers alone, in ms and MB, and the UI bench reports stalls without judging them outside
`column-walk` ([0022](0022-ui-bench-mode.md), [0050](0050-ui-bench-scenarios.md)).

## Decision

- **The image belongs to scripts/bench.** For the harness run and the `--ui` CI run, it asks the
  runner (`--disk-image-size`) how large an image the run needs, then creates a sparse APFS image
  in `$TMPDIR`, attaches it with `-nobrowse` at a folder beside it, never under /Volumes, and
  passes the mount point as `--image`. An EXIT trap, reached from INT and TERM too, detaches it,
  trying five times a second apart, and removes its folder, failed run or not, but never while
  the mount table lists anything under the folder. A run first removes earlier runs' image
  folders whose image is detached and names those still attached, with the command to detach.
- **Free space first.** `DiskImagePlan` counts the source fixture's bytes, 0 when it is built,
  plus the image's: the bytes copied and 512 MB for APFS. Both sit on `$TMPDIR`'s volume, so the
  sum is checked against its free bytes, and a shortfall exits before the image is made or the
  fixture written, naming each number.
- **W8 is a fixture with real bytes.** W1–W3 stay sparse. W8, its CI variant (`--w8-2gb`, a fifth
  of each count and size: 4 × 400 MB plus 4,000 small files, about 2 GB) and the 1 GB copy
  source are filled with a 1 MiB block made from the seed, and are built only by the runs that
  copy them.
- **In the CI run's first launch, after the filter keys.** The panel opens with Cmd-Opt-L, the
  copy is queued, and the presses start once a snapshot shows it running. They stop when the main
  thread learns the copy finished, so no later stall is filed under a press, and the presses
  whose frame came before that are the B6 case. Fewer than a tenth of the 500, 50, fails the
  run. The copy is a span from the call that queues it to then, and its presses are spans inside it, so a stall in either is
  filed under the copy. The copy's longest stall, or 0, is one B10 case, so it is judged like the
  other UI cases, `compare-ui` included, and passes only with no stall. The panel closes after, so
  the column and split cases keep the window's full height.
- **The copy case is held to a floor.** `CopyFloor.s7` is S7's lower rate for `copyfile` with
  the engine's flags on a 2 GiB file to an image, 792 MB/s. The case's samples are milliseconds
  per 1 GB; it fails when the rate at its median time is under the floor, and the p95 rate is
  printed for information. S7's 792 is the median of 5 runs and runs to an image swing about 2×,
  so a p95 against a median always failed; the floor is judged like with like. `compare` and
  `bench.json` use the same `overBudget` flag. Ten runs, with
  one untimed warm-up copy first so the source is in the page cache, and after each run the copy
  is removed and the image flushed with `F_FULLFSYNC`, untimed: without that the previous run's
  dirty pages and freed space compete with the next 1 GB write. The timed region is the
  `FileCopier` call alone. On CI (`CI`
  set) the rate and the floor are printed and the case is reported only: the hosted runners copy
  to virtualised disks at a rate no run has shown yet. Enforce it on CI once a few runs show
  the real rate there.

## Alternatives considered

- **A `--scenario` for the copy** — rejected: CI would need a second record and history, as 0050
  found for column keys, and the plan asks for `./scripts/bench --ui` to run it.
- **The runner or the app makes the image** — rejected: the plan puts it in scripts/bench, and a
  trap there still detaches it when the runner crashes.
- **Keep all 500 presses whatever the copy does** — rejected: presses after the copy ends don't
  time B6 under a copy, and their stalls would be filed under the copy. The count kept is
  printed.
- **A budget unit in MB/s** — not possible without editing `Budget.swift`, which holds only the
  table's budgets.
- **The floor at S7's 3-run rate, 1197 MB/s** — rejected: runs to an image swing about 2×, and the
  5-run pass measured 792.

## Consequences

`./scripts/bench` now needs about 2.5 GB free in `$TMPDIR` the first time (1 GB source, 1.5 GB
image), and `--ui` about 20.5 GB for W8 (10 GB source, 10.5 GB image), 10.5 GB once W8 is built;
`--ui --w8-2gb` about 4.5 GB. W8 takes 10 GB of `$TMPDIR` until removed by hand. The first UI
launch now includes the whole copy, which must fit in its 120 s launch timeout. On a machine whose
copy finishes before many of the 500 presses, as the 2 GB variant may in CI, the B6 case has fewer
samples, and one that leaves fewer than 50 fails the run. A killed bench (SIGKILL) leaves its
image attached; the next run names it. A run that starts while another is between making its
image folder and attaching the image can remove that folder. The floor may prove tight on CI's
disks; lowering it is a change to `CopyFloor.s7`.
